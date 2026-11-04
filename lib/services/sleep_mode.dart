import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';
import 'device_connection.dart';
import 'viewing_sessions.dart';

class SleepMode extends ChangeNotifier {
  static final instance = SleepMode();
  final Future<void> Function()? prepareOverride,
      closeOverride,
      displayOverride,
      lockOverride;
  final DateTime Function()? clock;
  SleepMode({
    this.prepareOverride,
    this.closeOverride,
    this.displayOverride,
    this.lockOverride,
    this.clock,
  });
  DateTime _now() => clock?.call() ?? DateTime.now();
  DateTime? deadline;
  Timer? _timer;
  Process? _guard;
  Future<void>? _startingGuard;
  File? _guardFile;
  bool overnight = false, applying = false, _opening = false;
  bool _warned = false;
  int _generation = 0;
  String message = '';
  String lastTimerAction = 'No timer action yet.';
  int _countdownPromptId = 0;
  int get countdownPromptId => _countdownPromptId;
  Duration get remaining {
    final d = deadline;
    if (d == null) {
      return Duration.zero;
    }
    final value = d.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }

  Future<String> _helper() async {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null) {
      throw StateError('Windows app-data folder unavailable.');
    }
    final dir = Directory('$base\\MILLITOPTV\\helpers');
    await dir.create(recursive: true);
    final file = File('${dir.path}\\overnight_tools.ps1');
    await file.writeAsString(
      await rootBundle.loadString('assets/native/overnight_tools.ps1'),
      flush: true,
    );
    return file.path;
  }

  List<String> _args(String helper, String action) => [
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    helper,
    '-Action',
    action,
  ];
  Future<void> _run(String action, {int profile = 1, String? url}) async {
    final result = await Process.run('powershell.exe', [
      ..._args(await _helper(), action),
      '-ProfileId',
      '$profile',
      if (url != null) ...['-Url', url],
    ]).timeout(const Duration(seconds: 45));
    if (result.exitCode != 0) {
      throw StateError(result.stderr.toString().trim());
    }
  }

  Future<void> _keepAwake() async {
    final previous = _startingGuard;
    if (previous != null) {
      await previous;
      return;
    }
    final task = _prepareGuard();
    _startingGuard = task;
    try {
      await task;
    } finally {
      if (identical(_startingGuard, task)) {
        _startingGuard = null;
      }
    }
  }

  Future<void> _prepareGuard() async {
    if (prepareOverride != null) {
      await prepareOverride!();
      overnight = true;
      notifyListeners();
      return;
    }
    if (_guard != null) {
      return;
    }
    final helper = await _helper();
    final dir = await Directory.systemTemp.createTemp('MillitopOvernight-');
    final flag = File('${dir.path}\\active');
    await flag.writeAsString('active', flush: true);
    final guard = await Process.start('powershell.exe', [
      ..._args(helper, 'Guard'),
      '-ParentPid',
      '$pid',
      '-GuardPath',
      flag.path,
    ]);
    _guard = guard;
    _guardFile = flag;
    final ready = Completer<void>();
    var readinessText = '';
    final sub = guard.stdout.listen((bytes) {
      readinessText += String.fromCharCodes(bytes);
      // The helper writes one ASCII readiness line before entering its loop.
      if (readinessText.contains('GUARD_READY') && !ready.isCompleted) {
        ready.complete();
      }
    });
    unawaited(guard.stderr.drain<void>());
    unawaited(guard.stdin.close());
    unawaited(
      guard.exitCode.then((_) async {
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('Overnight keep-awake could not start.'),
          );
        }
        if (identical(_guard, guard)) {
          _guard = null;
          overnight = false;
          DeviceConnection.instance.setMediaActive('overnight', false);
          message =
              'Overnight keep-awake ended. Check Windows power settings before leaving audio overnight.';
          notifyListeners();
        }
        await sub.cancel();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }),
    );
    try {
      await ready.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      if (await flag.exists()) {
        await flag.delete();
      }
      rethrow;
    }
    overnight = true;
    DeviceConnection.instance.setMediaActive('overnight', true);
    notifyListeners();
  }

  Future<void> openSounds(int profile, String url) async {
    if (_opening) {
      return;
    }
    _opening = true;
    try {
      await _keepAwake();
      await windowManager.setAlwaysOnTop(false);
      await _run('SleepSounds', profile: profile, url: url);
      await windowManager.minimize();
      message =
          'Sleep Sounds opened. Choose sounds and press Play on the website.';
    } finally {
      _opening = false;
      notifyListeners();
    }
  }

  Future<void> openSupport(int profile) async {
    if (applying) {
      throw StateError(
        'Wait for the viewing timer to finish before opening support.',
      );
    }
    cancelTimer();
    await windowManager.setAlwaysOnTop(false);
    await _run('Support', profile: profile);
    await windowManager.minimize();
  }

  Future<void> startTimer(int minutes) async {
    if (applying) {
      throw StateError('The previous timer is still finishing.');
    }
    if (minutes < 1 || minutes > 720) {
      throw ArgumentError('Choose 1 to 720 minutes.');
    }
    await _keepAwake();
    _generation++;
    deadline = _now().add(Duration(minutes: minutes));
    _warned = false;
    message = 'Viewing timer started. Sleep Sounds is excluded.';
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
      if (!_warned && remaining <= const Duration(seconds: 30)) {
        _warned = true;
        _countdownPromptId++;
        message =
            'Viewing ends in 30 seconds. Add time or cancel to keep watching.';
        notifyListeners();
        unawaited(_warning());
      }
      if (remaining == Duration.zero) {
        unawaited(_expire(_generation));
      }
    });
    notifyListeners();
  }

  Future<void> _warning() async {
    if (prepareOverride != null) {
      return;
    }
    try {
      await LocalNotification(
        title: 'Millitop viewing timer',
        body: 'Viewing ends in 30 seconds. Sleep Sounds will keep running.',
      ).show();
    } catch (_) {}
  }

  void cancelTimer() {
    if (applying) {
      return;
    }
    _generation++;
    deadline = null;
    _timer?.cancel();
    message = 'Viewing timer cancelled. Overnight audio mode is unchanged.';
    notifyListeners();
  }

  void extend(int minutes) {
    if (applying || deadline == null) {
      return;
    }
    deadline = deadline!.add(Duration(minutes: minutes));
    _warned = false;
    notifyListeners();
  }

  Future<void> _expire(int generation) async {
    if (applying || generation != _generation) {
      return;
    }
    applying = true;
    _timer?.cancel();
    notifyListeners();
    Object? closeFailure;
    Object? displayFailure;
    var lockFallback = false;
    try {
      try {
        await (closeOverride?.call() ?? ViewingSessions.instance.closeAll());
      } catch (error) {
        closeFailure = error;
      }
      if (generation != _generation) {
        return;
      }
      // Let browser/gallery window restoration finish before requesting darkness.
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        await (displayOverride?.call() ?? _run('DisplaysOff'));
      } catch (error) {
        try {
          await (lockOverride?.call() ?? _run('LockScreen'));
          lockFallback = true;
        } catch (_) {
          displayFailure = error;
        }
      }
      if (closeFailure == null && displayFailure == null) {
        lastTimerAction = lockFallback
            ? 'Locked fallback'
            : 'DisplayOff success';
        message = lockFallback
            ? 'Viewing finished. App-owned playback windows were closed. Windows display-off was unavailable, so the screen was locked as fallback. Sleep Sounds was left running.'
            : 'Viewing finished. App-owned playback windows were closed and displays-off was requested. Sleep Sounds was left running.';
      } else if (closeFailure != null && displayFailure == null) {
        lastTimerAction = lockFallback
            ? 'Locked fallback + close partial'
            : 'DisplayOff success + close partial';
        message = lockFallback
            ? 'Viewing timer ended and the screen was locked as fallback, but one or more app-owned playback windows did not close. Close the media window and try again.'
            : 'Viewing timer ended and displays-off was requested, but one or more app-owned playback windows did not close. Close the media window and try again.';
      } else if (closeFailure == null && displayFailure != null) {
        lastTimerAction = 'DisplayOff failed';
        message =
            'App-owned playback windows were closed, but Windows did not confirm displays-off. Check power/display settings and try again.';
      } else {
        lastTimerAction = 'DisplayOff failed + close failed';
        message =
            'Could not safely finish viewing or turn the displays off. Check the media window and Windows display settings, then try again.';
      }
    } finally {
      deadline = null;
      applying = false;
      notifyListeners();
    }
  }

  Future<void> endOvernight() async {
    if (applying) {
      throw StateError('Wait for the timer to finish.');
    }
    cancelTimer();
    final flag = _guardFile;
    _guardFile = null;
    _guard = null;
    if (flag != null && await flag.exists()) {
      await flag.delete();
    }
    overnight = false;
    DeviceConnection.instance.setMediaActive('overnight', false);
    message =
        'Overnight keep-awake ended. The Sleep Sounds browser was not closed.';
    notifyListeners();
  }
}
