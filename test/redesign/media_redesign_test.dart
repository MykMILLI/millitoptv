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
    await tester.tap(find.text('B'));
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeriesEpisodesPanel(
            seasons: const [1, 2],
            selectedSeason: 2,
            onSeasonChanged: (_) {},
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
    await tester.tap(find.text('E1 • Return'));
    expect(played, 'two');
  });
}
