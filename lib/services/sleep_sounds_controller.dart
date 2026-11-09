import 'dart:async';

import 'package:flutter/foundation.dart';

import 'home_preferences.dart';
import 'sleep_sounds_embedded_host.dart';

enum SleepSoundsBackend { browserFallback, embeddedWebView }

enum SleepSoundsState { stopped, loading, playing, paused, error }

@immutable
class SleepSoundsCapabilities {
  final bool supportsEmbeddedPlayback;
  final bool supportsPresets;
  final bool supportsPauseResume;
  final bool supportsMasterVolume;
  final bool supportsPerSoundVolume;

  const SleepSoundsCapabilities({
    required this.supportsEmbeddedPlayback,
    required this.supportsPresets,
    required this.supportsPauseResume,
    required this.supportsMasterVolume,
    required this.supportsPerSoundVolume,
  });

  static const browserFallback = SleepSoundsCapabilities(
    supportsEmbeddedPlayback: false,
    supportsPresets: false,
    supportsPauseResume: false,
    supportsMasterVolume: false,
    supportsPerSoundVolume: false,
  );

  static const embeddedDefault = SleepSoundsCapabilities(
    supportsEmbeddedPlayback: true,
    supportsPresets: true,
    supportsPauseResume: true,
    supportsMasterVolume: true,
    supportsPerSoundVolume: true,
  );
}

@immutable
class SleepSoundsBackendStatus {
  final bool playing;
  final bool paused;
  final String preset;
  final double masterVolume;
  final Map<String, double> perSoundVolume;
  final List<String> activeLayers;
  final SleepSoundsCapabilities capabilities;

  const SleepSoundsBackendStatus({
    required this.playing,
    required this.paused,
    required this.preset,
    required this.masterVolume,
    required this.perSoundVolume,
    required this.activeLayers,
    required this.capabilities,
  });
}

abstract class SleepSoundsPlaybackBackend {
  SleepSoundsCapabilities get capabilities;
  Stream<SleepSoundsBackendStatus> get statusStream;
  Stream<String> get errorStream;

  Future<void> initialize({
    required int profileId,
    required String preset,
    required double masterVolume,
  });
  Future<void> applyPreset(String preset);
  Future<void> setMasterVolume(double masterVolume);
  Future<void> setPerSoundVolume(String soundId, double volume);
  Future<void> play();
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

class BrowserSleepSoundsBackend implements SleepSoundsPlaybackBackend {
  BrowserSleepSoundsBackend({
    required this.launcher,
    required this.stopper,
    required this.url,
  });

  final Future<void> Function(int profileId, String url) launcher;
  final Future<void> Function(int profileId) stopper;
  final String url;
  final StreamController<SleepSoundsBackendStatus> _status =
      StreamController<SleepSoundsBackendStatus>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();

  int? _profileId;
  bool _playing = false;
  bool _paused = false;
  String _preset = 'rain';
  double _masterVolume = 70;

  @override
  SleepSoundsCapabilities get capabilities =>
      SleepSoundsCapabilities.browserFallback;

  @override
  Stream<SleepSoundsBackendStatus> get statusStream => _status.stream;

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Future<void> initialize({
    required int profileId,
    required String preset,
    required double masterVolume,
  }) async {
    _profileId = profileId;
    _preset = preset;
    _masterVolume = masterVolume;
    _emitStatus();
  }

  @override
  Future<void> applyPreset(String preset) async {
    throw UnsupportedError(
      'Preset control is only available in embedded Sleep Sounds mode.',
    );
  }

  @override
  Future<void> setMasterVolume(double masterVolume) async {
    throw UnsupportedError(
      'In-app volume control is only available in embedded Sleep Sounds mode.',
    );
  }

  @override
  Future<void> setPerSoundVolume(String soundId, double volume) async {
    throw UnsupportedError(
      'Per-sound volume is only available in embedded Sleep Sounds mode.',
    );
  }

  @override
  Future<void> play() async {
    final profileId = _profileId;
    if (profileId == null) {
      throw StateError('Sleep Sounds browser backend was not initialized.');
    }
    await launcher(profileId, url);
    _playing = true;
    _paused = false;
    _emitStatus();
  }

  @override
  Future<void> pause() async {
    throw UnsupportedError(
      'Pause/resume is controlled by the website in browser fallback mode.',
    );
  }

  @override
  Future<void> resume() async {
    final profileId = _profileId;
    if (profileId == null) {
      throw StateError('Sleep Sounds browser backend was not initialized.');
    }
    await launcher(profileId, url);
    _playing = true;
    _paused = false;
    _emitStatus();
  }

  @override
  Future<void> stop() async {
    final profileId = _profileId;
    if (profileId == null) {
      return;
    }
    await stopper(profileId);
    _playing = false;
    _paused = false;
    _emitStatus();
  }

  @override
  Future<void> dispose() async {
    await _status.close();
    await _errors.close();
  }

  void _emitStatus() {
    _status.add(
      SleepSoundsBackendStatus(
        playing: _playing,
        paused: _paused,
        preset: _preset,
        masterVolume: _masterVolume,
        perSoundVolume: const {},
        activeLayers: const [],
        capabilities: capabilities,
      ),
    );
  }
}

class EmbeddedSleepSoundsBackend implements SleepSoundsPlaybackBackend {
  EmbeddedSleepSoundsBackend({SleepSoundsEmbeddedHost? host})
    : _host = host ?? SleepSoundsEmbeddedHost.instance {
    _eventsSub = _host.events.listen(_onEvent);
  }

  final SleepSoundsEmbeddedHost _host;
  final StreamController<SleepSoundsBackendStatus> _status =
      StreamController<SleepSoundsBackendStatus>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final Map<String, Completer<void>> _pending = <String, Completer<void>>{};
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  int _counter = 0;
  SleepSoundsCapabilities _capabilities =
      SleepSoundsCapabilities.embeddedDefault;

  @override
  SleepSoundsCapabilities get capabilities => _capabilities;

  @override
  Stream<SleepSoundsBackendStatus> get statusStream => _status.stream;

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Future<void> initialize({
    required int profileId,
    required String preset,
    required double masterVolume,
  }) async {
    await _host.ensureReady(profileId);
    await _send(
      'initialize',
      payload: {
        'preset': preset,
        'masterVolume': (masterVolume / 100).clamp(0, 1),
      },
    );
    await _send('status');
  }

  @override
  Future<void> applyPreset(String preset) =>
      _send('applyPreset', payload: {'preset': preset});

  @override
  Future<void> setMasterVolume(double masterVolume) => _send(
    'setMasterVolume',
    payload: {'masterVolume': (masterVolume / 100).clamp(0, 1)},
  );

  @override
  Future<void> setPerSoundVolume(String soundId, double volume) => _send(
    'setPerSoundVolume',
    payload: {'soundId': soundId, 'volume': (volume / 100).clamp(0, 1)},
  );

  @override
  Future<void> play() => _send('play');

  @override
  Future<void> pause() => _send('pause');

  @override
  Future<void> resume() => _send('resume');

  @override
  Future<void> stop() => _send('stop');

  @override
  Future<void> dispose() async {
    await _eventsSub?.cancel();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          StateError('Sleep Sounds embedded backend was disposed.'),
        );
      }
    }
    _pending.clear();
    await _status.close();
    await _errors.close();
  }

  Future<void> _send(String action, {Map<String, dynamic>? payload}) async {
    final commandId = 'embedded-${++_counter}';
    final completer = Completer<void>();
    _pending[commandId] = completer;
    try {
      await _host.postCommand({
        'commandId': commandId,
        'action': action,
        ...?payload,
      });
    } catch (error) {
      _pending.remove(commandId);
      rethrow;
    }
    await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        _pending.remove(commandId);
        throw StateError(
          'Sleep Sounds command "$action" timed out waiting for acknowledgement.',
        );
      },
    );
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString() ?? '';
    if (type == 'ack') {
      final commandId = event['commandId']?.toString();
      if (commandId != null) {
        final completer = _pending.remove(commandId);
        completer?.complete();
      }
      return;
    }
    if (type == 'error') {
      final message = event['message']?.toString() ?? 'Unknown embedded error.';
      final commandId = event['commandId']?.toString();
      if (commandId != null) {
        final completer = _pending.remove(commandId);
        completer?.completeError(StateError(message));
      }
      _errors.add(message);
      return;
    }
    if (type != 'status' && type != 'ready') {
      return;
    }
    final caps = event['capabilities'];
    if (caps is Map) {
      _capabilities = SleepSoundsCapabilities(
        supportsEmbeddedPlayback:
            caps['supportsEmbeddedPlayback'] as bool? ?? true,
        supportsPresets: caps['supportsPresets'] as bool? ?? true,
        supportsPauseResume: caps['supportsPauseResume'] as bool? ?? true,
        supportsMasterVolume: true,
        supportsPerSoundVolume: caps['supportsPerSoundVolume'] as bool? ?? true,
      );
    }
    final perSoundRaw = event['perSoundVolume'];
    final perSound = <String, double>{};
    if (perSoundRaw is Map) {
      for (final entry in perSoundRaw.entries) {
        final key = entry.key.toString();
        final value = (entry.value as num?)?.toDouble();
        if (value != null) {
          perSound[key] = value.clamp(0, 1) * 100;
        }
      }
    }
    final layersRaw = event['activeLayers'];
    final layers = <String>[];
    if (layersRaw is List) {
      for (final layer in layersRaw) {
        layers.add(layer.toString());
      }
    }
    final master = (event['masterVolume'] as num?)?.toDouble();
    _status.add(
      SleepSoundsBackendStatus(
        playing: event['playing'] as bool? ?? false,
        paused: event['paused'] as bool? ?? false,
        preset: event['preset']?.toString() ?? 'rain',
        masterVolume: ((master ?? 0.7).clamp(0, 1) * 100).toDouble(),
        perSoundVolume: perSound,
        activeLayers: layers,
        capabilities: _capabilities,
      ),
    );
  }
}

class SleepSoundsController extends ChangeNotifier {
  SleepSoundsController._();
  static final instance = SleepSoundsController._();
  static const Map<String, double> defaultPerSoundVolume = <String, double>{
    'heavy-rain': 82,
    'thunder': 58,
    'white-noise': 64,
    'pink-noise': 60,
    'rain': 78,
    'ocean': 75,
    'forest': 72,
    'brown-noise': 70,
  };

  SleepSoundsBackend backend = SleepSoundsBackend.embeddedWebView;
  SleepSoundsState state = SleepSoundsState.stopped;
  int? activeProfileId;
  String selectedPreset = 'overnight-storm';
  double volume = 70;
  String message = '';
  String error = '';
  SleepSoundsCapabilities capabilities =
      SleepSoundsCapabilities.embeddedDefault;
  Map<String, double> perSoundVolume = Map<String, double>.from(
    defaultPerSoundVolume,
  );
  List<String> activeLayers = const <String>[];

  bool get running =>
      state == SleepSoundsState.loading ||
      state == SleepSoundsState.playing ||
      state == SleepSoundsState.paused;

  Future<void> Function(int profileId, String url)? _launcher;
  Future<void> Function(int profileId)? _stopper;
  String? _activeUrl;
  SleepSoundsPlaybackBackend? _activeBackend;
  StreamSubscription<SleepSoundsBackendStatus>? _backendStatusSub;
  StreamSubscription<String>? _backendErrorSub;
  Future<void>? _activeCommand;
  SleepSoundsPlaybackBackend Function()? _embeddedFactoryOverride;

  Future<void> loadPreferences(int profileId) async {
    final prefs = HomePreferences();
    selectedPreset = await prefs.sleepSoundsPreset(profileId);
    volume = await prefs.sleepSoundsVolume(profileId);
    final storedPerSound = await prefs.sleepSoundsPerSoundVolumes(profileId);
    perSoundVolume = Map<String, double>.from(defaultPerSoundVolume)
      ..addAll(storedPerSound);
    final storedBackend = await prefs.sleepSoundsBackend(profileId);
    backend = switch (storedBackend) {
      'browser' => SleepSoundsBackend.browserFallback,
      _ => SleepSoundsBackend.embeddedWebView,
    };
    notifyListeners();
  }

  Future<void> savePreferences(int profileId) async {
    final prefs = HomePreferences();
    await prefs.setSleepSoundsPreset(profileId, selectedPreset);
    await prefs.setSleepSoundsVolume(profileId, volume);
    await prefs.setSleepSoundsPerSoundVolumes(profileId, perSoundVolume);
    await prefs.setSleepSoundsBackend(
      profileId,
      backend == SleepSoundsBackend.embeddedWebView ? 'embedded' : 'browser',
    );
  }

  void setPreset(String value) {
    final next = value.trim();
    if (next.isEmpty || selectedPreset == next) {
      return;
    }
    selectedPreset = next;
    notifyListeners();
    final backend = _activeBackend;
    if (backend != null &&
        running &&
        capabilities.supportsPresets &&
        state != SleepSoundsState.loading) {
      unawaited(
        _enqueue(() async {
          await backend.applyPreset(next);
        }).catchError((error) {
          state = SleepSoundsState.error;
          this.error = error.toString();
          message = 'Could not apply Sleep Sounds preset.';
          notifyListeners();
        }),
      );
    }
  }

  void setVolume(double value) {
    final normalized = value.clamp(0, 100).toDouble();
    if (normalized == volume) {
      return;
    }
    volume = normalized;
    notifyListeners();
    final backend = _activeBackend;
    if (backend != null &&
        running &&
        capabilities.supportsMasterVolume &&
        state != SleepSoundsState.loading) {
      unawaited(
        _enqueue(() async {
          await backend.setMasterVolume(normalized);
        }).catchError((error) {
          state = SleepSoundsState.error;
          this.error = error.toString();
          message = 'Could not set Sleep Sounds volume.';
          notifyListeners();
        }),
      );
    }
  }

  Future<void> setPerSoundVolume(String soundId, double value) async {
    final normalizedSoundId = soundId.trim().toLowerCase();
    if (normalizedSoundId.isEmpty) {
      throw const FormatException('Sleep Sounds id cannot be empty.');
    }
    final backend = _activeBackend;
    final normalized = value.clamp(0, 100).toDouble();
    perSoundVolume = Map<String, double>.from(perSoundVolume)
      ..[normalizedSoundId] = normalized;
    error = '';
    notifyListeners();
    if (backend == null || !running) {
      message =
          'Per-sound volumes saved. They will apply when Sleep Sounds starts.';
      notifyListeners();
      return;
    }
    if (!capabilities.supportsPerSoundVolume) {
      message =
          'Per-sound levels are available when using the embedded Sleep Sounds backend.';
      notifyListeners();
      return;
    }
    await _enqueue(() async {
      await backend.setPerSoundVolume(normalizedSoundId, normalized);
    });
  }

  void setBackend(SleepSoundsBackend value) {
    if (backend == value) {
      return;
    }
    backend = value;
    message = running
        ? 'Backend changed. Stop Sleep Sounds and start again to switch backends.'
        : '';
    notifyListeners();
  }

  Future<void> play({
    required int profileId,
    required String url,
    Future<void> Function(int profileId, String url)? launcher,
    Future<void> Function(int profileId)? stopper,
  }) {
    return _enqueue(() async {
      if (state == SleepSoundsState.loading) {
        throw StateError('Sleep Sounds is already processing a command.');
      }
      if (running && activeProfileId != null && activeProfileId != profileId) {
        await _stopInternal();
      }
      _launcher = launcher ?? _launcher;
      _stopper = stopper ?? _stopper;
      _activeUrl = url;
      activeProfileId = profileId;
      state = SleepSoundsState.loading;
      error = '';
      message = backend == SleepSoundsBackend.embeddedWebView
          ? 'Preparing embedded Sleep Sounds...'
          : 'Opening Sleep Sounds browser fallback...';
      notifyListeners();
      final selectedBackend = _createBackend();
      await _attachBackend(selectedBackend);
      await selectedBackend.initialize(
        profileId: profileId,
        preset: selectedPreset,
        masterVolume: volume,
      );
      if (capabilities.supportsPresets) {
        await selectedBackend.applyPreset(selectedPreset);
      }
      if (capabilities.supportsMasterVolume) {
        await selectedBackend.setMasterVolume(volume);
      }
      if (capabilities.supportsPerSoundVolume) {
        for (final entry in perSoundVolume.entries) {
          await selectedBackend.setPerSoundVolume(entry.key, entry.value);
        }
      }
      await selectedBackend.play();
      state = SleepSoundsState.playing;
      if (activeLayers.isEmpty) {
        activeLayers = _expectedLayersForPreset(selectedPreset);
      }
      message = backend == SleepSoundsBackend.embeddedWebView
          ? 'Sleep Sounds is running in-app.'
          : 'Sleep Sounds browser fallback opened.';
      notifyListeners();
    });
  }

  Future<void> pause() {
    return _enqueue(() async {
      final backend = _activeBackend;
      if (backend == null) {
        throw StateError('Sleep Sounds is not running.');
      }
      if (!capabilities.supportsPauseResume) {
        throw UnsupportedError(
          'Pause/resume is unavailable for the current Sleep Sounds backend.',
        );
      }
      state = SleepSoundsState.loading;
      notifyListeners();
      await backend.pause();
      state = SleepSoundsState.paused;
      message = 'Sleep Sounds paused.';
      notifyListeners();
    });
  }

  Future<void> resume() {
    return _enqueue(() async {
      final backend = _activeBackend;
      if (backend == null) {
        final profile = activeProfileId;
        final launch = _launcher;
        final url = _activeUrl;
        if (profile == null || launch == null || url == null) {
          throw StateError('Sleep Sounds is not configured for resume.');
        }
        await play(
          profileId: profile,
          url: url,
          launcher: launch,
          stopper: _stopper,
        );
        return;
      }
      if (!capabilities.supportsPauseResume) {
        throw UnsupportedError(
          'Pause/resume is unavailable for the current Sleep Sounds backend.',
        );
      }
      state = SleepSoundsState.loading;
      notifyListeners();
      await backend.resume();
      state = SleepSoundsState.playing;
      message = 'Sleep Sounds resumed.';
      notifyListeners();
    });
  }

  Future<void> stop() => _enqueue(_stopInternal);

  Future<void> _stopInternal() async {
    final backend = _activeBackend;
    if (backend == null) {
      state = SleepSoundsState.stopped;
      message = 'Sleep Sounds is not running.';
      notifyListeners();
      return;
    }
    state = SleepSoundsState.loading;
    notifyListeners();
    try {
      await backend.stop();
      await _detachBackend();
      state = SleepSoundsState.stopped;
      message = 'Sleep Sounds stopped.';
      error = '';
      activeLayers = const <String>[];
      notifyListeners();
    } catch (e) {
      state = SleepSoundsState.error;
      error = e.toString().replaceFirst('Bad state: ', '');
      message = 'Could not stop Sleep Sounds.';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _attachBackend(SleepSoundsPlaybackBackend backend) async {
    await _detachBackend();
    _activeBackend = backend;
    capabilities = backend.capabilities;
    _backendStatusSub = backend.statusStream.listen(_applyBackendStatus);
    _backendErrorSub = backend.errorStream.listen((backendError) {
      state = SleepSoundsState.error;
      error = backendError;
      message = 'Sleep Sounds backend reported an error.';
      notifyListeners();
    });
  }

  Future<void> _detachBackend() async {
    final statusSub = _backendStatusSub;
    final errorSub = _backendErrorSub;
    _backendStatusSub = null;
    _backendErrorSub = null;
    final backend = _activeBackend;
    _activeBackend = null;
    if (statusSub != null) {
      unawaited(statusSub.cancel());
    }
    if (errorSub != null) {
      unawaited(errorSub.cancel());
    }
    if (backend != null) {
      unawaited(backend.dispose());
    }
    capabilities = this.backend == SleepSoundsBackend.embeddedWebView
        ? SleepSoundsCapabilities.embeddedDefault
        : SleepSoundsCapabilities.browserFallback;
  }

  SleepSoundsPlaybackBackend _createBackend() {
    if (backend == SleepSoundsBackend.embeddedWebView) {
      final overrideFactory = _embeddedFactoryOverride;
      return overrideFactory != null
          ? overrideFactory()
          : EmbeddedSleepSoundsBackend();
    }
    final launcher = _launcher;
    final stopper = _stopper;
    final url = _activeUrl;
    if (launcher == null || stopper == null || url == null) {
      throw StateError(
        'Browser fallback is missing launch configuration. Open Sleep Sounds again from the panel.',
      );
    }
    return BrowserSleepSoundsBackend(
      launcher: launcher,
      stopper: stopper,
      url: url,
    );
  }

  void _applyBackendStatus(SleepSoundsBackendStatus status) {
    capabilities = status.capabilities;
    selectedPreset = status.preset;
    volume = status.masterVolume.clamp(0, 100).toDouble();
    perSoundVolume = status.perSoundVolume;
    activeLayers = status.activeLayers;
    if (status.playing && status.paused) {
      state = SleepSoundsState.paused;
    } else if (status.playing) {
      state = SleepSoundsState.playing;
    } else if (state == SleepSoundsState.loading) {
      state = SleepSoundsState.loading;
    } else {
      state = SleepSoundsState.stopped;
    }
    notifyListeners();
  }

  List<String> _expectedLayersForPreset(String preset) {
    switch (preset) {
      case 'overnight-storm':
        return const ['heavy-rain', 'thunder', 'white-noise', 'pink-noise'];
      case 'heavy-rain':
        return const ['heavy-rain', 'white-noise'];
      case 'thunder':
        return const ['thunder', 'heavy-rain'];
      case 'white-noise':
        return const ['white-noise'];
      case 'pink-noise':
        return const ['pink-noise'];
      case 'ocean':
        return const ['ocean', 'brown-noise'];
      case 'forest':
        return const ['forest', 'rain'];
      case 'brown-noise':
        return const ['brown-noise'];
      case 'rain':
      default:
        return const ['rain', 'brown-noise'];
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() task) {
    return () async {
      while (_activeCommand != null) {
        try {
          await _activeCommand;
        } catch (_) {}
      }
      final gate = Completer<void>();
      _activeCommand = gate.future;
      try {
        return await task();
      } finally {
        gate.complete();
        if (identical(_activeCommand, gate.future)) {
          _activeCommand = null;
        }
      }
    }();
  }

  @visibleForTesting
  void setEmbeddedBackendFactoryForTesting(
    SleepSoundsPlaybackBackend Function() factory,
  ) {
    _embeddedFactoryOverride = factory;
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    await _detachBackend();
    _embeddedFactoryOverride = null;
    _launcher = null;
    _stopper = null;
    _activeUrl = null;
    activeProfileId = null;
    selectedPreset = 'overnight-storm';
    volume = 70;
    message = '';
    error = '';
    state = SleepSoundsState.stopped;
    backend = SleepSoundsBackend.embeddedWebView;
    capabilities = SleepSoundsCapabilities.embeddedDefault;
    perSoundVolume = Map<String, double>.from(defaultPerSoundVolume);
    activeLayers = const <String>[];
    _activeCommand = null;
    notifyListeners();
  }
}
