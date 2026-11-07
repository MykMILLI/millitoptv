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
