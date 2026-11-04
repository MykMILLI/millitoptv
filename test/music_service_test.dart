import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/music_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const seed = MusicTrack(
  id: 'seed',
  title: 'Seed song',
  artist: 'Seed artist',
  album: 'Seed album',
  durationSeconds: 180,
  genre: 'Rock',
  year: 1995,
);

Map<String, dynamic> song(
  String id, {
  String artist = 'Other artist',
  String genre = 'Rock',
  int year = 1995,
}) => {
  'id': id,
  'title': 'Song $id',
  'artist': artist,
  'album': 'Album',
  'duration': 123,
  'genre': genre,
  'year': year,
  'coverArt': 'cover-$id',
};

Map<String, dynamic> stationJson(Map<String, dynamic> track) => {
  'id': 'station',
  'name': 'My radio',
  'seedTrackId': 'seed',
  'seedTitle': 'Seed song',
  'createdAtUtc': '2026-01-01T00:00:00.000Z',
  'queue': [track],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('music storage', () {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final secure = <String, String>{};
    final service = MusicService();

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      secure.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final key = args['key'] as String;
            switch (call.method) {
              case 'read':
                return secure[key];
              case 'write':
                secure[key] = args['value'] as String;
                return null;
              case 'delete':
                secure.remove(key);
                return null;
              default:
                throw UnsupportedError(call.method);
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('ignores legacy URLs and accepts missing display metadata', () {
      final track = MusicTrack.fromJson({
        'id': 'legacy',
        'title': ' ',
        'durationSeconds': -4,
        'streamUrl': 'https://music.invalid/rest/stream?t=legacy-token',
      });
      expect(track.title, 'Unknown title');
      expect(track.artist, 'Unknown artist');
      expect(track.album, 'Unknown album');
      expect(track.durationSeconds, 0);
      // ignore: deprecated_member_use_from_same_package
      expect(track.streamUrl, isNull);
      expect(track.toJson(), isNot(contains('streamUrl')));
      expect(
        () => MusicTrack.fromJson({'title': 'No identifier'}),
        throwsFormatException,
      );
    });

    test('constructor compatibility never serializes a playback URL', () {
      const track = MusicTrack(
        id: 'old-caller',
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        durationSeconds: 1,
        streamUrl: 'https://music.invalid/rest/stream?t=old-token',
      );
      expect(track.toJson(), isNot(contains('streamUrl')));
    });

    test('reading recent and station queues rewrites sanitized JSON', () async {
      final legacy = {
        'id': 'legacy',
        'streamUrl': 'https://music.invalid/rest/stream?t=legacy-token',
      };
      SharedPreferences.setMockInitialValues({
        'music.recent.v1.7': jsonEncode([legacy]),
        'music.stations.v1.7': jsonEncode([stationJson(legacy)]),
      });
      expect((await service.recentlyPlayed(7)).single.title, 'Unknown title');
      expect(
        (await service.stations(7)).single.queue.single.artist,
        'Unknown artist',
      );
      final prefs = await SharedPreferences.getInstance();
      for (final key in ['music.recent.v1.7', 'music.stations.v1.7']) {
        final stored = prefs.getString(key)!;
        expect(stored, isNot(contains('streamUrl')));
        expect(stored, isNot(contains('legacy-token')));
        expect(stored, contains('Unknown album'));
      }
      // Migration remains readable and idempotent.
      final migrated = prefs.getString('music.stations.v1.7');
      await service.stations(7);
      expect(prefs.getString('music.stations.v1.7'), migrated);
    });

    test('legacy sync imports passwords securely but never exports them', () async {
      const password = 'legacy-local-password';
      final legacy = {
        ...seed.toJson(),
        'streamUrl': 'https://music.invalid/rest/stream?t=legacy-token',
      };
      await service.applyProfileSyncState(7, {
        'server': {
          'baseUrl': 'https://music.invalid',
          'username': 'listener',
          'password': password,
        },
        'stations': [stationJson(legacy)],
        'recentlyPlayed': [legacy],
      });
      expect(secure['music.navidrome.password.v1.7'], password);
      expect((await service.config(7))!.password, password);
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(prefs.get(key).toString(), isNot(contains(password)));
        expect(prefs.get(key).toString(), isNot(contains('legacy-token')));
      }
      final exported = await service.profileSyncState(7);
      expect(exported['server'], {
        'baseUrl': 'https://music.invalid',
        'username': 'listener',
      });
      expect(jsonEncode(exported), isNot(contains(password)));
      expect(jsonEncode(exported), isNot(contains('streamUrl')));

      // Credential-free sync must not overwrite this device's local login.
      await service.applyProfileSyncState(7, {
        'server': {
          'baseUrl': 'https://other.invalid',
          'username': 'other',
        },
      });
      expect((await service.config(7))!.baseUrl, 'https://music.invalid');
      await service.clearConfig(7);
      expect(secure, isEmpty);
      expect(await service.config(7), isNull);
    });
  });

  group('Navidrome song radio', () {
    late HttpServer server;
    late NavidromeClient client;
    HttpOverrides? previousHttpOverrides;
    var serverClosed = false;
    late Future<void> Function(HttpRequest) respond;
    final requests = <Uri>[];

    setUp(() async {
      requests.clear();
      serverClosed = false;
      previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = NavidromeClient(
        MusicServerConfig(
          baseUrl: 'http://${server.address.address}:${server.port}',
          username: 'listener',
          password: 'local-password',
        ),
      );
      server.listen((request) async {
        requests.add(request.uri);
        await respond(request);
        await request.response.close();
      });
    });

    tearDown(() async {
      if (!serverClosed) await server.close(force: true);
      HttpOverrides.global = previousHttpOverrides;
    });

    void reply(HttpRequest request, Map<String, dynamic> body) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'subsonic-response': {'status': 'ok', ...body},
      }));
    }

    test('song-ID recommendations preserve order, seed once, and limit', () async {
      respond = (request) async {
        reply(request, {
          'similarSongs2': {
            'song': [
              song('seed'),
              song('a'),
              song('a'),
              {'title': 'Invalid'},
              song('b'),
              song('c'),
            ],
          },
        });
      };
      final queue = await client.stationFromSeed(seed, limit: 3);
      expect(queue.map((track) => track.id), ['seed', 'a', 'b']);
      expect(identical(queue.first, seed), isTrue);
      expect(requests.single.path, '/rest/getSimilarSongs2.view');
      expect(requests.single.queryParameters['id'], seed.id);
      expect(requests.single.queryParameters['count'], '3');
      expect(client.radioDescription, contains('server recommendations'));
      expect(queue[1].toJson(), isNot(contains('streamUrl')));
      final stream = client.streamUri(queue[1].id);
      expect(stream.path, '/rest/stream.view');
      expect(stream.queryParameters['id'], 'a');
      expect(stream.queryParameters, contains('t'));
      expect(stream.queryParameters, isNot(contains('password')));
      expect(client.coverArtUri('cover-a').queryParameters['id'], 'cover-a');
    });

    for (final unsupported in [false, true]) {
      test(
        '${unsupported ? 'unsupported' : 'empty'} similarity uses constrained diverse fallback',
        () async {
          respond = (request) async {
            if (request.uri.path == '/rest/getSimilarSongs2.view') {
              reply(request, unsupported
                  ? {
                      'status': 'failed',
                      'error': {'code': 0, 'message': 'Not implemented'},
                    }
                  : {'similarSongs2': {'song': []}});
              return;
            }
            reply(request, {
              'randomSongs': {
                'song': [
                  song('seed'),
                  song('a1', artist: 'Artist A'),
                  song('a2', artist: 'Artist A'),
                  song('a1', artist: 'Artist A'),
                  song('same-artist', artist: seed.artist),
                  song('b1', artist: 'Artist B', genre: ' rock '),
                  song('wrong-genre', genre: 'Jazz'),
                  song('wrong-era', year: 2020),
                  {'id': 'missing-metadata'},
                ],
              },
            });
          };
          final queue = await client.stationFromSeed(seed, limit: 5);
          expect(queue.map((track) => track.id), [
            'seed', 'a1', 'b1', 'same-artist', 'a2',
          ]);
          expect(requests.map((uri) => uri.path), [
            '/rest/getSimilarSongs2.view',
            '/rest/getRandomSongs.view',
          ]);
          expect(requests.last.queryParameters, containsPair('genre', 'Rock'));
          expect(requests.last.queryParameters, containsPair('fromYear', '1991'));
          expect(requests.last.queryParameters, containsPair('toYear', '1999'));
          expect(client.radioDescription, contains('metadata fallback'));
          expect(client.radioDescription, contains('1991–1999'));
        },
      );
    }

    test('no metadata never requests unrelated random songs', () async {
      respond = (request) async {
        request.response.statusCode = HttpStatus.notFound;
      };
      final bare = MusicTrack.fromJson({'id': 'bare'});
      expect(await client.stationFromSeed(bare), [bare]);
      expect(requests, hasLength(1));
      expect(client.radioDescription, contains('Seed only'));
    });

    test('unsupported fallback still returns the seed', () async {
      respond = (request) async {
        request.response.statusCode = HttpStatus.notImplemented;
      };
      expect(await client.stationFromSeed(seed), [seed]);
      expect(requests, hasLength(2));
      expect(client.radioDescription, contains('seed only'));
    });

    for (final genreOnly in [true, false]) {
      test('${genreOnly ? 'genre' : 'era'} alone constrains fallback', () async {
        final partialSeed = MusicTrack.fromJson({
          'id': 'seed',
          if (genreOnly) 'genre': 'Rock' else 'year': 1995,
        });
        respond = (request) async {
          reply(
            request,
            request.uri.path.contains('getSimilarSongs2')
                ? {'similarSongs2': {}}
                : {
                    'randomSongs': {
                      'song': [
                        song(
                          'match',
                          genre: genreOnly ? 'Rock' : 'Jazz',
                          year: genreOnly ? 2020 : 1996,
                        ),
                        song(
                          'unrelated',
                          genre: 'Jazz',
                          year: 2020,
                        ),
                      ],
                    },
                  },
          );
        };
        expect(
          (await client.stationFromSeed(partialSeed)).map((track) => track.id),
          ['seed', 'match'],
        );
        expect(
          requests.last.queryParameters.containsKey('genre'),
          genreOnly,
        );
        expect(
          requests.last.queryParameters.containsKey('fromYear'),
          !genreOnly,
        );
      });
    }

    test('seed-only recommendations also trigger metadata fallback', () async {
      respond = (request) async {
        reply(request, request.uri.path.contains('getSimilarSongs2')
            ? {'similarSongs2': {'song': [song('seed'), song('seed')]}}
            : {'randomSongs': {'song': []}});
      };
      expect(await client.stationFromSeed(seed), [seed]);
      expect(requests, hasLength(2));
    });

    test('network and authentication failures are not swallowed', () async {
      respond = (request) async {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      };
      await expectLater(client.stationFromSeed(seed), throwsA(isA<HttpException>()));
      expect(requests, hasLength(1));
      respond = (request) async {
        reply(request, {
          'status': 'failed',
          'error': {'code': 40, 'message': 'Wrong username or password'},
        });
      };
      await expectLater(client.stationFromSeed(seed), throwsStateError);
      expect(requests, hasLength(2));
      expect(client.radioDescription, isEmpty);
    });

    test('fallback network failure also propagates', () async {
      respond = (request) async {
        if (request.uri.path.contains('getSimilarSongs2')) {
          reply(request, {'similarSongs2': {}});
        } else {
          request.response.statusCode = HttpStatus.internalServerError;
        }
      };
      await expectLater(client.stationFromSeed(seed), throwsA(isA<HttpException>()));
      expect(requests, hasLength(2));
    });

    test('malformed response and disconnected transport propagate', () async {
      respond = (request) async {
        request.response.write('not JSON');
      };
      await expectLater(client.stationFromSeed(seed), throwsFormatException);
      expect(requests, hasLength(1));
      await server.close(force: true);
      serverClosed = true;
      await expectLater(
        client.stationFromSeed(seed),
        throwsA(isA<SocketException>()),
      );
    });

    test('API tracks without metadata remain playable by identifier', () async {
      respond = (request) async {
        reply(request, {
          'searchResult3': {
            'song': [
              {'id': 'bare', 'duration': -1},
            ],
          },
        });
      };
      final track = (await client.searchSongs('query')).single;
      expect(track.title, 'Unknown title');
      expect(track.artist, 'Unknown artist');
      expect(track.album, 'Unknown album');
      expect(track.durationSeconds, 0);
      expect(track.toJson(), isNot(contains('streamUrl')));
    });

    test('small limits always keep the seed without fetching', () async {
      for (final limit in [-1, 0, 1]) {
        expect(await client.stationFromSeed(seed, limit: limit), [seed]);
      }
      expect(requests, isEmpty);
    });
  });
}
