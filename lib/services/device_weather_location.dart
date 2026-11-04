import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'weather_models.dart';

abstract class WeatherLocationProvider {
  Future<WeatherCoordinates> locate({required bool requestPermission});
  Future<bool> openSettings();
}

class WindowsWeatherLocation implements WeatherLocationProvider {
  static const Duration _freshLocationAge = Duration(minutes: 15);
  static const Duration _maxUsableLocationAge = Duration(hours: 24);
  static const Duration _futureSkewAllowance = Duration(minutes: 5);
  static const Duration _freshRetryWindow = Duration(seconds: 20);

  bool _isFreshTimestamp(DateTime timestamp, DateTime nowUtc) =>
      !timestamp.isBefore(nowUtc.subtract(_freshLocationAge)) &&
      !timestamp.isAfter(nowUtc.add(_futureSkewAllowance));

  bool _isUnusableTimestamp(DateTime timestamp, DateTime nowUtc) =>
      timestamp.isBefore(nowUtc.subtract(_maxUsableLocationAge)) ||
      timestamp.isAfter(nowUtc.add(_futureSkewAllowance));

  Future<Position?> _waitForFreshPosition() async {
    try {
      await for (final next in Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          timeLimit: _freshRetryWindow,
        ),
      ).timeout(_freshRetryWindow)) {
        if (_isFreshTimestamp(next.timestamp, DateTime.now().toUtc())) {
          return next;
        }
      }
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
    return null;
  }

  WeatherCoordinates _toCoordinates(Position position) => WeatherCoordinates(
    latitude: position.latitude,
    longitude: position.longitude,
    captured: position.timestamp,
    accuracy: position.accuracy.isFinite && position.accuracy > 0
        ? position.accuracy
        : null,
  );

  @override
  Future<WeatherCoordinates> locate({required bool requestPermission}) async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled().timeout(
        const Duration(seconds: 8),
      );
      if (!enabled) {
        throw const WeatherProblem(
          'Windows location services are off. Enable them in Settings > Privacy & security > Location.',
          showSettings: true,
        );
      }
      var permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 8),
      );
      if (permission == LocationPermission.denied && requestPermission) {
        permission = await Geolocator.requestPermission().timeout(
          const Duration(seconds: 45),
        );
      }
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        throw const WeatherProblem(
          'Location access is not allowed. Allow Millitop/desktop apps to use location in Windows settings, then select Location again.',
          showSettings: true,
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 25),
        ),
      ).timeout(const Duration(seconds: 30));
      final refreshed =
          _isFreshTimestamp(position.timestamp, DateTime.now().toUtc())
          ? null
          : await _waitForFreshPosition();
      final chosen = refreshed ?? position;
      final now = DateTime.now().toUtc();
      if (_isUnusableTimestamp(chosen.timestamp, now)) {
        throw const WeatherProblem(
          'Windows returned only stale location data. Move this device, wait a few seconds, then select Location again.',
        );
      }
      return _toCoordinates(chosen);
    } on WeatherProblem {
      rethrow;
    } on TimeoutException {
      throw const WeatherProblem(
        'Windows could not obtain a location in time. Check location access and try again.',
        showSettings: true,
      );
    } catch (_) {
      throw const WeatherProblem(
        'Device location is unavailable. Check Windows location settings and try again.',
        showSettings: true,
      );
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await Geolocator.openLocationSettings().timeout(
        const Duration(seconds: 8),
      );
    } catch (_) {
      return false;
    }
  }
}
