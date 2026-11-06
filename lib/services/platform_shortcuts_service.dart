import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

class PlatformShortcutsService {
  PlatformShortcutsService._();
  static final PlatformShortcutsService instance = PlatformShortcutsService._();

  final _controller = StreamController<String>.broadcast();
  Stream<String> get actions => _controller.stream;
  final QuickActions _quickActions = const QuickActions();
  bool _started = false;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    try {
      _quickActions.initialize((type) {
        _controller.add(type);
      });
      await _quickActions.setShortcutItems(const <ShortcutItem>[
        ShortcutItem(
          type: 'open_music',
          localizedTitle: 'Music',
          icon: 'music_note',
        ),
        ShortcutItem(
          type: 'open_live_tv',
          localizedTitle: 'Live TV',
          icon: 'tv',
        ),
        ShortcutItem(
          type: 'resume_playback',
          localizedTitle: 'Resume Playback',
          icon: 'play_arrow',
        ),
      ]);
    } catch (error) {
      debugPrint('Platform shortcuts unavailable: $error');
    }
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
