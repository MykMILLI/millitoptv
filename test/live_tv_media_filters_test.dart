import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/screens/live_tv_media_screen.dart';
import 'package:millitop_tv/services/media_catalog_cache.dart';
import 'package:millitop_tv/services/live_tv_playlist.dart';
import 'package:millitop_tv/services/live_tv_source.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';

const _source = LiveTvSource(
  id: 'test-source',
  name: 'Test library',
  type: 'm3u',
  m3uUrl: 'https://example.invalid/library.m3u',
);

class _CatalogService extends LiveTvPlaylistService {
  final List<LiveTvMediaItem> movies;
  final List<LiveTvMediaItem> series;

  _CatalogService({this.movies = const [], this.series = const []});

  @override
  Future<List<LiveTvMediaItem>> loadMovies(LiveTvSource source) =>
      Future.value(movies);

  @override
  Future<List<LiveTvMediaItem>> loadSeries(LiveTvSource source) =>
      Future.value(series);
}

/// Builds a large synthetic catalog (500 titles spread across 40 categories)
/// to exercise the category/genre filtering performance path. Before the
/// O(n^2) fix, selecting a category on a catalog this size would hang the
/// test (and the real app) well past a reasonable pump timeout.
List<LiveTvMediaItem> _largeCatalog({int count = 500, int groupCount = 40}) {
  return List.generate(count, (index) {
    final group = 'Category ${index % groupCount}';
    return LiveTvMediaItem(
      id: 'movie-$index',
      title: 'Movie $index',
      streamUrl: 'https://example.invalid/movie-$index.mp4',
      group: group,
      genres: index.isEven ? const ['Horror'] : const ['Comedy'],
    );
  });
}

Future<void> _open(
  WidgetTester tester, {
  required _CatalogService service,
  DateTime Function()? now,
}) => tester.pumpWidget(
  MaterialApp(
    theme: MillitopThemeController.instance.materialTheme,
    home: LiveTvMediaScreen(
      catalogCache: MediaCatalogCache.disabled(),
      profileId: 1,
      // These tests exercise the poster grid, not the Home hub.
      initialMediaType: 'movie',
      loadConfiguredSources: (_) => Future.value([_source]),
      playlistService: service,
      now: now,
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  adultAndBackTests();

  testWidgets('selecting a category on a large catalog does not hang', (
    tester,
  ) async {
    final service = _CatalogService(movies: _largeCatalog(), series: const []);
    await _open(tester, service: service);
    await tester.pumpAndSettle();

    expect(find.text('Movie 0'), findsOneWidget);

    final stopwatch = Stopwatch()..start();
    final categoryField = find.byWidgetPredicate(
      (widget) =>
          widget is InkWell &&
          widget.key is ValueKey &&
          (widget.key! as ValueKey).value.toString().startsWith('media-group-'),
    );
    await tester.tap(categoryField);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('category-picker-search')),
      'Category 3',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Category 3').first);
    await tester.pumpAndSettle();
    stopwatch.stop();

    expect(tester.takeException(), isNull);
    expect(stopwatch.elapsed < const Duration(seconds: 5), isTrue);
    expect(find.text('Movie 3'), findsOneWidget);
    expect(find.text('Movie 0'), findsNothing);
  });

  testWidgets('genre filter narrows visible items', (tester) async {
    final service = _CatalogService(
      movies: [
        const LiveTvMediaItem(
          id: 'horror-1',
          title: 'Spooky Movie',
          streamUrl: 'https://example.invalid/spooky.mp4',
          genres: ['Horror'],
        ),
        const LiveTvMediaItem(
          id: 'comedy-1',
          title: 'Funny Movie',
          streamUrl: 'https://example.invalid/funny.mp4',
          genres: ['Comedy'],
        ),
      ],
    );
    await _open(tester, service: service);
    await tester.pumpAndSettle();

    expect(find.text('Spooky Movie'), findsOneWidget);
    expect(find.text('Funny Movie'), findsOneWidget);

    final horrorChip = find.widgetWithText(FilterChip, 'Horror').first;
    await tester.ensureVisible(horrorChip);
    await tester.pumpAndSettle();
    await tester.tap(horrorChip);
    await tester.pumpAndSettle();

    expect(find.text('Spooky Movie'), findsOneWidget);
    expect(find.text('Funny Movie'), findsNothing);
  });

  testWidgets('active seasonal collection filters matching items', (
    tester,
  ) async {
    final service = _CatalogService(
      movies: [
        const LiveTvMediaItem(
          id: 'horror-1',
          title: 'Spooky Movie',
          streamUrl: 'https://example.invalid/spooky.mp4',
          genres: ['Horror'],
        ),
        const LiveTvMediaItem(
          id: 'comedy-1',
          title: 'Funny Movie',
          streamUrl: 'https://example.invalid/funny.mp4',
          genres: ['Comedy'],
        ),
      ],
    );
    await _open(tester, service: service, now: () => DateTime(2024, 10, 20));
    await tester.pumpAndSettle();

    expect(find.text('Halloween'), findsOneWidget);
    expect(find.text('Christmas'), findsNothing);

    final halloweenChip = find.widgetWithText(FilterChip, 'Halloween').first;
    await tester.ensureVisible(halloweenChip);
    await tester.pumpAndSettle();
    await tester.tap(halloweenChip);
    await tester.pumpAndSettle();

    expect(find.text('Spooky Movie'), findsOneWidget);
    expect(find.text('Funny Movie'), findsNothing);
  });

  testWidgets('seasonal collections are not suggested outside their window', (
    tester,
  ) async {
    final service = _CatalogService(movies: _largeCatalog(count: 1));
    await _open(tester, service: service, now: () => DateTime(2024, 6, 1));
    await tester.pumpAndSettle();

    expect(find.text('Halloween'), findsNothing);
    expect(find.text('Thanksgiving'), findsNothing);
    expect(find.text('Christmas'), findsNothing);
  });

  testWidgets('recently added sort orders newest first', (tester) async {
    final service = _CatalogService(
      movies: [
        LiveTvMediaItem(
          id: 'old',
          title: 'Old Movie',
          streamUrl: 'https://example.invalid/old.mp4',
          addedAt: DateTime(2023),
        ),
        LiveTvMediaItem(
          id: 'new',
          title: 'New Movie',
          streamUrl: 'https://example.invalid/new.mp4',
          addedAt: DateTime(2024),
        ),
      ],
    );
    await _open(tester, service: service);
    await tester.pumpAndSettle();

    final relevanceText = find.text('Relevance');
    await tester.ensureVisible(relevanceText);
    await tester.pumpAndSettle();
    await tester.tap(relevanceText);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recently Added').last);
    await tester.pumpAndSettle();

    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList();
    expect(titles.indexOf('New Movie') < titles.indexOf('Old Movie'), isTrue);
  });
}

List<LiveTvMediaItem> _mixedCatalog() => const [
  LiveTvMediaItem(
    id: 'regular-1',
    title: 'Family Movie',
    streamUrl: 'https://example.invalid/family.mp4',
    group: 'Movies',
  ),
  LiveTvMediaItem(
    id: 'iptv-adult-1',
    title: 'XXX - Late Feature',
    streamUrl: 'https://example.invalid/xxx.mp4',
    group: 'For Adults',
  ),
  LiveTvMediaItem(
    id: 'jf-adult-1',
    title: 'Library Title',
    streamUrl: 'https://example.invalid/jf.mp4',
    group: 'Adult',
  ),
];

void adultAndBackTests() {
  testWidgets('adult titles are hidden by default', (tester) async {
    await _open(tester, service: _CatalogService(movies: _mixedCatalog()));
    await tester.pumpAndSettle();

    expect(find.text('Family Movie'), findsOneWidget);
    expect(find.text('XXX - Late Feature'), findsNothing);
    expect(find.text('Library Title'), findsNothing);
    expect(find.byKey(const ValueKey('media-tab-adult')), findsNothing);
  });

  testWidgets('when enabled, adult titles live only in their own tab', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'media.showAdult.v1.1': true});
    await _open(tester, service: _CatalogService(movies: _mixedCatalog()));
    await tester.pumpAndSettle();

    // Movies grid stays clean.
    expect(find.text('Family Movie'), findsOneWidget);
    expect(find.text('XXX - Late Feature'), findsNothing);

    final adultTab = find.byKey(const ValueKey('media-tab-adult'));
    await tester.ensureVisible(adultTab);
    await tester.tap(adultTab);
    await tester.pumpAndSettle();

    expect(find.text('XXX - Late Feature'), findsOneWidget);
    expect(find.text('Library Title'), findsOneWidget);
    expect(find.text('Family Movie'), findsNothing);
  });

  testWidgets('Back from a grid returns to Movies & Series Home first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MillitopThemeController.instance.materialTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LiveTvMediaScreen(
                      catalogCache: MediaCatalogCache.disabled(),
                      profileId: 1,
                      loadConfiguredSources: (_) => Future.value([_source]),
                      playlistService: _CatalogService(movies: _mixedCatalog()),
                    ),
                  ),
                ),
                child: const Text('App Home'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('App Home'));
    await tester.pumpAndSettle();

    ChoiceChip chip(String key) =>
        tester.widget<ChoiceChip>(find.byKey(ValueKey(key)));
    expect(chip('media-tab-home').selected, isTrue);

    await tester.tap(find.byKey(const ValueKey('media-tab-movies')).first);
    await tester.pumpAndSettle();
    expect(chip('media-tab-movies').selected, isTrue);

    // First Back: still in Movies & Series, now on its Home.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('App Home'), findsNothing);
    expect(chip('media-tab-home').selected, isTrue);

    // Second Back: leaves to the app home screen.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('App Home'), findsOneWidget);
  });
}
