import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/screens/music_screen.dart';
import 'package:millitop_tv/services/music_playback.dart';
import 'package:millitop_tv/services/music_service.dart';
import 'package:millitop_tv/widgets/music_player.dart';

const _song = MusicTrack(
  id: 'one',
  title: 'A very long song title to exercise compact player truncation',
  artist: 'An artist with a very long name',
  album: 'Evening sounds',
  durationSeconds: 240,
);
const _next = MusicTrack(
  id: 'two',
  title: 'Next song',
  artist: 'Next artist',
  album: 'Night sounds',
  durationSeconds: 180,
);

class _UnconfiguredService extends MusicService {
  @override
  Future<MusicServerConfig?> config(int profileId) async => null;
  @override
  Future<List<MusicStation>> stations(int profileId) async => [];
  @override
  Future<List<MusicTrack>> recentlyPlayed(int profileId) async => [];
}

const _serverConfig = MusicServerConfig(
  baseUrl: 'https://music.example.com',
  username: 'listener',
  password: 'unused',
);

class _ConfiguredService extends _UnconfiguredService {
  int historyReads = 0;
  List<MusicTrack> recent = [];
  @override
  Future<MusicServerConfig?> config(int profileId) async => _serverConfig;
  @override
  Future<List<MusicTrack>> recentlyPlayed(int profileId) async {
    historyReads++;
    return List.of(recent);
  }
}

class _Client extends NavidromeClient {
  _Client() : super(_serverConfig);
  Future<List<MusicTrack>> Function(String)? search;
  final searches = <String>[];
  Completer<List<MusicTrack>>? recommendations;
  @override
  String get radioDescription =>
      'Genre/era radio · Jazz (metadata fallback, not song similarity)';
  @override
  Future<void> ping() async {}
  @override
  Future<List<MusicTrack>> randomSongs({
    int limit = 24,
    String? genre,
    int? fromYear,
    int? toYear,
  }) async => [_song];
  @override
  Future<List<MusicTrack>> searchSongs(String query, {int limit = 30}) async {
    searches.add(query);
    return search == null ? [_next] : await search!(query);
  }
  @override
  Future<List<MusicTrack>> stationFromSeed(MusicTrack seed, {int limit = 30}) =>
      recommendations?.future ?? Future.value([seed, _next]);
}

class _Playback extends MusicPlayback {
  bool active = false;
  int selected = 0;
  double level = 80;
  Duration? sought;
  int previousCalls = 0;
  int nextCalls = 0;
  int revision = 0;
  int history = 0;
  int playCalls = 0;
  int replaceCalls = 0;
  bool completed = false;
  List<MusicTrack> tracks = [_song, _next];
  @override
  MusicTrack get current => queue[selected];
  @override
  List<MusicTrack> get queue => tracks;
  @override
  int get queueRevision => revision;
  @override
  int get historyRevision => history;
  @override
  int get index => selected;
  @override
  int get profileId => 1;
  @override
  bool get playing => active;
  @override
  bool get buffering => false;
  @override
  double get volume => level;
  @override
  Future<void> toggle() async {
    active = !active;
    notifyListeners();
  }
  @override
  Future<void> select(int index) async {
    selected = index;
    revision++;
    notifyListeners();
  }
  @override
  Future<void> playQueue(int profileId, List<MusicTrack> tracks, {int index = 0}) async {
    playCalls++;
    this.tracks = List.of(tracks);
    selected = index;
    completed = false;
    active = true;
    revision++;
    notifyListeners();
  }
  @override
  Future<void> replaceUpcoming(List<MusicTrack> tracks, {int? expectedRevision}) async {
    if (expectedRevision != null && expectedRevision != revision) return;
    replaceCalls++;
    this.tracks = [...queue.take(selected + 1), ...tracks];
    if (completed && selected + 1 < queue.length) {
      selected++;
      active = true;
      completed = false;
      revision++;
    }
    notifyListeners();
  }
  void finishSeed() {
    completed = true;
    active = false;
    notifyListeners();
  }
  void recordHistory() {
    history++;
    notifyListeners();
  }
  @override
  Future<void> previous() async {
    previousCalls++;
    selected = 0;
    revision++;
    notifyListeners();
  }
  @override
  Future<void> next() async {
    nextCalls++;
    selected = 1;
    revision++;
    notifyListeners();
  }
  @override
  Future<void> seek(Duration target) async {
    sought = target;
  }
  @override
  Future<void> setVolume(double value) async {
    level = value;
    notifyListeners();
  }
}

Widget _app(Widget child, {bool reducedMotion = false, double textScale = 1}) => MaterialApp(
  theme: ThemeData.dark(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reducedMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(body: child),
    ),
  ),
);

void main() {
  testWidgets('transport supports keyboard focus and skips disabled boundaries', (tester) async {
    final playback = _Playback();
    addTearDown(playback.dispose);
    await tester.pumpWidget(_app(FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: ListenableBuilder(
        listenable: playback,
        builder: (_, _) => MusicTransport(playback: playback),
      ),
    )));
    expect(tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
    ).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(playback.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.playing, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(playback.nextCalls, 1);
    expect(tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_next_rounded),
    ).onPressed, isNull);
    expect(tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
    ).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('profile setup remains usable at 320 pixels', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _Playback();
    addTearDown(playback.dispose);
    await tester.pumpWidget(MaterialApp(
      home: MusicScreen(
        profileId: 1,
        playback: playback,
        service: _UnconfiguredService(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Connect Navidrome'), findsOneWidget);
    expect(find.text('Server origin'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mini player fits 320 pixels and opens shared full player', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _Playback();
    addTearDown(playback.dispose);
    playback.progress.value = const MusicProgress(
      Duration(seconds: 45), Duration(minutes: 4),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: MusicScreen(
        profileId: 1,
        playback: playback,
        service: _UnconfiguredService(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(_song.title));
    await tester.pumpAndSettle();
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.byType(MusicSeekBar), findsOneWidget);
    expect(find.byType(MusicVolume), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Play'));
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(playback.playing, isTrue);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search debounces, sanitizes failure and retries', (tester) async {
    final playback = _Playback();
    addTearDown(playback.dispose);
    final client = _Client();
    var failed = false;
    client.search = (_) async {
      if (!failed) {
        failed = true;
        throw StateError('https://music.example.com/request?token=private');
      }
      return [_next];
    };
    await tester.pumpWidget(MaterialApp(
      home: MusicScreen(
        profileId: 1,
        playback: playback,
        service: _ConfiguredService(),
        clientFactory: (_) => client,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'night');
    await tester.pump(const Duration(milliseconds: 349));
    expect(client.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(client.searches, ['night']);
    expect(find.text('Search unavailable. Please try again.'), findsOneWidget);
    expect(find.textContaining('token=private'), findsNothing);
    await tester.tap(find.text('Retry search'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(client.searches, ['night', 'night']);
    expect(find.text(_next.title), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stale search results cannot replace a newer query', (tester) async {
    final playback = _Playback();
    addTearDown(playback.dispose);
    final client = _Client();
    final older = Completer<List<MusicTrack>>();
    final newer = Completer<List<MusicTrack>>();
    client.search = (query) => query == 'old' ? older.future : newer.future;
    await tester.pumpWidget(MaterialApp(
      home: MusicScreen(
        profileId: 1, playback: playback, service: _ConfiguredService(),
        clientFactory: (_) => client,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 350));
    newer.complete([_next]);
    await tester.pump();
    older.complete([_song]);
    await tester.pump();
    expect(find.text(_next.title), findsOneWidget);
    expect(find.descendant(
      of: find.byType(GridView), matching: find.text(_song.title),
    ), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history refresh waits for the persisted-history revision', (tester) async {
    final playback = _Playback();
    addTearDown(playback.dispose);
    final service = _ConfiguredService();
    await tester.pumpWidget(MaterialApp(
      home: MusicScreen(
        profileId: 1, playback: playback, service: service,
        clientFactory: (_) => _Client(),
      ),
    ));
    await tester.pumpAndSettle();
    final initialReads = service.historyReads;
    await playback.select(1);
    await tester.pump();
    expect(service.historyReads, initialReads);
    service.recent = [_next];
    playback.recordHistory();
    await tester.pump();
    expect(service.historyReads, initialReads + 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('radio starts immediately and rejects a newer same-seed queue', (tester) async {
    final playback = _Playback();
    addTearDown(playback.dispose);
    final client = _Client()..recommendations = Completer<List<MusicTrack>>();
    await tester.pumpWidget(MaterialApp(
      home: MusicScreen(
        profileId: 1, playback: playback, service: _ConfiguredService(),
        clientFactory: (_) => client,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start radio').first);
    await tester.tap(find.text('Start radio').first);
    await tester.pump();
    expect(playback.playCalls, 1);
    expect(playback.queue.map((track) => track.id), ['one']);
    await playback.playQueue(1, [_song]);
    client.recommendations!.complete([_song, _next]);
    await tester.pump();
    expect(playback.replaceCalls, 0);
    expect(playback.queue.map((track) => track.id), ['one']);
    expect(find.text('Save station'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late radio results advance a completed seed without replaying it', (tester) async {
    final playback = _Playback();
    addTearDown(playback.dispose);
    final client = _Client()..recommendations = Completer<List<MusicTrack>>();
    await tester.pumpWidget(MaterialApp(
      home: MusicScreen(
        profileId: 1, playback: playback, service: _ConfiguredService(),
        clientFactory: (_) => client,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start radio').first);
    await tester.tap(find.text('Start radio').first);
    await tester.pump();
    playback.finishSeed();
    client.recommendations!.complete([_song, _next]);
    await tester.pump();
    expect(playback.playCalls, 1);
    expect(playback.replaceCalls, 1);
    expect(playback.current.id, 'two');
    expect(find.text('RADIO SOURCE'), findsOneWidget);
    expect(find.textContaining('metadata fallback, not song similarity'), findsOneWidget);
    expect(find.text('Save station'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('library content is constrained on ultrawide displays', (tester) async {
    tester.view.physicalSize = const Size(3000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _Playback();
    addTearDown(playback.dispose);
    await tester.pumpWidget(MaterialApp(
      home: MusicScreen(
        profileId: 1, playback: playback, service: _ConfiguredService(),
        clientFactory: (_) => _Client(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('music-library-content'))).width,
        lessThanOrEqualTo(1100));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop exposes transport seek volume and queue controls', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _Playback();
    addTearDown(playback.dispose);
    playback.progress.value = const MusicProgress(
      Duration(seconds: 45), Duration(minutes: 4),
    );
    await tester.pumpWidget(_app(Align(
      alignment: Alignment.bottomCenter,
      child: MusicPlayerBar(playback: playback, onOpen: () {}),
    )));
    expect(find.text('0:45'), findsOneWidget);
    expect(find.text('4:00'), findsOneWidget);
    expect(find.byTooltip('No previous track'), findsOneWidget);
    expect(tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
    ).onPressed, isNull);
    await tester.tap(find.byTooltip('Next track'));
    await tester.pump();
    expect(playback.nextCalls, 1);
    expect(find.byTooltip('No next track'), findsOneWidget);
    expect(tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_next_rounded),
    ).onPressed, isNull);
    await tester.tap(find.byTooltip('Previous track'));
    await tester.pump();
    expect(playback.previousCalls, 1);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    sliders.first.onChanged!(90000);
    sliders.last.onChanged!(35);
    await tester.pump();
    expect(playback.sought, const Duration(seconds: 90));
    expect(playback.volume, 35);
    await tester.tap(find.byTooltip('Open queue'));
    await tester.pumpAndSettle();
    expect(find.text('UP NEXT'), findsOneWidget);
    await tester.tap(find.text('Next song'));
    await tester.pumpAndSettle();
    expect(playback.current.id, 'two');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('artwork switch works on a narrow now-playing panel', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _Playback();
    addTearDown(playback.dispose);
    await tester.pumpWidget(_app(MusicNowPlaying(
      playback: playback, fullScreen: true,
    )));
    expect(tester.widget<VinylArtwork>(find.byType(VinylArtwork)).vinyl, isTrue);
    await tester.tap(find.text('Artwork'));
    await tester.pumpAndSettle();
    expect(tester.widget<VinylArtwork>(find.byType(VinylArtwork)).vinyl, isFalse);
    expect(find.byKey(const ValueKey('vinyl-rotation')), findsNothing);
    await tester.tap(find.text('Vinyl'));
    await tester.pumpAndSettle();
    expect(tester.widget<VinylArtwork>(find.byType(VinylArtwork)).vinyl, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow now-playing supports enlarged text without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _Playback();
    addTearDown(playback.dispose);
    await tester.pumpWidget(_app(
      MusicNowPlaying(playback: playback, fullScreen: true),
      textScale: 2,
    ));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Artwork'));
    await tester.tap(find.text('Artwork'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('vinyl only rotates while playing and preserves paused angle', (tester) async {
    Future<void> render(bool playing, {bool reduced = false}) =>
        tester.pumpWidget(_app(
          SizedBox(width: 240, height: 240,
            child: VinylArtwork(track: _song, playing: playing, vinyl: true)),
          reducedMotion: reduced,
        ));
    double angle() => tester.widget<RotationTransition>(
      find.byKey(const ValueKey('vinyl-rotation')),
    ).turns.value;
    await render(true);
    await tester.pump(const Duration(seconds: 1));
    final moving = angle();
    expect(moving, greaterThan(0));
    await render(false);
    await tester.pump(const Duration(seconds: 1));
    expect(angle(), moving);
    await render(true, reduced: true);
    await tester.pump(const Duration(seconds: 1));
    expect(angle(), moving);
    await render(true);
    await tester.pump(const Duration(seconds: 1));
    expect(angle(), greaterThan(moving));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing artwork renders a graceful cover fallback', (tester) async {
    await tester.pumpWidget(_app(const SizedBox(
      width: 120, height: 120, child: MusicCover(track: _song),
    )));
    expect(find.byIcon(Icons.album_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
