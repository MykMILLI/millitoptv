import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

class AudioBackgroundService extends BaseAudioHandler with SeekHandler {
  AudioBackgroundService._();
  static final AudioBackgroundService instance = AudioBackgroundService._();

  Future<void> Function()? onPlayRequested;
  Future<void> Function()? onPauseRequested;
  Future<void> Function()? onStopRequested;
  Future<void> Function()? onSkipNextRequested;
  Future<void> Function()? onSkipPreviousRequested;
  Future<void> Function(Duration position)? onSeekRequested;
  Future<void> Function(String mediaId)? onPlayMediaIdRequested;

  bool _initialized = false;
  static const String _rootId = 'millitop.root';
  static const String _queueId = 'millitop.queue';
  static const String _libraryId = 'millitop.library';
  List<MediaItem> _queueItems = const [];
  List<MediaItem> _libraryItems = const [];
  int _currentQueueIndex = 0;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.pause,
          MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        processingState: AudioProcessingState.idle,
        playing: false,
        queueIndex: 0,
      ),
    );
  }

  void updateBrowseCatalog({
    required List<MediaItem> queueItems,
    required List<MediaItem> libraryItems,
    required int queueIndex,
  }) {
    _queueItems = List<MediaItem>.from(queueItems);
    _libraryItems = List<MediaItem>.from(libraryItems);
    _currentQueueIndex = queueIndex.clamp(
      0,
      _queueItems.isEmpty ? 0 : _queueItems.length - 1,
    );
    queue.add(_queueItems);
    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: _queueItems.isEmpty ? 0 : _currentQueueIndex,
      ),
    );
  }

  void updateNowPlaying({
    required String id,
    required String title,
    required String artist,
    required String album,
    required Duration duration,
    Uri? artUri,
  }) {
    mediaItem.add(
      MediaItem(
        id: id,
        title: title,
        artist: artist,
        album: album,
        duration: duration.inMilliseconds <= 0 ? null : duration,
        artUri: artUri,
      ),
    );
  }

  void updatePlayback({
    required bool playing,
    required Duration position,
    required Duration duration,
    bool buffering = false,
  }) {
    final speed = playing ? 1.0 : 0.0;
    final state = buffering
        ? AudioProcessingState.buffering
        : (playing ? AudioProcessingState.ready : AudioProcessingState.ready);
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        processingState: state,
        playing: playing,
        updatePosition: position,
        bufferedPosition: position,
        speed: speed,
        queueIndex: _queueItems.isEmpty ? 0 : _currentQueueIndex,
      ),
    );
    if (duration.inMilliseconds > 0) {
      final item = mediaItem.value;
      if (item != null && item.duration != duration) {
        mediaItem.add(item.copyWith(duration: duration));
      }
    }
  }

  @override
  Future<void> play() async {
    final callback = onPlayRequested;
    if (callback != null) {
      await callback();
    }
  }

  @override
  Future<void> pause() async {
    final callback = onPauseRequested;
    if (callback != null) {
      await callback();
    }
  }

  @override
  Future<void> stop() async {
    final callback = onStopRequested;
    if (callback != null) {
      await callback();
    }
  }

  @override
  Future<void> skipToNext() async {
    final callback = onSkipNextRequested;
    if (callback != null) {
      await callback();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final callback = onSkipPreviousRequested;
    if (callback != null) {
      await callback();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final callback = onSeekRequested;
    if (callback != null) {
      await callback(position);
    }
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId == AudioService.browsableRootId ||
        parentMediaId == _rootId) {
      return const [
        MediaItem(
          id: _queueId,
          title: 'Now Playing Queue',
          album: 'Millitop',
          playable: false,
        ),
        MediaItem(
          id: _libraryId,
          title: 'Library Songs',
          album: 'Millitop',
          playable: false,
        ),
      ];
    }
    if (parentMediaId == _queueId) {
      return _queueItems;
    }
    if (parentMediaId == _libraryId) {
      return _libraryItems;
    }
    return const [];
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    final callback = onPlayMediaIdRequested;
    if (callback != null) {
      await callback(mediaItem.id);
      return;
    }
    return super.playMediaItem(mediaItem);
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final callback = onPlayMediaIdRequested;
    if (callback != null) {
      await callback(mediaId);
      return;
    }
    return super.playFromMediaId(mediaId, extras);
  }

  void clear() {
    mediaItem.add(null);
    queue.add(const []);
    _queueItems = const [];
    _libraryItems = const [];
    _currentQueueIndex = 0;
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        queueIndex: 0,
      ),
    );
  }
}

Future<void> initializeAudioBackgroundService() async {
  try {
    await AudioService.init(
      builder: () => AudioBackgroundService.instance,
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.millitop.music.playback',
        androidNotificationChannelName: 'Music Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    await AudioBackgroundService.instance.initialize();
  } catch (error) {
    debugPrint('Audio background initialization failed: $error');
  }
}
