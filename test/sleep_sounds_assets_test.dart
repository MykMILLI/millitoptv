import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled sleep-sounds assets are loadable and non-empty', () async {
    const howlerPath = 'assets/native/sleep_sounds/howler/howler-2.2.4.min.js';
    const soundPaths = <String>[
      'assets/native/sleep_sounds/moodist/rain/heavy-rain.mp3',
      'assets/native/sleep_sounds/moodist/rain/thunder.mp3',
      'assets/native/sleep_sounds/moodist/noise/white-noise.wav',
      'assets/native/sleep_sounds/moodist/noise/pink-noise.wav',
    ];

    final howler = await rootBundle.loadString(howlerPath);
    expect(howler.trim().isNotEmpty, isTrue);
    expect(howler, contains('howler.js v2.2.4'));
    expect(howler.toLowerCase(), isNot(contains('<html')));

    for (final path in soundPaths) {
      final bytes = await rootBundle.load(path);
      expect(bytes.lengthInBytes, greaterThan(0), reason: path);
    }
  });
}
