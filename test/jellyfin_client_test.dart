import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/screens/jellyfin_connect_screen.dart';
import 'package:millitop_tv/screens/live_tv_media_screen.dart';
import 'package:millitop_tv/services/jellyfin_client.dart';
import 'package:millitop_tv/services/live_tv_playlist.dart';
import 'package:millitop_tv/services/live_tv_source.dart';
import 'package:millitop_tv/services/media_catalog_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Call {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
  _Call(this.method, this.uri, this.headers, this.body);
}

/// Minimal in-memory Jellyfin server.
class _FakeJellyfin {
  final calls = <_Call>[];
  int totalItems = 3;
  bool legacyOnly = false;
  bool quickConnectApproved = false;

  Map<String, dynamic> _item(int i, {String type = 'Movie'}) => {
    'Id': 'item$i',
    'Name': '$type $i',
    'Type': type,
    'ProductionYear': 2020 + i,
    'Overview': 'Overview $i',
    'Genres': ['Drama'],
    'DateCreated': '2026-0${(i % 9) + 1}-01T00:00:00Z',
    'ImageTags': {'Primary': 'tag$i'},
    'BackdropImageTags': ['bd$i'],
    'RunTimeTicks': 60 * 60 * 1000 * 10000,
    'UserData': {
      'PlaybackPositionTicks': i == 0 ? 30 * 60 * 1000 * 10000 : 0,
      'Played': i == 2,
    },
  };

  Future<JellyfinHttpResponse> call(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    calls.add(_Call(method, uri, headers, body));
    final path = uri.path;
    JellyfinHttpResponse json(Object value) =>
        JellyfinHttpResponse(200, jsonEncode(value));
    if (legacyOnly && (path == '/UserViews' || path == '/UserItems/Resume')) {
      return const JellyfinHttpResponse(404, '');
    }
    switch (path) {
      case '/System/Info/Public':
        return json({'Id': 'srv', 'ServerName': 'Den', 'Version': '10.10.7'});
      case '/QuickConnect/Enabled':
        return json(true);
      case '/QuickConnect/Initiate':
        return json({'Code': '123456', 'Secret': 's3cret'});
      case '/QuickConnect/Connect':
        return json({
          'Code': '123456',
          'Secret': 's3cret',
          'Authenticated': quickConnectApproved,
        });
      case '/Users/AuthenticateByName':
      case '/Users/AuthenticateWithQuickConnect':
        return json({
          'AccessToken': 'tok',
          'ServerId': 'srv',
          'User': {'Id': 'u1', 'Name': 'mykal'},
        });
      case '/UserViews':
      case '/Users/u1/Views':
        return json({
          'Items': [
            {'Id': 'lib1', 'Name': 'Movies', 'CollectionType': 'movies'},
            {'Id': 'lib2', 'Name': 'Music', 'CollectionType': 'music'},
          ],
        });
      case '/Items':
        final start = int.parse(uri.queryParameters['StartIndex'] ?? '0');
        final limit = int.parse(uri.queryParameters['Limit'] ?? '100');
        final end = (start + limit).clamp(0, totalItems);
        return json({
          'TotalRecordCount': totalItems,
          'Items': [for (var i = start; i < end; i++) _item(i)],
        });
      case '/UserItems/Resume':
      case '/Users/u1/Items/Resume':
        return json({
          'Items': [_item(0)],
        });
      case '/Shows/NextUp':
        return json({
          'Items': [
            {
              ..._item(7, type: 'Episode'),
              'SeriesId': 'show1',
              'SeriesName': 'Severance',
              'ParentIndexNumber': 2,
              'IndexNumber': 3,
            },
          ],
        });
      case '/Items/Latest':
        return json([_item(1)]);
      case '/Items/item0/Similar':
        return json({
          'Items': [_item(5)],
        });
      case '/Sessions/Playing':
      case '/Sessions/Playing/Progress':
      case '/Sessions/Playing/Stopped':
        return const JellyfinHttpResponse(204, '');
    }
    return const JellyfinHttpResponse(404, '');
  }
}

JellyfinApi _api(_FakeJellyfin server, {String? token = 'tok'}) => JellyfinApi(
  serverUrl: 'http://den.local:8096',
  deviceId: 'dev1',
  deviceName: 'Test',
  accessToken: token,
  transport: server.call,
);

JellyfinAccount _account() => const JellyfinAccount(
  serverUrl: 'http://den.local:8096',
  serverName: 'Den',
  userId: 'u1',
  userName: 'mykal',
  accessToken: 'tok',
  deviceId: 'dev1',
  libraries: [
    JellyfinLibrary(id: 'lib1', name: 'Movies', collectionType: 'movies'),
  ],
  selectedLibraryIds: {'lib1'},
);

class _NoSourcesService extends LiveTvPlaylistService {
  const _NoSourcesService();
  @override
  Future<List<LiveTvMediaItem>> loadMovies(LiveTvSource source) async =>
      const [];
  @override
  Future<List<LiveTvMediaItem>> loadSeries(LiveTvSource source) async =>
      const [];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('server address', () {
    test('adds a scheme and strips the web client path', () {
      expect(
        normalizeJellyfinServerUrl('den.local:8096/web/index.html'),
        'http://den.local:8096',
      );
      expect(
        normalizeJellyfinServerUrl('https://example.com/jellyfin/'),
        'https://example.com/jellyfin',
      );
    });

    test('rejects embedded credentials', () {
      expect(
        () => normalizeJellyfinServerUrl('http://a:b@den.local'),
        throwsFormatException,
      );
    });
  });

  test('every request carries the MediaBrowser authorization header', () async {
    final server = _FakeJellyfin();
    await _api(server).publicInfo();
    final header = server.calls.single.headers['Authorization']!;
    expect(header, startsWith('MediaBrowser '));
    expect(header, contains('Client="Millitop TV"'));
    expect(header, contains('DeviceId="dev1"'));
    expect(header, contains('Token="tok"'));
  });

  test('password sign-in sends Username/Pw and returns the token', () async {
    final server = _FakeJellyfin();
    final auth = await _api(
      server,
      token: null,
    ).authenticateByName('mykal', 'pw');
    expect(auth.accessToken, 'tok');
    expect(auth.userId, 'u1');
    expect(jsonDecode(server.calls.single.body!), {
      'Username': 'mykal',
      'Pw': 'pw',
    });
  });

  test('library items are paged and mapped with placeholders', () async {
    final server = _FakeJellyfin()..totalItems = 5;
    final entries = await _api(server).libraryItems(
      'u1',
      const JellyfinLibrary(
        id: 'lib1',
        name: 'Movies',
        collectionType: 'movies',
      ),
      pageSize: 2,
    );
    expect(entries, hasLength(5));
    expect(
      server.calls.where((call) => call.uri.path == '/Items'),
      hasLength(3),
    );
    final first = entries.first;
    // The token must never appear in what gets cached.
    expect(first.media.streamUrl, 'jellyfin://item/item0');
    expect(jellyfinItemIdFromUrl(first.media.streamUrl), 'item0');
    expect(first.media.posterUrl, contains('/Items/item0/Images/Primary'));
    expect(first.media.posterUrl, isNot(contains('tok')));
    expect(first.media.year, 2020);
    expect(first.userData.positionMs, 30 * 60 * 1000);
    expect(first.progress, closeTo(0.5, 0.001));
    expect(entries[2].userData.played, isTrue);
  });

  test('falls back to pre-10.9 endpoints on 404', () async {
    final server = _FakeJellyfin()..legacyOnly = true;
    final libraries = await _api(server).libraries('u1');
    expect(libraries.map((item) => item.name), ['Movies', 'Music']);
    expect(libraries.where((item) => item.isVideo), hasLength(1));
    expect(server.calls.last.uri.path, '/Users/u1/Views');
  });

  test('stream URL is built only at play time and carries the token', () {
    final url = _api(_FakeJellyfin()).streamUrl('item0');
    expect(url, contains('/Videos/item0/stream'));
    expect(url, contains('static=true'));
    expect(url, contains('api_key=tok'));
  });

  test('playback reporter sends start, throttled progress, stop', () async {
    final server = _FakeJellyfin();
    final reporter = JellyfinPlaybackReporter(
      api: _api(server),
      itemId: 'item0',
    );
    reporter.progress(1000, paused: false);
    reporter.progress(6000, paused: false); // throttled (<10s)
    await reporter.stopped(9000);
    await Future<void>.delayed(Duration.zero);
    final paths = server.calls.map((call) => call.uri.path).toList();
    expect(paths, ['/Sessions/Playing', '/Sessions/Playing/Stopped']);
    final stop = jsonDecode(server.calls.last.body!) as Map;
    expect(stop['PositionTicks'], 9000 * 10000);
    expect(stop['ItemId'], 'item0');
  });

  test('disabled reporter stays silent', () async {
    final server = _FakeJellyfin();
    final reporter = JellyfinPlaybackReporter(
      api: _api(server),
      itemId: 'item0',
      enabled: false,
    );
    reporter.progress(1000, paused: false);
    await reporter.stopped(2000);
    expect(server.calls, isEmpty);
  });

  test('account store keeps the token out of shared preferences', () async {
    final secrets = MemoryJellyfinSecretStore();
    final store = JellyfinAccountStore(secrets: secrets);
    await store.save(4, _account());
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('jellyfin.account.v1.4')!;
    expect(raw, isNot(contains('tok')));
    expect(secrets.values['jellyfin.token.v1.4'], 'tok');
    final loaded = await store.load(4);
    expect(loaded!.accessToken, 'tok');
    expect(loaded.sources.single.id, 'jellyfin:lib1');
    expect(await store.load(5), isNull);
    await store.clear(4);
    expect(await store.load(4), isNull);
  });

  testWidgets('Home shows Jellyfin rows and libraries as sources', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _FakeJellyfin();
    final store = JellyfinAccountStore(secrets: MemoryJellyfinSecretStore());
    await store.save(1, _account());
    await tester.pumpWidget(
      MaterialApp(
        home: LiveTvMediaScreen(
          profileId: 1,
          catalogCache: MediaCatalogCache.disabled(),
          playlistService: const _NoSourcesService(),
          loadConfiguredSources: (_) async => const [],
          jellyfinStore: store,
          jellyfinTransport: server.call,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('media-home')), findsOneWidget);
    expect(find.text('Continue Watching Movies'), findsOneWidget);
    expect(find.text('Next Up'), findsOneWidget);
    expect(find.text('Severance'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Because you watched Movie 0'),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('media-home')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Because you watched Movie 0'), findsOneWidget);
    expect(find.text('Movies (Jellyfin)'), findsWidgets);
    expect(find.byKey(const ValueKey('media-home-hero-play')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('media-tab-movies')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('media-home')), findsNothing);
    expect(find.text('Movie 1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [
    Size(320, 640),
    Size(360, 740),
    Size(412, 915),
    Size(740, 360),
    Size(800, 1280),
  ]) {
    testWidgets('populated Movies & Series home and Connect fit $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _FakeJellyfin();
      final store = JellyfinAccountStore(secrets: MemoryJellyfinSecretStore());
      await store.save(1, _account());
      await tester.pumpWidget(
        MaterialApp(
          home: LiveTvMediaScreen(
            profileId: 1,
            catalogCache: MediaCatalogCache.disabled(),
            playlistService: const _NoSourcesService(),
            loadConfiguredSources: (_) async => const [],
            jellyfinStore: store,
            jellyfinTransport: server.call,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-home')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'home at $size');
      await tester.tap(find.byKey(const ValueKey('media-tab-movies')));
      await tester.pumpAndSettle();
      expect(find.text('Movie 1'), findsWidgets);
      expect(tester.takeException(), isNull, reason: 'grid at $size');

      await tester.pumpWidget(
        MaterialApp(
          home: JellyfinConnectScreen(
            profileId: 2,
            store: JellyfinAccountStore(secrets: MemoryJellyfinSecretStore()),
            transport: server.call,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'connect at $size');
    });
  }

  testWidgets('Connect screen signs in with a password and lists libraries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _FakeJellyfin();
    final secrets = MemoryJellyfinSecretStore();
    final store = JellyfinAccountStore(secrets: secrets);
    await tester.pumpWidget(
      MaterialApp(
        home: JellyfinConnectScreen(
          profileId: 2,
          store: store,
          transport: server.call,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jellyfin-server-url')),
      'den.local:8096',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Den'), findsWidgets);
    expect(find.text('Get a Quick Connect code'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('jellyfin-username')),
      'mykal',
    );
    await tester.enterText(
      find.byKey(const ValueKey('jellyfin-password')),
      'pw',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Signed in'), findsOneWidget);
    expect(find.byKey(const ValueKey('jellyfin-library-lib1')), findsOneWidget);
    // Music libraries are not offered in Movies & Series.
    expect(find.byKey(const ValueKey('jellyfin-library-lib2')), findsNothing);
    final saved = await store.load(2);
    expect(saved!.selectedLibraryIds, {'lib1'});
    expect(saved.userName, 'mykal');
  });
}
