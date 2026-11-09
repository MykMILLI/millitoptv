import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_log.dart';
import '../device_connection.dart';
import 'watch_party_models.dart';
import 'watch_party_voice.dart';

export 'watch_party_models.dart';

class WatchPartyException implements Exception {
  final int status;
  final String message;
  const WatchPartyException(this.status, this.message);
  @override
  String toString() => message;
}

/// Watch parties relayed through tvadmin.
///
/// The host app tells tvadmin what is playing and where the stream lives;
/// tvadmin relays the stream to guests (browser or app) so the host's media
/// servers never need to be exposed. Playback state is pushed by the host and
/// fanned out over server-sent events.
class WatchPartyService extends ChangeNotifier {
  WatchPartyService._();
  static final instance = WatchPartyService._();

  static final Uri defaultServer = Uri.parse('https://tvadmin.millitop.net');
  static const _nameKey = 'watch_party.display_name';
  static const reactions = ['👍', '😂', '😮', '❤️', '👏', '🔥'];

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 20);

  Uri? _server;
  String? _token;
  String? _meId;
  String? _relayKey;
  String _role = 'guest';

  // Party state from the server.
  String? partyTitle;
  String? joinCode;
  String? joinUrl;
  String hostName = 'Host';
  bool hostOnline = false;
  bool locked = false;
  WatchPartyRemoteMedia? media;
  WatchPartyPlayback? playback;
  List<WatchPartyPerson> people = const [];
  final List<WatchPartyMessage> messages = [];
  int _clockOffsetMs = 0;
  bool connected = false;
  String? endedReason;
  String? relayWarning;

  /// Live reaction bursts for the overlay (emoji, name).
  final StreamController<(String, String)> _reactions =
      StreamController.broadcast();
  Stream<(String, String)> get reactionStream => _reactions.stream;
  int unreadChat = 0;
  bool panelOpen = false;

  late final WatchPartyVoice voice = WatchPartyVoice(this);

  bool get active => _token != null;
  bool get isHost => active && _role == 'host';
  bool get isGuest => active && _role == 'guest';
  String? get meId => _meId;
  int get serverNowMs => DateTime.now().millisecondsSinceEpoch + _clockOffsetMs;

  /// Address the guest player opens. Includes the media revision so a new
  /// title never reuses a cached stream.
  String? get relayUrl {
    final rev = media?.rev;
    if (_server == null || _relayKey == null || rev == null) return null;
    return _server!.resolve('/watch-relay/$_relayKey/$rev/main').toString();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle

  Future<String> savedDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_nameKey) ?? '';
  }

  Future<void> _saveDisplayName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name);
  }

  /// Starts a party on this paired device and shares whatever is playing.
  Future<void> startParty({
    required String title,
    required String displayName,
  }) async {
    final connection = DeviceConnection.instance;
    final server = connection.serverUri;
    if (server == null) {
      throw const WatchPartyException(
        409,
        'Pair this device with tvadmin in Settings before hosting a watch party.',
      );
    }
    await leave(silent: true);
    final response = await connection.postDevice(
      '/api/device/watch-parties/create',
      {'title': title, 'displayName': displayName},
      expectedConnection: connection.connectionKey,
    );
    await _saveDisplayName(displayName);
    _adopt(server, response);
    AppLog.audit('Watch party started', details: {'code': joinCode ?? ''});
    if (_local != null) unawaited(_shareLocal());
  }

  /// Joins someone else's party from the app.
  Future<void> joinParty({
    required String code,
    required String displayName,
    String? invite,
    Uri? server,
  }) async {
    final target =
        server ?? DeviceConnection.instance.serverUri ?? defaultServer;
    await leave(silent: true);
    final response = await _request(
      'POST',
      '/api/watch/join',
      body: {
        'code': code,
        'displayName': displayName,
        'client': 'app',
        'invite': ?invite,
      },
      server: target,
      authorized: false,
    );
    await _saveDisplayName(displayName);
    _adopt(target, response);
  }

  /// Accepts a pasted link such as https://tvadmin.millitop.net/watch/ABCD2345.
  static ({String code, Uri? server, String? invite})? parseJoinInput(
    String raw,
  ) {
    final value = raw.trim();
    final uri = Uri.tryParse(value);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      final index = uri.pathSegments.indexOf('watch');
      if (index >= 0 && index + 1 < uri.pathSegments.length) {
        final code = _normalizeCode(uri.pathSegments[index + 1]);
        if (code == null) return null;
        return (
          code: code,
          server: Uri(
            scheme: uri.scheme,
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            path: '/',
          ),
          invite: uri.queryParameters['invite'],
        );
      }
      return null;
    }
    final code = _normalizeCode(value);
    return code == null ? null : (code: code, server: null, invite: null);
  }

  static String? _normalizeCode(String raw) {
    final code = raw.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    return RegExp(r'^[A-Z2-9]{8}$').hasMatch(code) ? code : null;
  }

  void _adopt(Uri server, Map<String, dynamic> response) {
    final participant = response['participant'];
    if (participant is! Map || participant['token'] is! String) {
      throw const WatchPartyException(
        502,
        'tvadmin returned an unexpected answer.',
      );
    }
    _server = server;
    _token = participant['token'] as String;
    _meId = participant['id']?.toString();
    _relayKey = participant['relayKey']?.toString();
    _role = participant['role']?.toString() ?? 'guest';
    endedReason = null;
    relayWarning = null;
    messages.clear();
    unreadChat = 0;
    _applySnapshot(response, includeMessages: true);
    _connectEvents();
    notifyListeners();
  }

  /// Leaves (guest) or ends (host) the party.
  Future<void> leave({bool silent = false}) async {
    if (!active) return;
    final wasHost = isHost;
    try {
      await voice.leave();
    } catch (_) {}
    try {
      await _request(
        'POST',
        wasHost ? '/api/watch/end' : '/api/watch/leave',
        body: {},
      );
    } catch (error) {
      if (!silent) {
        AppLog.warn(LogCategory.sync, 'Watch party leave failed: $error');
      }
    }
    _teardown(null);
  }

  void _teardown(String? reason) {
    _eventsGeneration++;
    _eventsClient?.close(force: true);
    _eventsClient = null;
    _eventsWatchdog?.cancel();
    _heartbeat?.cancel();
    _detachHostPlayer();
    unawaited(voice.leave(announce: false));
    _token = null;
    _meId = null;
    _relayKey = null;
    _role = 'guest';
    media = null;
    playback = null;
    people = const [];
    connected = false;
    _mediaRev = null;
    _sharedIdentity = null;
    endedReason = reason;
    notifyListeners();
  }

  void dismissEnded() {
    endedReason = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // HTTP

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Uri? server,
    bool authorized = true,
  }) async {
    final base = server ?? _server;
    if (base == null) {
      throw const WatchPartyException(409, 'Not in a watch party.');
    }
    final token = _token;
    if (authorized && token == null) {
      throw const WatchPartyException(409, 'Not in a watch party.');
    }
    final request = await _http.openUrl(method, base.resolve(path));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (authorized) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 20));
    Object? decoded;
    try {
      decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    final map = decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{};
    if (response.statusCode >= 400) {
      final message =
          map['error']?.toString() ??
          'tvadmin answered ${response.statusCode}.';
      if (authorized &&
          (response.statusCode == 401 || response.statusCode == 410)) {
        _teardown(message);
      }
      throw WatchPartyException(response.statusCode, message);
    }
    if (decoded is! Map) {
      throw const WatchPartyException(
        502,
        'tvadmin returned an unexpected answer.',
      );
    }
    return map;
  }

  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) => _request(method, path, body: body);

  // ---------------------------------------------------------------------------
  // Events (SSE)

  int _eventsGeneration = 0;
  HttpClient? _eventsClient;
  Timer? _eventsWatchdog;
  int _eventsFailures = 0;

  void _connectEvents() {
    final generation = ++_eventsGeneration;
    unawaited(_eventsLoop(generation));
  }

  Future<void> _eventsLoop(int generation) async {
    while (generation == _eventsGeneration && active) {
      try {
        // A dedicated client per stream so a stalled stream can be torn
        // down without touching the pooled API connections.
        _eventsClient?.close(force: true);
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 12);
        _eventsClient = client;
        final request = await client.getUrl(
          _server!.resolve('/api/watch/events'),
        );
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
        request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (generation != _eventsGeneration) {
          client.close(force: true);
          return;
        }
        if (response.statusCode == 401 || response.statusCode == 410) {
          final text = await response.transform(utf8.decoder).join();
          String message = 'This watch party has ended.';
          try {
            message = (jsonDecode(text) as Map)['error']?.toString() ?? message;
          } catch (_) {}
          _teardown(message);
          return;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw WatchPartyException(
            response.statusCode,
            'Event stream unavailable.',
          );
        }
        _eventsFailures = 0;
        _setConnected(true);
        _armWatchdog(generation);
        var event = 'message';
        final data = StringBuffer();
        await for (final line
            in response
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (generation != _eventsGeneration) return;
          _armWatchdog(generation);
          if (line.isEmpty) {
            if (data.isNotEmpty) _dispatch(event, data.toString());
            event = 'message';
            data.clear();
          } else if (line.startsWith(':')) {
            continue;
          } else if (line.startsWith('event:')) {
            event = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (data.isNotEmpty) data.write('\n');
            data.write(line.substring(5).trimLeft());
          }
        }
      } catch (error) {
        if (generation != _eventsGeneration) return;
        AppLog.warn(LogCategory.sync, 'Watch party events dropped: $error');
      }
      if (generation != _eventsGeneration || !active) return;
      _setConnected(false);
      _eventsFailures++;
      final delay = math.min(15000, 500 * (1 << math.min(_eventsFailures, 5)));
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
  }

  void _armWatchdog(int generation) {
    _eventsWatchdog?.cancel();
    // The server sends a keep-alive every 15 s.
    _eventsWatchdog = Timer(const Duration(seconds: 40), () {
      if (generation != _eventsGeneration) return;
      _eventsClient?.close(force: true);
    });
  }

  void _setConnected(bool value) {
    if (connected == value) return;
    connected = value;
    notifyListeners();
  }

  void _dispatch(String event, String raw) {
    Map<String, dynamic> data;
    try {
      data = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (event) {
      case 'hello':
        _applySnapshot(data, includeMessages: true);
        if (isHost) unawaited(_resyncHost());
      case 'state':
        _applySnapshot(data, includeMessages: false);
      case 'playback':
        final next = WatchPartyPlayback.fromJson(data['playback']);
        if (next != null) playback = next;
      case 'chat':
        final message = data['message'];
        if (message is Map) {
          final parsed = WatchPartyMessage.fromJson(
            message.cast<String, dynamic>(),
          );
          if (!messages.any((m) => m.id == parsed.id && !m.notice)) {
            messages.add(parsed);
            if (!panelOpen && parsed.from != _meId) unreadChat++;
          }
          _trimMessages();
        }
      case 'notice':
        messages.add(
          WatchPartyMessage(
            id: -DateTime.now().microsecondsSinceEpoch,
            from: '',
            name: '',
            body: data['text']?.toString() ?? '',
            at: DateTime.now(),
            notice: true,
          ),
        );
        _trimMessages();
      case 'reaction':
        final emoji = data['emoji']?.toString();
        if (emoji != null) {
          _reactions.add((emoji, data['name']?.toString() ?? ''));
        }
        return;
      case 'signal':
        unawaited(voice.handleSignal(data));
        return;
      case 'ended':
        _teardown(_endedText(data['reason']?.toString()));
        return;
      case 'removed':
        _teardown('The host removed you from the watch party.');
        return;
      default:
        return;
    }
    notifyListeners();
  }

  static String _endedText(String? reason) => switch (reason) {
    'replaced' => 'The host started a new watch party.',
    'host-timeout' => 'The host went offline, so the watch party ended.',
    'admin' => 'An administrator ended the watch party.',
    _ => 'The host ended the watch party.',
  };

  void _trimMessages() {
    if (messages.length > 200) messages.removeRange(0, messages.length - 200);
  }

  void _applySnapshot(
    Map<String, dynamic> data, {
    required bool includeMessages,
  }) {
    final serverTime = (data['serverTimeMs'] as num?)?.toInt();
    if (serverTime != null) {
      final offset = serverTime - DateTime.now().millisecondsSinceEpoch;
      // Network delay only ever makes the server look behind, so keep the
      // largest offset seen recently.
      _clockOffsetMs = _clockSamples == 0
          ? offset
          : math.max(_clockOffsetMs, offset);
      _clockSamples++;
    }
    final party = data['party'];
    if (party is Map) {
      partyTitle = party['title']?.toString();
      joinCode = party['code']?.toString();
      joinUrl = party['joinUrl']?.toString();
      hostName = party['hostName']?.toString() ?? 'Host';
      hostOnline = party['hostOnline'] == true;
      locked = party['locked'] == true;
    }
    if (data.containsKey('media')) {
      media = WatchPartyRemoteMedia.fromJson(data['media']);
    }
    if (data.containsKey('playback')) {
      playback = WatchPartyPlayback.fromJson(data['playback']) ?? playback;
    }
    final list = data['participants'];
    if (list is List) {
      people = [
        for (final item in list)
          if (item is Map)
            WatchPartyPerson.fromJson(item.cast<String, dynamic>()),
      ];
      voice.sync(people);
    }
    final history = data['messages'];
    if (includeMessages && history is List) {
      messages
        ..clear()
        ..addAll([
          for (final item in history)
            if (item is Map)
              WatchPartyMessage.fromJson(item.cast<String, dynamic>()),
        ]);
    }
  }

  int _clockSamples = 0;

  // ---------------------------------------------------------------------------
  // Participant actions

  Future<void> sendChat(String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    await _request('POST', '/api/watch/chat', body: {'body': trimmed});
  }

  Future<void> react(String emoji) =>
      _request('POST', '/api/watch/reaction', body: {'emoji': emoji});

  Future<List<Map<String, dynamic>>> invite(
    List<String> emails, {
    String? note,
  }) async {
    final result = await _request(
      'POST',
      '/api/watch/invite',
      body: {
        'emails': emails,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    );
    final list = result['results'];
    return [
      if (list is List)
        for (final item in list)
          if (item is Map) item.cast<String, dynamic>(),
    ];
  }

  Future<void> setLocked(bool value) async {
    await _request('POST', '/api/watch/lock', body: {'locked': value});
    locked = value;
    notifyListeners();
  }

  Future<void> remove(String participantId) => _request(
    'POST',
    '/api/watch/remove',
    body: {'participantId': participantId},
  );

  void setPanelOpen(bool open) {
    panelOpen = open;
    if (open) unreadChat = 0;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Host binding: screens register whatever they are playing.

  ({Player player, WatchPartyMedia media})? _local;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _heartbeat;
  int? _mediaRev;
  String? _sharedIdentity;
  bool _sharing = false;
  bool _pendingShare = false;
  DateTime _lastReport = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  double _lastRate = 1;
  Duration _lastPosition = Duration.zero;
  DateTime _lastPositionAt = DateTime.now();

  bool get hasLocalPlayback => _local != null;
  String? get localTitle => _local?.media.title;

  /// Call when a player starts (or switches) media. Safe to call often; only
  /// a change of title/stream is sent to tvadmin.
  void registerLocalPlayback(Player player, WatchPartyMedia media) {
    final previous = _local;
    _local = (player: player, media: media);
    if (previous?.player != player) _attachHostPlayer(player);
    if (isHost && media.identity != _sharedIdentity) unawaited(_shareLocal());
    notifyListeners();
  }

  /// Call when a screen disposes its player.
  void unregisterLocalPlayback(Player player) {
    if (_local?.player != player) return;
    if (isHost && _mediaRev != null) {
      unawaited(_sendPlayback(force: true, playingOverride: false));
    }
    _detachHostPlayer();
    _local = null;
    notifyListeners();
  }

  void _attachHostPlayer(Player player) {
    _detachHostPlayer();
    final stream = player.stream;
    _subs
      ..add(stream.playing.listen((_) => _onLocalChange()))
      ..add(stream.buffering.listen((_) => _onLocalChange()))
      ..add(stream.rate.listen((_) => _onLocalChange()))
      ..add(stream.completed.listen((_) => _onLocalChange()))
      ..add(stream.position.listen(_onLocalPosition));
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (isHost) unawaited(_sendPlayback());
    });
  }

  void _detachHostPlayer() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _onLocalChange() {
    if (!isHost) return;
    final state = _local?.player.state;
    if (state == null) return;
    if (state.playing != _lastPlaying ||
        state.buffering != _lastBuffering ||
        state.rate != _lastRate) {
      unawaited(_sendPlayback(force: true));
    }
  }

  void _onLocalPosition(Duration position) {
    final now = DateTime.now();
    final state = _local?.player.state;
    if (isHost && state != null) {
      final elapsed = now.difference(_lastPositionAt).inMilliseconds;
      final expected =
          _lastPosition.inMilliseconds +
          (_lastPlaying && !_lastBuffering ? (elapsed * _lastRate).round() : 0);
      // A jump of more than 1.5 s that time does not explain is a seek.
      if ((position.inMilliseconds - expected).abs() > 1500) {
        unawaited(_sendPlayback(force: true));
      }
    }
    _lastPosition = position;
    _lastPositionAt = now;
  }

  Future<void> _resyncHost() async {
    if (_local == null) return;
    if (_mediaRev == null || _local!.media.identity != _sharedIdentity) {
      await _shareLocal();
    } else {
      await _sendPlayback(force: true);
    }
  }

  Future<void> _shareLocal() async {
    if (_sharing) {
      _pendingShare = true;
      return;
    }
    _sharing = true;
    try {
      do {
        _pendingShare = false;
        final local = _local;
        if (!isHost || local == null) return;
        final position = local.player.state.position.inMilliseconds;
        final result = await _request(
          'POST',
          '/api/watch/media',
          body: {'media': local.media.toServerJson(), 'positionMs': position},
        );
        _mediaRev = (result['mediaRev'] as num?)?.toInt();
        _sharedIdentity = local.media.identity;
        final relay = result['relay'];
        relayWarning = relay is Map && relay['reachable'] == false
            ? 'tvadmin could not reach this stream${relay['warning'] == null ? '' : ': ${relay['warning']}'}. Guests may not be able to play it.'
            : null;
        notifyListeners();
        await _sendPlayback(force: true);
      } while (_pendingShare);
    } catch (error) {
      AppLog.warn(LogCategory.sync, 'Watch party media share failed: $error');
      relayWarning = 'Could not share what is playing: $error';
      notifyListeners();
    } finally {
      _sharing = false;
    }
  }

  Future<void> _sendPlayback({
    bool force = false,
    bool? playingOverride,
  }) async {
    final local = _local;
    final rev = _mediaRev;
    if (!isHost || local == null || rev == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastReport) < const Duration(seconds: 4)) {
      return;
    }
    final state = local.player.state;
    final playing = playingOverride ?? (state.playing && !state.completed);
    _lastReport = now;
    _lastPlaying = state.playing;
    _lastBuffering = state.buffering;
    _lastRate = state.rate;
    try {
      await _request(
        'POST',
        '/api/watch/playback',
        body: {
          'mediaRev': rev,
          'positionMs': state.position.inMilliseconds,
          'playing': playing,
          'buffering': state.buffering,
          'rate': state.rate <= 0 ? 1 : state.rate,
        },
      );
    } on WatchPartyException catch (error) {
      if (error.status == 409) {
        _sharedIdentity = null;
        unawaited(_shareLocal());
      }
    } catch (_) {
      // The 5 s heartbeat retries.
    }
  }

  /// Shares the current title again (used by the panel's "Share what's playing").
  Future<void> shareNow() async {
    _sharedIdentity = null;
    await _shareLocal();
  }
}
