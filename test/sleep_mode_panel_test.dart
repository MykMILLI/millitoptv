import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/screens/sleep_mode_panel.dart';
import 'package:millitop_tv/services/sleep_mode.dart';
import 'package:millitop_tv/services/sleep_sounds_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SleepSoundsController.instance.resetForTesting();
    SleepMode.instance.cancelTimer();
  });

  testWidgets('sleep mode panel shows simplified four-sound layout only', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: SleepModePanel(profileId: 1)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sleep Sounds'), findsOneWidget);
    expect(
      find.text('Mix your sounds. Keep them playing all night.'),
      findsOneWidget,
    );

    expect(find.text('Heavy Rain'), findsOneWidget);
    expect(find.text('Thunder'), findsOneWidget);
    expect(find.text('White Noise'), findsOneWidget);
    expect(find.text('Pink Noise'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(4));

    expect(find.text('Screen-off timer'), findsOneWidget);
    expect(
      find.text('Stops TV, videos and music. Sleep sounds keep playing.'),
      findsOneWidget,
    );
    expect(find.text('15 min'), findsOneWidget);
    expect(find.text('30 min'), findsOneWidget);
    expect(find.text('45 min'), findsOneWidget);
    expect(find.text('60 min'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);

    expect(find.textContaining('Start 45-minute timer'), findsOneWidget);
    expect(
      find.text('Screen off. PC stays on. Sleep sounds stay on.'),
      findsOneWidget,
    );

    expect(find.textContaining('Sleep Sounds backend'), findsNothing);
    expect(find.text('Advanced backend options'), findsNothing);
    expect(find.text('Stop entertainment now'), findsNothing);
    expect(find.text('End overnight keep-awake'), findsNothing);
    expect(find.textContaining('Playback state:'), findsNothing);
    expect(find.textContaining('Timer minutes'), findsNothing);
  });
}
