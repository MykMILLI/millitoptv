import 'dart:math' as math;

class WeatherProblem implements Exception {
  final String message;
  final bool showSettings;
  const WeatherProblem(this.message, {this.showSettings = false});
  @override
  String toString() => message;
}

class WeatherCoordinates {
  final double latitude, longitude;
  final double? accuracy;
  final DateTime captured;
  WeatherCoordinates({
    required this.latitude,
    required this.longitude,
    required this.captured,
    this.accuracy,
  }) {
    if (!latitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        !longitude.isFinite ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException('Invalid device coordinates.');
    }
  }
  double distanceTo(WeatherCoordinates other) {
    double radians(double value) => value * math.pi / 180;
    final dLat = radians(other.latitude - latitude);
    final dLon = radians(other.longitude - longitude);
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(radians(latitude)) *
            math.cos(radians(other.latitude)) *
            math.pow(math.sin(dLon / 2), 2);
    return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
  }

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'captured': captured.toUtc().toIso8601String(),
    'accuracy': accuracy,
  };
  factory WeatherCoordinates.fromJson(Map<String, dynamic> data) =>
      WeatherCoordinates(
        latitude: (data['latitude'] as num).toDouble(),
        longitude: (data['longitude'] as num).toDouble(),
        captured: DateTime.parse(data['captured'] as String),
        accuracy: (data['accuracy'] as num?)?.toDouble(),
      );
}

class WeatherForecast {
  final WeatherCoordinates coordinates;
  final String label, unit, condition;
  final double temperature;
  final DateTime start, end, fetched;
  WeatherForecast({
    required this.coordinates,
    required this.label,
    required this.unit,
    required this.condition,
    required this.temperature,
    required this.start,
    required this.end,
    required this.fetched,
  }) {
    if (!temperature.isFinite ||
        !['C', 'F'].contains(unit) ||
        condition.trim().isEmpty ||
        label.trim().isEmpty ||
        !end.isAfter(start)) {
      throw const FormatException('Invalid weather forecast.');
    }
  }
  bool usableAt(DateTime now) =>
      !fetched.isAfter(now.add(const Duration(minutes: 5))) &&
      fetched.isAfter(now.subtract(const Duration(hours: 3)));
  String get temperatureText =>
      '${temperature == temperature.roundToDouble() ? temperature.toInt() : temperature.toStringAsFixed(1)}°$unit';
  Map<String, dynamic> toJson() => {
    'coordinates': coordinates.toJson(),
    'label': label,
    'unit': unit,
    'condition': condition,
    'temperature': temperature,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'fetched': fetched.toUtc().toIso8601String(),
  };
  factory WeatherForecast.fromJson(Map<String, dynamic> data) =>
      WeatherForecast(
        coordinates: WeatherCoordinates.fromJson(
          Map<String, dynamic>.from(data['coordinates'] as Map),
        ),
        label: data['label'] as String,
        unit: data['unit'] as String,
        condition: data['condition'] as String,
        temperature: (data['temperature'] as num).toDouble(),
        start: DateTime.parse(data['start'] as String),
        end: DateTime.parse(data['end'] as String),
        fetched: DateTime.parse(data['fetched'] as String),
      );
}
