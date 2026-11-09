import 'dart:async';
import 'dart:math' as math;

import 'package:media_kit/media_kit.dart';

import 'app_log.dart';
import 'sleep_sounds_controller.dart';

/// Bundled Moodist recordings used by the in-app Sleep Sounds mixer.
///
/// Mirrors Moodist's playback model: one independent player per sound,
/// each looping its own recording, mixed by the OS audio stack.
const Map<String, String> sleepSoundAssetPaths = <String, String>{
  'heavy-rain': 'assets/native/sleep_sounds/moodist/rain/heavy-rain.mp3',
  'thunder': 'assets/native/sleep_sounds/moodist/rain/thunder.mp3',
  'white-noise': 'assets/native/sleep_sounds/moodist/noise/white-noise.wav',
  'pink-noise': 'assets/native/sleep_sounds/moodist/noise/pink-noise.wav',
};

/// One looping audio layer. Abstracted so tests can run without libmpv.
abstract class SleepSoundLayer {
  /// Loads the recording (once) without starting playback.
  Future<void> load();

  /// Starts or resumes playback and completes once audio is actually playing.
  Future<void> play();
  Future<void> pause();

  /// Linear gain, 0.0 – 1.0.
  Future<void> setGain(double gain);
  Future<void> dispose();

  bool get playing;
  Stream<String> get errors;
}

typedef SleepSoundLayerFactory = SleepSoundLayer Function(String soundId);

/// Native (libmpv via media_kit) looping layer.
///
/// Notes on seamless looping:
/// * The recording is queued twice in a looping playlist with
///   `gapless-audio=yes`, so every wrap is an mpv gapless file transition
///   rather than an end-of-file seek. That keeps the audio output open and
///   avoids the small hiccup `loop-file` can introduce.
/// * MP3 encoder padding is trimmed by FFmpeg when LAME gapless info exists.
class MediaKitSleepSoundLayer implements SleepSoundLayer {
  MediaKitSleepSoundLayer(this.soundId, this.assetPath);

  final String soundId;
  final String assetPath;
  Player? _player;
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  bool _playing = false;

  @override
  bool get playing => _playing;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> load() async {
    if (_player != null) return;
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: PlayerConfiguration(
        title: 'MILLITOP Sleep Sounds',
        logLevel: MPVLogLevel.error,
      ),
    );
    _player = player;
    _subs
      ..add(player.stream.playing.listen((value) => _playing = value))
      ..add(
        player.stream.error.listen((value) {
          if (value.trim().isEmpty) return;
          _errors.add('$soundId: $value');
        }),
      );
    final platform = player.platform;
    if (platform is NativePlayer) {
      // Audio only: never decode/show embedded MP3 cover art.
      await platform.setProperty('audio-display', 'no');
      await platform.setProperty('gapless-audio', 'yes');
      await platform.setProperty('prefetch-playlist', 'yes');
    }
    await player.setVolume(0);
    final uri = 'asset:///$assetPath';
    await player.open(Playlist([Media(uri), Media(uri)]), play: false);
    await player.setPlaylistMode(PlaylistMode.loop);
  }

  @override
  Future<void> play() async {
    final player = _player;
    if (player == null) {
      throw StateError('$soundId is not loaded.');
    }
    if (player.state.playing) return;
    final started = Completer<void>();
    final sub = player.stream.playing.listen((value) {
      if (value && !started.isCompleted) started.complete();
    });
    try {
      await player.play();
      if (!player.state.playing) {
        await started.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw StateError(
            'Could not start "$soundId". The audio device did not respond.',
          ),
        );
      }
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> pause() async {
    final player = _player;
    if (player == null || !player.state.playing) return;
    await player.pause();
  }

  @override
  Future<void> setGain(double gain) async {
    final player = _player;
    if (player == null) return;
    // mpv's volume uses a cubic curve; convert linear gain (like Moodist /
    // Howler) so slider percentages sound the same as in Moodist.
    final linear = gain.clamp(0.0, 1.0);
    final mpvVolume = linear <= 0 ? 0.0 : math.pow(linear, 1 / 3) * 100;
    await player.setVolume(mpvVolume.toDouble());
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final player = _player;
    _player = null;
    _playing = false;
    if (player != null) {
      await player.dispose();
    }
    await _errors.close();
  }
}

/// Plays the four Sleep Sounds layers natively inside the app.
///
/// Sleep Sounds is deliberately NOT registered with ViewingSessions, the
/// mixed playlist session, audio_service or the sleep-timer expiry path, so
/// the screen-off timer never stops it.
class NativeSleepSoundsBackend implements SleepSoundsPlaybackBackend {
  NativeSleepSoundsBackend({SleepSoundLayerFactory? layerFactory})
    : _layerFactory =
          layerFactory ??
          ((id) => MediaKitSleepSoundLayer(id, sleepSoundAssetPaths[id]!));

  static const Duration fade = Duration(milliseconds: 250);
  static const int _fadeSteps = 10;

  final SleepSoundLayerFactory _layerFactory;
  final Map<String, SleepSoundLayer> _layers = <String, SleepSoundLayer>{};
  final Map<String, StreamSubscription<String>> _layerErrorSubs =
      <String, StreamSubscription<String>>{};
  final Map<String, int> _fadeGeneration = <String, int>{};
  final Map<String, double> _gain = <String, double>{};
  final StreamController<SleepSoundsBackendStatus> _status =
      StreamController<SleepSoundsBackendStatus>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();

  Map<String, bool> _enabled = <String, bool>{};
  Map<String, double> _volumes = <String, double>{};
  String _preset = 'mix';
  double _master = 100;
  bool _playing = false;
  bool _paused = false;
  bool _disposed = false;

  static const SleepSoundsCapabilities _caps = SleepSoundsCapabilities(
    supportsEmbeddedPlayback: true,
    supportsPresets: false,
    supportsPauseResume: true,
    supportsMasterVolume: false,
    supportsPerSoundVolume: true,
  );

  @override
  SleepSoundsCapabilities get capabilities => _caps;

  @override
  Stream<SleepSoundsBackendStatus> get statusStream => _status.stream;

  @override
  Stream<String> get errorStream => _errors.stream;

  Iterable<String> get _ids => SleepSoundsController.simpleSoundIds;

  bool _isEnabled(String id) => _enabled[id] ?? false;

  /// Each slider maps straight to its layer's level (no hidden master).
  double _target(String id) =>
      _isEnabled(id) ? ((_volumes[id] ?? 0) / 100).clamp(0.0, 1.0) : 0.0;

  @override
  Future<void> initialize({
    required int profileId,
    required String preset,
    required double masterVolume,
    required Map<String, bool> enabled,
    required Map<String, double> volumes,
  }) async {
    _preset = preset;
    _master = masterVolume;
    _enabled = {for (final id in _ids) id: enabled[id] ?? false};
    _volumes = {for (final id in _ids) id: (volumes[id] ?? 0).clamp(0, 100)};
    AppLog.info(
      LogCategory.playback,
      'Sleep Sounds native backend initializing.',
      details: {'profileId': profileId, 'enabled': _enabled.toString()},
    );
    for (final id in _ids) {
      if (_isEnabled(id)) {
        await _ensureLayer(id);
      }
    }
  }

  Future<SleepSoundLayer> _ensureLayer(String id) async {
    final existing = _layers[id];
    if (existing != null) return existing;
    if (!sleepSoundAssetPaths.containsKey(id)) {
      throw StateError('Unknown sleep sound "$id".');
    }
    final layer = _layerFactory(id);
    _layers[id] = layer;
    _gain[id] = 0;
    _layerErrorSubs[id] = layer.errors.listen((message) {
      AppLog.error(
        LogCategory.playback,
        'Sleep Sounds layer error.',
        details: {'soundId': id, 'message': message},
      );
      if (!_errors.isClosed) _errors.add(message);
    });
    try {
      await layer.load();
    } catch (_) {
      _layers.remove(id);
      await _layerErrorSubs.remove(id)?.cancel();
      await layer.dispose();
      rethrow;
    }
    return layer;
  }

  /// Smooth gain ramp. A newer ramp on the same layer cancels older ones.
  Future<void> _rampTo(String id, double target, {Duration? duration}) async {
    final layer = _layers[id];
    if (layer == null) return;
    final generation = (_fadeGeneration[id] ?? 0) + 1;
    _fadeGeneration[id] = generation;
    final from = _gain[id] ?? 0;
    final total = duration ?? fade;
    if (total == Duration.zero || (from - target).abs() < 0.001) {
      _gain[id] = target;
      await layer.setGain(target);
      return;
    }
    final stepDelay = Duration(
      microseconds: total.inMicroseconds ~/ _fadeSteps,
    );
    for (var step = 1; step <= _fadeSteps; step++) {
      if (_fadeGeneration[id] != generation || _disposed) return;
      final value = from + (target - from) * (step / _fadeSteps);
      _gain[id] = value;
      await layer.setGain(value);
      if (step < _fadeSteps) await Future<void>.delayed(stepDelay);
    }
  }

  Future<void> _startLayer(String id) async {
    final layer = await _ensureLayer(id);
    if (!layer.playing) {
      _gain[id] = 0;
      await layer.setGain(0);
      await layer.play();
    }
    await _rampTo(id, _target(id));
  }

  Future<void> _quietLayer(String id) async {
    final layer = _layers[id];
    if (layer == null) return;
    await _rampTo(id, 0);
    await layer.pause();
  }

  @override
  Future<void> play() async {
    final enabledIds = [
      for (final id in _ids)
        if (_isEnabled(id)) id,
    ];
    if (enabledIds.isEmpty) {
      throw StateError('Turn on at least one sound.');
    }
    try {
      await Future.wait(enabledIds.map(_startLayer));
    } catch (_) {
      // Leave nothing half-playing after a failed start.
      await Future.wait(_layers.keys.toList().map(_quietLayer));
      _playing = false;
      _paused = false;
      _emit();
      rethrow;
    }
    _playing = true;
    _paused = false;
    _emit();
  }

  @override
  Future<void> pause() async {
    await Future.wait(_layers.keys.toList().map(_quietLayer));
    _paused = true;
    _emit();
  }

  @override
  Future<void> resume() async {
    final enabledIds = [
      for (final id in _ids)
        if (_isEnabled(id)) id,
    ];
    await Future.wait(enabledIds.map(_startLayer));
    _paused = false;
    _playing = true;
    _emit();
  }

  @override
  Future<void> stop() async {
    await Future.wait(_layers.keys.toList().map(_quietLayer));
    _playing = false;
    _paused = false;
    _emit();
  }

  @override
  Future<void> applyMix({
    required Map<String, bool> enabled,
    required Map<String, double> volumes,
  }) async {
    for (final id in _ids) {
      _enabled[id] = enabled[id] ?? false;
      _volumes[id] = (volumes[id] ?? _volumes[id] ?? 0).clamp(0, 100);
    }
    if (_playing && !_paused) {
      await Future.wait(
        _ids.map((id) => _isEnabled(id) ? _startLayer(id) : _quietLayer(id)),
      );
    }
    _emit();
  }

  @override
  Future<void> setLayerEnabled(String soundId, bool enabled) async {
    _enabled[soundId] = enabled;
    if (_playing && !_paused) {
      // Only the named layer changes; the other layers keep playing.
      if (enabled) {
        await _startLayer(soundId);
      } else {
        await _quietLayer(soundId);
      }
    }
    _emit();
  }

  @override
  Future<void> setPerSoundVolume(String soundId, double volume) async {
    _volumes[soundId] = volume.clamp(0, 100).toDouble();
    if (_playing && !_paused && _isEnabled(soundId)) {
      await _rampTo(
        soundId,
        _target(soundId),
        duration: const Duration(milliseconds: 80),
      );
    }
    _emit();
  }

  @override
  Future<void> setMasterVolume(double masterVolume) async {
    // The simplified mixer has no master slider; keep value for status only.
    _master = masterVolume.clamp(0, 100).toDouble();
  }

  @override
  Future<void> applyPreset(String preset) async {
    _preset = preset;
  }

  void _emit() {
    if (_status.isClosed) return;
    _status.add(
      SleepSoundsBackendStatus(
        playing: _playing,
        paused: _paused,
        preset: _preset,
        masterVolume: _master,
        perSoundVolume: Map<String, double>.from(_volumes),
        activeLayers: [
          for (final id in _ids)
            if (_playing && !_paused && _isEnabled(id)) id,
        ],
        capabilities: _caps,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _layerErrorSubs.values) {
      unawaited(sub.cancel());
    }
    _layerErrorSubs.clear();
    final layers = _layers.values.toList();
    _layers.clear();
    for (final layer in layers) {
      try {
        await layer.dispose();
      } catch (_) {}
    }
    await _status.close();
    await _errors.close();
  }
}
