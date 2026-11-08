import 'package:home_widget/home_widget.dart';
import 'app_log.dart';

class MusicWidgetService {
  const MusicWidgetService();
  static bool _widgetUnavailable = false;

  Future<void> update({
    required String title,
    required String artist,
    required bool playing,
  }) async {
    if (_widgetUnavailable) {
      return;
    }
    try {
      await HomeWidget.saveWidgetData<String>('music_title', title);
      await HomeWidget.saveWidgetData<String>('music_artist', artist);
      await HomeWidget.saveWidgetData<bool>('music_playing', playing);
      await HomeWidget.updateWidget(
        androidName: 'MillitopMusicWidgetProvider',
        iOSName: 'MillitopMusicWidget',
      );
    } catch (error, stackTrace) {
      final message = error.toString();
      if (message.contains(
        'No Widget found with Name MillitopMusicWidgetProvider',
      )) {
        _widgetUnavailable = true;
        AppLog.warn(
          LogCategory.playback,
          'Music home-screen widget provider is unavailable; skipping widget updates on this device.',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
      AppLog.error(
        LogCategory.playback,
        'Music home-screen widget update failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
