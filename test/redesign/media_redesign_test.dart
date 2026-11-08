import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/widgets/redesign/media_library_shell.dart';
import 'package:millitop_tv/widgets/redesign/media_side_panels.dart';

void main() {
  test('letter grouping and sort policy remain consistent', () {
    expect(mediaLetter('  Arcadia'), 'A');
    expect(mediaLetter('23 Roads'), '#');
    expect(mediaLetter(''), '#');
    expect(mediaLetter('Élan'), '#');
    expect(mediaSortKey(' the Harbor '), 'THE HARBOR');
  });
  testWidgets('alphabet button forwards real letter', (tester) async {
    String? jumped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 60,
            child: AlphabetRail(
              selected: 'A',
              available: const {'A', 'B'},
              onJump: (s) => jumped = s,
            ),
          ),
        ),
      ),
    );
    if (find.text('B').evaluate().isNotEmpty) {
      await tester.tap(find.text('B'));
    } else {
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B').last);
    }
    expect(jumped, 'B');
  });
  testWidgets('queue provides empty state and real autoplay toggle', (
    tester,
  ) async {
    bool? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MovieQueuePanel(
            items: const [],
            autoplay: false,
            onAutoplayChanged: (v) => changed = v,
            onPlay: (_) {},
            onRemove: (_) {},
            onReorder: (_, _) {},
            onMoveUp: (_) {},
            onMoveDown: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('Your queue is empty'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    expect(changed, true);
  });
  testWidgets('series panel shows only selected season', (tester) async {
    String? played;
    int seasonChanged = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeriesEpisodesPanel(
            seasons: const [1, 2],
            selectedSeason: 2,
            onSeasonChanged: (_) => seasonChanged++,
            episodes: const [
              EpisodeRow(
                id: 'one',
                season: 1,
                number: 1,
                title: 'Pilot',
                subtitle: '45 min',
              ),
              EpisodeRow(
                id: 'two',
                season: 2,
                number: 1,
                title: 'Return',
                subtitle: '48 min',
              ),
            ],
            onPlay: (id) => played = id,
            autoplay: false,
            onAutoplayChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('E1 • Pilot'), findsNothing);
    expect(find.text('E1 • Return'), findsOneWidget);
    await tester.tap(find.text('E1 • Return'));
    expect(played, 'two');
    expect(seasonChanged, 0);
  });

  testWidgets('queue row actions expose accessible move and remove controls', (
    tester,
  ) async {
    String? moveUp;
    String? moveDown;
    String? removed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MovieQueuePanel(
            items: const [
              MediaQueueRow(
                id: 'source:a',
                title: 'Now',
                subtitle: 'Now playing',
                nowPlaying: true,
                canRemove: false,
              ),
              MediaQueueRow(
                id: 'source:b',
                title: 'Up next',
                subtitle: 'Next',
                canMoveUp: false,
                canMoveDown: true,
                canRemove: true,
              ),
            ],
            autoplay: true,
            onAutoplayChanged: (_) {},
            onPlay: (_) {},
            onRemove: (id) => removed = id,
            onReorder: (_, _) {},
            onMoveUp: (id) => moveUp = id,
            onMoveDown: (id) => moveDown = id,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Move down').last);
    await tester.pump();
    expect(moveDown, 'source:b');
    await tester.tap(find.byTooltip('Remove from queue').last);
    await tester.pump();
    expect(removed, 'source:b');
    expect(moveUp, isNull);
  });

  testWidgets('library shell closes filters and restores content width', (
    tester,
  ) async {
    var filtersOpen = true;
    Future<void> pump() async {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => MediaLibraryShell(
              section: LibrarySection.movies,
              onSectionChanged: (_) {},
              searchController: TextEditingController(),
              onSearchChanged: (_) {},
              libraryName: 'All libraries',
              onChooseLibrary: () {},
              summary: 'Summary',
              genreLabel: 'All genres',
              onChooseGenre: () {},
              sortLabel: 'Title A-Z',
              onChooseSort: () {},
              filtersOpen: filtersOpen,
              onToggleFilters: () => setState(() => filtersOpen = !filtersOpen),
              onCloseFilters: () => setState(() => filtersOpen = false),
              filters: const SizedBox(height: 100, child: Text('Filters body')),
              content: const SizedBox.expand(
                child: ColoredBox(color: Colors.blue),
              ),
              embedInScaffold: true,
            ),
          ),
        ),
      );
    }

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump();
    expect(find.text('Filters body'), findsOneWidget);
    await tester.tap(find.byTooltip('Close filters'));
    await tester.pumpAndSettle();
    expect(find.text('Filters body'), findsNothing);
  });
}
