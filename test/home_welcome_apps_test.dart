import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/screens/home_app_tiles.dart';
import 'package:millitop_tv/services/podcast_playback.dart';
import 'package:millitop_tv/services/podcast_service.dart';
import 'package:millitop_tv/services/web_app_catalog.dart';
import 'package:millitop_tv/services/web_app_definition.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';
import 'package:millitop_tv/widgets/animated_media_app_icon.dart';
import 'package:millitop_tv/widgets/rotating_welcome_message.dart';

const _resumeShow = PodcastShow(
  id: 'show-1',
  title: 'Home Show',
  author: 'Author',
  feedUrl: 'https://example.com/feed.xml',
  artwork: '',
);
const _resumeEpisode = PodcastEpisode(
  id: 'ep-1',
  title: 'Resume Episode',
  description: '',
  mediaUrl: 'https://example.com/audio.mp3',
  artwork: '',
  show: _resumeShow,
  video: false,
  published: null,
  duration: Duration(minutes: 30),
);

class _ManagedApps extends ManagedWebAppSource {
  @override
  String get key => 'test/household';
  @override
  bool get allowed => true;
  @override
  Future<List<WebAppDefinition>> fetch() async => [
    WebAppDefinition.fromJson({
      'id': '11111111-1111-4111-8111-111111111111',
      'title': 'Console Emby',
      'url': 'https://example.com',
      'icon': 'emby',
      'revision': 1,
    }, managed: true),
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('consecutive welcome starts vary without repeating', () {
    final first = RotatingWelcomeMessage.nextInitialIndex();
    final second = RotatingWelcomeMessage.nextInitialIndex();
    expect(first, isNot(second));
    expect(welcomeSayings.toSet().length, welcomeSayings.length);
  });

  testWidgets('welcome sayings rotate every 20 seconds and stop when removed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: RotatingWelcomeMessage(initialIndex: 0)),
      ),
    );
    expect(find.text(welcomeSayings[0]), findsOneWidget);
    await tester.pump(const Duration(seconds: 19));
    expect(find.text(welcomeSayings[0]), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text(welcomeSayings[1]), findsOneWidget);
    expect(find.text(welcomeSayings[0]), findsNothing);
    for (var index = 2; index <= welcomeSayings.length; index++) {
      await tester.pump(const Duration(seconds: 20));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.text(welcomeSayings[index % welcomeSayings.length]),
        findsOneWidget,
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  });

  test(
    'factory and saved builtin Emby are excluded; console Emby remains',
    () async {
      SharedPreferences.setMockInitialValues({
        'webapps.local.v1.1': jsonEncode([
          {
            'id': 'emby',
            'title': 'Old Emby',
            'url': 'https://example.com',
            'icon': 'emby',
            'enabled': true,
            'revision': 1,
          },
        ]),
      });
      final catalog = WebAppCatalog(source: _ManagedApps());
      await catalog.sync();
      final apps = await catalog.load(1, includeHidden: true);
      expect(builtinWebApps.any((app) => app.id == 'emby'), isFalse);
      expect(apps.any((app) => app.id == 'emby'), isFalse);
      expect(
        apps.any((app) => app.managed && app.title == 'Console Emby'),
        isTrue,
      );
      catalog.dispose();
    },
  );

  testWidgets(
    'Apps panel omits VLC and local Emby even with stale saved ordering',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'home.appOrder.v1.1': ['native:vlc', 'web:emby'],
      });
      final catalog = WebAppCatalog(source: _ManagedApps());
      await catalog.sync();
      await tester.pumpWidget(
        MaterialApp(
          theme: MillitopThemeController.instance.materialTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: HomeAppTiles(profileId: 1, catalog: catalog),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('native:vlc')), findsNothing);
      expect(find.text('VLC player'), findsNothing);
      expect(find.byKey(const ValueKey('web:emby')), findsNothing);
      expect(find.text('Console Emby'), findsOneWidget);
      expect(find.text('Live TV'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );

  testWidgets('YouTube icon is red and the podcast icon animates with a pulse ring', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AnimatedMediaAppIcon(kind: MediaAppIconKind.youtube),
              AnimatedMediaAppIcon(kind: MediaAppIconKind.podcasts),
            ],
          ),
        ),
      ),
    );
    final containers = tester.widgetList<Container>(find.byType(Container));
    final youtubeBadge = containers.firstWhere(
      (c) => (c.decoration as BoxDecoration).color == const Color(0xFFFF0033),
    );
    expect(youtubeBadge, isNotNull);
    expect(
      containers.any(
        (c) => (c.decoration as BoxDecoration).color == const Color(0xFFB46CFF),
      ),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 7));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Home shows a Continue Listening podcast card and resumes the exact episode',
    (tester) async {
      await SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(
          'podcasts.v1.1',
          jsonEncode(
            PodcastLibrary(
              following: const [_resumeShow],
              progress: {
                _resumeEpisode.key: {
                  'episode': _resumeEpisode.toJson(),
                  'positionMs': 60000,
                  'durationMs': _resumeEpisode.duration.inMilliseconds,
                  'completed': false,
                  'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
                },
              },
            ).toJson(),
          ),
        ),
      );
      final catalog = WebAppCatalog(source: _ManagedApps());
      await catalog.sync();
      await tester.pumpWidget(
        MaterialApp(
          theme: MillitopThemeController.instance.materialTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: HomeAppTiles(
                profileId: 1,
                catalog: catalog,
                podcastPlayback: PodcastPlayback(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Continue Listening'), findsOneWidget);
      expect(find.text('Resume Episode'), findsOneWidget);
      expect(find.text('Home Show'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );
}
