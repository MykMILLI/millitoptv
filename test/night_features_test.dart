import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/services/global_playlists.dart';
import 'package:millitop_tv/services/home_preferences.dart';
import 'package:millitop_tv/services/live_tv_playlist.dart';
import 'package:millitop_tv/services/live_tv_source.dart';
import 'package:millitop_tv/services/playlist_playback.dart';
import 'package:millitop_tv/services/sleep_sounds_controller.dart';
import 'package:millitop_tv/services/viewing_sessions.dart';
import 'package:millitop_tv/services/sleep_mode.dart';

class _FakeSleepSoundsBackend implements SleepSoundsPlaybackBackend {
  final StreamController<SleepSoundsBackendStatus> _status =
      StreamController<SleepSoundsBackendStatus>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final List<String> calls = <String>[];
  bool _playing = false;
  bool _paused = false;
  String _preset = 'rain';
  double _masterVolume = 70;

  @override
  SleepSoundsCapabilities get capabilities =>
      SleepSoundsCapabilities.embeddedDefault;

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
    calls.add('initialize:$profileId');
    _preset = preset;
    _masterVolume = masterVolume;
    calls.add('applyMix:${enabled.length}:${volumes.length}');
    _emit();
  }

  @override
  Future<void> applyPreset(String preset) async {
    calls.add('applyPreset:$preset');
    _preset = preset;
    _emit();
  }

  @override
  Future<void> setMasterVolume(double masterVolume) async {
    calls.add('setMasterVolume:${masterVolume.round()}');
    _masterVolume = masterVolume;
    _emit();
  }

  @override
  Future<void> setPerSoundVolume(String soundId, double volume) async {
    calls.add('setPerSoundVolume:$soundId:${volume.round()}');
  }

  @override
  Future<void> applyMix({
    required Map<String, bool> enabled,
    required Map<String, double> volumes,
  }) async {
    calls.add('applyMix:${enabled.length}:${volumes.length}');
  }

  @override
  Future<void> setLayerEnabled(String soundId, bool enabled) async {
    calls.add('setLayerEnabled:$soundId:$enabled');
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _playing = true;
    _paused = false;
    _emit();
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing = true;
    _paused = true;
    _emit();
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    _playing = true;
    _paused = false;
    _emit();
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _playing = false;
    _paused = false;
    _emit();
  }

  @override
  Future<void> dispose() async {
    await _status.close();
    await _errors.close();
  }

  void _emit() {
    _status.add(
      SleepSoundsBackendStatus(
        playing: _playing,
        paused: _paused,
        preset: _preset,
        masterVolume: _masterVolume,
        perSoundVolume: const {'rain': 80},
        activeLayers: _playing
            ? const ['heavy-rain', 'thunder', 'white-noise', 'pink-noise']
            : const <String>[],
        capabilities: SleepSoundsCapabilities.embeddedDefault,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SleepSoundsController.instance.resetForTesting();
  });
  test('saved app order is stable, removes missing apps, appends new apps', () {
    expect(mergeAppOrder(['a', 'b', 'c'], ['b', 'missing', 'a', 'b']), [
      'b',
      'a',
      'c',
    ]);
  });
  test('orders are independent per profile', () async {
    final prefs = HomePreferences();
    await prefs.saveOrder(1, ['b', 'a']);
    expect(await prefs.order(1), ['b', 'a']);
    expect(await prefs.order(2), isEmpty);
  });
  test(
    'sleep address defaults correctly and refuses insecure origins',
    () async {
      final prefs = HomePreferences();
      expect(await prefs.sleepUrl(1), 'https://sleep.millitop.net');
      await expectLater(
        prefs.setSleepUrl(1, 'http://example.com'),
        throwsFormatException,
      );
    },
  );
  test('sleep sounds preferences persist per profile', () async {
    final prefs = HomePreferences();
    expect(await prefs.sleepSoundsPreset(1), 'overnight-storm');
    expect(await prefs.sleepSoundsVolume(1), 70);
    expect(await prefs.sleepSoundsBackend(1), 'embedded');
    final defaults = await prefs.sleepSoundsPerSoundVolumes(1);
    expect(defaults['thunder'], 35);
    await prefs.setSleepSoundsPreset(1, 'ocean');
    await prefs.setSleepSoundsVolume(1, 42);
    await prefs.setSleepSoundsBackend(1, 'embedded');
    await prefs.setSleepSoundsPerSoundVolumes(1, const {'thunder': 33.0});
    expect(await prefs.sleepSoundsPreset(1), 'ocean');
    expect(await prefs.sleepSoundsVolume(1), 42);
    expect(await prefs.sleepSoundsBackend(1), 'embedded');
    final savedMap = await prefs.sleepSoundsPerSoundVolumes(1);
    expect(savedMap['thunder'], 33);
    expect(await prefs.sleepSoundsPreset(2), 'overnight-storm');
  });
  test(
    'sleep sounds controller starts and stops via launcher callbacks',
    () async {
      final controller = SleepSoundsController.instance;
      controller.setBackend(SleepSoundsBackend.browserFallback);
      var launched = 0;
      var stopped = 0;
      await controller.play(
        profileId: 7,
        url: 'https://sleep.millitop.net',
        launcher: (_, __) async {
          launched++;
        },
        stopper: (_) async {
          stopped++;
        },
      );
      expect(controller.state, SleepSoundsState.playing);
      expect(launched, 1);
      await controller.stop();
      expect(controller.state, SleepSoundsState.stopped);
      expect(stopped, 1);
    },
  );
  test(
    'sleep sounds per-sound volumes can be adjusted before playback starts',
    () async {
      final controller = SleepSoundsController.instance;
      await controller.setPerSoundVolume('thunder', 41);
      expect(controller.perSoundVolume['thunder'], 41);
      expect(controller.state, SleepSoundsState.stopped);
      expect(controller.error, isEmpty);
      expect(
        controller.message,
        contains('will apply when Sleep Sounds starts'),
      );
    },
  );
  test('sleep sounds embedded backend invokes contract commands', () async {
    final controller = SleepSoundsController.instance;
    controller.setBackend(SleepSoundsBackend.embeddedWebView);
    final backend = _FakeSleepSoundsBackend();
    controller.setEmbeddedBackendFactoryForTesting(() => backend);
    await controller.play(profileId: 3, url: 'https://sleep.millitop.net');
    expect(controller.state, SleepSoundsState.playing);
    expect(backend.calls, contains('initialize:3'));
    expect(backend.calls, contains('applyMix:4:4'));
    expect(backend.calls, contains('setMasterVolume:70'));
    expect(backend.calls.last, 'play');
    await controller.pause();
    await controller.resume();
    await controller.stop();
    expect(backend.calls, containsAll(['pause', 'resume', 'stop']));
  });
  test('live tv playlist URL is profile scoped and validated', () async {
    final prefs = HomePreferences();
    expect(await prefs.liveTvPlaylistUrl(1), isEmpty);
    await expectLater(
      prefs.setLiveTvPlaylistUrl(1, 'https://user:pass@example.com/list.m3u'),
      throwsFormatException,
    );
    await prefs.setLiveTvPlaylistUrl(1, 'https://example.com/playlist.m3u');
    expect(
      await prefs.liveTvPlaylistUrl(1),
      'https://example.com/playlist.m3u',
    );
    expect(await prefs.liveTvPlaylistUrl(2), isEmpty);
  });
  test('live tv playlist parser keeps playable channels', () {
    const sample = '''
#EXTM3U
#EXTINF:-1 tvg-id="news1" group-title="News",Local News
https://streams.example.com/news.m3u8
#EXTINF:-1 group-title="Sports",Live Sports
http://streams.example.com/sports.ts
#EXTINF:-1,Ignored
file://local-path
''';
    final parsed = LiveTvPlaylist.parse(sample);
    expect(parsed.channels.length, 2);
    expect(parsed.channels.first.title, 'Local News');
    expect(parsed.channels.first.group, 'News');
    expect(parsed.channels.last.title, 'Live Sports');
  });
  test('live tv source storage supports m3u and xtream', () async {
    final prefs = HomePreferences();
    await prefs.saveLiveTvSources(1, const [
      LiveTvSource(
        id: 'one',
        name: 'M3U One',
        type: 'm3u',
        m3uUrl: 'https://example.com/list.m3u',
      ),
      LiveTvSource(
        id: 'two',
        name: 'Provider XC',
        type: 'xtream',
        serverUrl: 'http://provider.example:8080',
        username: 'demo',
        password: 'secret',
      ),
    ]);
    final values = await prefs.liveTvSources(1);
    expect(values.length, 2);
    expect(values.first.isM3u, isTrue);
    expect(values.last.isXtream, isTrue);
  });
  test('live tv recents are stored, deduplicated, and ordered', () async {
    final prefs = HomePreferences();
    await prefs.upsertLiveTvRecentChannel(
      7,
      LiveTvRecentChannel(
        sourceId: 's1',
        sourceName: 'Source One',
        channelId: 'name:espn',
        channelName: 'ESPN',
        watchedAtUtc: DateTime.utc(2026, 1, 1, 10, 0, 0),
      ),
    );
    await prefs.upsertLiveTvRecentChannel(
      7,
      LiveTvRecentChannel(
        sourceId: 's2',
        sourceName: 'Source Two',
        channelId: 'name:news',
        channelName: 'News',
        watchedAtUtc: DateTime.utc(2026, 1, 1, 11, 0, 0),
      ),
    );
    await prefs.upsertLiveTvRecentChannel(
      7,
      LiveTvRecentChannel(
        sourceId: 's1',
        sourceName: 'Source One',
        channelId: 'name:espn',
        channelName: 'ESPN',
        watchedAtUtc: DateTime.utc(2026, 1, 1, 12, 0, 0),
      ),
    );
    final values = await prefs.liveTvRecentChannels(7);
    expect(values.length, 2);
    expect(values.first.channelId, 'name:espn');
    expect(values.first.watchedAtUtc, DateTime.utc(2026, 1, 1, 12, 0, 0));
    expect(values.last.channelId, 'name:news');
  });
  test('live tv channel recents can be removed', () async {
    final prefs = HomePreferences();
    await prefs.upsertLiveTvRecentChannel(
      9,
      LiveTvRecentChannel(
        sourceId: 's1',
        sourceName: 'Source One',
        channelId: 'name:espn',
        channelName: 'ESPN',
        watchedAtUtc: DateTime.utc(2026, 1, 1, 10, 0, 0),
      ),
    );
    await prefs.upsertLiveTvRecentChannel(
      9,
      LiveTvRecentChannel(
        sourceId: 's1',
        sourceName: 'Source One',
        channelId: 'name:news',
        channelName: 'News',
        watchedAtUtc: DateTime.utc(2026, 1, 1, 11, 0, 0),
      ),
    );
    await prefs.removeLiveTvRecentChannel(
      9,
      sourceId: 's1',
      channelId: 'name:espn',
    );
    final values = await prefs.liveTvRecentChannels(9);
    expect(values.length, 1);
    expect(values.first.channelId, 'name:news');
  });
  test('live tv media history is stored and deduplicated', () async {
    final prefs = HomePreferences();
    await prefs.upsertLiveTvRecentMedia(
      4,
      LiveTvRecentMedia(
        sourceId: 's1',
        mediaType: 'movie',
        mediaId: 'vod:123',
        title: 'Interstellar',
        subtitle: 'Sci-Fi',
        watchedAtUtc: DateTime.utc(2026, 1, 2, 8, 0, 0),
      ),
    );
    await prefs.upsertLiveTvRecentMedia(
      4,
      LiveTvRecentMedia(
        sourceId: 's1',
        mediaType: 'movie',
        mediaId: 'vod:123',
        title: 'Interstellar',
        subtitle: 'Sci-Fi',
        watchedAtUtc: DateTime.utc(2026, 1, 2, 9, 0, 0),
      ),
    );
    final values = await prefs.liveTvRecentMedia(4);
    expect(values.length, 1);
    expect(values.first.title, 'Interstellar');
    expect(values.first.watchedAtUtc, DateTime.utc(2026, 1, 2, 9, 0, 0));
  });
  test('live tv media recents can be removed', () async {
    final prefs = HomePreferences();
    await prefs.upsertLiveTvRecentMedia(
      5,
      LiveTvRecentMedia(
        sourceId: 's1',
        mediaType: 'movie',
        mediaId: 'vod:123',
        title: 'Interstellar',
        watchedAtUtc: DateTime.utc(2026, 1, 2, 8, 0, 0),
      ),
    );
    await prefs.upsertLiveTvRecentMedia(
      5,
      LiveTvRecentMedia(
        sourceId: 's1',
        mediaType: 'series',
        mediaId: 'series:77',
        title: 'The Expanse',
        watchedAtUtc: DateTime.utc(2026, 1, 2, 9, 0, 0),
      ),
    );
    await prefs.removeLiveTvRecentMedia(
      5,
      sourceId: 's1',
      mediaType: 'movie',
      mediaId: 'vod:123',
    );
    final values = await prefs.liveTvRecentMedia(5);
    expect(values.length, 1);
    expect(values.first.mediaType, 'series');
    expect(values.first.mediaId, 'series:77');
  });
  test('viewing closure targets only explicitly registered sessions', () async {
    final sessions = ViewingSessions();
    var calls = 0;
    sessions.register('owned', () async {
      calls++;
    });
    await sessions.closeAll();
    expect(calls, 1);
    await sessions.closeAll();
    expect(calls, 1);
  });
  test(
    'closure failure remains registered instead of reporting success',
    () async {
      final sessions = ViewingSessions();
      var calls = 0;
      sessions.register('owned', () async {
        calls++;
        throw StateError('not confirmed');
      });
      await expectLater(sessions.closeAll(), throwsStateError);
      await expectLater(sessions.closeAll(), throwsStateError);
      expect(calls, 2);
      expect(sessions.closing, false);
    },
  );
  testWidgets(
    'timer closes viewing before display off and keeps overnight mode',
    (tester) async {
      var now = DateTime(2026, 10, 24, 21);
      final events = <String>[];
      final sleep = SleepMode(
        clock: () => now,
        prepareOverride: () async {},
        closeOverride: () async {
          events.add('close');
        },
        displayOverride: () async {
          events.add('display');
        },
      );
      await sleep.startTimer(1);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      expect(events, ['close', 'display']);
      expect(sleep.overnight, true);
      await sleep.endOvernight();
      sleep.dispose();
    },
  );
  testWidgets('cancelled viewing timer never closes sessions', (tester) async {
    var calls = 0;
    final sleep = SleepMode(
      prepareOverride: () async {},
      closeOverride: () async {
        calls++;
      },
      displayOverride: () async {
        calls++;
      },
    );
    await sleep.startTimer(1);
    sleep.cancelTimer();
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 0);
    expect(sleep.overnight, true);
    await sleep.endOvernight();
    sleep.dispose();
  });
  testWidgets('display-off is still requested when viewing closure fails', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 24, 21);
    var off = false;
    final sleep = SleepMode(
      clock: () => now,
      prepareOverride: () async {},
      closeOverride: () async {
        throw StateError('blocked');
      },
      displayOverride: () async {
        off = true;
      },
    );
    await sleep.startTimer(1);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(off, true);
    expect(sleep.message, contains('did not close'));
    expect(sleep.darkScreenModeAvailable, false);
    await sleep.endOvernight();
    sleep.dispose();
  });

  testWidgets('display-off failure offers dark-screen fallback', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 24, 21);
    final sleep = SleepMode(
      clock: () => now,
      prepareOverride: () async {},
      closeOverride: () async {},
      displayOverride: () async {
        throw StateError('unsupported');
      },
    );
    await sleep.startTimer(1);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(sleep.darkScreenModeAvailable, true);
    sleep.setDarkScreenMode(true);
    expect(sleep.darkScreenModeEnabled, true);
    await sleep.endOvernight();
    sleep.dispose();
  });

  testWidgets('expiry runs once even with repeated timer ticks', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 24, 21);
    var closes = 0;
    final sleep = SleepMode(
      clock: () => now,
      prepareOverride: () async {},
      closeOverride: () async {
        closes++;
      },
      displayOverride: () async {},
    );
    await sleep.startTimer(1);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(closes, 1);
    await sleep.endOvernight();
    sleep.dispose();
  });

  testWidgets('extending near expiry prevents immediate shutdown', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 24, 21);
    var closes = 0;
    final sleep = SleepMode(
      clock: () => now,
      prepareOverride: () async {},
      closeOverride: () async {
        closes++;
      },
      displayOverride: () async {},
    );
    await sleep.startTimer(1);
    now = now.add(const Duration(seconds: 40));
    sleep.extend(1);
    await tester.pump(const Duration(seconds: 1));
    expect(closes, 0);
    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(closes, 1);
    await tester.pump(const Duration(seconds: 2));
    await sleep.endOvernight();
    sleep.dispose();
  });

  testWidgets('countdown warning prompt is single-fire per countdown window', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 24, 21, 0, 0);
    final sleep = SleepMode(
      clock: () => now,
      prepareOverride: () async {},
      closeOverride: () async {},
      displayOverride: () async {},
    );
    await sleep.startTimer(1);
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    expect(sleep.countdownPromptId, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(sleep.countdownPromptId, 1);
    sleep.extend(1);
    now = now.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 1));
    expect(sleep.countdownPromptId, 2);
    sleep.cancelTimer();
    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(sleep.countdownPromptId, 2);
    await sleep.endOvernight();
    sleep.dispose();
  });

  testWidgets('expiry stops mixed queue and remains stopped on later ticks', (
    tester,
  ) async {
    final session = PlaylistPlaybackSession(
      profileId: 1,
      playlistId: 'mix',
      playlistName: 'Mixed',
      entries: const [
        PlaylistPlaybackEntry(
          entryId: 'entry-1',
          item: HubItem(
            type: HubMediaType.youtube,
            sourceId: 'youtube',
            id: 'v1',
            title: 'Video one',
            sourceName: 'YouTube',
            payload: {'id': 'v1', 'title': 'Video one', 'author': 'Creator'},
          ),
        ),
        PlaylistPlaybackEntry(
          entryId: 'entry-2',
          item: HubItem(
            type: HubMediaType.movie,
            sourceId: 'provider-a',
            id: 'movie-b',
            title: 'Movie B',
            sourceName: 'Provider A',
            payload: {
              'sourceId': 'provider-a',
              'sourceName': 'Provider A',
              'mediaType': 'movie',
              'mediaId': 'movie-b',
              'title': 'Movie B',
              'streamUrl': 'https://example.invalid/movie-b.mp4',
            },
          ),
        ),
      ],
      startIndex: 0,
      shuffled: false,
    );
    PlaylistPlaybackRegistry.instance.activate(session);
    var now = DateTime(2026, 10, 24, 21, 0, 0);
    final sleep = SleepMode(clock: () => now, prepareOverride: () async {});
    await sleep.startTimer(1);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    expect(session.state, PlaylistPlaybackSessionState.stopped);
    expect(PlaylistPlaybackRegistry.instance.active, isNull);
    now = now.add(const Duration(minutes: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(PlaylistPlaybackRegistry.instance.active, isNull);
    sleep.dispose();
  });

  testWidgets('timer expiry preserves running sleep sounds session', (
    tester,
  ) async {
    final controller = SleepSoundsController.instance;
    controller.setBackend(SleepSoundsBackend.browserFallback);
    var launched = 0;
    var stopped = 0;
    await controller.play(
      profileId: 8,
      url: 'https://sleep.millitop.net',
      launcher: (_, __) async {
        launched++;
      },
      stopper: (_) async {
        stopped++;
      },
    );
    expect(launched, 1);
    var now = DateTime(2026, 10, 24, 21, 0, 0);
    final sleep = SleepMode(
      clock: () => now,
      prepareOverride: () async {},
      closeOverride: () async {},
      displayOverride: () async {},
    );
    await sleep.startTimer(1);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    expect(controller.running, isTrue);
    expect(stopped, 0);
    await controller.stop();
    expect(stopped, 1);
    await sleep.endOvernight();
    sleep.dispose();
  });
}
