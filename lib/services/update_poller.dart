import 'dart:async';

/// Keeps retry scheduling independent of network/startup success.
class UpdatePoller {
  final Future<void> Function() check;
  final Duration interval;
  Timer? _timer;
  Timer? _soon;
  bool _running = false;
  bool _busy = false;
  UpdatePoller(this.check, {this.interval = const Duration(minutes: 1)});

  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(interval, (_) => unawaited(_run()));
    unawaited(_run());
  }

  void checkSoon() {
    if (!_running || _soon != null) return;
    _soon = Timer(const Duration(milliseconds: 500), () {
      _soon = null;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    if (!_running || _busy) return;
    _busy = true;
    try {
      await check();
    } catch (_) {
      // One failed attempt must not cancel future scheduled attempts.
    } finally {
      _busy = false;
    }
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _soon?.cancel();
    _timer = null;
    _soon = null;
  }
}
