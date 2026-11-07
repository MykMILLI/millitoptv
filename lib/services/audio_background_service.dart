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

  bool _initialized = false;

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
        queueIndex: 0,
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

  void clear() {
    mediaItem.add(null);
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
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
