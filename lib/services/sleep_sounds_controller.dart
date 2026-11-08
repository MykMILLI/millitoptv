import 'dart:async';

import 'package:flutter/foundation.dart';

import 'home_preferences.dart';

enum SleepSoundsBackend { browserFallback, embeddedWebView }

enum SleepSoundsState { stopped, loading, playing, paused, error }

class SleepSoundsController extends ChangeNotifier {
  SleepSoundsController._();
  static final instance = SleepSoundsController._();

  SleepSoundsBackend backend = SleepSoundsBackend.browserFallback;
  SleepSoundsState state = SleepSoundsState.stopped;
  int? activeProfileId;
  String selectedPreset = 'rain';
  double volume = 70;
  String message = '';
  String error = '';
  bool get running =>
      state == SleepSoundsState.loading ||
      state == SleepSoundsState.playing ||
      state == SleepSoundsState.paused;

  Future<void> Function(int profileId, String url)? _launcher;
  Future<void> Function(int profileId)? _stopper;
  String? _activeUrl;

  Future<void> loadPreferences(int profileId) async {
    final prefs = HomePreferences();
    selectedPreset = await prefs.sleepSoundsPreset(profileId);
    volume = await prefs.sleepSoundsVolume(profileId);
    final storedBackend = await prefs.sleepSoundsBackend(profileId);
    backend = switch (storedBackend) {
      'embedded' => SleepSoundsBackend.embeddedWebView,
      _ => SleepSoundsBackend.browserFallback,
    };
    notifyListeners();
  }

  Future<void> savePreferences(int profileId) async {
    final prefs = HomePreferences();
    await prefs.setSleepSoundsPreset(profileId, selectedPreset);
    await prefs.setSleepSoundsVolume(profileId, volume);
    await prefs.setSleepSoundsBackend(
      profileId,
      backend == SleepSoundsBackend.embeddedWebView ? 'embedded' : 'browser',
    );
  }

  void setPreset(String value) {
    final next = value.trim();
    if (next.isEmpty || selectedPreset == next) {
      return;
    }
    selectedPreset = next;
    notifyListeners();
  }

  void setVolume(double value) {
    final normalized = value.clamp(0, 100).toDouble();
    if (normalized == volume) {
      return;
    }
    volume = normalized;
    notifyListeners();
  }

  void setBackend(SleepSoundsBackend value) {
    if (backend == value) {
      return;
    }
    backend = value;
    notifyListeners();
  }

  Future<void> play({
    required int profileId,
    required String url,
    required Future<void> Function(int profileId, String url) launcher,
    required Future<void> Function(int profileId) stopper,
  }) async {
    if (state == SleepSoundsState.loading) {
      throw StateError('Sleep Sounds is already launching.');
    }
    if (backend == SleepSoundsBackend.embeddedWebView) {
      throw StateError(
        'Embedded Sleep Sounds is not enabled yet. Use browser fallback.',
      );
    }
    state = SleepSoundsState.loading;
    error = '';
    message = 'Opening Sleep Sounds...';
    notifyListeners();
    try {
      _launcher = launcher;
      _stopper = stopper;
      _activeUrl = url;
      activeProfileId = profileId;
      await launcher(profileId, url);
      state = SleepSoundsState.playing;
      message =
          'Sleep Sounds opened in browser fallback mode. Use the website controls to start or pause audio.';
      notifyListeners();
    } catch (e) {
      state = SleepSoundsState.error;
      error = e.toString().replaceFirst('Bad state: ', '');
      message = 'Sleep Sounds failed to open.';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> pause() async {
    if (backend == SleepSoundsBackend.browserFallback) {
      throw StateError(
        'Pause is controlled by the Sleep Sounds website in browser fallback mode.',
      );
    }
    state = SleepSoundsState.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    final profile = activeProfileId;
    final launch = _launcher;
    final url = _activeUrl;
    if (backend == SleepSoundsBackend.browserFallback) {
      if (profile == null || launch == null || url == null) {
        throw StateError('Sleep Sounds is not configured for resume.');
      }
      state = SleepSoundsState.loading;
      notifyListeners();
      await launch(profile, url);
      state = SleepSoundsState.playing;
      message = 'Sleep Sounds browser window restored.';
      notifyListeners();
      return;
    }
    state = SleepSoundsState.playing;
    notifyListeners();
  }

  Future<void> stop() async {
    final profile = activeProfileId;
    final stop = _stopper;
    if (profile == null || stop == null) {
      state = SleepSoundsState.stopped;
      message = 'Sleep Sounds is not running.';
      notifyListeners();
      return;
    }
    state = SleepSoundsState.loading;
    notifyListeners();
    try {
      await stop(profile);
      state = SleepSoundsState.stopped;
      message = 'Sleep Sounds stopped.';
      error = '';
      notifyListeners();
    } catch (e) {
      state = SleepSoundsState.error;
      error = e.toString().replaceFirst('Bad state: ', '');
      message = 'Could not stop Sleep Sounds.';
      notifyListeners();
      rethrow;
    }
  }
}
