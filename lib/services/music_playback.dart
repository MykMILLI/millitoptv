import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'music_service.dart';
import 'pip_playback.dart';

class MusicProgress {
  final Duration position;
  final Duration duration;
  const MusicProgress(this.position, this.duration);
}

class MusicAudioEvent {
  final int generation;
  final bool? playing;
  final bool? buffering;
  final Duration? position;
  final Duration? duration;
  final bool completed;
  final bool failed;
  const MusicAudioEvent(
    this.generation, {
    this.playing,
    this.buffering,
    this.position,
    this.duration,
    this.completed = false,
    this.failed = false,
  });
}

abstract class MusicAudioBackend {
  Stream<MusicAudioEvent> get events;
  Future<void> open(Uri uri, int generation);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration target);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

class MediaKitMusicBackend implements MusicAudioBackend {
  Player? _player;
  final _events = StreamController<MusicAudioEvent>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  @override
  Stream<MusicAudioEvent> get events => _events.stream;

  Player get _active {
    MediaKit.ensureInitialized();
    return _player ??= Player();
  }

  @override
  Future<void> open(Uri uri, int generation) async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final player = _active;
    // Stop before subscribing so completion from the old media cannot advance
    // the newly selected queue item.
    await player.stop();
    _subscriptions.addAll([
      player.stream.playing.listen(
        (value) => _events.add(MusicAudioEvent(generation, playing: value)),
      ),
      player.stream.buffering.listen(
        (value) => _events.add(MusicAudioEvent(generation, buffering: value)),
      ),
      player.stream.position.listen(
        (value) => _events.add(MusicAudioEvent(generation, position: value)),
      ),
      player.stream.duration.listen(
        (value) => _events.add(MusicAudioEvent(generation, duration: value)),
      ),
      player.stream.completed.listen((value) {
        if (value) {
          _events.add(MusicAudioEvent(generation, completed: true));
        }
      }),
      player.stream.error.listen(
        (_) => _events.add(MusicAudioEvent(generation, failed: true)),
      ),
    ]);
    await player.open(Media(uri.toString()), play: true);
  }

  @override
  Future<void> play() => _active.play();
  @override
  Future<void> pause() async {
    await _player?.pause();
  }
  @override
  Future<void> stop() async {
    await _player?.stop();
  }
  @override
  Future<void> seek(Duration target) => _active.seek(target);
  @override
  Future<void> setVolume(double volume) => _active.setVolume(volume);
  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player?.dispose();
    await _events.close();
  }
}

/// App-owned, profile-scoped queue. Screen navigation never disposes playback.
/// Only one media is opened at a time so credentials are resolved at each use.
class MusicPlayback extends ChangeNotifier {
  static final instance = MusicPlayback();
  final MusicService _service;
  final MusicAudioBackend _backend;
  final Future<void> Function() _beforePlay;
  late final StreamSubscription<MusicAudioEvent> _subscription;
  final progress = ValueNotifier(
    const MusicProgress(Duration.zero, Duration.zero),
  );
  Future<void> _pending = Future<void>.value();
  int _generation = 0;
  int _historyRevision = 0;
  int? _profileId;
  List<MusicTrack> _queue = const [];
  int _index = -1;
  bool _playing = false;
  bool _buffering = false;
  bool _closed = false;
  bool _completed = false;
  String? _error;
  double _volume = 80;

  MusicPlayback({
    MusicService? service,
    MusicAudioBackend? backend,
    Future<void> Function()? beforePlay,
  }) : _service = service ?? MusicService(),
       _backend = backend ?? MediaKitMusicBackend(),
       _beforePlay = beforePlay ?? _pauseTv {
    _subscription = _backend.events.listen(_onEvent);
  }

  static Future<void> _pauseTv() async {
    await PipPlaybackController.instance.session?.player.pause();
  }

  int? get profileId => _profileId;
  List<MusicTrack> get queue => List.unmodifiable(_queue);
  int get index => _index;
  MusicTrack? get current =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  bool get playing => _playing;
  bool get buffering => _buffering;
  String? get error => _error;
  double get volume => _volume;
  int get queueRevision => _generation;
  int get historyRevision => _historyRevision;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> _serialize(
    Future<void> Function() action, {
    int? generation,
  }) {
    if (_closed) return Future<void>.value();
    _pending = _pending.then((_) async {
      if (_closed) return;
      try {
        await action();
      } catch (_) {
        if (_closed || (generation != null && generation != _generation)) return;
        if (generation != null) {
          // A timeout does not cancel a native open. Invalidate its events and
          // explicitly stop it before allowing another command to run.
          _generation++;
          try {
            await _backend.stop();
          } catch (_) {}
        } else {
          try {
            await _backend.pause();
          } catch (_) {}
        }
        // Native and HTTP exceptions can contain authenticated URLs.
        _error = 'Music playback failed. Check your connection and retry.';
        _buffering = false;
        _playing = false;
        _notify();
      }
    });
    return _pending;
  }

  Future<void> activateProfile(int id) {
    if (_closed || _profileId == id) return Future<void>.value();
    _generation++;
    _profileId = id;
    _queue = const [];
    _index = -1;
    _playing = false;
    _buffering = false;
    _error = null;
    progress.value = const MusicProgress(Duration.zero, Duration.zero);
    _notify();
    return _serialize(_backend.stop);
  }

  Future<void> deactivateProfile() {
    final stopped = activateProfile(-1);
    _profileId = null;
    return stopped;
  }

  Future<void> playQueue(
    int profileId,
    List<MusicTrack> tracks, {
    int index = 0,
  }) {
    if (_closed || tracks.isEmpty || index < 0 || index >= tracks.length) {
      return Future<void>.value();
    }
    // Profile changes and queue replacement invalidate all earlier async work.
    _profileId = profileId;
    _queue = List.of(tracks);
    return select(index);
  }

  Future<void> select(int index) {
    if (_closed || index < 0 || index >= _queue.length) {
      return Future<void>.value();
    }
    final generation = ++_generation;
    final track = _queue[index];
    final profile = _profileId!;
    _index = index;
    _error = null;
    _buffering = true;
    _playing = false;
    _completed = false;
    progress.value = MusicProgress(
      Duration.zero,
      Duration(seconds: track.durationSeconds),
    );
    _notify();
    return _serialize(() async {
      if (generation != _generation) return;
      final config = await _service.config(profile);
      if (generation != _generation || _closed) return;
      if (config == null) throw StateError('Connect to your music server.');
      await _beforePlay();
      if (generation != _generation || _closed) return;
      await _backend
          .open(NavidromeClient(config).streamUri(track.id), generation)
          .timeout(const Duration(seconds: 25));
      if (generation != _generation || _closed) return;
      await _backend.setVolume(_volume);
      try {
        await _service.upsertRecentlyPlayed(profile, track);
        if (generation == _generation && !_closed) _historyRevision++;
      } catch (_) {
        // History persistence failure must not stop successful audio playback.
      }
      if (generation != _generation || _closed) return;
      _buffering = false;
      _notify();
    }, generation: generation);
  }

  /// Adds radio recommendations without reopening or restarting the seed.
  Future<void> replaceUpcoming(
    List<MusicTrack> tracks, {
    int? expectedRevision,
  }) async {
    final track = current;
    if (_closed ||
        track == null ||
        (expectedRevision != null && expectedRevision != queueRevision)) {
      return;
    }
    final seen = _queue.take(_index + 1).map((item) => item.id).toSet();
    _queue = [
      ..._queue.take(_index + 1),
      ...tracks.where((item) => seen.add(item.id)),
    ];
    _notify();
    if (_completed && _index + 1 < _queue.length) {
      await next();
    }
  }

  Future<void> previous() => select(_index - 1);
  Future<void> next() => select(_index + 1);
  Future<void> pause() => _serialize(() async {
    await _backend.pause();
    _playing = false;
    _notify();
  });
  Future<void> toggle() {
    if (current == null) return Future<void>.value();
    if (_error != null || _completed) return select(_index);
    if (_playing) return pause();
    return _serialize(() async {
      await _beforePlay();
      await _backend.play();
    });
  }

  Future<void> seek(Duration target) => _serialize(() async {
    final duration = progress.value.duration;
    if (current == null || duration <= Duration.zero) return;
    await _backend.seek(
      Duration(
        milliseconds: target.inMilliseconds
            .clamp(0, duration.inMilliseconds)
            .toInt(),
      ),
    );
  });

  Future<void> setVolume(double value) => _serialize(() async {
    _volume = value.clamp(0, 100).toDouble();
    if (current != null) await _backend.setVolume(_volume);
    _notify();
  });

  void _onEvent(MusicAudioEvent event) {
    if (_closed ||
        event.generation != _generation ||
        current == null ||
        _error != null) {
      return;
    }
    if (event.position != null || event.duration != null) {
      progress.value = MusicProgress(
        event.position ?? progress.value.position,
        event.duration ?? progress.value.duration,
      );
    }
    var changed = false;
    if (event.playing != null && event.playing != _playing) {
      _playing = event.playing!;
      changed = true;
    }
    if (event.buffering != null && event.buffering != _buffering) {
      _buffering = event.buffering!;
      changed = true;
    }
    if (event.failed) {
      _error = 'Music playback failed. Check your connection and retry.';
      _playing = false;
      _buffering = false;
      changed = true;
    }
    if (event.completed && !_completed && !event.failed && _error == null) {
      _completed = true;
      if (_index + 1 < _queue.length) {
        unawaited(next());
        return;
      }
      _playing = false;
      _buffering = false;
      changed = true;
    }
    if (changed) _notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    await _pending;
    await _subscription.cancel();
    await _backend.dispose();
    progress.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
