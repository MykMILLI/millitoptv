import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/device_weather_location.dart';

void main() {
  test('Windows seconds-based timestamps are scaled to real time', () {
    final now = DateTime.utc(2026, 11, 7, 18, 30, 15);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    // geolocator_windows sends seconds; the platform interface reads millis.
    final asParsed = DateTime.fromMillisecondsSinceEpoch(seconds, isUtc: true);
    expect(asParsed.year, 1970);
    expect(WindowsWeatherLocation.normalizeTimestamp(asParsed), now);
  });

  test('correct millisecond timestamps are left unchanged', () {
    final now = DateTime.utc(2026, 11, 7, 18, 30, 15, 250);
    expect(WindowsWeatherLocation.normalizeTimestamp(now), now);
  });
}
