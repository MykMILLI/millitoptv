import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/library/library_models.dart';
import 'package:millitop_tv/library/library_repository.dart';
import 'package:millitop_tv/screens/app_settings_screen.dart';
import 'package:millitop_tv/screens/live_tv_screen.dart';
import 'package:millitop_tv/screens/live_tv_media_screen.dart';
import 'package:millitop_tv/services/media_catalog_cache.dart';
import 'package:millitop_tv/screens/media_library_home.dart';
import 'package:millitop_tv/screens/music_screen.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';

class _EmptyFolders extends MediaLibraryRepository {
  @override
  Future<List<LibraryFolder>> load(int profile) async => [];
}

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
      testWidgets('primary screens fit $size with ${theme.name}', (
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
        for (final screen in [
          const AppSettingsScreen(profileId: 1),
          MediaLibraryHome(profileId: 1, repository: _EmptyFolders()),
          MediaLibraryHome(
            profileId: 1,
            recordings: true,
            repository: _EmptyFolders(),
          ),
          const MusicScreen(profileId: 1),
          const LiveTvScreen(profileId: 1),
          LiveTvMediaScreen(
            profileId: 1,
            catalogCache: MediaCatalogCache.disabled(),
          ),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: themes.materialTheme,
              home: screen is MediaLibraryHome
                  ? Scaffold(body: SingleChildScrollView(child: screen))
                  : screen,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            tester.takeException(),
            isNull,
            reason: '${screen.runtimeType} at $size',
          );
          if (screen is AppSettingsScreen && size.width < 700) {
            expect(find.text('Settings category'), findsOneWidget);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: '${screen.runtimeType} cleanup',
          );
        }
      });
    }
  }
}
