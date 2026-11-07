import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pstube_engine/pstube_engine.dart';
import 'package:millitop_tv/screens/youtube_screen.dart';
import 'package:millitop_tv/services/home_preferences.dart';
import 'package:millitop_tv/services/tube_library.dart';
import 'package:millitop_tv/services/tube_downloads.dart';
import 'package:millitop_tv/services/podcast_downloads.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';

const sample = TubeVideo(
  id: 'video1',
  title: 'A real video title',
  author: 'Channel One',
  channelId: 'channel1',
  seconds: 100,
  views: 10000,
);
const second = TubeVideo(
  id: 'video2',
  title: 'Second video',
  author: 'Channel Two',
  channelId: 'channel2',
  seconds: 30,
);

class FakeEngine implements TubeEngine {
  final calls = <String>[];
  bool fail = false;
  @override
  Future<TubePage> trending() async {
    calls.add('trending');
    if (fail) throw StateError('Server unavailable');
    return TubePage([
      sample,
    ], next: () async => const TubePage([sample, second]));
  }

  @override
  Future<TubePage> search(String query) async {
    calls.add('search:$query');
    return const TubePage([sample, second]);
  }

  @override
  Future<TubePage> channel(String id) async {
    calls.add('channel:$id');
    return const TubePage([sample]);
  }

  @override
  Future<TubePage> playlist(String id) async {
    calls.add('playlist:$id');
    return const TubePage([sample]);
  }

  @override
  Future<TubeDetails> details(String id) async => const TubeDetails(
    video: sample,
    videoStreams: [
      TubeStream(url: 'https://example.com/video.mp4', quality: '360p'),
    ],
    audioStreams: [],
  );
  @override
  Future<TubeComments> comments(String id) async => const TubeComments([]);
  @override
  void close() {
    calls.add('close');
  }
}

class MemoryDownloads extends TubeDownloads {
  @override
  Future<List<TubeVideo>> list(int profile) async => [];
}

class RealHttpOverrides extends HttpOverrides {}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'offline downloads preserve bytes, isolate profiles and remove failed transfers',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final root = await Directory.systemTemp.createTemp(
        'millitop-tube-download-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final listener = server.listen((request) async {
        if (request.uri.path == '/missing') {
          request.response.statusCode = 404;
        } else {
          request.response.add([1, 2, 3, 4, 5]);
        }
        await request.response.close();
      });
      final downloads = TubeDownloads(supportDirectory: () async => root);
      try {
        await downloads.save(
          1,
          sample,
          TubeStream(
            url: 'http://127.0.0.1:${server.port}/video',
            quality: '360p',
          ),
          (_, __) {},
        );
        expect(
          await File((await downloads.local(1, sample.id))!).readAsBytes(),
          [1, 2, 3, 4, 5],
        );
        expect((await downloads.list(1)).single.id, sample.id);
        expect(await downloads.list(2), isEmpty);
        await expectLater(
          downloads.save(
            1,
            second,
            TubeStream(
              url: 'http://127.0.0.1:${server.port}/missing',
              quality: '360p',
            ),
            (_, __) {},
          ),
          throwsA(isA<HttpException>()),
        );
        expect(await downloads.local(1, second.id), isNull);
        await expectLater(
          downloads.save(
            1,
            second,
            const TubeStream(
              url: 'https://example.com/video',
              quality: '1080p',
              videoOnly: true,
            ),
            (_, __) {},
          ),
          throwsStateError,
        );
        await downloads.remove(1, sample.id);
        expect(await downloads.list(1), isEmpty);
      } finally {
        await listener.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    }, RealHttpOverrides()),
  );

  test(
    'PsTube Piped contracts normalize video metadata and adaptive playback',
    () {
      final details = PsTubeEngine.pipedDetails('abcdefghijk', {
        'title': 'Video',
        'uploader': 'Creator',
        'uploaderUrl': '/channel/UCchannel',
        'duration': 90,
        'views': 1200,
        'videoStreams': [
          {
            'url': 'https://cdn.example.com/video',
            'quality': '1080p',
            'height': 1080,
            'videoOnly': true,
          },
        ],
        'audioStreams': [
          {'url': 'https://cdn.example.com/audio', 'quality': '128 kbps'},
        ],
        'subtitles': [
          {'url': 'https://cdn.example.com/sub.vtt', 'name': 'English'},
        ],
        'relatedStreams': [
          {'url': '/watch?v=nextvideo12', 'title': 'Next', 'type': 'stream'},
        ],
      });
      expect(details.video.channelId, 'UCchannel');
      expect(details.videoStreams.single.videoOnly, true);
      expect(details.audioStreams.single.url, 'https://cdn.example.com/audio');
      expect(details.subtitles.single.label, 'English');
      expect(details.related.single.id, 'nextvideo12');
      expect(TubeVideo.fromJson(sample.toJson()).title, sample.title);
      expect(
        () => PsTubeEngine.pipedDetails('bad', {'videoStreams': []}),
        throwsStateError,
      );
      expect(() => webUrl('file:///C:/private'), throwsFormatException);
      expect(tubeTime(3723), '1:02:03');
    },
  );

  test(
    'Piped trending and comments pagination use the upstream route shapes',
    () async {
      final requested = <String>[];
      final engine = PsTubeEngine(
        fetch: (uri) async {
          requested.add('${uri.path}?${uri.query}');
          if (uri.path == '/trending') {
            return [
              {'url': '/watch?v=abcdefghijk', 'title': 'Video'},
            ];
          }
          return {
            'comments': [
              {'author': 'Person', 'commentText': 'Comment', 'likeCount': 2},
            ],
            'nextpage': uri.path.startsWith('/nextpage') ? null : 'next',
          };
        },
      );
      try {
        expect((await engine.trending()).videos.single.id, 'abcdefghijk');
        final comments = await engine.comments('abcdefghijk');
        expect(comments.comments.single.likes, 2);
        expect((await comments.next!())!.next, isNull);
        expect(requested, [
          '/trending?region=US',
          '/comments/abcdefghijk?',
          '/nextpage/comments/abcdefghijk?nextpage=next',
        ]);
      } finally {
        engine.close();
      }
    },
  );

  test(
    'profile libraries synchronize newest entries and deletion tombstones',
    () async {
      final store = TubeStore();
      var library = const TubeLibrary()
          .toggle('subscriptions', sample)
          .toggle('liked', sample)
          .toggle('later', sample)
          .toggle('playlist/Favorites', second)
          .progress(
            sample,
            const Duration(seconds: 30),
            const Duration(seconds: 100),
          );
      await store.save(1, library);
      final prefs = HomePreferences();
      await prefs.applyLiveTvProfileSyncState(2, {'youtube': library.toJson()});
      expect(
        (await store.load(2)).list('subscriptions').single.channelId,
        'channel1',
      );
      expect((await store.load(2)).playlists.single, 'playlist/Favorites');
      expect((await store.load(2)).history[sample.id]['positionMs'], 30000);
      final stale = library.toJson();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      library = library.toggle('liked', sample);
      await store.save(1, library);
      await store.applySync(1, stale);
      expect((await store.load(1)).list('liked'), isEmpty);
      expect((await store.load(3)).watched, isEmpty);
      final temp = await Directory.systemTemp.createTemp(
        'millitop-youtube-test-',
      );
      try {
        await prefs.clearProfileData(
          2,
          podcastDownloads: PodcastDownloads(
            supportDirectory: () async => temp,
          ),
          tubeDownloads: TubeDownloads(supportDirectory: () async => temp),
        );
        expect((await store.load(2)).entries, isEmpty);
        expect((await store.load(1)).list('later'), isNotEmpty);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'desktop sidebar, search, pagination and local Watch later work',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1250, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final engine = FakeEngine();
      await tester.pumpWidget(
        MaterialApp(
          theme: MillitopThemeController.instance.materialTheme,
          home: YouTubeScreen(
            profileId: 1,
            engine: engine,
            downloads: MemoryDownloads(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(sample.title), findsOneWidget);
      expect(find.text('Subscriptions'), findsNWidgets(2));
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(find.text(second.title), findsOneWidget);
      expect(find.text(sample.title), findsOneWidget);
      await tester.tap(find.byTooltip('Video actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch later').last);
      await tester.pumpAndSettle();
      expect((await TubeStore().load(1)).list('later').single.id, sample.id);
      await tester.tap(find.text('Watch later').first);
      await tester.pumpAndSettle();
      expect(find.text(second.title), findsNothing);
      await tester.enterText(find.byType(TextField), 'flutter');
      await tester.tap(find.byTooltip('Search YouTube'));
      await tester.pumpAndSettle();
      expect(engine.calls, contains('search:flutter'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Music'));
      await tester.pumpAndSettle();
      expect(engine.calls, contains('search:Music'));
      expect(tester.takeException(), isNull);
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
        '${size.width}px ${theme.name} navigation and search remain usable',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final controller = MillitopThemeController.instance;
          final previous = controller.current.id;
          controller.setTheme(theme);
          addTearDown(() => controller.setTheme(previous));
          final engine = FakeEngine();
          await tester.pumpWidget(
            MaterialApp(
              theme: controller.materialTheme,
              home: YouTubeScreen(
                profileId: 1,
                engine: engine,
                downloads: MemoryDownloads(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(sample.title), findsOneWidget);
          if (size.width < 850) {
            await tester.tap(find.byTooltip('Navigation'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text('History').first);
          await tester.pumpAndSettle();
          expect(find.text('History'), size.width < 850 ? findsOneWidget : findsNWidgets(2));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('failed upstream load displays explicit error and Retry', (
    tester,
  ) async {
    final engine = FakeEngine()..fail = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: MillitopThemeController.instance.materialTheme,
        home: YouTubeScreen(
          profileId: 1,
          engine: engine,
          downloads: MemoryDownloads(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Server unavailable'), findsOneWidget);
    engine.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text(sample.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
