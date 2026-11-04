import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/services/auto_weather.dart';
import 'package:millitop_tv/services/device_weather_location.dart';
import 'package:millitop_tv/services/nws_weather.dart';
import 'package:millitop_tv/services/weather_models.dart';
import 'package:millitop_tv/screens/live_weather_card.dart';
import 'package:millitop_tv/widgets/app_quit_button.dart';

WeatherCoordinates fix([double latitude = 41.1]) => WeatherCoordinates(
  latitude: latitude,
  longitude: -81.4,
  captured: DateTime.now().toUtc(),
  accuracy: 100,
);
WeatherForecast sample(WeatherCoordinates coordinates) {
  final now = DateTime.now().toUtc();
  return WeatherForecast(
    coordinates: coordinates,
    label: 'Near Test City, OH',
    temperature: 61,
    unit: 'F',
    condition: 'Clear',
    start: now.subtract(const Duration(minutes: 10)),
    end: now.add(const Duration(minutes: 50)),
    fetched: now,
  );
}

class FakeLocation implements WeatherLocationProvider {
  WeatherCoordinates position = fix();
  WeatherProblem? error;
  int calls = 0;
  final permissions = <bool>[];
  @override
  Future<WeatherCoordinates> locate({required bool requestPermission}) async {
    calls++;
    permissions.add(requestPermission);
    if (error != null) {
      throw error!;
    }
    return position;
  }

  @override
  Future<bool> openSettings() async => true;
}

class FakeWeather implements WeatherForecastSource {
  bool fail = false;
  int calls = 0;
  Completer<WeatherForecast>? pending;
  @override
  Future<WeatherForecast> fetch(WeatherCoordinates coordinates) async {
    calls++;
    if (fail) {
      throw const WeatherProblem('Offline');
    }
    if (pending != null) {
      return pending!.future;
    }
    return sample(coordinates);
  }
}

AutoWeatherController controller(
  FakeLocation location,
  FakeWeather source, {
  int profileId = 7,
}) => AutoWeatherController(
  profileId: profileId,
  location: location,
  source: source,
  enableTimer: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'no location request before opt-in; old manual location is not migrated',
    () async {
      SharedPreferences.setMockInitialValues({
        'weather.nws.7.location':
            '{"city":"Old manual city","latitude":41,"longitude":-81}',
      });
      final location = FakeLocation();
      final c = controller(location, FakeWeather());
      await c.initialize();
      expect(c.enabled, isFalse);
      expect(c.forecast, isNull);
      expect(location.calls, 0);
      c.dispose();
    },
  );
  test(
    'Location requests permission and persists automatic mode per profile',
    () async {
      final location = FakeLocation();
      final c = controller(location, FakeWeather());
      await c.initialize();
      await c.useMyLocation();
      expect(location.permissions, [true]);
      expect(c.enabled, isTrue);
      expect(c.forecast!.temperatureText, '61°F');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('weather.auto.v1.7.enabled'), isTrue);
      expect(prefs.getBool('weather.auto.v1.8.enabled'), isNull);
      c.dispose();
    },
  );
  test('refresh reacquires position without requesting permission', () async {
    final location = FakeLocation();
    final c = controller(location, FakeWeather());
    await c.initialize();
    await c.useMyLocation();
    await c.refresh();
    expect(location.permissions, [true, false]);
    c.dispose();
  });
  test(
    'permission denial does not use fixed coordinates or request weather',
    () async {
      final location = FakeLocation()
        ..error = const WeatherProblem('Permission denied', showSettings: true);
      final source = FakeWeather();
      final c = controller(location, source);
      await c.initialize();
      await c.useMyLocation();
      expect(c.enabled, isFalse);
      expect(c.showSettings, isTrue);
      expect(c.forecast, isNull);
      expect(source.calls, 0);
      expect(c.busy, isFalse);
      c.dispose();
    },
  );
  test(
    'same-area weather failure retains explicitly cached forecast',
    () async {
      final source = FakeWeather();
      final c = controller(FakeLocation(), source);
      await c.initialize();
      await c.useMyLocation();
      source.fail = true;
      await c.refresh();
      expect(c.hasUsableForecast, isTrue);
      expect(c.problem, 'Offline');
      expect(c.busy, isFalse);
      c.dispose();
    },
  );
  test('moving clears previous-area weather when new forecast fails', () async {
    final location = FakeLocation();
    final source = FakeWeather();
    final c = controller(location, source);
    await c.initialize();
    await c.useMyLocation();
    location.position = fix(42.1);
    source.fail = true;
    await c.refresh();
    expect(c.forecast, isNull);
    expect(c.problem, 'Offline');
    c.dispose();
  });
  test(
    'persisted opt-in resumes automatic location without a permission prompt',
    () async {
      final first = controller(FakeLocation(), FakeWeather());
      await first.initialize();
      await first.useMyLocation();
      first.dispose();
      final location = FakeLocation();
      final second = controller(location, FakeWeather());
      await second.initialize();
      expect(location.permissions, [false]);
      expect(second.hasUsableForecast, isTrue);
      second.dispose();
    },
  );
  test('stop using location clears automatic mode and its cache', () async {
    final c = controller(FakeLocation(), FakeWeather());
    await c.initialize();
    await c.useMyLocation();
    await c.stopUsingLocation();
    final prefs = await SharedPreferences.getInstance();
    expect(c.enabled, isFalse);
    expect(c.forecast, isNull);
    expect(prefs.getBool('weather.auto.v1.7.enabled'), isFalse);
    expect(prefs.getString('weather.auto.v1.7.forecast'), isNull);
    c.dispose();
  });
  test('late weather response is ignored after disposal', () async {
    final location = FakeLocation();
    final source = FakeWeather()..pending = Completer<WeatherForecast>();
    final c = controller(location, source);
    await c.initialize();
    final operation = c.useMyLocation();
    for (var i = 0; i < 100 && source.calls == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(source.calls, 1);
    c.dispose();
    source.pending!.complete(sample(location.position));
    await operation;
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('weather.auto.v1.7.forecast'), isNull);
  });
  test('forecast cache roundtrips and excludes old or future-invalid data', () {
    final original = sample(fix());
    final restored = WeatherForecast.fromJson(original.toJson());
    expect(restored.temperatureText, original.temperatureText);
    expect(
      restored.usableAt(original.fetched.add(const Duration(hours: 4))),
      isFalse,
    );
    expect(
      restored.usableAt(original.fetched.subtract(const Duration(hours: 1))),
      isFalse,
    );
    expect(fix().distanceTo(fix(42.1)), greaterThan(3000));
    expect(() => fix(double.nan), throwsFormatException);
  });
  test('NWS gets place label and skips expired forecast periods', () async {
    final now = DateTime.now().toUtc();
    final source = NwsWeatherSource(
      clock: () => now,
      loader: (uri) async {
        if (uri.path.startsWith('/points/')) {
          return {
            'properties': {
              'forecastHourly':
                  'https://api.weather.gov/gridpoints/TST/1,2/forecast/hourly',
              'relativeLocation': {
                'properties': {'city': 'Test City', 'state': 'OH'},
              },
            },
          };
        }
        Map<String, dynamic> period(
          DateTime start,
          DateTime end,
          num temperature,
        ) => {
          'startTime': start.toIso8601String(),
          'endTime': end.toIso8601String(),
          'temperature': temperature,
          'temperatureUnit': 'F',
          'shortForecast': 'Clear',
        };
        return {
          'properties': {
            'periods': [
              period(
                now.subtract(const Duration(hours: 2)),
                now.subtract(const Duration(hours: 1)),
                1,
              ),
              period(
                now.subtract(const Duration(minutes: 10)),
                now.add(const Duration(minutes: 50)),
                61,
              ),
            ],
          },
        };
      },
    );
    final result = await source.fetch(fix());
    expect(result.label, 'Near Test City, OH');
    expect(result.temperatureText, '61°F');
  });
  test('NWS refuses forecast links to other hosts', () async {
    var calls = 0;
    final source = NwsWeatherSource(
      loader: (uri) async {
        calls++;
        return {
          'properties': {'forecastHourly': 'https://example.invalid/forecast'},
        };
      },
    );
    await expectLater(source.fetch(fix()), throwsA(isA<WeatherProblem>()));
    expect(calls, 1);
  });
  testWidgets('Location works without any manual input fields', (tester) async {
    final c = controller(FakeLocation(), FakeWeather());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 540,
              child: LiveWeatherCard(profileId: 7, controller: c),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Use your location'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-location')));
    await tester.pumpAndSettle();
    expect(find.text('61°F'), findsOneWidget);
    expect(find.text('Near Test City, OH'.toUpperCase()), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  testWidgets('Quit closes once, without a confirmation dialog', (
    tester,
  ) async {
    var calls = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppQuitButton(
            onQuit: () {
              calls++;
              return gate.future;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('millitop-quit')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('millitop-quit')));
    expect(calls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
  });
  testWidgets('Quit is disabled during a protected operation', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppQuitButton(
            blocked: true,
            onQuit: () async {
              calls++;
            },
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('millitop-quit')),
    );
    expect(button.onPressed, isNull);
    expect(calls, 0);
  });
  testWidgets('Quit recovers if native close reports an error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppQuitButton(
            onQuit: () async {
              throw StateError('test');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('millitop-quit')));
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('millitop-quit')),
    );
    expect(button.onPressed, isNotNull);
    expect(
      find.text('Could not quit Millitop. Please try again.'),
      findsOneWidget,
    );
  });
  testWidgets('Remote Select activates focused Quit', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppQuitButton(
            autofocus: true,
            onQuit: () async {
              calls++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });
}
