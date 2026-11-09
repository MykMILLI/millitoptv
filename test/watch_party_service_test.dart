import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/watch_party/watch_party_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unit tests always run. The end-to-end group runs only when WP_E2E points
/// at a local watch party server (see tmp_remote_dashboard tests).
void main() {
  test('Jellyfin static streams become H.264 HLS for guests', () {
    final url = WatchPartyMedia.relayFriendlyUrl(
      'http://192.168.1.5:8096/Videos/abc123/stream?static=true&api_key=KEY&DeviceId=dev1',
    );
    final uri = Uri.parse(url);
    expect(uri.path, '/Videos/abc123/master.m3u8');
    expect(uri.queryParameters['api_key'], 'KEY');
    expect(uri.queryParameters['VideoCodec'], 'h264');
    expect(uri.queryParameters['MediaSourceId'], 'abc123');
    const other = 'http://example.com/live/1.ts';
    expect(WatchPartyMedia.relayFriendlyUrl(other), other);
  });

  test('join input accepts codes and invite links', () {
    expect(WatchPartyService.parseJoinInput('abcd-2345')?.code, 'ABCD2345');
    final link = WatchPartyService.parseJoinInput(
      'https://tvadmin.millitop.net/watch/ABCD2345?invite=wi_x',
    );
    expect(link?.code, 'ABCD2345');
    expect(link?.server.toString(), 'https://tvadmin.millitop.net/');
    expect(link?.invite, 'wi_x');
    expect(WatchPartyService.parseJoinInput('nope'), isNull);
  });

  test('posters with credentials are never shared', () {
    expect(WatchPartyMedia.safePosterUrl('https://a.b/x.jpg'), isNotNull);
    expect(WatchPartyMedia.safePosterUrl('http://a.b/x.jpg'), isNull);
    expect(
      WatchPartyMedia.safePosterUrl(
        'https://m/getCoverArt.view?u=a&t=b&s=c&id=1',
      ),
      isNull,
    );
    expect(
      WatchPartyMedia.safePosterUrl(
        'https://j/Items/1/Images/Primary?api_key=k',
      ),
      isNull,
    );
  });

  final e2e = Platform.environment['WP_E2E'];
  group('end to end', skip: e2e == null ? 'set WP_E2E' : false, () {
    final base = Uri.parse(e2e ?? 'http://127.0.0.1:3999');
    final http = HttpClient();
    Future<Map<String, dynamic>> post(
      String path,
      Map<String, dynamic> body,
      String token,
    ) async {
      final req = await http.postUrl(base.resolve(path));
      req.headers.contentType = ContentType.json;
      req.headers.set('authorization', 'Bearer $token');
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      expect(res.statusCode, lessThan(300), reason: '$path $text');
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    }

    Future<void> until(bool Function() check, String what) async {
      for (var i = 0; i < 100; i++) {
        if (check()) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('Timed out waiting for $what');
    }

    test(
      'app guest joins, receives chat, media, playback and the end',
      () async {
        SharedPreferences.setMockInitialValues({});
        final created = await post('/api/device/watch-parties/create', {
          'title': 'Dart test',
          'displayName': 'Host',
        }, 'mtv_testdevicetoken');
        final hostToken = (created['participant'] as Map)['token'] as String;
        final code = (created['party'] as Map)['code'] as String;
        final party = WatchPartyService.instance;
        await party.joinParty(
          code: code,
          displayName: 'Dart guest',
          server: base,
        );
        expect(party.isGuest, isTrue);
        await until(() => party.connected, 'event stream');
        await until(() => party.people.length == 2, 'participants');
        await post('/api/watch/chat', {'body': 'hi from host'}, hostToken);
        await until(
          () => party.messages.any((m) => m.body == 'hi from host'),
          'chat',
        );
        final media = await post('/api/watch/media', {
          'media': {
            'kind': 'youtube',
            'title': 'YT',
            'youtubeId': 'dQw4w9WgXcQ',
          },
        }, hostToken);
        final rev = media['mediaRev'] as int;
        await until(() => party.media?.rev == rev, 'media');
        expect(party.relayUrl, contains('/watch-relay/'));
        await post('/api/watch/playback', {
          'mediaRev': rev,
          'positionMs': 60000,
          'playing': true,
          'rate': 1,
        }, hostToken);
        await until(() => party.playback?.positionMs == 60000, 'playback');
        final target = party.playback!.targetPositionMs(party.serverNowMs);
        expect(target, inInclusiveRange(60000, 62000));
        await party.sendChat('hello host');
        await until(
          () => party.messages.any((m) => m.body == 'hello host'),
          'own chat',
        );
        await post('/api/watch/end', {}, hostToken);
        await until(() => !party.active, 'ended');
        expect(party.endedReason, 'The host ended the watch party.');
      },
    );
  });
}
