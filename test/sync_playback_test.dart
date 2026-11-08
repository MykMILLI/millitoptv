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

    test(
      'session entries keep distinct queue identities for repeated media',
      () {
        final repeated = HubItem.youtube(_video);
        final entries = PlaylistPlayback.segments([repeated, repeated]).first;
        expect(entries.entries.length, 1);
        final session = PlaylistPlaybackSession(
          profileId: 1,
          playlistId: 'mix',
          playlistName: 'Mix',
          entries: [
            const PlaylistPlaybackEntry(
              entryId: 'a',
              item: HubItem(
                type: HubMediaType.youtube,
                sourceId: 'youtube',
                id: 'v1',
                title: 'Video one',
                sourceName: 'YouTube',
                payload: {
                  'id': 'v1',
                  'title': 'Video one',
                  'author': 'Creator',
                },
              ),
            ),
            const PlaylistPlaybackEntry(
              entryId: 'b',
              item: HubItem(
                type: HubMediaType.youtube,
                sourceId: 'youtube',
                id: 'v1',
                title: 'Video one',
                sourceName: 'YouTube',
                payload: {
                  'id': 'v1',
                  'title': 'Video one',
                  'author': 'Creator',
                },
              ),
            ),
          ],
          startIndex: 0,
          shuffled: false,
        );
        expect(session.entries[0].entryId, isNot(session.entries[1].entryId));
        expect(session.entries[0].item.id, session.entries[1].item.id);
      },
    );

    test('pending queue reorder and removal keep current item protected', () {
      final session = PlaylistPlaybackSession(
        profileId: 1,
        playlistId: 'mix',
        playlistName: 'Mix',
        entries: [
          PlaylistPlaybackEntry(entryId: 'now', item: HubItem.youtube(_video)),
          PlaylistPlaybackEntry(entryId: 'two', item: HubItem.youtube(_video2)),
          PlaylistPlaybackEntry(
            entryId: 'three',
            item: HubItem.song(_song('c')),
          ),
        ],
        startIndex: 0,
        shuffled: false,
      );
      expect(session.reorderPending(0, 1), isFalse);
      expect(session.removePending('now'), isFalse);
      expect(session.reorderPending(2, 1), isTrue);
      expect(session.entries[1].entryId, 'three');
      expect(session.removePending('two'), isTrue);
      expect(session.entries.map((entry) => entry.entryId), ['now', 'three']);
    });

    test('shuffle reorders a copy and keeps every item', () {
      final player = PlaylistPlayback(
        profileId: 1,
        open: (_, __, ___) async => const PlaylistPlaybackExit.explicitBack(),
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

    testWidgets('plays mixed items in order and explicit stop ends playback', (
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
        open: (_, __, segment) async {
          opened.add(segment.items.map((i) => i.id).join(','));
          if (opened.length == 1) {
            return const PlaylistPlaybackExit.completed();
          }
          return const PlaylistPlaybackExit.explicitStop();
        },
      );
      final run = player.play(
        context,
        playlistId: 'mix',
        name: 'Mix',
        items: items,
      );
      await tester.pump();
      await run;
      expect(opened, ['a,b', 'v1']);
    });

    testWidgets('completion advances once without a blocking up-next modal', (
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
        open: (_, __, segment) async {
          opened.add(segment.first.item.id);
          return const PlaylistPlaybackExit.completed();
        },
      );
      final run = player.play(
        context,
        playlistId: 'mix',
        name: 'Mix',
        items: [HubItem.youtube(_video), HubItem.youtube(_video2)],
      );
      await run;
      expect(opened, ['v1', 'v2']);
      expect(find.byKey(const ValueKey('playlist-up-next')), findsNothing);
    });

    testWidgets(
      'switch commands move across provider boundaries without reshuffling',
      (tester) async {
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
        final mixed = [
          HubItem.youtube(_video),
          HubItem(
            type: HubMediaType.movie,
            sourceId: 'provider-a',
            id: 'movie-b',
            title: 'Movie B',
            sourceName: 'Provider A',
            payload: const {
              'sourceId': 'provider-a',
              'sourceName': 'Provider A',
              'mediaType': 'movie',
              'mediaId': 'movie-b',
              'title': 'Movie B',
              'streamUrl': 'https://example.invalid/movie-b.mp4',
            },
          ),
          HubItem.youtube(_video2),
        ];
        final player = PlaylistPlayback(
          profileId: 1,
          random: math.Random(2),
          open: (_, session, segment) async {
            opened.add(segment.first.item.id);
            if (opened.length == 1) {
              final target = session.entries.firstWhere(
                (entry) => entry.item.id == 'movie-b',
              );
              return PlaylistPlaybackExit.switched(target.entryId);
            }
            return const PlaylistPlaybackExit.explicitStop();
          },
        );
        await player.play(
          context,
          playlistId: 'mixed',
          name: 'Mixed',
          items: mixed,
          shuffle: true,
        );
        expect(opened.length, 2);
        expect(opened[1], 'movie-b');
      },
    );
  });
}
