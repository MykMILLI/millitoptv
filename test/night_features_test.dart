import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/services/home_preferences.dart';
import 'package:millitop_tv/services/live_tv_playlist.dart';
import 'package:millitop_tv/services/live_tv_source.dart';
import 'package:millitop_tv/services/viewing_sessions.dart';
import 'package:millitop_tv/services/sleep_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test('Family Moments is profile scoped and defaults visible', () async {
    final prefs = HomePreferences();
    expect(await prefs.familyMoments(1), true);
    await prefs.setFamilyMoments(1, false);
    expect(await prefs.familyMoments(1), false);
    expect(await prefs.familyMoments(2), true);
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
    await sleep.endOvernight();
    sleep.dispose();
  });
}
