import 'package:home_widget/home_widget.dart';

class MusicWidgetService {
  const MusicWidgetService();

  Future<void> update({
    required String title,
    required String artist,
    required bool playing,
  }) async {
    await HomeWidget.saveWidgetData<String>('music_title', title);
    await HomeWidget.saveWidgetData<String>('music_artist', artist);
    await HomeWidget.saveWidgetData<bool>('music_playing', playing);
    await HomeWidget.updateWidget(
      androidName: 'MillitopMusicWidgetProvider',
      iOSName: 'MillitopMusicWidget',
    );
  }
}
