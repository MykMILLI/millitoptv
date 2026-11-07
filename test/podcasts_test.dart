import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:millitop_tv/screens/podcasts_screen.dart';
import 'package:millitop_tv/services/home_preferences.dart';
import 'package:millitop_tv/services/global_playlists.dart';
import 'package:millitop_tv/services/playlist_hub.dart';
import 'package:millitop_tv/services/podcast_service.dart';
import 'package:millitop_tv/services/podcast_playback.dart';
import 'package:millitop_tv/services/podcast_downloads.dart';
import 'package:millitop_tv/services/tube_downloads.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';
import 'package:millitop_tv/widgets/podcast_player_bar.dart';

const show = PodcastShow(
  id: '42',
  title: 'Test Podcast',
  author: 'Publisher',
  feedUrl: 'https://example.com/feed.xml',
  artwork: '',
);
const feed = '''
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
<item><guid>a</guid><title>Audio episode</title>
<description><![CDATA[<p>Audio description</p>]]></description>
<pubDate>Fri, 06 Nov 2026 10:00:00 GMT</pubDate><itunes:duration>48:20</itunes:duration>
<enclosure url="https://example.com/audio.mp3" type="audio/mpeg"/></item>
<item><guid>v</guid><title>Video episode</title><itunes:duration>01:02:03</itunes:duration>
<enclosure url="/video.mp4" type="video/mp4"/></item>
<item><guid>a</guid><title>Duplicate</title>
<enclosure url="https://example.com/audio.mp3" type="audio/mpeg"/></item>
<item><title>No enclosure</title></item>
</channel></rss>''';

class _MemoryDownloads extends PodcastDownloads {
  @override
  Future<List<PodcastEpisode>> list(int profile) async => [];
}

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late Directory downloadRoot;
  late PodcastDownloads downloads;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    downloadRoot = await Directory.systemTemp.createTemp(
      'millitop-podcasts-test-',
    );
    downloads = PodcastDownloads(supportDirectory: () async => downloadRoot);
  });
  tearDown(() async => downloadRoot.delete(recursive: true));

  test(
    'RSS preserves actual audio/video media, duration, dates and dedupes',
    () {
      final episodes = PodcastCatalog.parseFeed(feed, show);
      expect(episodes.length, 2);
      final audio = episodes.firstWhere((e) => !e.video);
      final video = episodes.firstWhere((e) => e.video);
      expect(audio.duration, const Duration(minutes: 48, seconds: 20));
      expect(audio.description, 'Audio description');
      expect(audio.published, DateTime.utc(2026, 11, 6, 10));
      expect(video.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(video.mediaUrl, 'https://example.com/video.mp4');
      expect(PodcastEpisode.fromJson(video.toJson()).key, video.key);
    },
  );

  test(
    'Apple directory request uses podcast entity and maps publisher feeds',
    () async {
      final catalog = PodcastCatalog(
        fetch: (uri) async {
          expect(uri.host, 'itunes.apple.com');
          expect(uri.queryParameters['media'], 'podcast');
          expect(uri.queryParameters['entity'], 'podcast');
          expect(uri.queryParameters['term'], 'science');
          return jsonEncode({
            'results': [
              {
                'collectionId': 42,
                'collectionName': show.title,
                'artistName': show.author,
                'feedUrl': show.feedUrl,
              },
            ],
          });
        },
      );
      expect((await catalog.search('science')).single.feedUrl, show.feedUrl);
    },
  );

  test(
    'invalid feeds and credentials in feed URLs are rejected explicitly',
    () {
      expect(
        () => PodcastCatalog.parseFeed('<rss>', show),
        throwsA(isA<Exception>()),
      );
      expect(
        () => PodcastShow.fromJson({
          ...show.toJson(),
          'feedUrl': 'https://user:pass@example.com/feed',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'resumableEpisodes excludes completed/unstarted/at-end entries and sorts newest first',
    () {
      final audio = PodcastCatalog.parseFeed(feed, show).first;
      final video = PodcastCatalog.parseFeed(feed, show).last;
      final completedEpisode = PodcastEpisode(
        id: 'completed-ep',
        title: 'Completed',
        description: '',
        mediaUrl: 'https://example.com/completed.mp3',
        artwork: '',
        show: show,
        video: false,
        published: null,
        duration: const Duration(milliseconds: 180000),
      );
      final unstartedEpisode = PodcastEpisode(
        id: 'unstarted-ep',
        title: 'Unstarted',
        description: '',
        mediaUrl: 'https://example.com/unstarted.mp3',
        artwork: '',
        show: show,
        video: false,
        published: null,
        duration: const Duration(milliseconds: 180000),
      );
      final atEndEpisode = PodcastEpisode(
        id: 'atend-ep',
        title: 'At end',
        description: '',
        mediaUrl: 'https://example.com/atend.mp3',
        artwork: '',
        show: show,
        video: false,
        published: null,
        duration: const Duration(milliseconds: 180000),
      );
      final library = PodcastLibrary(
        progress: {
          audio.key: {
            'episode': audio.toJson(),
            'positionMs': 60000,
            'durationMs': 180000,
            'completed': false,
            'updatedAtUtc': '2026-11-06T10:00:00Z',
          },
          video.key: {
            'episode': video.toJson(),
            'positionMs': 30000,
            'durationMs': 180000,
            'completed': false,
            'updatedAtUtc': '2026-11-07T10:00:00Z',
          },
          completedEpisode.key: {
            'episode': completedEpisode.toJson(),
            'positionMs': 90000,
            'durationMs': 180000,
            'completed': true,
            'updatedAtUtc': '2026-11-05T10:00:00Z',
          },
          unstartedEpisode.key: {
            'episode': unstartedEpisode.toJson(),
            'positionMs': 0,
            'durationMs': 180000,
            'completed': false,
            'updatedAtUtc': '2026-11-04T10:00:00Z',
          },
          atEndEpisode.key: {
            'episode': atEndEpisode.toJson(),
            'positionMs': 180000,
            'durationMs': 180000,
            'completed': false,
            'updatedAtUtc': '2026-11-03T10:00:00Z',
          },
        },
      );
      final entries = library.resumableEpisodes;
      expect(entries.length, 2);
      expect(entries[0].episode.key, video.key);
      expect(entries[1].episode.key, audio.key);
    },
  );

  test(
    'podcast library and sync stay isolated per profile and retain newer progress',
    () async {
      final store = PodcastStore();
      final episode = PodcastCatalog.parseFeed(feed, show).first;
      final local = PodcastLibrary(
        following: [show],
        queue: [episode],
        speed: 1.5,
        progress: {
          episode.key: {
            'episode': episode.toJson(),
            'positionMs': 90000,
            'durationMs': 180000,
            'completed': false,
            'updatedAtUtc': '2026-11-07T10:00:00Z',
          },
        },
      );
      await store.save(1, local);
      expect((await store.load(2)).following, isEmpty);
      await store.applySync(
        1,
        PodcastLibrary(
          following: [show],
          queue: [episode],
          progress: {
            episode.key: {
              'episode': episode.toJson(),
              'positionMs': 1000,
              'durationMs': 180000,
              'completed': false,
              'updatedAtUtc': '2026-11-06T10:00:00Z',
            },
          },
        ).toJson(),
      );
      expect((await store.load(1)).progress[episode.key]['positionMs'], 90000);
      final prefs = HomePreferences();
      await prefs.applyLiveTvProfileSyncState(2, {'podcasts': local.toJson()});
      final restored = await store.load(2);
      expect(restored.following.single.id, '42');
      expect(restored.queue.single.key, episode.key);
      expect(restored.speed, 1.5);
      await prefs.clearProfileData(
        2,
        podcastDownloads: downloads,
        tubeDownloads: TubeDownloads(
          supportDirectory: () async => downloadRoot,
        ),
      );
      expect((await store.load(2)).queue, isEmpty);
      expect((await store.load(1)).following, isNotEmpty);
    },
  );

  testWidgets('themed podcast screen discovers feeds and filters audio/video', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = PodcastCatalog(
      fetch: (uri) async => uri.host == 'itunes.apple.com'
          ? jsonEncode({
              'results': [
                {
                  'collectionId': 42,
                  'collectionName': show.title,
                  'artistName': show.author,
                  'feedUrl': show.feedUrl,
                },
              ],
            })
          : feed,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MillitopThemeController.instance.materialTheme,
        home: PodcastsScreen(
          profileId: 1,
          catalog: catalog,
          playback: PodcastPlayback(),
          downloads: _MemoryDownloads(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Podcasts'), findsOneWidget);
    expect(find.text('Latest episodes'), findsOneWidget);
    expect(find.text('Audio episode'), findsOneWidget);
    expect(find.text('Video episode'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Video'));
    await tester.pumpAndSettle();
    expect(find.text('Audio episode'), findsNothing);
    expect(find.text('Video episode'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Audio'));
    await tester.pumpAndSettle();
    expect(find.text('Video episode'), findsNothing);
    expect(find.text('Audio episode'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Favorite episode'));
    await tester.pumpAndSettle();
    final favorite = (await PlaylistHubRepository().load(1)).favorites.single;
    expect(favorite.type, HubMediaType.podcast);
    expect(favorite.title, 'Audio episode');
    await tester.tap(find.byTooltip('Remove podcast favorite'));
    await tester.pumpAndSettle();
    expect((await PlaylistHubRepository().load(1)).favorites, isEmpty);
  });

  test(
    'downloads preserve bytes, isolate profiles and clean failures',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final listener = server.listen((request) async {
        if (request.uri.path == '/missing') {
          request.response.statusCode = 404;
        } else {
          request.response.headers.contentType = ContentType('audio', 'mpeg');
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      try {
        final episode = PodcastEpisode.fromJson({
          ...PodcastCatalog.parseFeed(feed, show).first.toJson(),
          'mediaUrl': 'http://127.0.0.1:${server.port}/episode.mp3',
        });
        await downloads.download(1, episode, (_, __) {});
        final local = await downloads.localPath(1, episode);
        expect(await File(local!).readAsBytes(), [1, 2, 3, 4]);
        expect((await downloads.list(1)).single.key, episode.key);
        expect(await downloads.list(2), isEmpty);
        final missing = PodcastEpisode.fromJson({
          ...episode.toJson(),
          'id': 'missing',
          'mediaUrl': 'http://127.0.0.1:${server.port}/missing',
        });
        await expectLater(
          downloads.download(1, missing, (_, __) {}),
          throwsA(isA<HttpException>()),
        );
        expect(await downloads.localPath(1, missing), isNull);
        await downloads.clearProfile(1);
        expect(await downloads.list(1), isEmpty);
      } finally {
        await listener.cancel();
        await server.close(force: true);
      }
    }, _RealHttpOverrides()),
  );

  test(
    'queue, following and completed progress persist through session changes',
    () async {
      final playback = PodcastPlayback();
      await playback.initialize(1);
      await playback.follow(show);
      final episode = PodcastCatalog.parseFeed(feed, show).first;
      await playback.enqueue(episode);
      await playback.enqueue(episode);
      expect(playback.library.queue.length, 1);
      await playback.setSpeed(1.5);
      playback.active = episode;
      playback.duration = const Duration(minutes: 5);
      playback.position = playback.duration;
      playback.library = PodcastLibrary(
        following: playback.library.following,
        queue: playback.library.queue,
        speed: playback.library.speed,
        progress: {
          episode.key: {
            'episode': episode.toJson(),
            'completed': true,
            'positionMs': 300000,
            'durationMs': 300000,
            'updatedAtUtc': '2026-11-01T10:00:00Z',
          },
        },
      );
      await playback.stop();
      final persisted = await PodcastStore().load(1);
      expect(persisted.progress[episode.key]['completed'], true);
      expect(persisted.following.single.id, show.id);
      expect(persisted.speed, 1.5);
      await playback.removeQueued(episode);
      expect(playback.library.queue, isEmpty);
      await playback.follow(show);
      expect(playback.library.following, isEmpty);
      await Future.wait([
        playback.initialize(2),
        playback.stop(),
        playback.initialize(3),
      ]);
      expect(playback.profileId, 3);
      expect(playback.active, isNull);
      playback.dispose();
    },
  );

  test(
    'RFC 2822 publication dates accept numeric offsets and malformed metadata',
    () {
      final numeric = PodcastCatalog.parseFeed(
        feed.replaceFirst(
          'Fri, 06 Nov 2026 10:00:00 GMT',
          'Fri, 06 Nov 2026 10:00:00 +0530',
        ),
        show,
      );
      expect(
        numeric.firstWhere((e) => !e.video).published,
        DateTime.utc(2026, 11, 6, 4, 30),
      );
      final malformed = PodcastCatalog.parseFeed(
        feed.replaceFirst('Fri, 06 Nov 2026 10:00:00 GMT', 'invalid date'),
        show,
      );
      expect(malformed.length, 2);
      expect(malformed.firstWhere((e) => !e.video).published, isNull);
    },
  );

  for (final theme in MillitopThemeId.values) {
    for (final size in [
      const Size(320, 640),
      const Size(360, 740),
      const Size(412, 915),
      const Size(740, 360),
      const Size(1280, 720),
      const Size(1920, 1080),
    ]) {
      testWidgets(
        '${size.width}px layout, resume cards and player respect ${theme.name}',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final episode = PodcastCatalog.parseFeed(feed, show).first;
          await PodcastStore().save(
            1,
            PodcastLibrary(
              following: [show],
              progress: {
                episode.key: {
                  'episode': episode.toJson(),
                  'positionMs': 2000,
                  'durationMs': 30000,
                  'completed': false,
                  'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
                },
              },
            ),
          );
          final catalog = PodcastCatalog(
            fetch: (uri) async => uri.host == 'itunes.apple.com'
                ? jsonEncode({
                    'results': [
                      {
                        'collectionId': 42,
                        'collectionName': show.title,
                        'artistName': show.author,
                        'feedUrl': show.feedUrl,
                      },
                    ],
                  })
                : feed,
          );
          final themes = MillitopThemeController.instance;
          final playback = PodcastPlayback();
          final previousTheme = themes.current.id;
          themes.setTheme(theme);
          addTearDown(() => themes.setTheme(previousTheme));
          await tester.pumpWidget(
            MaterialApp(
              theme: themes.materialTheme,
              home: PodcastsScreen(
                profileId: 1,
                catalog: catalog,
                playback: playback,
                downloads: _MemoryDownloads(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Continue listening & watching'), findsOneWidget);
          await tester.ensureVisible(
            find.widgetWithText(ChoiceChip, 'Following'),
          );
          await tester.tap(find.widgetWithText(ChoiceChip, 'Following'));
          await tester.pumpAndSettle();
          expect(find.text('Following'), findsWidgets);
          await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'All'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Discover on Apple Podcasts'),
            180,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('Discover on Apple Podcasts'), findsOneWidget);
          expect(tester.takeException(), isNull);
          playback.active = episode;
          playback.duration = episode.duration;
          await tester.pumpWidget(
            MaterialApp(
              theme: themes.materialTheme,
              home: Scaffold(
                body: PodcastPlayerBar(onOpenQueue: () {}, playback: playback),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byTooltip('Back 15 seconds'), findsOneWidget);
          expect(find.byTooltip('Sleep timer'), findsOneWidget);
          expect(tester.takeException(), isNull);
          playback.active = null;
        },
      );
    }
  }
}
