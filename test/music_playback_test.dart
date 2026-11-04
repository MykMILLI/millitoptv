import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/music_playback.dart';
import 'package:millitop_tv/services/music_service.dart';

const first = MusicTrack(
  id: 'one',
  title: 'One',
  artist: 'Artist',
  album: 'Album',
  durationSeconds: 100,
);
const second = MusicTrack(
  id: 'two',
  title: 'Two',
  artist: 'Other artist',
  album: 'Album',
  durationSeconds: 120,
);

class FakeMusicService extends MusicService {
  String password = 'local-test-value';
  Completer<void>? configGate;
  Completer<void>? historyGate;
  final history = <String>[];
  @override
  Future<MusicServerConfig?> config(int profileId) async {
    await configGate?.future;
    return MusicServerConfig(
      baseUrl: 'https://music.example.com',
      username: 'listener',
      password: password,
    );
  }

  @override
  Future<void> upsertRecentlyPlayed(int profileId, MusicTrack track) async {
    await historyGate?.future;
    history.add(track.id);
  }
}

class FakeMusicBackend implements MusicAudioBackend {
  final controller = StreamController<MusicAudioEvent>.broadcast(sync: true);
  final opened = <Uri>[];
  int generation = 0;
  int pauses = 0;
  int stops = 0;
  bool disposed = false;
  bool failOpen = false;
  Duration? sought;
  double volume = 0;
  @override
  Stream<MusicAudioEvent> get events => controller.stream;
  @override
  Future<void> open(Uri uri, int generation) async {
    if (failOpen) throw StateError('Must never display $uri');
    this.generation = generation;
    opened.add(uri);
    controller.add(MusicAudioEvent(generation, playing: true));
  }

  void complete() =>
      controller.add(MusicAudioEvent(generation, completed: true));
  @override
  Future<void> pause() async {
    pauses++;
    controller.add(MusicAudioEvent(generation, playing: false));
  }

  @override
  Future<void> play() async =>
      controller.add(MusicAudioEvent(generation, playing: true));
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> seek(Duration target) async {
    sought = target;
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

void main() {
  late FakeMusicBackend backend;
  late FakeMusicService service;
  late MusicPlayback playback;
  var audioFocusRequests = 0;

  setUp(() {
    backend = FakeMusicBackend();
    service = FakeMusicService();
    audioFocusRequests = 0;
    playback = MusicPlayback(
      service: service,
      backend: backend,
      beforePlay: () async {
        audioFocusRequests++;
      },
    );
  });
  tearDown(() async {
    await playback.close();
    playback.dispose();
  });

  test('completion advances queue and metadata, then stops at end', () async {
    await playback.playQueue(1, [first, second]);
    expect(playback.current, first);
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(playback.index, 1);
    expect(playback.current, second);
    expect(backend.opened.last.queryParameters['id'], second.id);
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(playback.index, 1);
    expect(playback.playing, isFalse);
    expect(backend.opened, hasLength(2));
    expect(service.history, ['one', 'two']);
  });

  test('previous, next, selected index and boundaries are consistent', () async {
    await playback.playQueue(1, [first, second], index: 1);
    await playback.next();
    expect(playback.index, 1);
    await playback.previous();
    await playback.previous();
    expect(playback.index, 0);
    await playback.select(1);
    expect(playback.current, second);
    await playback.select(99);
    expect(playback.index, 1);
    expect(backend.opened, hasLength(3));
  });

  test('empty and invalid queues do not change playback', () async {
    await playback.playQueue(1, []);
    await playback.playQueue(1, [first], index: -1);
    await playback.toggle();
    expect(playback.current, isNull);
    expect(backend.opened, isEmpty);
  });

  test('radio extension deduplicates without reopening seed', () async {
    await playback.playQueue(1, [first]);
    await playback.replaceUpcoming([first, second, second, first]);
    expect(playback.queue.map((track) => track.id), ['one', 'two']);
    expect(backend.opened, hasLength(1));
    expect(playback.index, 0);
  });

  test('late radio results advance if the seed already completed', () async {
    await playback.playQueue(1, [first]);
    backend.complete();
    await playback.replaceUpcoming([first, second]);
    expect(playback.current, second);
    expect(backend.opened, hasLength(2));
  });

  test('stale radio results cannot alter a newer queue selection', () async {
    await playback.playQueue(1, [first]);
    final revision = playback.queueRevision;
    await playback.playQueue(1, [second]);
    await playback.replaceUpcoming([first], expectedRevision: revision);
    expect(playback.queue, [second]);
  });

  test('rapid selections reject stale credential loads and events', () async {
    service.configGate = Completer<void>();
    final old = playback.playQueue(1, [first, second]);
    await Future<void>.delayed(Duration.zero);
    final latest = playback.select(1);
    service.configGate!.complete();
    await Future.wait([old, latest]);
    expect(backend.opened, hasLength(1));
    expect(backend.opened.single.queryParameters['id'], 'two');
    backend.controller.add(
      MusicAudioEvent(backend.generation - 1, completed: true, playing: false),
    );
    expect(playback.current, second);
    expect(playback.playing, isTrue);
  });

  test('stream URLs are regenerated using current credentials', () async {
    await playback.playQueue(1, [first, second]);
    final firstUri = backend.opened.single;
    service.password = 'changed-local-test-value';
    await playback.next();
    expect(backend.opened.last.queryParameters['t'],
        isNot(firstUri.queryParameters['t']));
    expect(backend.opened.last.queryParameters, isNot(contains('password')));
    expect(audioFocusRequests, 2);
  });

  test('progress does not notify the whole playback view', () async {
    await playback.playQueue(1, [first]);
    var screenNotifications = 0;
    var progressNotifications = 0;
    playback.addListener(() => screenNotifications++);
    playback.progress.addListener(() => progressNotifications++);
    backend.controller.add(
      MusicAudioEvent(backend.generation, position: const Duration(seconds: 4)),
    );
    expect(screenNotifications, 0);
    expect(progressNotifications, 1);
  });

  test('history revision notifies only after persisted history is ready', () async {
    service.historyGate = Completer<void>();
    final revisions = <int>[];
    playback.addListener(() => revisions.add(playback.historyRevision));
    final opening = playback.playQueue(1, [first]);
    await Future<void>.delayed(Duration.zero);
    final beforeWrite = playback.historyRevision;
    service.historyGate!.complete();
    await opening;
    expect(beforeWrite, 0);
    expect(playback.historyRevision, 1);
    expect(revisions.last, 1);
    expect(service.history, ['one']);
  });

  test('seek and volume clamp, buffering and pause synchronize', () async {
    await playback.playQueue(1, [first]);
    await playback.seek(const Duration(seconds: 200));
    expect(backend.sought, const Duration(seconds: 100));
    await playback.seek(const Duration(seconds: -1));
    expect(backend.sought, Duration.zero);
    await playback.setVolume(150);
    expect(backend.volume, 100);
    backend.controller.add(
      MusicAudioEvent(backend.generation, buffering: true),
    );
    expect(playback.buffering, isTrue);
    await playback.pause();
    expect(playback.playing, isFalse);
    await playback.toggle();
    expect(playback.playing, isTrue);
  });

  test('safe errors support retry without leaking authenticated URL', () async {
    backend.failOpen = true;
    await playback.playQueue(1, [first]);
    expect(playback.error, isNotNull);
    expect(playback.error, isNot(contains('https')));
    expect(playback.buffering, isFalse);
    final failedGeneration = playback.queueRevision - 1;
    backend.controller.add(
      MusicAudioEvent(failedGeneration, playing: true, completed: true),
    );
    expect(playback.playing, isFalse);
    backend.failOpen = false;
    await playback.toggle();
    expect(playback.error, isNull);
    expect(playback.playing, isTrue);
  });

  test('stream errors remain failed until an explicit retry', () async {
    await playback.playQueue(1, [first, second]);
    backend.controller.add(MusicAudioEvent(backend.generation, failed: true));
    backend.controller.add(MusicAudioEvent(backend.generation, playing: true));
    backend.complete();
    expect(playback.playing, isFalse);
    expect(playback.index, 0);
    expect(playback.error, isNotNull);
    await playback.toggle();
    expect(playback.playing, isTrue);
    expect(playback.error, isNull);
  });

  test('profile switch clears queue and stops previous profile audio', () async {
    await playback.playQueue(1, [first]);
    await playback.activateProfile(2);
    expect(playback.profileId, 2);
    expect(playback.queue, isEmpty);
    expect(playback.current, isNull);
    expect(backend.stops, 1);
    expect(playback.playing, isFalse);
  });

  test('close invalidates pending loads and disposes native resources', () async {
    service.configGate = Completer<void>();
    final opening = playback.playQueue(1, [first]);
    await Future<void>.delayed(Duration.zero);
    final closing = playback.close();
    service.configGate!.complete();
    await Future.wait([opening, closing]);
    expect(backend.opened, isEmpty);
    expect(backend.disposed, isTrue);
  });
}
