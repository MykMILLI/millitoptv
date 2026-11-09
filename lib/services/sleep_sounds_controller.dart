import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'home_preferences.dart';
import 'sleep_sounds_native_backend.dart';

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
    required Map<String, bool> enabled,
    required Map<String, double> volumes,
  });
  Future<void> applyPreset(String preset);
  Future<void> setMasterVolume(double masterVolume);
  Future<void> applyMix({
    required Map<String, bool> enabled,
    required Map<String, double> volumes,
  });
  Future<void> setLayerEnabled(String soundId, bool enabled);
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
    required Map<String, bool> enabled,
    required Map<String, double> volumes,
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
  Future<void> applyMix({
    required Map<String, bool> enabled,
    required Map<String, double> volumes,
  }) async {
    throw UnsupportedError(
      'In-app layer mixing is only available in embedded Sleep Sounds mode.',
    );
  }

  @override
  Future<void> setLayerEnabled(String soundId, bool enabled) async {
    throw UnsupportedError(
      'In-app layer mixing is only available in embedded Sleep Sounds mode.',
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

class SleepSoundsController extends ChangeNotifier {
  SleepSoundsController._();
  static final instance = SleepSoundsController._();
  static const List<String> simpleSoundIds = <String>[
    'heavy-rain',
    'thunder',
    'white-noise',
    'pink-noise',
  ];
  static const Map<String, double> defaultPerSoundVolume = <String, double>{
    'heavy-rain': 70,
    'thunder': 35,
    'white-noise': 25,
    'pink-noise': 40,
  };
  static const Map<String, bool> defaultEnabledMap = <String, bool>{
    'heavy-rain': true,
    'thunder': true,
    'white-noise': true,
    'pink-noise': true,
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
  Map<String, bool> soundEnabled = Map<String, bool>.from(defaultEnabledMap);
  List<String> activeLayers = const <String>[];
  int? stopAtWeekdayMinutes;
  int? stopAtWeekendMinutes;

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
  final Map<String, Timer> _volumeDebounceBySound = <String, Timer>{};
  Timer? _autoStopTicker;
  DateTime? _lastAutoStopLocalDate;

  Future<void> loadPreferences(int profileId) async {
    if (running && activeProfileId == profileId) {
      return;
    }
    final prefs = HomePreferences();
    selectedPreset = await prefs.sleepSoundsPreset(profileId);
    volume = await prefs.sleepSoundsVolume(profileId);
    final storedPerSound = await prefs.sleepSoundsPerSoundVolumes(profileId);
    final mergedPerSound = Map<String, double>.from(defaultPerSoundVolume)
      ..addAll(storedPerSound);
    final storedEnabled = await prefs.sleepSoundsEnabledMap(profileId);
    final mergedEnabled = Map<String, bool>.from(defaultEnabledMap)
      ..addAll(storedEnabled);
    // One-time migration from legacy presets to the simplified 4-layer mix.
    if (!storedEnabled.keys.any((key) => simpleSoundIds.contains(key))) {
      final preset = selectedPreset.trim().toLowerCase();
      if (preset == 'heavy-rain') {
        mergedEnabled
          ..['heavy-rain'] = true
          ..['thunder'] = false
          ..['white-noise'] = false
          ..['pink-noise'] = false;
      } else if (preset == 'thunder') {
        mergedEnabled
          ..['heavy-rain'] = true
          ..['thunder'] = true
          ..['white-noise'] = false
          ..['pink-noise'] = false;
      } else if (preset == 'white-noise') {
        mergedEnabled
          ..['heavy-rain'] = false
          ..['thunder'] = false
          ..['white-noise'] = true
          ..['pink-noise'] = false;
      } else if (preset == 'pink-noise') {
        mergedEnabled
          ..['heavy-rain'] = false
          ..['thunder'] = false
          ..['white-noise'] = false
          ..['pink-noise'] = true;
      }
    }
    perSoundVolume = {
      for (final id in simpleSoundIds)
        id: mergedPerSound[id] ?? defaultPerSoundVolume[id]!,
    };
    soundEnabled = {
      for (final id in simpleSoundIds)
        id: mergedEnabled[id] ?? defaultEnabledMap[id]!,
    };
    final storedBackend = await prefs.sleepSoundsBackend(profileId);
    stopAtWeekdayMinutes = await prefs.sleepSoundsStopAtWeekdayMinutes(
      profileId,
    );
    stopAtWeekendMinutes = await prefs.sleepSoundsStopAtWeekendMinutes(
      profileId,
    );
    backend = switch (storedBackend) {
      'browser' => SleepSoundsBackend.browserFallback,
      _ => SleepSoundsBackend.embeddedWebView,
    };
    _refreshAutoStopTicker();
    notifyListeners();
  }

  Future<void> savePreferences(int profileId) async {
    final prefs = HomePreferences();
    await prefs.setSleepSoundsPreset(profileId, selectedPreset);
    await prefs.setSleepSoundsVolume(profileId, volume);
    await prefs.setSleepSoundsPerSoundVolumes(profileId, perSoundVolume);
    await prefs.setSleepSoundsEnabledMap(profileId, soundEnabled);
    await prefs.setSleepSoundsStopAtWeekdayMinutes(
      profileId,
      stopAtWeekdayMinutes,
    );
    await prefs.setSleepSoundsStopAtWeekendMinutes(
      profileId,
      stopAtWeekendMinutes,
    );
    await prefs.setSleepSoundsBackend(
      profileId,
      backend == SleepSoundsBackend.embeddedWebView ? 'embedded' : 'browser',
    );
  }

  Future<void> setScheduledStopMinutes({
    required int profileId,
    int? weekdayMinutes,
    int? weekendMinutes,
  }) async {
    stopAtWeekdayMinutes = weekdayMinutes;
    stopAtWeekendMinutes = weekendMinutes;
    await savePreferences(profileId);
    _refreshAutoStopTicker();
    notifyListeners();
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
    _volumeDebounceBySound[normalizedSoundId]?.cancel();
    _volumeDebounceBySound[normalizedSoundId] = Timer(
      const Duration(milliseconds: 120),
      () {
        unawaited(
          _enqueue(() async {
            await backend.setPerSoundVolume(normalizedSoundId, normalized);
          }).catchError((error) {
            state = SleepSoundsState.error;
            this.error = error.toString();
            message = 'Could not update $normalizedSoundId volume.';
            notifyListeners();
          }),
        );
      },
    );
  }

  Future<void> setSoundEnabled(String soundId, bool enabled) async {
    final normalizedSoundId = soundId.trim().toLowerCase();
    if (!simpleSoundIds.contains(normalizedSoundId)) {
      throw FormatException('Unsupported Sleep Sound: $soundId');
    }
    soundEnabled = Map<String, bool>.from(soundEnabled)
      ..[normalizedSoundId] = enabled;
    error = '';
    notifyListeners();
    final backend = _activeBackend;
    if (backend == null || !running) {
      message = 'Mix updated. Press Start sounds to apply.';
      notifyListeners();
      return;
    }
    await _enqueue(() async {
      await backend.setLayerEnabled(normalizedSoundId, enabled);
      await backend.setPerSoundVolume(
        normalizedSoundId,
        perSoundVolume[normalizedSoundId] ?? 0,
      );
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
  }) => _enqueue(() async {
    await _startOrReconfigure(
      profileId: profileId,
      url: url,
      launcher: launcher,
      stopper: stopper,
    );
  });

  Future<void> _startOrReconfigure({
    required int profileId,
    required String url,
    Future<void> Function(int profileId, String url)? launcher,
    Future<void> Function(int profileId)? stopper,
  }) async {
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
    final anyEnabled = soundEnabled.values.any((enabled) => enabled);
    if (!anyEnabled) {
      state = SleepSoundsState.stopped;
      message = 'Enable at least one sound to start Sleep Sounds.';
      notifyListeners();
      return;
    }
    message = backend == SleepSoundsBackend.embeddedWebView
        ? 'Starting sounds...'
        : 'Opening Sleep Sounds browser fallback...';
    notifyListeners();
    try {
      final selectedBackend = _createBackend();
      await _attachBackend(selectedBackend);
      await selectedBackend.initialize(
        profileId: profileId,
        preset: selectedPreset,
        masterVolume: volume,
        enabled: {
          for (final id in simpleSoundIds) id: soundEnabled[id] ?? false,
        },
        volumes: {
          for (final id in simpleSoundIds)
            id: perSoundVolume[id] ?? defaultPerSoundVolume[id]!,
        },
      );
      if (capabilities.supportsMasterVolume) {
        await selectedBackend.setMasterVolume(volume);
      }
      if (capabilities.supportsPerSoundVolume) {
        await selectedBackend.applyMix(
          enabled: {
            for (final id in simpleSoundIds) id: soundEnabled[id] ?? false,
          },
          volumes: {
            for (final id in simpleSoundIds)
              id: perSoundVolume[id] ?? defaultPerSoundVolume[id]!,
          },
        );
      }
      await selectedBackend.play();
      state = SleepSoundsState.playing;
      if (activeLayers.isEmpty) {
        activeLayers = [
          for (final id in simpleSoundIds)
            if (soundEnabled[id] ?? false) id,
        ];
      }
      message = backend == SleepSoundsBackend.embeddedWebView
          ? 'Sleep sounds are playing.'
          : 'Sleep Sounds browser fallback opened.';
      _refreshAutoStopTicker();
      notifyListeners();
    } catch (e, stackTrace) {
      await _detachBackend();
      state = SleepSoundsState.error;
      error = e.toString().replaceFirst('Bad state: ', '');
      message = 'Could not start Sleep Sounds. Please retry.';
      AppLog.error(
        LogCategory.playback,
        'Sleep Sounds start attempt failed.',
        error: e,
        stackTrace: stackTrace,
      );
      notifyListeners();
      rethrow;
    }
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
      _refreshAutoStopTicker();
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
        await _startOrReconfigure(
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
      _refreshAutoStopTicker();
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
      _refreshAutoStopTicker();
      notifyListeners();
    } catch (e, stackTrace) {
      state = SleepSoundsState.error;
      error = e.toString().replaceFirst('Bad state: ', '');
      message = 'Could not stop Sleep Sounds.';
      AppLog.error(
        LogCategory.playback,
        'Sleep Sounds stop failed.',
        error: e,
        stackTrace: stackTrace,
      );
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
    _refreshAutoStopTicker();
    capabilities = this.backend == SleepSoundsBackend.embeddedWebView
        ? SleepSoundsCapabilities.embeddedDefault
        : SleepSoundsCapabilities.browserFallback;
  }

  void _refreshAutoStopTicker() {
    final hasSchedule =
        stopAtWeekdayMinutes != null || stopAtWeekendMinutes != null;
    if (!hasSchedule || !running) {
      _autoStopTicker?.cancel();
      _autoStopTicker = null;
      return;
    }
    _autoStopTicker ??= Timer.periodic(const Duration(seconds: 20), (_) {
      _checkScheduledStop();
    });
  }

  void _checkScheduledStop() {
    if (!running) {
      _refreshAutoStopTicker();
      return;
    }
    final now = DateTime.now();
    final isWeekend =
        now.weekday == DateTime.saturday || now.weekday == DateTime.sunday;
    final targetMinutes = isWeekend
        ? stopAtWeekendMinutes
        : stopAtWeekdayMinutes;
    if (targetMinutes == null) {
      return;
    }
    final nowMinutes = now.hour * 60 + now.minute;
    final day = DateTime(now.year, now.month, now.day);
    if (_lastAutoStopLocalDate == day) {
      return;
    }
    if (nowMinutes < targetMinutes) {
      return;
    }
    _lastAutoStopLocalDate = day;
    unawaited(
      _enqueue(() async {
        if (!running) {
          return;
        }
        await _stopInternal();
        message = 'Sleep sounds stopped on schedule.';
        AppLog.info(
          LogCategory.playback,
          'Sleep Sounds auto-stop reached.',
          details: {
            'weekdayMinutes': stopAtWeekdayMinutes,
            'weekendMinutes': stopAtWeekendMinutes,
          },
        );
        notifyListeners();
      }).catchError((error, stackTrace) {
        AppLog.error(
          LogCategory.playback,
          'Sleep Sounds auto-stop failed.',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  SleepSoundsPlaybackBackend _createBackend() {
    if (backend == SleepSoundsBackend.embeddedWebView) {
      final overrideFactory = _embeddedFactoryOverride;
      return overrideFactory != null
          ? overrideFactory()
          : NativeSleepSoundsBackend();
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
    for (final timer in _volumeDebounceBySound.values) {
      timer.cancel();
    }
    _autoStopTicker?.cancel();
    _autoStopTicker = null;
    _volumeDebounceBySound.clear();
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
    soundEnabled = Map<String, bool>.from(defaultEnabledMap);
    activeLayers = const <String>[];
    stopAtWeekdayMinutes = null;
    stopAtWeekendMinutes = null;
    _lastAutoStopLocalDate = null;
    _activeCommand = null;
    notifyListeners();
  }
}
