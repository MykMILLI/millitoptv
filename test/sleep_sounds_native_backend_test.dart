import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/sleep_sounds_native_backend.dart';

class FakeLayer implements SleepSoundLayer {
  FakeLayer(this.id, {this.failPlay = false});

  final String id;
  final bool failPlay;
  int loads = 0;
  int plays = 0;
  int pauses = 0;
  bool disposed = false;
  double gain = -1;
  bool _playing = false;
  final StreamController<String> _errors = StreamController<String>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> load() async => loads++;

  @override
  Future<void> play() async {
    if (failPlay) throw StateError('device busy');
    plays++;
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauses++;
    _playing = false;
  }

  @override
  Future<void> setGain(double value) async => gain = value;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _errors.close();
  }
}

const allOn = {
  'heavy-rain': true,
  'thunder': true,
  'white-noise': true,
  'pink-noise': true,
};
const levels = {
  'heavy-rain': 70.0,
  'thunder': 35.0,
  'white-noise': 25.0,
  'pink-noise': 40.0,
};

void main() {
  late Map<String, FakeLayer> layers;
  late NativeSleepSoundsBackend backend;

  Future<void> start(Map<String, bool> enabled) async {
    await backend.initialize(
      profileId: 1,
      preset: 'mix',
      masterVolume: 70,
      enabled: enabled,
      volumes: levels,
    );
    await backend.play();
  }

  setUp(() {
    layers = {};
    backend = NativeSleepSoundsBackend(
      layerFactory: (id) => layers[id] = FakeLayer(id),
    );
  });

  test('all four sounds play together at their own levels', () async {
    await start(allOn);
    expect(layers.keys, unorderedEquals(levels.keys));
    for (final entry in levels.entries) {
      final layer = layers[entry.key]!;
      expect(layer.playing, isTrue, reason: entry.key);
      expect(layer.gain, closeTo(entry.value / 100, 1e-9), reason: entry.key);
      expect(layer.loads, 1);
    }
  });

  test('toggling one sound leaves the others untouched', () async {
    await start(allOn);
    final rainPlays = layers['heavy-rain']!.plays;
    await backend.setLayerEnabled('thunder', false);
    expect(layers['thunder']!.playing, isFalse);
    expect(layers['thunder']!.gain, 0);
    expect(layers['heavy-rain']!.playing, isTrue);
    expect(layers['heavy-rain']!.plays, rainPlays, reason: 'no restart');

    await backend.setLayerEnabled('thunder', true);
    expect(layers['thunder']!.playing, isTrue);
    expect(layers['thunder']!.gain, closeTo(0.35, 1e-9));
    expect(layers['thunder']!.loads, 1, reason: 'not reloaded');
  });

  test('zero volume is silent and volume changes apply live', () async {
    await start(allOn);
    await backend.setPerSoundVolume('pink-noise', 0);
    expect(layers['pink-noise']!.gain, 0);
    await backend.setPerSoundVolume('pink-noise', 90);
    expect(layers['pink-noise']!.gain, closeTo(0.9, 1e-9));
  });

  test('disabled sounds are not loaded or played', () async {
    await start({...allOn, 'white-noise': false, 'pink-noise': false});
    expect(layers.containsKey('white-noise'), isFalse);
    expect(layers.containsKey('pink-noise'), isFalse);
  });

  test('pause and resume keep the mix', () async {
    await start(allOn);
    await backend.pause();
    expect(layers.values.every((l) => !l.playing), isTrue);
    await backend.resume();
    expect(layers.values.every((l) => l.playing), isTrue);
    expect(layers['heavy-rain']!.gain, closeTo(0.7, 1e-9));
  });

  test('volume changes while paused apply on resume, not before', () async {
    await start(allOn);
    await backend.pause();
    await backend.setPerSoundVolume('heavy-rain', 20);
    expect(layers['heavy-rain']!.playing, isFalse);
    await backend.resume();
    expect(layers['heavy-rain']!.gain, closeTo(0.2, 1e-9));
  });

  test('status reports real playing state and levels', () async {
    final statuses = <dynamic>[];
    backend.statusStream.listen(statuses.add);
    await start(allOn);
    await Future<void>.delayed(Duration.zero);
    final last = statuses.last;
    expect(last.playing, isTrue);
    expect(last.activeLayers, hasLength(4));
    expect(last.perSoundVolume['thunder'], 35);
  });

  test('a failed start leaves nothing half playing', () async {
    backend = NativeSleepSoundsBackend(
      layerFactory: (id) =>
          layers[id] = FakeLayer(id, failPlay: id == 'thunder'),
    );
    await expectLater(start(allOn), throwsStateError);
    expect(layers.values.where((l) => l.playing), isEmpty);
  });

  test('stop silences everything and dispose releases players', () async {
    await start(allOn);
    await backend.stop();
    expect(layers.values.every((l) => !l.playing), isTrue);
    await backend.dispose();
    expect(layers.values.every((l) => l.disposed), isTrue);
  });

  test('refuses to start with every sound off', () async {
    await backend.initialize(
      profileId: 1,
      preset: 'mix',
      masterVolume: 70,
      enabled: const {},
      volumes: levels,
    );
    expect(backend.play(), throwsStateError);
  });
}
