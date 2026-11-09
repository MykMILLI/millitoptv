import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';
import 'app_log.dart';

class SleepSoundsEmbeddedHost extends ChangeNotifier {
  SleepSoundsEmbeddedHost._();
  static final SleepSoundsEmbeddedHost instance = SleepSoundsEmbeddedHost._();

  static const String _howlerAssetPath =
      'assets/native/sleep_sounds/howler/howler-2.2.4.min.js';
  static const Map<String, String> _soundAssetPaths = <String, String>{
    'heavy-rain': 'assets/native/sleep_sounds/moodist/rain/heavy-rain.mp3',
    'thunder': 'assets/native/sleep_sounds/moodist/rain/thunder.mp3',
    'white-noise': 'assets/native/sleep_sounds/moodist/noise/white-noise.wav',
    'pink-noise': 'assets/native/sleep_sounds/moodist/noise/pink-noise.wav',
  };

  WebviewController? _controller;
  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<dynamic>? _loadErrorSub;
  StreamSubscription<dynamic>? _loadingSub;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  Completer<void>? _readyCompleter;
  Completer<void>? _viewAttachedCompleter;
  int? _activeProfileId;
  bool _initializing = false;
  bool _disposed = false;
  String? _embeddedHtmlCache;
  String lastError = '';
  String? _activeAttemptId;
  DateTime? _attemptStartedAt;

  Stream<Map<String, dynamic>> get events => _events.stream;
  WebviewController? get controller => _controller;
  bool get ready => _readyCompleter?.isCompleted == true;
  int? get activeProfileId => _activeProfileId;

  Future<void> ensureReady(int profileId, {String? attemptId}) async {
    if (_disposed) {
      throw StateError('Embedded Sleep Sounds host was disposed.');
    }
    if (_initializing) {
      while (_initializing) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (ready) {
        return;
      }
    }
    if (_controller != null &&
        _activeProfileId == profileId &&
        _readyCompleter?.isCompleted == true) {
      return;
    }
    _initializing = true;
    try {
      _activeAttemptId = (attemptId == null || attemptId.trim().isEmpty)
          ? 'sleep-start-${DateTime.now().microsecondsSinceEpoch}'
          : attemptId;
      _attemptStartedAt = DateTime.now();
      _traceStage('start-attempt');
      await _resetController();
      _traceStage('asset-validation-start');
      final embeddedHtml = await _buildEmbeddedHtml();
      _traceStage('asset-validation-completed');
      final next = WebviewController();
      await next.initialize();
      await next.setBackgroundColor(Colors.black);
      await next.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      _traceStage('webview-controller-initialized');

      _readyCompleter = Completer<void>();
      _viewAttachedCompleter = Completer<void>();
      _controller = next;
      _activeProfileId = profileId;
      notifyListeners();
      _traceStage('webview-controller-published');

      _messageSub = next.webMessage.listen(_handleWebMessage);
      _loadErrorSub = next.onLoadError.listen((error) {
        final text = error.toString();
        lastError = text;
        _events.add({
          'type': 'error',
          'message': 'Embedded Sleep Sounds load error: $text',
        });
      });
      _loadingSub = next.loadingState.listen((state) {
        _events.add({'type': 'loading', 'value': state.name});
        if (state.name == 'navigationCompleted') {
          _traceStage('document-navigation-completed');
        }
      });

      await _viewAttachedCompleter!.future.timeout(const Duration(seconds: 6));
      _traceStage('persistent-webview-widget-attached');
      await next.loadStringContent(embeddedHtml);
      await _readyCompleter!.future.timeout(const Duration(seconds: 25));
      _traceStage('javascript-bootstrap-reached');
      await postCommand({
        'commandId': 'howler-status-${DateTime.now().microsecondsSinceEpoch}',
        'action': 'howlerStatus',
        'attemptId': _activeAttemptId,
      });
      await _awaitEvent(
        (event) =>
            event['type'] == 'howler-status' &&
            event['available'] == true &&
            event['attemptId'] == _activeAttemptId,
        const Duration(seconds: 5),
        'howler-available',
      );
      await postCommand({
        'commandId': 'host-ping-${DateTime.now().microsecondsSinceEpoch}',
        'action': 'ping',
        'attemptId': _activeAttemptId,
      });
      await _awaitEvent(
        (event) =>
            event['type'] == 'pong' && event['attemptId'] == _activeAttemptId,
        const Duration(seconds: 5),
        'ping-pong-completed',
      );
      await postCommand({
        'commandId':
            'probe-heavy-rain-${DateTime.now().microsecondsSinceEpoch}',
        'action': 'probeHeavyRain',
        'attemptId': _activeAttemptId,
      });
      await _awaitEvent(
        (event) =>
            event['type'] == 'probe-heavy-rain-ok' &&
            event['attemptId'] == _activeAttemptId,
        const Duration(seconds: 12),
        'heavy-rain-load-decode-completed',
      );
      _events.add({'type': 'host-ready'});
      _traceStage('host-ready');
      notifyListeners();
    } catch (error, stackTrace) {
      _traceStage(
        'host-failed',
        level: LogLevel.error,
        details: {'error': error.toString()},
      );
      AppLog.error(
        LogCategory.playback,
        'Sleep Sounds embedded host initialization failed.',
        error: error,
        stackTrace: stackTrace,
        details: {'attemptId': _activeAttemptId ?? ''},
      );
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  Future<void> postCommand(Map<String, dynamic> payload) async {
    final active = _controller;
    if (active == null || _readyCompleter?.isCompleted != true) {
      throw StateError('Embedded Sleep Sounds host is not ready.');
    }
    await active.postWebMessage(jsonEncode(payload));
  }

  void _handleWebMessage(dynamic value) {
    Map<String, dynamic>? map;
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          map = Map<String, dynamic>.from(decoded);
        }
      } on FormatException {
        return;
      }
    } else if (value is Map) {
      map = Map<String, dynamic>.from(value);
    }
    if (map == null) {
      return;
    }
    final type = map['type']?.toString();
    if (type == 'ready') {
      if (!(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter!.complete();
      }
    }
    if (type == 'trace') {
      _traceStage(
        map['stage']?.toString() ?? 'js-trace',
        details: {
          'source': 'javascript',
          'audioContextState': map['audioContextState']?.toString() ?? '',
          'soundId': map['soundId']?.toString() ?? '',
        },
      );
    }
    if (type == 'error' || type == 'js-error') {
      AppLog.error(
        LogCategory.playback,
        'Sleep Sounds embedded JavaScript error.',
        details: {
          'attemptId': _activeAttemptId ?? '',
          'type': type,
          'message': map['message']?.toString() ?? '',
          'action': map['action']?.toString() ?? '',
        },
      );
    }
    _events.add(map);
  }

  Future<void> _awaitEvent(
    bool Function(Map<String, dynamic> event) match,
    Duration timeout,
    String successStage,
  ) async {
    final completer = Completer<void>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    sub = _events.stream.listen((event) {
      if (completer.isCompleted) {
        return;
      }
      if (match(event)) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
      _traceStage(successStage);
    } on TimeoutException catch (error, stackTrace) {
      _traceStage(
        '$successStage-timeout',
        level: LogLevel.error,
        details: {'timeoutMs': timeout.inMilliseconds},
      );
      AppLog.error(
        LogCategory.playback,
        'Sleep Sounds startup stage timed out.',
        error: error,
        stackTrace: stackTrace,
        details: {
          'attemptId': _activeAttemptId ?? '',
          'stage': successStage,
          'timeoutMs': timeout.inMilliseconds,
        },
      );
      rethrow;
    } finally {
      unawaited(sub.cancel());
    }
  }

  Future<String> _buildEmbeddedHtml() async {
    final cached = _embeddedHtmlCache;
    if (cached != null) {
      return cached;
    }
    final howlerJs = await rootBundle.loadString(_howlerAssetPath);
    final soundDataUris = await _loadSoundDataUris();
    final soundAssetsJson = jsonEncode(soundDataUris);

    final html =
        '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta http-equiv="X-UA-Compatible" content="IE=edge" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>MILLITOP Sleep Sounds</title>
  <style>
    html,body{margin:0;padding:0;background:#000;color:#fff;font-family:Segoe UI,Arial,sans-serif}
  </style>
</head>
<body>
<script>
$howlerJs
</script>
<script>
(function() {
  const supportsBridge = !!(window.chrome && window.chrome.webview);
  const SOUND_ASSETS = $soundAssetsJson;
  const IDS = ['heavy-rain', 'thunder', 'white-noise', 'pink-noise'];
  const FADE_MS = 220;
  const engine = {
    players: new Map(),
    playIds: new Map(),
    preset: 'overnight-storm',
    playing: false,
    paused: false,
    masterVolume: 0.7,
    volumes: {
      'heavy-rain': 0.70,
      'thunder': 0.35,
      'white-noise': 0.25,
      'pink-noise': 0.40
    },
    enabled: {
      'heavy-rain': true,
      'thunder': true,
      'white-noise': true,
      'pink-noise': true
    },
    capabilities: {
      supportsPerSoundVolume: true,
      supportsPresets: true,
      supportsPauseResume: true,
      supportsEmbeddedPlayback: true
    }
  };
  let currentAttemptId = '';

  function stage(stageName, details) {
    emit('trace', Object.assign({
      stage: stageName,
      attemptId: currentAttemptId,
      audioContextState: Howler && Howler.ctx ? Howler.ctx.state : 'unknown'
    }, details || {}));
  }

  function emit(type, payload) {
    if (!supportsBridge) return;
    const msg = Object.assign({ type: type }, payload || {});
    window.chrome.webview.postMessage(JSON.stringify(msg));
  }

  function clamp(value, min, max) {
    const num = Number(value);
    if (Number.isNaN(num)) return min;
    return Math.max(min, Math.min(max, num));
  }

  function toBoolean(value) {
    return value === true;
  }

  function layerVolume(id) {
    const raw = engine.volumes[id];
    if (typeof raw !== 'number' || Number.isNaN(raw)) {
      return 0.7;
    }
    return clamp(raw, 0, 1);
  }

  function layerEnabled(id) {
    return toBoolean(engine.enabled[id]);
  }

  function targetVolume(id) {
    return layerEnabled(id) ? layerVolume(id) * engine.masterVolume : 0;
  }

  function ensurePlayer(id) {
    if (engine.players.has(id)) {
      return engine.players.get(id);
    }
    const src = SOUND_ASSETS[id];
    if (!src) {
      throw new Error('Missing local asset for "' + id + '".');
    }
    const player = new Howl({
      src: [src],
      preload: true,
      loop: true,
      html5: false,
      volume: 0,
      onloaderror: function(_, err) {
        emit('error', { message: 'Could not load Sleep Sounds asset for "' + id + '": ' + String(err) });
      },
      onload: function() {
        if (id === 'heavy-rain') {
          emit('probe-heavy-rain-ok', { attemptId: currentAttemptId });
        }
      },
      onplayerror: function(_, err) {
        emit('error', { message: 'Playback unlock error for "' + id + '": ' + String(err) });
      }
    });
    engine.players.set(id, player);
    return player;
  }

  function activeLayers() {
    const layers = [];
    IDS.forEach(function(id) {
      const player = engine.players.get(id);
      const playId = engine.playIds.get(id);
      if (!player || playId == null) return;
      if (player.playing(playId)) {
        layers.push(id);
      }
    });
    return layers;
  }

  function applyLayerVolume(id, duration) {
    const player = engine.players.get(id);
    const playId = engine.playIds.get(id);
    if (!player || playId == null) return;
    const current = player.volume(playId);
    const next = targetVolume(id);
    if (!Number.isFinite(current) || !Number.isFinite(next)) return;
    const fadeMs = clamp(duration, 0, 1500);
    if (fadeMs <= 0) {
      player.volume(next, playId);
      return;
    }
    player.fade(current, next, fadeMs, playId);
  }

  function startLayer(id) {
    return new Promise(function(resolve, reject) {
      try {
        const player = ensurePlayer(id);
        const existingId = engine.playIds.get(id);
        if (existingId != null && player.playing(existingId)) {
          applyLayerVolume(id, FADE_MS);
          resolve();
          return;
        }

        let settled = false;
        function finishWithError(message) {
          if (settled) return;
          settled = true;
          reject(new Error(message));
        }
        function finishSuccess(playId) {
          if (settled) return;
          settled = true;
          engine.playIds.set(id, playId);
          stage('play-event-received', { soundId: id });
          applyLayerVolume(id, FADE_MS);
          resolve();
        }

        const onPlayError = function(_, err) {
          player.off('playerror', onPlayError);
          Howler.once('unlock', function() {
            try {
              const unlockedId = player.play(existingId);
              const playId = typeof unlockedId === 'number' ? unlockedId : existingId;
              if (typeof playId === 'number') {
                finishSuccess(playId);
              } else {
                finishWithError('Could not resume "' + id + '" after unlock.');
              }
            } catch (retryErr) {
              finishWithError('Could not start "' + id + '" after unlock: ' + String(retryErr));
            }
          });
          setTimeout(function() {
            finishWithError('Audio unlock required for "' + id + '": ' + String(err));
          }, 2200);
        };
        player.on('playerror', onPlayError);

        let startedId;
        try {
          startedId = existingId != null ? player.play(existingId) : player.play();
        } catch (err) {
          player.off('playerror', onPlayError);
          finishWithError('Could not play "' + id + '": ' + String(err));
          return;
        }
        const playId = typeof startedId === 'number' ? startedId : existingId;
        if (typeof playId !== 'number') {
          player.off('playerror', onPlayError);
          finishWithError('No playback handle for "' + id + '".');
          return;
        }
        if (player.playing(playId)) {
          player.off('playerror', onPlayError);
          finishSuccess(playId);
          return;
        }
        player.once('play', function(playedId) {
          if (playedId !== playId) return;
          player.off('playerror', onPlayError);
          finishSuccess(playId);
        }, playId);
        setTimeout(function() {
          player.off('playerror', onPlayError);
          finishWithError('Playback start timed out for "' + id + '".');
        }, 5000);
      } catch (err) {
        reject(err);
      }
    });
  }

  function pauseLayer(id) {
    return new Promise(function(resolve) {
      const player = engine.players.get(id);
      const playId = engine.playIds.get(id);
      if (!player || playId == null || !player.playing(playId)) {
        resolve();
        return;
      }
      const current = player.volume(playId);
      player.fade(current, 0, FADE_MS, playId);
      setTimeout(function() {
        try { player.pause(playId); } catch (_) {}
        resolve();
      }, FADE_MS + 20);
    });
  }

  function stopLayer(id) {
    return new Promise(function(resolve) {
      const player = engine.players.get(id);
      const playId = engine.playIds.get(id);
      if (!player || playId == null) {
        resolve();
        return;
      }
      const current = player.volume(playId);
      player.fade(current, 0, FADE_MS, playId);
      setTimeout(function() {
        try { player.stop(playId); } catch (_) {}
        resolve();
      }, FADE_MS + 20);
    });
  }

  async function startEnabledLayers() {
    const enabledIds = IDS.filter(function(id) { return layerEnabled(id); });
    if (enabledIds.length === 0) {
      throw new Error('Enable at least one Sleep Sound to start playback.');
    }
    for (const id of enabledIds) {
      await startLayer(id);
    }
    for (const id of IDS) {
      if (!layerEnabled(id)) {
        await pauseLayer(id);
      }
    }
  }

  async function pauseAllLayers() {
    const layers = activeLayers();
    for (const id of layers) {
      await pauseLayer(id);
    }
  }

  async function stopAllLayers() {
    const ids = Array.from(engine.playIds.keys());
    for (const id of ids) {
      await stopLayer(id);
    }
  }

  async function syncLayer(id) {
    ensurePlayer(id);
    if (!engine.playing || engine.paused) {
      return;
    }
    if (layerEnabled(id)) {
      await startLayer(id);
      applyLayerVolume(id, FADE_MS);
      return;
    }
    await pauseLayer(id);
  }

  async function syncMix() {
    for (const id of IDS) {
      await syncLayer(id);
    }
  }

  function applyMasterVolume() {
    IDS.forEach(function(id) {
      applyLayerVolume(id, FADE_MS);
    });
  }

  function sendStatus(commandId) {
    emit('status', {
      commandId: commandId || null,
      playing: engine.playing,
      paused: engine.paused,
      preset: engine.preset,
      masterVolume: engine.masterVolume,
      perSoundVolume: engine.volumes,
      activeLayers: activeLayers(),
      capabilities: engine.capabilities
    });
  }

  function applyPreset(preset) {
    const key = String(preset || '').trim();
    if (!key) return;
    engine.preset = key;
    if (key === 'heavy-rain') {
      engine.enabled = {
        'heavy-rain': true,
        'thunder': false,
        'white-noise': false,
        'pink-noise': false
      };
      return;
    }
    if (key === 'thunder') {
      engine.enabled = {
        'heavy-rain': true,
        'thunder': true,
        'white-noise': false,
        'pink-noise': false
      };
      return;
    }
    if (key === 'white-noise') {
      engine.enabled = {
        'heavy-rain': false,
        'thunder': false,
        'white-noise': true,
        'pink-noise': false
      };
      return;
    }
    if (key === 'pink-noise') {
      engine.enabled = {
        'heavy-rain': false,
        'thunder': false,
        'white-noise': false,
        'pink-noise': true
      };
      return;
    }
    engine.enabled = {
      'heavy-rain': true,
      'thunder': true,
      'white-noise': true,
      'pink-noise': true
    };
  }

  async function commandHandler(raw) {
    let cmd = raw;
    if (typeof raw === 'string') {
      try { cmd = JSON.parse(raw); } catch (_) { cmd = { action: '' }; }
    }
    const action = (cmd.action || '').toString();
    const commandId = cmd.commandId || null;
    if (typeof cmd.attemptId === 'string' && cmd.attemptId.trim().length > 0) {
      currentAttemptId = cmd.attemptId.trim();
    }
    try {
      if (action === 'initialize') {
        stage('javascript-bootstrap-reached');
        if (cmd.preset) {
          applyPreset(cmd.preset);
        }
        if (typeof cmd.masterVolume === 'number') {
          engine.masterVolume = clamp(cmd.masterVolume, 0, 1);
        }
        if (cmd.enabled && typeof cmd.enabled === 'object') {
          IDS.forEach(function(id) {
            if (Object.prototype.hasOwnProperty.call(cmd.enabled, id)) {
              engine.enabled[id] = toBoolean(cmd.enabled[id]);
            }
          });
        }
        if (cmd.volumes && typeof cmd.volumes === 'object') {
          IDS.forEach(function(id) {
            if (Object.prototype.hasOwnProperty.call(cmd.volumes, id)) {
              engine.volumes[id] = clamp(cmd.volumes[id], 0, 1);
            }
          });
        }
        IDS.forEach(function(id) {
          ensurePlayer(id);
        });
        stage('assets-preloaded');
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'ping') {
        emit('pong', { commandId: commandId, action: action, attemptId: currentAttemptId });
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'howlerStatus') {
        emit('howler-status', {
          commandId: commandId,
          action: action,
          attemptId: currentAttemptId,
          available: typeof Howl === 'function',
          audioContextState: Howler && Howler.ctx ? Howler.ctx.state : 'unknown'
        });
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'probeHeavyRain') {
        const player = ensurePlayer('heavy-rain');
        if (player.state() === 'loaded') {
          emit('probe-heavy-rain-ok', { attemptId: currentAttemptId, from: 'cached' });
        } else {
          player.once('load', function() {
            emit('probe-heavy-rain-ok', { attemptId: currentAttemptId });
          });
          player.once('loaderror', function(_, err) {
            emit('error', { action: action, message: 'Heavy Rain load failed: ' + String(err), attemptId: currentAttemptId });
          });
          player.load();
        }
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'applyPreset') {
        applyPreset(cmd.preset);
        if (engine.playing && !engine.paused) {
          await syncMix();
        }
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'applyMix') {
        if (cmd.enabled && typeof cmd.enabled === 'object') {
          IDS.forEach(function(id) {
            if (Object.prototype.hasOwnProperty.call(cmd.enabled, id)) {
              engine.enabled[id] = toBoolean(cmd.enabled[id]);
            }
          });
        }
        if (cmd.volumes && typeof cmd.volumes === 'object') {
          IDS.forEach(function(id) {
            if (Object.prototype.hasOwnProperty.call(cmd.volumes, id)) {
              engine.volumes[id] = clamp(cmd.volumes[id], 0, 1);
            }
          });
        }
        if (engine.playing && !engine.paused) {
          await syncMix();
        }
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'setLayerEnabled') {
        const id = String(cmd.soundId || '').trim();
        if (IDS.includes(id)) {
          engine.enabled[id] = toBoolean(cmd.enabled);
          await syncLayer(id);
        }
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'setMasterVolume') {
        engine.masterVolume = clamp(cmd.masterVolume, 0, 1);
        applyMasterVolume();
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'setPerSoundVolume') {
        const id = String(cmd.soundId || '').trim();
        if (IDS.includes(id)) {
          engine.volumes[id] = clamp(cmd.volume, 0, 1);
          applyLayerVolume(id, FADE_MS);
        }
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'play') {
        stage('play-requested');
        await startEnabledLayers();
        engine.playing = true;
        engine.paused = false;
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'pause') {
        await pauseAllLayers();
        engine.playing = true;
        engine.paused = true;
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'resume') {
        await startEnabledLayers();
        engine.playing = true;
        engine.paused = false;
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'stop') {
        await stopAllLayers();
        engine.playing = false;
        engine.paused = false;
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      if (action === 'status') {
        sendStatus(commandId);
        emit('ack', { commandId: commandId, action: action });
        return;
      }
      emit('ack', { commandId: commandId, action: action, ignored: true });
    } catch (err) {
      emit('error', {
        commandId: commandId,
        action: action,
        message: String(err && err.message ? err.message : err)
      });
    }
  }

  if (typeof Howl !== 'function') {
    emit('error', { message: 'Howler runtime did not initialize in embedded host.' });
  }
  window.addEventListener('error', function(event) {
    emit('js-error', {
      attemptId: currentAttemptId,
      message: event && event.message ? String(event.message) : 'Unknown JavaScript error'
    });
  });
  window.addEventListener('unhandledrejection', function(event) {
    let reason = 'Unknown rejection';
    try {
      reason = String(event && event.reason ? event.reason : reason);
    } catch (_) {}
    emit('js-error', { attemptId: currentAttemptId, message: reason });
  });
  if (supportsBridge) {
    window.chrome.webview.addEventListener('message', function(event) {
      commandHandler(event.data);
    });
  }
  emit('ready', {
    capabilities: engine.capabilities,
    source: 'moodist-howler-local-assets',
    howlerLoaded: typeof Howl === 'function',
    attemptId: currentAttemptId
  });
})();
</script>
</body>
</html>
''';
    _embeddedHtmlCache = html;
    return html;
  }

  Future<Map<String, String>> _loadSoundDataUris() async {
    final result = <String, String>{};
    for (final entry in _soundAssetPaths.entries) {
      final mimeType = _mimeTypeFor(entry.value);
      final bytes = await rootBundle.load(entry.value);
      result[entry.key] = _bytesToDataUri(bytes, mimeType);
    }
    return result;
  }

  String _bytesToDataUri(ByteData bytes, String mimeType) {
    final encoded = base64Encode(bytes.buffer.asUint8List());
    return 'data:$mimeType;base64,$encoded';
  }

  String _mimeTypeFor(String path) {
    if (path.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    if (path.endsWith('.wav')) {
      return 'audio/wav';
    }
    return 'application/octet-stream';
  }

  Future<void> _resetController() async {
    await _messageSub?.cancel();
    await _loadErrorSub?.cancel();
    await _loadingSub?.cancel();
    _messageSub = null;
    _loadErrorSub = null;
    _loadingSub = null;
    _viewAttachedCompleter = null;
    final active = _controller;
    _controller = null;
    if (active != null) {
      try {
        await active.dispose();
      } catch (_) {}
    }
  }

  Future<void> disposeHost() async {
    _disposed = true;
    await _resetController();
    _activeProfileId = null;
    _readyCompleter = null;
    notifyListeners();
  }

  void markWidgetAttached() {
    final completer = _viewAttachedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _traceStage(
    String stage, {
    LogLevel level = LogLevel.info,
    Map<String, Object?> details = const {},
  }) {
    final started = _attemptStartedAt;
    final elapsedMs = started == null
        ? 0
        : DateTime.now().difference(started).inMilliseconds;
    final payload = <String, Object?>{
      'attemptId': _activeAttemptId ?? '',
      'stage': stage,
      'elapsedMs': elapsedMs,
      ...details,
    };
    AppLog.instance.log(
      level,
      LogCategory.playback,
      'Sleep Sounds startup stage: $stage',
      details: payload,
    );
    _events.add({'type': 'trace', ...payload});
  }
}

class SleepSoundsEmbeddedHostView extends StatelessWidget {
  const SleepSoundsEmbeddedHostView({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SleepSoundsEmbeddedHost.instance,
      builder: (context, _) {
        final controller = SleepSoundsEmbeddedHost.instance.controller;
        if (controller == null) {
          return const SizedBox.shrink();
        }
        SleepSoundsEmbeddedHost.instance.markWidgetAttached();
        return IgnorePointer(
          child: Opacity(opacity: 0.01, child: Webview(controller)),
        );
      },
    );
  }
}
