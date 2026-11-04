import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_weather_location.dart';
import 'nws_weather.dart';
import 'weather_models.dart';

class AutoWeatherController extends ChangeNotifier {
  final int profileId;
  final WeatherLocationProvider location;
  final WeatherForecastSource source;
  final bool enableTimer;
  final DateTime Function() _clock;
  bool enabled = false, busy = false, initialized = false;
  bool showSettings = false;
  String status = '', problem = '', persistenceWarning = '';
  WeatherForecast? forecast;
  WeatherCoordinates? currentLocation;
  Timer? _timer;
  bool _disposed = false, _initializing = false;
  AutoWeatherController({
    required this.profileId,
    WeatherLocationProvider? location,
    WeatherForecastSource? source,
    this.enableTimer = true,
    DateTime Function()? clock,
  }) : location = location ?? WindowsWeatherLocation(),
       source = source ?? NwsWeatherSource(),
       _clock = clock ?? DateTime.now;
  String get prefix => 'weather.auto.v1.$profileId';
  bool get hasUsableForecast => forecast?.usableAt(_clock()) ?? false;
  void _emit() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    if (_disposed || initialized || _initializing) {
      return;
    }
    _initializing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) {
        return;
      }
      enabled = prefs.getBool('$prefix.enabled') ?? false;
      if (enabled) {
        final raw = prefs.getString('$prefix.forecast');
        if (raw != null) {
          try {
            final cached = WeatherForecast.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
            if (cached.usableAt(_clock())) {
              forecast = cached;
            }
          } catch (_) {
            /* A corrupt cache never supplies a sample location. */
          }
        }
      }
    } catch (_) {
      problem =
          'Weather preferences could not be loaded. Select Location to try again.';
    } finally {
      _initializing = false;
      initialized = true;
      _emit();
    }
    if (_disposed) {
      return;
    }
    if (enableTimer) {
      _timer = Timer.periodic(const Duration(minutes: 20), (_) {
        if (enabled && !busy) {
          unawaited(refresh());
        }
      });
    }
    if (enabled) {
      await refresh();
    }
  }

  Future<void> useMyLocation() => refresh(requestPermission: true);

  Future<void> refresh({bool requestPermission = false}) async {
    if (_disposed || busy || (!enabled && !requestPermission)) {
      return;
    }
    busy = true;
    problem = '';
    persistenceWarning = '';
    showSettings = false;
    currentLocation = null;
    status = 'Finding your device location...';
    _emit();
    try {
      final fix = await location.locate(requestPermission: requestPermission);
      if (_disposed) {
        return;
      }
      currentLocation = fix;
      if (forecast != null && forecast!.coordinates.distanceTo(fix) > 3000) {
        forecast = null;
      }
      if (!enabled) {
        enabled = true;
        try {
          final prefs = await SharedPreferences.getInstance();
          if (_disposed) {
            return;
          }
          if (!await prefs.setBool('$prefix.enabled', true)) {
            throw StateError('Preference not saved.');
          }
        } catch (_) {
          persistenceWarning =
              'Location is enabled for this session; its preference could not be saved.';
        }
      }
      status = 'Updating weather for your area...';
      _emit();
      final next = await source.fetch(fix);
      if (_disposed) {
        return;
      }
      forecast = next;
      problem = '';
      status = '';
      _emit();
      try {
        final prefs = await SharedPreferences.getInstance();
        if (_disposed) {
          return;
        }
        if (!await prefs.setString(
          '$prefix.forecast',
          jsonEncode(next.toJson()),
        )) {
          throw StateError('Cache not saved.');
        }
      } catch (_) {
        persistenceWarning =
            'Weather is available, but its offline cache could not be saved.';
      }
    } on WeatherProblem catch (error) {
      if (_disposed) {
        return;
      }
      problem = error.message;
      showSettings = error.showSettings;
    } catch (_) {
      if (_disposed) {
        return;
      }
      problem =
          'Weather could not be refreshed. Try Location or Refresh again.';
    } finally {
      if (!_disposed) {
        busy = false;
        status = '';
        _emit();
      }
    }
  }

  Future<void> stopUsingLocation() async {
    if (_disposed || busy) {
      return;
    }
    busy = true;
    _emit();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) {
        return;
      }
      if (!await prefs.setBool('$prefix.enabled', false)) {
        throw StateError('Preference not saved.');
      }
      if (_disposed) {
        return;
      }
      enabled = false;
      forecast = null;
      currentLocation = null;
      problem = '';
      showSettings = false;
      persistenceWarning = '';
      if (!await prefs.remove('$prefix.forecast')) {
        persistenceWarning =
            'Automatic location is off, but the old local weather cache could not be removed.';
      }
    } catch (_) {
      if (!_disposed) {
        problem = 'Could not save the location preference. Try again.';
      }
    } finally {
      if (!_disposed) {
        busy = false;
        _emit();
      }
    }
  }

  Future<bool> openSettings() => location.openSettings();
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
