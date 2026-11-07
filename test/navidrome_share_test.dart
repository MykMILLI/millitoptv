import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/music_service.dart';

void main() {
  late HttpServer server;
  Uri? capturedUri;

  setUp(() async {
    capturedUri = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        capturedUri = request.uri;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'shares': {
                'share': [
                  {
                    'id': 'share-1',
                    'url': 'https://navidrome.example/share/share-1',
                    'description': 'Test share',
                  },
                ],
              },
            },
          }),
        );
        await request.response.close();
      }
    }());
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test(
    'createShare sends repeated id params and returns the server share url',
    () async {
      final config = MusicServerConfig(
        baseUrl: 'http://${server.address.address}:${server.port}',
        username: 'tester',
        password: 'secret',
      );
      final client = NavidromeClient(config);
      final expires = DateTime.utc(2030, 1, 1);

      final share = await client.createShare(
        ids: const ['song-1', 'song-2'],
        description: 'Shared playlist',
        expires: expires,
      );

      expect(share['url'], 'https://navidrome.example/share/share-1');
      expect(capturedUri, isNotNull);
      expect(
        capturedUri!.queryParametersAll['id'],
        containsAll(['song-1', 'song-2']),
      );
      expect(capturedUri!.queryParameters['description'], 'Shared playlist');
      expect(
        capturedUri!.queryParameters['expires'],
        '${expires.millisecondsSinceEpoch}',
      );
    },
  );

  test('createShare rejects an empty id list', () async {
    final config = MusicServerConfig(
      baseUrl: 'http://${server.address.address}:${server.port}',
      username: 'tester',
      password: 'secret',
    );
    final client = NavidromeClient(config);

    expect(
      () => client.createShare(ids: const []),
      throwsA(isA<FormatException>()),
    );
  });
}
