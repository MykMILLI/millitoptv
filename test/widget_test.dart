import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('Launcher displays its home screen', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: Launcher(profileId: 1)));

    await tester.pumpAndSettle();

    expect(find.text('MILLITOP TV'), findsOneWidget);
    expect(find.text('Live TV'), findsOneWidget);
    expect(find.text('Podcasts'), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('VLC player'), findsNothing);
    expect(find.text('Emby'), findsNothing);
    expect(find.text('Jellyfin'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'Home remains usable at phone, landscape and TV sizes in every theme',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final themes = MillitopThemeController.instance;
      final previous = themes.current.id;
      addTearDown(() => themes.setTheme(previous));
      for (final theme in MillitopThemeId.values) {
        themes.setTheme(theme);
        for (final size in [
          const Size(320, 640),
          const Size(360, 740),
          const Size(412, 915),
          const Size(740, 360),
          const Size(1280, 720),
          const Size(1920, 1080),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpWidget(
            MaterialApp(
              theme: themes.materialTheme,
              home: Launcher(
                key: ValueKey('${theme.name}-$size'),
                profileId: 1,
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (find.text('Podcasts').evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              find.text('Podcasts'),
              200,
              scrollable: find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is Scrollable &&
                        widget.axisDirection == AxisDirection.down,
                  )
                  .first,
            );
          }
          expect(find.text('Podcasts'), findsOneWidget);
          expect(find.text('YouTube'), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: 'Home ${theme.name} at $size',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );
}
