import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/screens/live_tv_media_screen.dart';
import 'package:millitop_tv/services/live_tv_playlist.dart';
import 'package:millitop_tv/services/live_tv_source.dart';
import 'package:millitop_tv/services/home_preferences.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';

const _source = LiveTvSource(
  id: 'test-source',
  name: 'Test library',
  type: 'm3u',
  m3uUrl: 'https://example.invalid/library.m3u',
);
const _movie = LiveTvMediaItem(
  id: 'movie',
  title: 'Test movie',
  streamUrl: 'https://example.invalid/movie.mp4',
);
const _series = LiveTvMediaItem(
  id: 'series',
  title: 'Test series',
  streamUrl: 'https://example.invalid/episode.mp4',
  series: true,
);
final _modal = find.byKey(const Key('catalog-loading-modal'));

class _CatalogService extends LiveTvPlaylistService {
  Future<List<LiveTvMediaItem>> moviesResponse = Future.value([_movie]);
  Future<List<LiveTvMediaItem>> seriesResponse = Future.value([_series]);

  @override
  Future<List<LiveTvMediaItem>> loadMovies(LiveTvSource source) =>
      moviesResponse;

  @override
  Future<List<LiveTvMediaItem>> loadSeries(LiveTvSource source) =>
      seriesResponse;
}

Future<void> _open(
  WidgetTester tester, {
  required Future<List<LiveTvSource>> Function(int) loadSources,
  _CatalogService? service,
}) => tester.pumpWidget(
  MaterialApp(
    theme: MillitopThemeController.instance.materialTheme,
    home: LiveTvMediaScreen(
      profileId: 1,
      loadConfiguredSources: loadSources,
      playlistService: service ?? _CatalogService(),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [
    const Size(320, 640),
    const Size(360, 740),
    const Size(412, 915),
    const Size(740, 360),
    const Size(1280, 720),
    const Size(1920, 1080),
  ]) {
    for (final theme in MillitopThemeId.values) {
      testWidgets('modal appears on first frame at $size in ${theme.name}', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final themes = MillitopThemeController.instance;
        final previous = themes.current.id;
        themes.setTheme(theme);
        addTearDown(() => themes.setTheme(previous));
        final sources = Completer<List<LiveTvSource>>();

        await _open(tester, loadSources: (_) => sources.future);

        expect(_modal, findsOneWidget);
        expect(find.text('Loading Movies & Series'), findsOneWidget);
        expect(
          tester
              .widget<ModalBarrier>(
                find.descendant(
                  of: _modal,
                  matching: find.byType(ModalBarrier),
                ),
              )
              .dismissible,
          isFalse,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(_modal, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        sources.complete([]);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('modal spans source discovery, movies and series, then closes', (
    tester,
  ) async {
    final sources = Completer<List<LiveTvSource>>();
    final movies = Completer<List<LiveTvMediaItem>>();
    final series = Completer<List<LiveTvMediaItem>>();
    final service = _CatalogService()
      ..moviesResponse = movies.future
      ..seriesResponse = series.future;
    await _open(tester, loadSources: (_) => sources.future, service: service);
    expect(_modal, findsOneWidget);

    sources.complete([_source]);
    await tester.pump();
    expect(_modal, findsOneWidget);
    expect(find.text('Loading movies...'), findsOneWidget);
    expect(find.text('Test library'), findsWidgets);

    movies.complete([_movie]);
    await tester.pump();
    expect(_modal, findsOneWidget);
    expect(find.text('Loading series...'), findsOneWidget);
    expect(find.text('Movies: 1'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.descendant(
              of: _modal,
              matching: find.byType(LinearProgressIndicator),
            ),
          )
          .value,
      0.5,
    );

    series.complete([_series]);
    await tester.pumpAndSettle();
    expect(_modal, findsNothing);
    expect(find.text('Test movie'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reload displays modal before source discovery completes', (
    tester,
  ) async {
    Future<List<LiveTvSource>> sourcesResult = Future.value([_source]);
    await _open(tester, loadSources: (_) => sourcesResult);
    await tester.pumpAndSettle();
    expect(_modal, findsNothing);

    final pending = Completer<List<LiveTvSource>>();
    sourcesResult = pending.future;
    await tester.tap(find.byTooltip('Reload library'));
    await tester.pump();
    expect(_modal, findsOneWidget);
    expect(
      find.text('Checking configured and dashboard sources...'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(_modal, findsOneWidget);

    pending.complete([_source]);
    await tester.pumpAndSettle();
    expect(_modal, findsNothing);
    expect(find.text('Test movie'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source discovery failure closes modal and displays error', (
    tester,
  ) async {
    final pending = Completer<List<LiveTvSource>>();
    await _open(tester, loadSources: (_) => pending.future);
    await tester.pump();
    pending.completeError(StateError('Source discovery failed'));
    await tester.pumpAndSettle();
    expect(_modal, findsNothing);
    expect(find.text('Source discovery failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final failMovies in [true, false]) {
    testWidgets('${failMovies ? 'movie' : 'series'} failure closes modal', (
      tester,
    ) async {
      final pending = Completer<List<LiveTvMediaItem>>();
      final service = _CatalogService();
      if (failMovies) {
        service.moviesResponse = pending.future;
      } else {
        service.seriesResponse = pending.future;
      }
      await _open(
        tester,
        loadSources: (_) async => [_source],
        service: service,
      );
      await tester.pump();
      expect(_modal, findsOneWidget);
      pending.completeError(StateError('Catalog unavailable'));
      await tester.pumpAndSettle();
      expect(_modal, findsNothing);
      expect(find.text('Catalog unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final fail in [true, false]) {
    testWidgets('reload ${fail ? 'failure' : 'no sources'} closes modal', (
      tester,
    ) async {
      Future<List<LiveTvSource>> sourcesResult = Future.value([_source]);
      await _open(tester, loadSources: (_) => sourcesResult);
      await tester.pumpAndSettle();
      final pending = Completer<List<LiveTvSource>>();
      sourcesResult = pending.future;
      await tester.tap(find.byTooltip('Reload library'));
      await tester.pump();
      expect(_modal, findsOneWidget);
      if (fail) {
        pending.completeError(StateError('Sources unavailable'));
      } else {
        pending.complete([]);
      }
      await tester.pumpAndSettle();
      expect(_modal, findsNothing);
      expect(
        find.textContaining(
          fail ? 'Sources unavailable' : 'No VOD sources are available',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no sources closes startup modal with setup guidance', (
    tester,
  ) async {
    await _open(tester, loadSources: (_) async => []);
    await tester.pumpAndSettle();
    expect(_modal, findsNothing);
    expect(find.textContaining('Add a source in Live TV'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a saved item never falls back to another provider', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LiveTvMediaScreen(
        profileId: 1,
        playlistService: _CatalogService(),
        loadConfiguredSources: (_) async => [_source],
        initialSourceId: 'missing-provider',
        initialLibraryItem: const LiveTvLibraryItem(
          sourceId: 'missing-provider', sourceName: 'Missing provider',
          mediaType: 'movie', mediaId: 'movie', title: 'Saved movie',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(_modal, findsNothing);
    expect(find.textContaining('The source for "Saved movie" is unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
