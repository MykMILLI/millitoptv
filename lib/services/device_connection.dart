import 'billing_transport.dart';
import 'dart:async';
import 'app_log.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

class DeviceConnection {
  DeviceConnection._();
  static final instance = DeviceConnection._();

  static const _storageKey = 'millitop.tv.device.connection.v1';
  static const _storage = FlutterSecureStorage();

  final status = ValueNotifier<String>('Not connected');
  final Set<String> _mediaSessions = {};

  Map<String, dynamic>? _record;
  Future<void>? _starting;
  Timer? _timer;

  bool _sending = false;
  bool _enrolling = false;
  bool _suspended = false;
  int _generation = 0;
  int _failures = 0;

  String _sessionId = const Uuid().v4();
  String _version = 'unknown';
  DateTime _lastInteraction = DateTime.now();

  bool get isConnected =>
      isEnrolled && !_suspended && status.value == 'Connected';

  /// Base address of the paired Millitop server, used to build signed DVR
  /// playback links. Null when this device is not paired.
  Uri? get serverUri {
    final raw = _record?['serverUrl'];
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    try {
      return validateServer(raw);
    } catch (_) {
      return null;
    }
  }

  String get connectionKey =>
      _record == null ? '' : '${_record!['serverUrl']}|${_record!['deviceId']}';

  Future<Map<String, dynamic>> postDevice(
    String route,
    Map<String, dynamic> body, {
    required String expectedConnection,
  }) async {
    await start();
    if (!const {
      '/api/device/messages',
      '/api/device/receipts',
      '/api/device/updates/check',
      '/api/device/updates/report',
      '/api/device/updates/confirm',
      '/api/device/web-apps',
      '/api/device/live-tv/favorites',
      '/api/device/live-tv/history',
      '/api/device/live-tv/dvr',
      '/api/device/live-tv/config',
      '/api/device/live-tv/playback',
      '/api/device/live-tv/queue',
      '/api/device/household/profiles',
      '/api/device/live-tv/dvr/schedule',
      '/api/device/live-tv/dvr/recordings',
      '/api/device/service/access',
      '/api/device/media-library/catalog',
      '/api/device/telemetry',
    }.contains(route)) {
      throw ArgumentError('Unsupported device route.');
    }
    if (_record == null || _suspended || expectedConnection != connectionKey) {
      throw StateError('Device connection is unavailable or changed.');
    }
    final saved = _record!;
    final requestTimeout = route == '/api/device/media-library/catalog'
        ? const Duration(seconds: 90)
        // Starting/stopping a recording waits for the server to open or
        // finalize the channel stream.
        : route == '/api/device/live-tv/dvr'
        ? const Duration(seconds: 40)
        : const Duration(seconds: 15);
    final watch = Stopwatch()..start();
    final category = route.contains('/dvr')
        ? LogCategory.dvr
        : LogCategory.sync;
    final action = body['action']?.toString();
    try {
      final result = await _postGuarded(
        saved,
        route,
        body,
        requestTimeout,
        expectedConnection,
      );
      if (category == LogCategory.dvr && action != null && action != 'list') {
        AppLog.audit(
          'DVR $action',
          details: {'route': route, 'ms': watch.elapsedMilliseconds},
        );
      }
      return result;
    } catch (error, stack) {
      if (route != '/api/device/telemetry') {
        AppLog.error(
          category,
          'Dashboard request $route${action == null ? '' : ' ($action)'} failed',
          error: error,
          stackTrace: stack,
          details: {'ms': watch.elapsedMilliseconds},
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _postGuarded(
    Map<String, dynamic> saved,
    String route,
    Map<String, dynamic> body,
    Duration requestTimeout,
    String expectedConnection,
  ) async {
    try {
      return await _post(
        validateServer(saved['serverUrl'] as String),
        route,
        body,
        token: saved['deviceToken'] as String,
        requestTimeout: requestTimeout,
      );
    } on DeviceRequestFailure catch (error) {
      if (error.statusCode == 401 && connectionKey == expectedConnection) {
        _suspended = true;
        _timer?.cancel();
        status.value = 'Connection revoked or invalid. Pair again.';
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> postBilling(
    String route,
    Map<String, dynamic> body, {
    required String expectedConnection,
    String? session,
  }) async {
    await start();
    if (!const {
      '/api/device/account',
      '/api/device/account/unlock',
      '/api/device/account/pay',
      '/api/device/account/payments',
    }.contains(route)) {
      throw ArgumentError('Unsupported billing route.');
    }
    final record = _record;
    if (record == null || _suspended || expectedConnection != connectionKey) {
      throw const BillingTransportException(
        401,
        'connection',
        'Device pairing is unavailable or changed.',
      );
    }
    final server = validateServer(record['serverUrl'] as String);
    if (server.scheme != 'https') {
      throw const BillingTransportException(
        0,
        'https_required',
        'Account billing requires HTTPS. Use the secure Millitop connection before viewing financial information.',
      );
    }
    if (session != null && !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(session)) {
      throw const BillingTransportException(
        403,
        'session',
        'Unlock Account again.',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final deadline = Timer(
      const Duration(seconds: 120),
      () => client.close(force: true),
    );
    try {
      final request = await client
          .postUrl(server.resolve(route))
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${record['deviceToken']}',
      );
      if (session != null) {
        request.headers.set('X-Millitop-Billing-Session', session);
      }
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 100),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > 8388608) {
          throw const BillingTransportException(
            0,
            'size',
            'Account response exceeded the safe size limit. No partial balance is shown.',
          );
        }
        bytes.addAll(chunk);
      }
      if (connectionKey != expectedConnection) {
        throw const BillingTransportException(
          401,
          'connection',
          'Device connection changed. Open Account again.',
        );
      }
      Map<String, dynamic> data = {};
      try {
        data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      } catch (_) {}
      if (response.statusCode == 401) {
        _suspended = true;
        _timer?.cancel();
        status.value = 'Connection revoked or invalid. Pair again.';
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = data['error'];
        throw BillingTransportException(
          response.statusCode,
          'http',
          message is String && message.length <= 500
              ? message
              : 'Account request could not be completed. Retry or contact support.',
        );
      }
      if (data.isEmpty) {
        throw const BillingTransportException(
          0,
          'invalid_response',
          'The server did not return a valid account response.',
        );
      }
      return data;
    } on BillingTransportException {
      rethrow;
    } catch (_) {
      throw const BillingTransportException(
        0,
        'network',
        'Account information could not be verified. Check connectivity and retry.',
      );
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  Future<void> useSecureBillingOrigin() async {
    await start();
    final record = _record;
    if (record == null || _suspended) {
      throw const BillingTransportException(
        401,
        'connection',
        'Pair the device before configuring billing.',
      );
    }
    final previous = connectionKey;
    final old = validateServer(record['serverUrl'] as String);
    if (old.scheme == 'https') {
      return;
    }
    if (old.scheme != 'http') {
      throw const BillingTransportException(
        0,
        'origin',
        'This connection cannot be automatically moved. Pair again using an HTTP or HTTPS server origin.',
      );
    }
    final secure = validateServer('https://tvadmin.millitop.net');
    Map<String, dynamic> proof;
    try {
      proof = await _post(secure, '/api/device/heartbeat', {
        'sessionId': _sessionId,
        'state': _mediaSessions.isNotEmpty ? 'media_active' : 'browsing',
        'active': true,
        'appVersion': _version,
      }, token: record['deviceToken'] as String);
    } on DeviceRequestFailure catch (error) {
      final message = error.message.trim();
      throw BillingTransportException(
        error.statusCode,
        'origin',
        message.isEmpty
            ? 'The secure server did not accept this device credential.'
            : message,
      );
    } on HandshakeException catch (error) {
      throw BillingTransportException(
        0,
        'origin',
        'Secure connection failed TLS validation. Confirm the HTTPS certificate and system clock, then retry. Details: $error',
      );
    } on SocketException {
      throw const BillingTransportException(
        0,
        'origin',
        'Could not reach the secure server. Confirm https://tvadmin.millitop.net is reachable from this device.',
      );
    }
    if (proof['accepted'] != true || previous != connectionKey) {
      throw const BillingTransportException(
        0,
        'origin',
        'The secure server could not verify the existing device credential. The saved connection was not replaced.',
      );
    }
    final updated = <String, dynamic>{
      ...record,
      'serverUrl': secure.toString(),
    };
    await _storage.write(key: _storageKey, value: jsonEncode(updated));
    _generation++;
    _timer?.cancel();
    _record = updated;
    _failures = 0;
    status.value = 'Connecting';
    await checkNow();
  }

  bool get isEnrolled => _record != null;
  bool get isSuspended => _suspended;
  bool get mediaActive => _mediaSessions.isNotEmpty;
  String get deviceName => _record?['deviceName'] as String? ?? '';
  String get serverUrl => _record?['serverUrl'] as String? ?? '';

  static const String _secureDefaultOrigin = 'https://tvadmin.millitop.net';
  static const String _knownMistypedSecureOrigin =
      'https://tvadmin.milltop.net';

  static String _normalizeServerInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Enter the dashboard server address.');
    }
    if (trimmed.toLowerCase().startsWith('http://')) {
      throw const FormatException(
        'Use HTTPS for the dashboard server, for example https://tvadmin.millitop.net.',
      );
    }
    if (trimmed.contains('://')) {
      return trimmed;
    }
    return 'https://$trimmed';
  }

  static List<Uri> _enrollmentServerCandidates(String address) {
    final primary = validateServer(_normalizeServerInput(address));
    final secureDefault = validateServer(_secureDefaultOrigin);
    final mistypedSecure = validateServer(_knownMistypedSecureOrigin);
    final candidates = <Uri>[primary];

    void addIfMissing(Uri value) {
      if (!candidates.contains(value)) {
        candidates.add(value);
      }
    }

    if (primary == mistypedSecure) {
      addIfMissing(secureDefault);
    }

    if (primary.host.toLowerCase() == 'tvadmin.milltop.net') {
      addIfMissing(secureDefault);
    }

    return candidates;
  }

  static Uri validateServer(String input) {
    final uri = Uri.tryParse(input.trim());

    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Enter a server origin without a path, credentials, or query.',
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('Use an HTTP or HTTPS server origin.');
    }

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _version = '${info.version}+${info.buildNumber}';

      final saved = await _storage.read(key: _storageKey);

      if (saved == null) {
        status.value = 'Not connected';
        return;
      }

      final record = jsonDecode(saved) as Map<String, dynamic>;
      validateServer(record['serverUrl'] as String);

      if (record['deviceName'] is! String ||
          record['deviceId'] is! String ||
          record['deviceToken'] is! String ||
          !RegExp(
            r'^mtv_[A-Za-z0-9_-]{43}$',
          ).hasMatch(record['deviceToken'] as String)) {
        throw const FormatException('Invalid saved connection.');
      }

      _record = record;
      status.value = 'Connecting';
      await _heartbeat();
    } catch (_) {
      status.value =
          'Could not initialize the saved connection. Open Device setup.';
    }
  }

  void noteInteraction() {
    _lastInteraction = DateTime.now();
  }

  void setMediaActive(String source, bool active) {
    if (active) {
      _mediaSessions.add(source);
    } else {
      _mediaSessions.remove(source);
    }
  }

  Future<Map<String, dynamic>> _post(
    Uri server,
    String route,
    Map<String, dynamic> body, {
    String? token,
    Duration requestTimeout = const Duration(seconds: 15),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);

    try {
      final request = await client
          .postUrl(server.resolve(route))
          .timeout(requestTimeout);

      // Never redirect a request containing a device credential.
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;

      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }

      request.write(jsonEncode(body));

      final response = await request.close().timeout(requestTimeout);

      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(requestTimeout);

      Map<String, dynamic> data = {};

      try {
        data = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        // Do not show raw proxy/HTML responses or log credentials.
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final serverMessage = data['error'];
        throw DeviceRequestFailure(
          response.statusCode,
          serverMessage is String
              ? serverMessage.trim().substring(
                  0,
                  serverMessage.trim().length.clamp(0, 300),
                )
              : '',
        );
      }

      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> enroll(String address, String pairingCode) async {
    await start();

    if (_enrolling) return;
    if (_record != null) {
      throw StateError('Disconnect the existing connection first.');
    }

    final candidates = _enrollmentServerCandidates(address);
    final code = pairingCode.replaceAll(RegExp(r'[-\s]'), '').toUpperCase();

    if (!RegExp(r'^[0-9A-F]{12}$').hasMatch(code)) {
      throw const FormatException('Enter the full pairing code.');
    }

    _enrolling = true;
    status.value = 'Pairing';

    try {
      Map<String, dynamic>? data;
      Uri? enrolledServer;
      DeviceRequestFailure? lastRequestFailure;
      Object? lastNetworkFailure;
      for (final candidate in candidates) {
        try {
          data = await _post(candidate, '/api/device/enroll', {'code': code});
          enrolledServer = candidate;
          break;
        } on DeviceRequestFailure catch (error) {
          lastRequestFailure = error;
          if (error.statusCode == 400 || error.statusCode == 429) {
            rethrow;
          }
        } on SocketException catch (error) {
          lastNetworkFailure = error;
        } on HandshakeException catch (error) {
          lastNetworkFailure = error;
        }
      }

      if (data == null || enrolledServer == null) {
        if (lastRequestFailure != null) {
          throw lastRequestFailure;
        }
        final normalizedInput = _normalizeServerInput(address);
        final typoHint =
            normalizedInput.toLowerCase().contains('tvadmin.milltop.net')
            ? ' Use https://tvadmin.millitop.net.'
            : '';
        if (lastNetworkFailure != null) {
          if (lastNetworkFailure is HandshakeException) {
            throw StateError(
              'TLS handshake failed while pairing.$typoHint Confirm the '
              'dashboard certificate, server time, and exact HTTPS address.',
            );
          }
          throw lastNetworkFailure;
        }
        throw StateError(
          'Pairing could not reach the dashboard server.$typoHint',
        );
      }

      if (data['deviceId'] is! String ||
          data['deviceName'] is! String ||
          data['deviceToken'] is! String ||
          !RegExp(
            r'^mtv_[A-Za-z0-9_-]{43}$',
          ).hasMatch(data['deviceToken'] as String)) {
        throw StateError(
          'The server returned an invalid enrollment response. '
          'Check the dashboard before generating another code.',
        );
      }

      final record = <String, dynamic>{
        'serverUrl': enrolledServer.toString(),
        'deviceId': data['deviceId'],
        'deviceName': data['deviceName'],
        'deviceToken': data['deviceToken'],
      };

      try {
        await _storage.write(key: _storageKey, value: jsonEncode(record));
      } catch (_) {
        throw StateError(
          'The server enrolled this PC, but Windows could not save its '
          'credential. Revoke that device in the dashboard before retrying.',
        );
      }

      _generation++;
      _record = record;
      _suspended = false;
      _failures = 0;
      _sessionId = const Uuid().v4();
      status.value = 'Paired; connecting';
      await _heartbeat();
    } on DeviceRequestFailure catch (error) {
      status.value = 'Pairing failed';

      if (error.statusCode == 400) {
        throw StateError('The code is invalid, expired, or already used.');
      }

      if (error.statusCode == 429) {
        throw StateError('Too many pairing attempts. Try again later.');
      }

      throw StateError('Pairing failed with HTTP ${error.statusCode}.');
    } catch (error) {
      status.value = 'Pairing did not finish';

      if (error is StateError) rethrow;
      if (error is SocketException) {
        final typoHint = address.toLowerCase().contains('tvadmin.milltop.net')
            ? ' Use https://tvadmin.millitop.net.'
            : '';
        throw StateError(
          'Pairing could not resolve or reach the dashboard host.$typoHint',
        );
      }
      if (error is HandshakeException) {
        throw StateError(
          'Secure pairing failed because TLS could not be established. '
          'Confirm the exact HTTPS server URL, certificate trust, and '
          'system clock. Details: $error',
        );
      }

      throw StateError(
        'Pairing could not finish. If the server created a device, revoke '
        'it before retrying with a fresh code. Check server connectivity.',
      );
    } finally {
      _enrolling = false;
    }
  }

  Future<void> _heartbeat() async {
    if (_sending || _record == null || _suspended) return;

    _sending = true;
    _timer?.cancel();

    final generation = _generation;
    final record = _record!;

    try {
      final recentlyActive =
          DateTime.now().difference(_lastInteraction).inSeconds < 120;

      final state = _mediaSessions.isNotEmpty
          ? 'media_active'
          : recentlyActive
          ? 'browsing'
          : 'idle';

      await _post(
        validateServer(record['serverUrl'] as String),
        '/api/device/heartbeat',
        {
          'sessionId': _sessionId,
          'state': state,
          'active': recentlyActive,
          'appVersion': _version,
        },
        token: record['deviceToken'] as String,
      );

      if (generation != _generation) return;

      _failures = 0;
      status.value = 'Connected';
    } on DeviceRequestFailure catch (error) {
      if (generation != _generation) return;

      if (error.statusCode == 401) {
        _suspended = true;
        status.value = 'Connection revoked or invalid. Pair again.';
      } else {
        _failures++;
        status.value = 'Server unavailable; retrying';
      }
    } catch (_) {
      if (generation != _generation) return;
      _failures++;
      status.value = 'Offline; retrying';
    } finally {
      _sending = false;

      if (_record != null && !_suspended) {
        final delay = _failures == 0
            ? 30
            : (30 * (1 << _failures.clamp(0, 3))).clamp(30, 240);

        _timer = Timer(Duration(seconds: delay), _heartbeat);
      }
    }
  }

  Future<void> checkNow() async {
    await start();
    if (!_suspended) await _heartbeat();
  }

  Future<void> disconnect() async {
    // Keep the current connection if secure deletion fails.
    await _storage.delete(key: _storageKey);

    _generation++;
    _timer?.cancel();
    _record = null;
    _suspended = false;
    _failures = 0;
    status.value = 'Not connected';
  }
}

class DeviceRequestFailure implements Exception {
  final int statusCode;

  /// Short, server-authored explanation (the JSON `error` field), if any.
  final String message;
  const DeviceRequestFailure(this.statusCode, [this.message = '']);

  @override
  String toString() =>
      message.isNotEmpty ? message : 'Request failed (HTTP $statusCode).';
}
