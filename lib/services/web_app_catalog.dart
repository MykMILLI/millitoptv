import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'device_connection.dart';
import 'web_app_definition.dart';

abstract class ManagedWebAppSource {
  String get key;
  bool get allowed;
  Future<List<WebAppDefinition>> fetch();
}

class DeviceManagedWebApps implements ManagedWebAppSource {
  final link = DeviceConnection.instance;
  @override
  String get key => link.connectionKey;
  @override
  bool get allowed => link.isEnrolled && !link.isSuspended;
  @override
  Future<List<WebAppDefinition>> fetch() async {
    final expected = key;
    final result = await link.postDevice(
      '/api/device/web-apps',
      {},
      expectedConnection: expected,
    );
    if (expected != key || !allowed) {
      throw StateError('Device connection changed.');
    }
    if (result['protocol'] != 1 ||
        result['apps'] is! List ||
        (result['apps'] as List).length > 200) {
      throw const FormatException('Unsupported managed-app response.');
    }
    return (result['apps'] as List)
        .map(
          (v) => WebAppDefinition.fromJson(
            Map<String, dynamic>.from(v as Map),
            managed: true,
          ),
        )
        .toList();
  }
}

class WebAppCatalog extends ChangeNotifier {
  static final instance = WebAppCatalog();
  final ManagedWebAppSource source;
  List<WebAppDefinition> _managed = [];
  String _key = '';
  DateTime? _synced;
  Timer? _timer;
  bool _started = false, _disposed = false;
  Future<void>? _inFlight;
  bool lastSyncOk = false;
  Future<void> _writes = Future<void>.value();
  String syncStatus = 'Managed apps have not been checked.';
  WebAppCatalog({ManagedWebAppSource? source})
    : source = source ?? DeviceManagedWebApps();
  String _localKey(int profile) => 'webapps.local.v1.$profile';
  String _remoteKey(String key) =>
      'webapps.managed.v1.${sha256.convert(utf8.encode(key))}';
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    await DeviceConnection.instance.start();
    await sync();
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(sync()),
    );
  }

  Future<void> _readManagedCache() async {
    if (_key == source.key) {
      return;
    }
    _key = source.key;
    _managed = [];
    _synced = null;
    if (!source.allowed || _key.isEmpty) {
      return;
    }
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        _remoteKey(_key),
      );
      if (raw == null) {
        return;
      }
      final data = jsonDecode(raw) as Map;
      final time = DateTime.parse(data['fetched'] as String);
      final now = DateTime.now().toUtc();
      if (time.isAfter(now.add(const Duration(minutes: 5))) ||
          time.isBefore(now.subtract(const Duration(hours: 24)))) {
        return;
      }
      _managed = (data['apps'] as List)
          .map(
            (v) => WebAppDefinition.fromJson(
              Map<String, dynamic>.from(v as Map),
              managed: true,
            ),
          )
          .toList();
      _synced = time;
    } catch (_) {
      _managed = [];
    }
  }

  Future<void> sync() =>
      _inFlight ??= _doSync().whenComplete(() => _inFlight = null);
  Future<void> _doSync() async {
    if (_disposed) {
      return;
    }
    lastSyncOk = false;
    try {
      await _readManagedCache();
      if (!source.allowed || source.key.isEmpty) {
        _managed = [];
        syncStatus = 'Pair this device to receive managed apps.';
        return;
      }
      final expected = source.key;
      final apps = await source.fetch();
      if (_disposed || expected != source.key) {
        return;
      }
      lastSyncOk = true;
      _managed = apps;
      _synced = DateTime.now().toUtc();
      _key = expected;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _remoteKey(expected),
        jsonEncode({
          'fetched': _synced!.toIso8601String(),
          'apps': apps
              .map(
                (a) => {...a.toJson(), 'id': a.id.substring('managed:'.length)},
              )
              .toList(),
        }),
      );
      syncStatus = 'Managed apps synchronized.';
    } catch (_) {
      if (!source.allowed) {
        _managed = [];
      }
      syncStatus =
          'Managed apps could not be refreshed. Local apps remain available; cached managed apps expire after 24 hours.';
    } finally {
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<List<WebAppDefinition>> _overrides(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _localKey(profile),
    );
    if (raw == null) {
      return [];
    }
    final values = (jsonDecode(raw) as List)
        .map(
          (v) => WebAppDefinition.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .toList();
    if (values.any((a) => a.managed) ||
        values.map((a) => a.id).toSet().length != values.length) {
      throw const FormatException('Invalid local app list.');
    }
    return values;
  }

  Future<List<WebAppDefinition>> load(
    int profile, {
    bool includeHidden = false,
  }) async {
    await _readManagedCache();
    final overrides = await _overrides(profile);
    final local = <String, WebAppDefinition>{
      for (final a in builtinWebApps) a.id: a,
      for (final a in overrides) a.id: a,
    };
    final values = <WebAppDefinition>[
      ...local.values,
      if (source.allowed &&
          _key == source.key &&
          _synced != null &&
          DateTime.now().toUtc().difference(_synced!) <
              const Duration(hours: 24))
        ..._managed,
    ];
    return values.where((a) => includeHidden || a.enabled).toList();
  }

  Future<void> save(
    int profile, {
    String? id,
    required String title,
    required String url,
    String icon = 'web',
    bool enabled = true,
  }) async {
    final key = id ?? 'local:${const Uuid().v4()}';
    final app = WebAppDefinition.fromJson({
      'id': key,
      'title': title,
      'url': url,
      'icon': icon,
      'enabled': enabled,
      'revision': 1,
    });
    if (key.startsWith('managed:')) {
      throw StateError('Managed apps are edited in the dashboard.');
    }
    final next = _writes.catchError((Object _) {}).then<void>((_) async {
      final list = await _overrides(profile);
      list.removeWhere((a) => a.id == key);
      if (list.length >= 100) {
        throw StateError(
          'This profile already has 100 web-app customizations.',
        );
      }
      list.add(app);
      if (!await (await SharedPreferences.getInstance()).setString(
        _localKey(profile),
        jsonEncode(list.map((a) => a.toJson()).toList()),
      )) {
        throw StateError('Could not save app settings.');
      }
    });
    _writes = next;
    await next;
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> removeOrReset(int profile, WebAppDefinition app) async {
    if (app.managed) {
      throw StateError('Managed apps are edited in the dashboard.');
    }
    final next = _writes.catchError((Object _) {}).then<void>((_) async {
      final list = await _overrides(profile);
      list.removeWhere((v) => v.id == app.id);
      if (!await (await SharedPreferences.getInstance()).setString(
        _localKey(profile),
        jsonEncode(list.map((v) => v.toJson()).toList()),
      )) {
        throw StateError('Could not save settings.');
      }
    });
    _writes = next;
    await next;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
