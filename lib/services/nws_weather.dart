import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'weather_models.dart';

abstract class WeatherForecastSource {
  Future<WeatherForecast> fetch(WeatherCoordinates coordinates);
}

typedef WeatherJsonLoader = Future<Map<String, dynamic>> Function(Uri uri);

class _NwsHttpProblem implements Exception {
  final int status;
  const _NwsHttpProblem(this.status);
}

class NwsWeatherSource implements WeatherForecastSource {
  final WeatherJsonLoader _loader;
  final DateTime Function() _clock;
  NwsWeatherSource({WeatherJsonLoader? loader, DateTime Function()? clock})
    : _loader = loader ?? _getJson,
      _clock = clock ?? DateTime.now;

  Future<Map<String, dynamic>> _load(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'api.weather.gov' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443) {
      throw const WeatherProblem(
        'The weather service returned an unexpected endpoint.',
      );
    }
    return _loader(uri);
  }

  static Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final deadline = Timer(
      const Duration(seconds: 25),
      () => client.close(force: true),
    );
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'MillitopTV/1.2 (weather; https://millitop.net)',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/geo+json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) {
        throw _NwsHttpProblem(response.statusCode);
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 12))) {
        if (bytes.length + chunk.length > 2097152) {
          throw const WeatherProblem(
            'The weather response was unexpectedly large.',
          );
        }
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  @override
  Future<WeatherForecast> fetch(WeatherCoordinates coordinates) async {
    try {
      Map<String, dynamic> points;
      try {
        points = await _load(
          Uri.https(
            'api.weather.gov',
            '/points/${coordinates.latitude.toStringAsFixed(4)},${coordinates.longitude.toStringAsFixed(4)}',
          ),
        );
      } on _NwsHttpProblem catch (error) {
        if (error.status == 404) {
          throw const WeatherProblem(
            'NWS forecasts are not available for this location. This provider is U.S.-focused.',
          );
        }
        rethrow;
      }
      final properties = points['properties'] as Map;
      String label = 'Current area';
      final relative = properties['relativeLocation'];
      if (relative is Map && relative['properties'] is Map) {
        final place = relative['properties'] as Map;
        final city = place['city']?.toString().trim() ?? '';
        final state = place['state']?.toString().trim() ?? '';
        if (city.isNotEmpty) {
          label = 'Near $city${state.isEmpty ? '' : ', $state'}';
        }
      }
      final data = await _load(
        Uri.parse(properties['forecastHourly'] as String),
      );
      final now = _clock().toUtc();
      final available = ((data['properties'] as Map)['periods'] as List)
          .cast<Map>()
          .where(
            (period) =>
                DateTime.parse(period['endTime'] as String).isAfter(now),
          )
          .toList();
      available.sort(
        (a, b) => DateTime.parse(
          a['startTime'] as String,
        ).compareTo(DateTime.parse(b['startTime'] as String)),
      );
      if (available.isEmpty) {
        throw const WeatherProblem(
          'The weather service returned only expired forecast periods.',
        );
      }
      final current = available
          .where(
            (period) =>
                !DateTime.parse(period['startTime'] as String).isAfter(now),
          )
          .toList();
      final period = current.isNotEmpty ? current.first : available.first;
      return WeatherForecast(
        coordinates: coordinates,
        label: label,
        temperature: (period['temperature'] as num).toDouble(),
        unit: period['temperatureUnit'] as String,
        condition: period['shortForecast'] as String,
        start: DateTime.parse(period['startTime'] as String),
        end: DateTime.parse(period['endTime'] as String),
        fetched: now,
      );
    } on WeatherProblem {
      rethrow;
    } on _NwsHttpProblem catch (error) {
      throw WeatherProblem(
        error.status == 429
            ? 'The weather service is busy. Please wait before refreshing again.'
            : 'The weather service is temporarily unavailable (HTTP ${error.status}).',
      );
    } catch (_) {
      throw const WeatherProblem(
        'Weather could not be retrieved. Check the internet connection and try Refresh.',
      );
    }
  }
}
