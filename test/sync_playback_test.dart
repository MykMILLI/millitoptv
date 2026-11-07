import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pstube_engine/pstube_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:millitop_tv/services/device_connection.dart';
import 'package:millitop_tv/services/global_playlists.dart';
import 'package:millitop_tv/services/home_preferences.dart';
import 'package:millitop_tv/services/live_tv_control.dart';
import 'package:millitop_tv/services/music_service.dart';
import 'package:millitop_tv/services/playlist_playback.dart';
import 'package:millitop_tv/services/tube_library.dart';

const _video = TubeVideo(
  id: 'v1',
  title: 'Video one',
  author: 'Creator',
  channelId: 'chan-1',
);
const _video2 = TubeVideo(
  id: 'v2',
  title: 'Video two',
  author: 'Other',
  channelId: 'chan-2',
);

MusicTrack _song(String id) => MusicTrack(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  album: 'Album',
  durationSeconds: 180,
  streamUrl: 'https://example.invalid/$id.mp3',
);

class _FakeConnection extends Fake implements DeviceConnection {
  Map<String, dynamic> server = {};
  final posts = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> postDevice(
    String route,
    Map<String, dynamic> body, {
    required String expectedConnection,
  }) async {
    posts.add(body);
    if (body['action'] == 'set') {
      server = Map<String, dynamic>.from(body['profileState'] as Map);
      return {'ok': true};
    }
    return {'profileState': server};
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('YouTube sync merge', () {
    test('keeps subscriptions from both devices', () async {
      final store = TubeStore();
      await store.save(1, const TubeLibrary().toggle('subscriptions', _video));
      final remote = const TubeLibrary().toggle('subscriptions', _video2);
      await store.applySync(1, remote.toJson());
      final merged = await store.load(1);
      expect(
        merged.list('subscriptions').map((v) => v.channelId),
        containsAll(['chan-1', 'chan-2']),
      );
    });

    test(
      'a newer unsubscribe wins and malformed entries are skipped',
      () async {
        final store = TubeStore();
        final local = const TubeLibrary().toggle('subscriptions', _video);
        await store.save(1, local);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final removed = local.toggle('subscriptions', _video);
        await store.applySync(1, {
          'entries': {
            ...removed.entries,
            'liked:broken': {'video': 'nope'},
            'liked:no-date': {'video': _video2.toJson()},
          },
          'history': {},
        });
        final merged = await store.load(1);
        expect(merged.list('subscriptions'), isEmpty);
        expect(merged.entries.containsKey('liked:broken'), isFalse);
        expect(merged.entries.containsKey('liked:no-date'), isFalse);
      },
    );
  });

  test('pushConfig keeps what another device saved on the server', () async {
    // Device B already uploaded a subscription this device has never seen.
    final connection = _FakeConnection()
      ..server = {
        'youtube': const TubeLibrary()
            .toggle('subscriptions', _video2)
            .toJson(),
        'globalPlaylists': {'playlists': {}, 'favorites': {}},
      };
    final tube = TubeStore();
    await tube.save(1, const TubeLibrary().toggle('subscriptions', _video));
    final prefs = HomePreferences();
    await LiveTvControlService(connection: connection).pushConfig(
      expectedConnection: 'test',
      profileId: 1,
      sources: const [],
      tmdbApiKey: '',
      profileState: await prefs.liveTvProfileSyncState(1),
    );
    final uploaded = TubeLibrary.fromJson(
      Map<String, dynamic>.from(connection.server['youtube'] as Map),
    );
    expect(
      uploaded.list('subscriptions').map((v) => v.channelId),
      containsAll(['chan-1', 'chan-2']),
    );
    expect(
      (await tube.load(1)).list('subscriptions').map((v) => v.channelId),
      containsAll(['chan-1', 'chan-2']),
    );
  });

  group('playlist playback', () {
    final items = [
      HubItem.song(_song('a')),
      HubItem.song(_song('b')),
      HubItem.youtube(_video),
      HubItem.song(_song('c')),
    ];

    test('groups consecutive songs into one Music queue', () {
      final steps = PlaylistPlayback.segments(items);
      expect(steps.map((s) => s.items.length), [2, 1, 1]);
      expect(steps.map((s) => s.isMusic), [true, false, true]);
    });

    test('shuffle reorders a copy and keeps every item', () {
      final player = PlaylistPlayback(
        profileId: 1,
        open: (_, _) async {},
        random: math.Random(3),
      );
      final shuffled = player.order(items, shuffle: true);
      expect(
        shuffled.map((i) => i.key).toSet(),
        items.map((i) => i.key).toSet(),
      );
      expect(items.first.id, 'a');
      expect(player.order(items, shuffle: false).map((i) => i.id), [
        'a',
        'b',
        'v1',
        'c',
      ]);
    });

    testWidgets('plays mixed items in order and Stop ends playback', (
      tester,
    ) async {
      final opened = <String>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              return const Scaffold();
            },
          ),
        ),
      );
      final player = PlaylistPlayback(
        profileId: 1,
        upNextSeconds: 0,
        open: (_, segment) async =>
            opened.add(segment.items.map((i) => i.id).join(',')),
      );
      final run = player.play(context, name: 'Mix', items: items);
      await tester.pumpAndSettle();
      expect(opened, ['a,b']);
      expect(find.text('Up next in Mix'), findsOneWidget);
      expect(find.text('Video one'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('playlist-up-next-play')));
      await tester.pumpAndSettle();
      expect(opened, ['a,b', 'v1']);
      await tester.tap(find.byKey(const ValueKey('playlist-up-next-stop')));
      await tester.pumpAndSettle();
      await run;
      expect(opened, ['a,b', 'v1']);
    });

    testWidgets('Up next continues on its own after the countdown', (
      tester,
    ) async {
      final opened = <String>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              return const Scaffold();
            },
          ),
        ),
      );
      final player = PlaylistPlayback(
        profileId: 1,
        upNextSeconds: 2,
        open: (_, segment) async => opened.add(segment.first.id),
      );
      final run = player.play(
        context,
        name: 'Mix',
        items: [HubItem.youtube(_video), HubItem.youtube(_video2)],
      );
      await tester.pump();
      expect(find.textContaining('starts in 2s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await run;
      expect(opened, ['v1', 'v2']);
    });
  });
}
