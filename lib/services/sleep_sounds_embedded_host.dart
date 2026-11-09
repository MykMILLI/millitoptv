import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

class SleepSoundsEmbeddedHost extends ChangeNotifier {
  SleepSoundsEmbeddedHost._();
  static final SleepSoundsEmbeddedHost instance = SleepSoundsEmbeddedHost._();

  WebviewController? _controller;
  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<dynamic>? _loadErrorSub;
  StreamSubscription<dynamic>? _loadingSub;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  Completer<void>? _readyCompleter;
  int? _activeProfileId;
  bool _initializing = false;
  bool _disposed = false;
  String lastError = '';

  Stream<Map<String, dynamic>> get events => _events.stream;
  WebviewController? get controller => _controller;
  bool get ready => _readyCompleter?.isCompleted == true;
  int? get activeProfileId => _activeProfileId;

  Future<void> ensureReady(int profileId) async {
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
      await _resetController();
      final next = WebviewController();
      await next.initialize();
      await next.setBackgroundColor(Colors.black);
      await next.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

      _readyCompleter = Completer<void>();
      _controller = next;
      _activeProfileId = profileId;

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
      });

      await next.loadStringContent(_embeddedSleepSoundsHtml);
      await _readyCompleter!.future.timeout(const Duration(seconds: 15));
      _events.add({'type': 'host-ready'});
      notifyListeners();
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
    _events.add(map);
  }

  Future<void> _resetController() async {
    await _messageSub?.cancel();
    await _loadErrorSub?.cancel();
    await _loadingSub?.cancel();
    _messageSub = null;
    _loadErrorSub = null;
    _loadingSub = null;
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
        return IgnorePointer(
          child: Opacity(opacity: 0.01, child: Webview(controller)),
        );
      },
    );
  }
}

const String _embeddedSleepSoundsHtml = '''
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
(function() {
  const supportsBridge = !!(window.chrome && window.chrome.webview);
  const engine = {
    context: null,
    master: null,
    active: new Map(),
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

  function emit(type, payload) {
    if (!supportsBridge) return;
    const msg = Object.assign({ type }, payload || {});
    window.chrome.webview.postMessage(JSON.stringify(msg));
  }

  function ensureAudio() {
    if (engine.context) return;
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) throw new Error('Web Audio API is unavailable.');
    engine.context = new Ctx();
    engine.master = engine.context.createGain();
    engine.master.gain.value = engine.masterVolume;
    engine.master.connect(engine.context.destination);
  }

  function withTimeout(promise, ms, label) {
    return Promise.race([
      promise,
      new Promise((_, reject) => setTimeout(() => reject(new Error(label + ' timed out')), ms))
    ]);
  }

  function makeNoiseNode(kind) {
    const processor = engine.context.createScriptProcessor(4096, 1, 1);
    let brown = 0.0;
    let pink0 = 0.0;
    let pink1 = 0.0;
    let pink2 = 0.0;
    let pink3 = 0.0;
    let pink4 = 0.0;
    let pink5 = 0.0;
    let pink6 = 0.0;
    processor.onaudioprocess = function(e) {
      const out = e.outputBuffer.getChannelData(0);
      for (let i = 0; i < out.length; i++) {
        const white = Math.random() * 2 - 1;
        if (kind === 'white-noise') {
          out[i] = white * 0.45;
          continue;
        }
        if (kind === 'pink-noise') {
          pink0 = 0.99886 * pink0 + white * 0.0555179;
          pink1 = 0.99332 * pink1 + white * 0.0750759;
          pink2 = 0.96900 * pink2 + white * 0.1538520;
          pink3 = 0.86650 * pink3 + white * 0.3104856;
          pink4 = 0.55000 * pink4 + white * 0.5329522;
          pink5 = -0.7616 * pink5 - white * 0.0168980;
          const pink = pink0 + pink1 + pink2 + pink3 + pink4 + pink5 + pink6 + white * 0.5362;
          pink6 = white * 0.115926;
          out[i] = pink * 0.11;
          continue;
        }
        brown = (brown + (0.02 * white)) / 1.02;
        out[i] = brown * 3.5;
      }
    };
    return processor;
  }

  function createThunderLayer(gain) {
    const osc = engine.context.createOscillator();
    osc.type = 'sine';
    osc.frequency.value = 48;
    const rumble = engine.context.createGain();
    rumble.gain.value = 0.00001;
    osc.connect(rumble);
    rumble.connect(gain);
    osc.start();

    const timer = setInterval(() => {
      const now = engine.context.currentTime;
      const hit = 0.12 + Math.random() * 0.20;
      rumble.gain.cancelScheduledValues(now);
      rumble.gain.setValueAtTime(0.00001, now);
      rumble.gain.linearRampToValueAtTime(hit, now + 0.03);
      rumble.gain.exponentialRampToValueAtTime(0.00001, now + 1.2 + Math.random() * 1.8);
      osc.frequency.setValueAtTime(42 + Math.random() * 16, now);
    }, 3200 + Math.floor(Math.random() * 3000));
    return { osc, rumble, timer };
  }

  function baseGainFor(id) {
    switch (id) {
      case 'heavy-rain':
        return 0.34;
      case 'thunder':
        return 0.26;
      case 'white-noise':
        return 0.20;
      case 'pink-noise':
        return 0.18;
      case 'rain':
        return 0.20;
      case 'ocean':
        return 0.24;
      case 'forest':
        return 0.16;
      case 'brown-noise':
      default:
        return 0.28;
    }
  }

  function layerEnabled(id) {
    return engine.enabled[id] === true;
  }

  function layerVolume(id) {
    const raw = engine.volumes[id];
    if (typeof raw !== 'number' || Number.isNaN(raw)) {
      return 0.7;
    }
    return Math.max(0, Math.min(1, raw));
  }

  function applyLayerOutput(id) {
    const layer = engine.active.get(id);
    if (!layer || !layer.outputGain) return;
    const now = engine.context.currentTime;
    const target = layerEnabled(id) ? layerVolume(id) : 0;
    layer.outputGain.gain.cancelScheduledValues(now);
    layer.outputGain.gain.setValueAtTime(layer.outputGain.gain.value, now);
    layer.outputGain.gain.linearRampToValueAtTime(target, now + 0.08);
  }

  function startLayer(id) {
    if (engine.active.has(id)) {
      applyLayerOutput(id);
      return;
    }
    ensureAudio();
    const node = makeNoiseNode(id);
    const filter = engine.context.createBiquadFilter();
    const gain = engine.context.createGain();
    const outputGain = engine.context.createGain();
    const lfo = engine.context.createOscillator();
    const lfoGain = engine.context.createGain();
    let thunder = null;

    if (id === 'heavy-rain') {
      filter.type = 'highpass';
      filter.frequency.value = 800;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.23;
      lfoGain.gain.value = 0.05;
    } else if (id === 'thunder') {
      filter.type = 'lowpass';
      filter.frequency.value = 150;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.06;
      lfoGain.gain.value = 0.04;
      thunder = createThunderLayer(gain);
    } else if (id === 'white-noise') {
      filter.type = 'highpass';
      filter.frequency.value = 1200;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.12;
      lfoGain.gain.value = 0.015;
    } else if (id === 'pink-noise') {
      filter.type = 'bandpass';
      filter.frequency.value = 560;
      filter.Q.value = 0.5;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.08;
      lfoGain.gain.value = 0.02;
    } else if (id === 'rain') {
      filter.type = 'highpass';
      filter.frequency.value = 1300;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.18;
      lfoGain.gain.value = 0.03;
    } else if (id === 'ocean') {
      filter.type = 'lowpass';
      filter.frequency.value = 700;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.07;
      lfoGain.gain.value = 0.06;
    } else if (id === 'forest') {
      filter.type = 'bandpass';
      filter.frequency.value = 1800;
      filter.Q.value = 0.7;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.22;
      lfoGain.gain.value = 0.04;
    } else {
      filter.type = 'lowpass';
      filter.frequency.value = 260;
      gain.gain.value = baseGainFor(id);
      lfo.frequency.value = 0.03;
      lfoGain.gain.value = 0.05;
    }

    gain.gain.value *= layerVolume(id);
    outputGain.gain.value = 0;
    lfo.connect(lfoGain);
    lfoGain.connect(gain.gain);
    node.connect(filter);
    filter.connect(gain);
    gain.connect(outputGain);
    outputGain.connect(engine.master);
    lfo.start();
    engine.active.set(id, { node, filter, gain, outputGain, lfo, lfoGain, thunder });
    applyLayerOutput(id);
  }

  function stopLayer(id) {
    const entry = engine.active.get(id);
    if (!entry) return;
      try { entry.node.disconnect(); } catch (_) {}
      try { entry.filter.disconnect(); } catch (_) {}
      try { entry.gain.disconnect(); } catch (_) {}
      try { entry.outputGain.disconnect(); } catch (_) {}
      try { entry.lfo.stop(); } catch (_) {}
      try { entry.lfo.disconnect(); } catch (_) {}
      try { entry.lfoGain.disconnect(); } catch (_) {}
      if (entry.thunder) {
        try { clearInterval(entry.thunder.timer); } catch (_) {}
        try { entry.thunder.osc.stop(); } catch (_) {}
        try { entry.thunder.osc.disconnect(); } catch (_) {}
        try { entry.thunder.rumble.disconnect(); } catch (_) {}
      }
    engine.active.delete(id);
  }

  function stopAllLayers() {
    Array.from(engine.active.keys()).forEach((id) => stopLayer(id));
    engine.active.clear();
  }

  function mixForPreset(preset) {
    switch (preset) {
      case 'overnight-storm':
        return ['heavy-rain', 'thunder', 'white-noise', 'pink-noise'];
      case 'heavy-rain':
        return ['heavy-rain', 'white-noise'];
      case 'thunder':
        return ['thunder', 'heavy-rain'];
      case 'white-noise':
        return ['white-noise'];
      case 'pink-noise':
        return ['pink-noise'];
      default:
        return ['heavy-rain', 'thunder', 'white-noise', 'pink-noise'];
    }
  }

  function syncLayers() {
    const ids = ['heavy-rain', 'thunder', 'white-noise', 'pink-noise'];
    ids.forEach((id) => {
      if (!layerEnabled(id)) {
        stopLayer(id);
        return;
      }
      startLayer(id);
      applyLayerOutput(id);
    });
    if (engine.active.size === 0) {
      engine.playing = false;
      engine.paused = false;
    }
  }

  function applyMasterVolume() {
    if (!engine.master) return;
    engine.master.gain.value = Math.max(0, Math.min(1, engine.masterVolume));
  }

  function sendStatus(commandId) {
    emit('status', {
      commandId: commandId || null,
      playing: engine.playing,
      paused: engine.paused,
      preset: engine.preset,
      masterVolume: engine.masterVolume,
      perSoundVolume: engine.volumes,
      activeLayers: Array.from(engine.active.keys()).filter((id) => layerEnabled(id)),
      capabilities: engine.capabilities
    });
  }

  async function commandHandler(raw) {
    let cmd = raw;
    if (typeof raw === 'string') {
      try { cmd = JSON.parse(raw); } catch (_) { cmd = { action: '' }; }
    }
    const action = (cmd.action || '').toString();
    const commandId = cmd.commandId || null;
    try {
      if (action === 'initialize') {
        ensureAudio();
        if (cmd.preset) engine.preset = String(cmd.preset);
        if (typeof cmd.masterVolume === 'number') {
          engine.masterVolume = Math.max(0, Math.min(1, cmd.masterVolume));
          applyMasterVolume();
        }
        if (cmd.enabled && typeof cmd.enabled === 'object') {
          Object.keys(cmd.enabled).forEach((id) => {
            engine.enabled[id] = cmd.enabled[id] === true;
          });
        }
        if (cmd.volumes && typeof cmd.volumes === 'object') {
          Object.keys(cmd.volumes).forEach((id) => {
            const next = Number(cmd.volumes[id]);
            if (!Number.isNaN(next)) {
              engine.volumes[id] = Math.max(0, Math.min(1, next));
            }
          });
        }
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'applyPreset') {
        const preset = String(cmd.preset || '').trim();
        if (preset) engine.preset = preset;
        const nextLayers = mixForPreset(engine.preset);
        Object.keys(engine.enabled).forEach((id) => {
          engine.enabled[id] = nextLayers.includes(id);
        });
        if (engine.playing && !engine.paused) {
          syncLayers();
        }
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'applyMix') {
        if (cmd.enabled && typeof cmd.enabled === 'object') {
          Object.keys(cmd.enabled).forEach((id) => {
            engine.enabled[id] = cmd.enabled[id] === true;
          });
        }
        if (cmd.volumes && typeof cmd.volumes === 'object') {
          Object.keys(cmd.volumes).forEach((id) => {
            const next = Number(cmd.volumes[id]);
            if (!Number.isNaN(next)) {
              engine.volumes[id] = Math.max(0, Math.min(1, next));
            }
          });
        }
        if (engine.playing && !engine.paused) {
          syncLayers();
        }
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'setLayerEnabled') {
        const id = String(cmd.soundId || '').trim();
        if (id) {
          engine.enabled[id] = cmd.enabled === true;
          if (engine.playing && !engine.paused) {
            syncLayers();
          }
        }
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'setMasterVolume') {
        const next = Number(cmd.masterVolume);
        if (!Number.isNaN(next)) {
          engine.masterVolume = Math.max(0, Math.min(1, next));
          applyMasterVolume();
        }
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'setPerSoundVolume') {
        const id = String(cmd.soundId || '').trim();
        const next = Number(cmd.volume);
        if (id && !Number.isNaN(next)) {
          engine.volumes[id] = Math.max(0, Math.min(1, next));
          applyLayerOutput(id);
        }
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'play') {
        ensureAudio();
        syncLayers();
        if (engine.active.size == 0) {
          throw new Error('Enable at least one Sleep Sound to start playback.');
        }
        await withTimeout(engine.context.resume(), 3000, 'Audio resume');
        engine.playing = true;
        engine.paused = false;
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'pause') {
        ensureAudio();
        await withTimeout(engine.context.suspend(), 3000, 'Audio pause');
        engine.paused = true;
        engine.playing = true;
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'resume') {
        ensureAudio();
        if (engine.active.size === 0) {
          syncLayers();
        }
        if (engine.active.size == 0) {
          throw new Error('Enable at least one Sleep Sound to resume playback.');
        }
        await withTimeout(engine.context.resume(), 3000, 'Audio resume');
        engine.paused = false;
        engine.playing = true;
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'stop') {
        ensureAudio();
        stopAllLayers();
        engine.paused = false;
        engine.playing = false;
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      if (action === 'status') {
        sendStatus(commandId);
        emit('ack', { commandId, action });
        return;
      }
      emit('error', { commandId, message: 'Unknown action: ' + action });
    } catch (err) {
      emit('error', { commandId, message: String(err) });
    }
  }

  if (supportsBridge) {
    window.chrome.webview.addEventListener('message', (event) => {
      commandHandler(event.data);
    });
  }
  emit('ready', {
    preset: engine.preset,
    masterVolume: engine.masterVolume,
    perSoundVolume: engine.volumes,
    capabilities: engine.capabilities
  });
})();
</script>
</body>
</html>
''';
