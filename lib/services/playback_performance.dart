import 'dart:io';
import 'package:media_kit/media_kit.dart';

enum HardwareDecodingMode { auto, enabled, disabled }

class PlaybackPerformanceSettings {
  final HardwareDecodingMode hardwareDecoding;
  final bool androidAggressiveMode;
  final int desktopBufferMb;
  final int androidBufferMb;

  const PlaybackPerformanceSettings({
    this.hardwareDecoding = HardwareDecodingMode.auto,
    this.androidAggressiveMode = true,
    this.desktopBufferMb = 64,
    this.androidBufferMb = 96,
  });

  bool get canTuneHardwareDecoding => Platform.isWindows || Platform.isAndroid;

  PlaybackPerformanceSettings copyWith({
    HardwareDecodingMode? hardwareDecoding,
    bool? androidAggressiveMode,
    int? desktopBufferMb,
    int? androidBufferMb,
  }) {
    return PlaybackPerformanceSettings(
      hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
      androidAggressiveMode:
          androidAggressiveMode ?? this.androidAggressiveMode,
      desktopBufferMb: desktopBufferMb ?? this.desktopBufferMb,
      androidBufferMb: androidBufferMb ?? this.androidBufferMb,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'hardwareDecoding': switch (hardwareDecoding) {
        HardwareDecodingMode.auto => 'auto',
        HardwareDecodingMode.enabled => 'enabled',
        HardwareDecodingMode.disabled => 'disabled',
      },
      'androidAggressiveMode': androidAggressiveMode,
      'desktopBufferMb': desktopBufferMb,
      'androidBufferMb': androidBufferMb,
    };
  }

  static PlaybackPerformanceSettings fromJson(Map<String, dynamic> json) {
    final mode = switch (json['hardwareDecoding']?.toString().trim()) {
      'enabled' => HardwareDecodingMode.enabled,
      'disabled' => HardwareDecodingMode.disabled,
      _ => HardwareDecodingMode.auto,
    };

    int bufferMb(dynamic value, int fallback) {
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed == null || parsed < 16 || parsed > 512) {
        return fallback;
      }
      return parsed;
    }

    return PlaybackPerformanceSettings(
      hardwareDecoding: mode,
      androidAggressiveMode: json['androidAggressiveMode'] != false,
      desktopBufferMb: bufferMb(json['desktopBufferMb'], 64),
      androidBufferMb: bufferMb(json['androidBufferMb'], 96),
    );
  }
}

PlayerConfiguration playerConfigurationFor(
  PlaybackPerformanceSettings settings,
) {
  final bufferMb = Platform.isAndroid
      ? settings.androidBufferMb
      : settings.desktopBufferMb;
  return PlayerConfiguration(
    bufferSize: bufferMb * 1024 * 1024,
    logLevel: MPVLogLevel.error,
  );
}

Future<void> applyNativePlaybackPerformance(
  Player player,
  PlaybackPerformanceSettings settings,
) async {
  final platform = player.platform;
  if (platform is! NativePlayer) {
    return;
  }

  final hwdec = switch (settings.hardwareDecoding) {
    HardwareDecodingMode.auto => 'auto-safe',
    HardwareDecodingMode.enabled => 'yes',
    HardwareDecodingMode.disabled => 'no',
  };
  await platform.setProperty('hwdec', hwdec);

  if (Platform.isAndroid) {
    await platform.setProperty(
      'framedrop',
      settings.androidAggressiveMode ? 'vo' : 'decoder',
    );
    await platform.setProperty(
      'vd-lavc-skiploopfilter',
      settings.androidAggressiveMode ? 'nonkey' : 'default',
    );
    await platform.setProperty('video-sync', 'audio');
  }
}

Future<String> playbackEngineStatusLabel(
  Player player,
  PlaybackPerformanceSettings settings,
) async {
  final platform = player.platform;
  if (platform is! NativePlayer) {
    return 'GPU decode: unavailable';
  }
  String current = '';
  try {
    current = (await platform.getProperty('hwdec-current')).trim().toLowerCase();
  } catch (_) {
    return 'GPU decode: unavailable';
  }
  final active =
      current.isNotEmpty &&
      current != 'no' &&
      current != 'null' &&
      current != 'unknown';
  switch (settings.hardwareDecoding) {
    case HardwareDecodingMode.disabled:
      return active ? 'GPU decode: active' : 'GPU decode: disabled';
    case HardwareDecodingMode.enabled:
      return active ? 'GPU decode: active' : 'GPU decode: fallback';
    case HardwareDecodingMode.auto:
      return active ? 'GPU decode: active' : 'GPU decode: fallback';
  }
}
