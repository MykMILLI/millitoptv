typedef CloseViewingSession = Future<void> Function();

/// Only sessions launched and explicitly registered by Millitop are closed.
class ViewingSessions {
  static final instance = ViewingSessions();
  final Map<String, CloseViewingSession> _sessions = {};
  bool closing = false;
  void register(String key, CloseViewingSession close) {
    if (closing) {
      throw StateError(
        'The viewing timer is ending playback. Try again shortly.',
      );
    }
    _sessions[key] = close;
  }

  void remove(String key) {
    _sessions.remove(key);
  }

  Future<void> closeAll() async {
    if (closing) {
      throw StateError('Playback is already closing.');
    }
    closing = true;
    Object? failure;
    try {
      for (final entry in Map<String, CloseViewingSession>.of(
        _sessions,
      ).entries) {
        try {
          await entry.value().timeout(const Duration(seconds: 45));
          _sessions.remove(entry.key);
        } catch (error) {
          failure ??= error;
        }
      }
    } finally {
      closing = false;
    }
    if (failure != null) {
      throw failure;
    }
  }
}
