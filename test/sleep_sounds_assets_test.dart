import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled sleep-sounds assets are loadable and non-empty', () async {
    const soundPaths = <String>[
      'assets/native/sleep_sounds/moodist/rain/heavy-rain.mp3',
      'assets/native/sleep_sounds/moodist/rain/thunder.mp3',
      'assets/native/sleep_sounds/moodist/noise/white-noise.wav',
      'assets/native/sleep_sounds/moodist/noise/pink-noise.wav',
    ];

    for (final path in soundPaths) {
      final bytes = await rootBundle.load(path);
      expect(bytes.lengthInBytes, greaterThan(0), reason: path);
    }
  });
}
