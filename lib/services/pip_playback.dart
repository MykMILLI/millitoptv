import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PipPlaybackSession {
  final Player player;
  final VideoController video;
  final String title;
  final String? subtitle;
  final bool seekable;
  final Future<void> Function()? onClose;

  const PipPlaybackSession({
    required this.player,
    required this.video,
    required this.title,
    this.subtitle,
    required this.seekable,
    this.onClose,
  });
}

class PipPlaybackController extends ChangeNotifier {
  PipPlaybackController._();
  static final instance = PipPlaybackController._();

  PipPlaybackSession? _session;
  bool _expanding = false;
  bool _closing = false;

  PipPlaybackSession? get session => _session;
  bool get expanding => _expanding;
  bool get hasVisibleMiniPlayer => _session != null && !_expanding;

  Future<void> minimize(PipPlaybackSession session) async {
    final previous = _session;
    _session = session;
    _expanding = false;
    notifyListeners();
    if (previous != null) {
      await _disposeSession(previous);
    }
  }

  Future<PipPlaybackSession?> beginExpand() async {
    final current = _session;
    if (current == null) {
      return null;
    }
    _expanding = true;
    notifyListeners();
    return current;
  }

  void endExpand() {
    if (_session == null) {
      _expanding = false;
      notifyListeners();
      return;
    }
    if (!_expanding) {
      return;
    }
    _expanding = false;
    notifyListeners();
  }

  Future<void> close() async {
    if (_closing) {
      return;
    }
    final current = _session;
    if (current == null) {
      return;
    }
    _closing = true;
    _session = null;
    _expanding = false;
    notifyListeners();
    try {
      await _disposeSession(current);
    } finally {
      _closing = false;
    }
  }

  Future<void> _disposeSession(PipPlaybackSession session) async {
    if (session.onClose != null) {
      await session.onClose!.call();
      return;
    }
    await session.player.dispose();
  }
}
