import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pstube_engine/pstube_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:millitop_tv/main.dart';
import 'package:millitop_tv/screens/app_settings_screen.dart';
import 'package:millitop_tv/screens/live_tv_media_screen.dart';
import 'package:millitop_tv/screens/live_tv_screen.dart';
import 'package:millitop_tv/screens/media_library_home.dart';
import 'package:millitop_tv/screens/music_screen.dart';
import 'package:millitop_tv/screens/playlists_screen.dart';
import 'package:millitop_tv/screens/podcasts_screen.dart';
import 'package:millitop_tv/screens/youtube_screen.dart';
import 'package:millitop_tv/services/global_playlists.dart';
import 'package:millitop_tv/services/home_preferences.dart';
import 'package:millitop_tv/services/music_service.dart';
import 'package:millitop_tv/services/playlist_hub.dart';
import 'package:millitop_tv/services/podcast_service.dart';
import 'package:millitop_tv/services/tube_library.dart';
import 'package:millitop_tv/theme/millitop_visual_theme.dart';

const _song = MusicTrack(
  id: 'song-1',
  title: 'Favorite song',
  artist: 'Favorite artist',
  album: 'Album',
  durationSeconds: 180,
  streamUrl: 'https://example.invalid/song.mp3',
);
const _show = PodcastShow(
  id: 'show-1',
  title: 'Favorite show',
  author: 'Publisher',
  feedUrl: 'https://example.invalid/feed',
  artwork: '',
);
const _podcast = PodcastEpisode(
  id: 'episode-1',
  title: 'Favorite podcast',
  description: '',
  mediaUrl: 'https://example.invalid/podcast.mp3',
  artwork: '',
  show: _show,
  video: false,
  published: null,
  duration: Duration(minutes: 30),
);
const _video = TubeVideo(
  id: 'video-1',
  title: 'Favorite YouTube',
  author: 'Creator',
);

LiveTvLibraryItem _vod(
  String type, {
  String source = 'provider-1',
  String? id,
}) => LiveTvLibraryItem(
  sourceId: source,
  sourceName: 'Provider $source',
  mediaType: type,
  mediaId: id ?? 'same-id',
  title: 'Favorite $type $source',
  streamUrl: 'https://example.invalid/$type.mp4',
);

Future<HubSnapshot> _seed(int profile) async {
  final preferences = HomePreferences();
  for (final type in ['channel', 'movie', 'series', 'episode']) {
    await preferences.upsertLiveTvFavorite(profile, _vod(type));
  }
  await preferences.upsertLiveTvFavorite(
    profile,
    _vod('movie', source: 'provider-2'),
  );
  await preferences.upsertLiveTvPlaylist(
    profile,
    LiveTvUserPlaylist(
      id: 'vod-list',
      name: 'Provider playlist',
      items: [_vod('movie')],
      updatedAtUtc: DateTime.utc(2026, 11, 1),
    ),
  );
  final music = MusicService();
  await music.setFavorite(profile, _song, true);
  await music.upsertPlaylist(
    profile,
    MusicPlaylist(
      id: 'music-list',
      name: 'Music playlist',
      createdAtUtc: DateTime.utc(2026, 11, 2),
      tracks: [_song],
    ),
  );
  await GlobalPlaylistStore().setFavorite(
    profile,
    HubItem.podcast(_podcast),
    true,
  );
  await PodcastStore().save(profile, const PodcastLibrary(queue: [_podcast]));
  final tube = const TubeLibrary()
      .toggle('liked', _video)
      .toggle('playlist/My videos', _video)
      .toggle('later', _video);
  await TubeStore().save(profile, tube);
  return PlaylistHubRepository().load(profile);
}

class _DelayedRepository extends PlaylistHubRepository {
  final pending = <int, Completer<HubSnapshot>>{};
  @override
  Future<HubSnapshot> load(int profile) =>
      pending.putIfAbsent(profile, Completer<HubSnapshot>.new).future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'aggregates every media type and native collection without source collisions',
    () async {
      final snapshot = await _seed(1);
      expect(snapshot.warnings, isEmpty);
      expect(snapshot.favorites.length, 8);
      expect(
        snapshot.favorites.map((v) => v.type).toSet(),
        HubMediaType.values.toSet(),
      );
      expect(
        snapshot.favorites.where((v) => v.type == HubMediaType.movie).length,
        2,
      );
      expect(
        snapshot.playlists.map((v) => v.name),
        containsAll([
          'Provider playlist',
          'Music playlist',
          'Podcast queue',
          'My videos',
          'Watch later',
        ]),
      );
      expect(snapshot.available.map((v) => v.key).toSet().length, 8);
      expect((await PlaylistHubRepository().load(2)).favorites, isEmpty);
      expect((await PlaylistHubRepository().load(2)).playlists, isEmpty);
    },
  );

  test(
    'mixed-media playlists persist, deduplicate, rename, reorder and delete',
    () async {
      final store = GlobalPlaylistStore();
      final items = [
        HubItem.song(_song),
        HubItem.podcast(_podcast),
        vodHubItem(_vod('movie')),
      ];
      final created = await store.savePlaylist(
        1,
        name: '  My evening  ',
        items: [...items, items.first],
      );
      expect(created.name, 'My evening');
      expect(created.items.map((v) => v.key), items.map((v) => v.key));
      expect((await store.load(2)).playlists, isEmpty);
      await store.savePlaylist(
        1,
        id: created.id,
        name: 'My favorites',
        items: [items.last, items.first],
      );
      final saved = (await store.load(1)).playlists[created.id]!;
      expect(saved.name, 'My favorites');
      expect(saved.items.map((v) => v.type), [
        HubMediaType.movie,
        HubMediaType.song,
      ]);
      await store.deletePlaylist(1, created.id);
      expect((await store.load(1)).playlists[created.id]!.deleted, isTrue);
      expect((await PlaylistHubRepository().load(1)).playlists, isEmpty);
      await expectLater(
        store.savePlaylist(1, name: ' ', items: []),
        throwsFormatException,
      );
    },
  );

  test(
    'concurrent favorites and playlists do not overwrite each other',
    () async {
      await Future.wait([
        GlobalPlaylistStore().savePlaylist(
          1,
          name: 'One',
          items: [HubItem.song(_song)],
        ),
        GlobalPlaylistStore().savePlaylist(
          1,
          name: 'Two',
          items: [HubItem.podcast(_podcast)],
        ),
        GlobalPlaylistStore().setFavorite(1, HubItem.podcast(_podcast), true),
      ]);
      final library = await GlobalPlaylistStore().load(1);
      expect(library.playlists.length, 2);
      expect(library.favorites.length, 1);
    },
  );

  test(
    'sync merges newer records and tombstones without resurrecting deletions',
    () async {
      final store = GlobalPlaylistStore();
      final created = await store.savePlaylist(
        1,
        name: 'Shared',
        items: [HubItem.song(_song)],
      );
      await store.setFavorite(1, HubItem.podcast(_podcast), true);
      final original = (await store.load(1)).toJson();
      await HomePreferences().applyLiveTvProfileSyncState(2, {
        'globalPlaylists': original,
      });
      expect(
        (await store.load(2)).playlists[created.id]!.items.first.type,
        HubMediaType.song,
      );
      await store.deletePlaylist(1, created.id);
      await store.setFavorite(1, HubItem.podcast(_podcast), false);
      final deleted = (await store.load(1)).toJson();
      await store.applySync(2, deleted);
      await store.applySync(2, original);
      final synced = await store.load(2);
      expect(synced.playlists[created.id]!.deleted, isTrue);
      expect(synced.favorites.values.single.deleted, isTrue);
      expect((await PlaylistHubRepository().load(2)).favorites, isEmpty);
      await HomePreferences().applyLiveTvProfileSyncState(2, {
        'youtube': const TubeLibrary().toJson(),
      });
      expect((await store.load(2)).playlists[created.id]!.deleted, isTrue);
    },
  );

  test('removing favorites updates their original native stores', () async {
    final snapshot = await _seed(1);
    final repository = PlaylistHubRepository();
    for (final item in snapshot.favorites) {
      await repository.setFavorite(1, item, false);
    }
    expect((await repository.load(1)).favorites, isEmpty);
    expect(await HomePreferences().liveTvFavorites(1), isEmpty);
    expect(await MusicService().favorites(1), isEmpty);
    expect((await TubeStore().load(1)).list('liked'), isEmpty);
    expect((await repository.load(1)).playlists, isNotEmpty);
  });

  test(
    'channel favorites and removals survive legacy snapshots across sources',
    () async {
      await _seed(1);
      final channel = vodHubItem(_vod('channel'));
      expect(await channelFavoriteKeys(1), contains('provider-1|same-id'));
      await PlaylistHubRepository().setFavorite(1, channel, false);
      expect(
        await channelFavoriteKeys(1),
        isNot(contains('provider-1|same-id')),
      );
      await HomePreferences().applyLiveTvProfileSyncState(1, {
        'favorites': [_vod('channel').toJson()],
      });
      expect(await channelFavoriteKeys(1), isEmpty);
      expect(
        (await PlaylistHubRepository().load(
          1,
        )).favorites.where((v) => v.type == HubMediaType.channel),
        isEmpty,
      );
      await PlaylistHubRepository().setFavorite(
        1,
        vodHubItem(_vod('channel', source: 'provider-2')),
        true,
      );
      expect(await channelFavoriteKeys(1), {'provider-2|same-id'});
      expect(await channelFavoriteKeys(2), isEmpty);
    },
  );

  test(
    'suggestions adapt to history and artist interests without changing saved playlists',
    () {
      final a = HubItem.song(_song);
      final b = HubItem.song(
        const MusicTrack(
          id: 'other',
          title: 'Another favorite',
          artist: 'Another artist',
          album: 'Album',
          durationSeconds: 1,
        ),
      );
      final similar = HubItem.song(
        const MusicTrack(
          id: 'new-song',
          title: 'Recently heard',
          artist: 'Favorite artist',
          album: 'Album',
          durationSeconds: 1,
        ),
      );
      final movie = vodHubItem(_vod('movie'));
      final list = HubPlaylist(
        id: 'mine',
        name: 'Keep my order',
        items: [b, movie, a],
        updatedAtUtc: DateTime.utc(2026),
      );
      final snapshot = HubSnapshot(
        favorites: [a, b, movie],
        recent: [similar],
        playlists: [list],
      );
      expect(snapshot.forYou.first.key, a.key);
      final changed = HubSnapshot(
        favorites: snapshot.favorites,
        recent: [movie],
        playlists: snapshot.playlists,
      );
      expect(changed.forYou.first.key, movie.key);
      expect(list.items.map((v) => v.key), [b.key, movie.key, a.key]);
    },
  );

  test(
    'music sessions excluded from recommendations do not influence suggestions',
    () async {
      await MusicService().setFavorite(1, _song, true);
      await MusicService().upsertRecentlyPlayed(1, _song);
      final event = MusicPlayEvent(
        eventId: 'event',
        trackId: _song.id,
        title: _song.title,
        artist: _song.artist,
        album: _song.album,
        sessionId: 'private-session',
        listenedMs: 60000,
        trackDurationMs: 180000,
        countedAsPlay: true,
        excludedFromRecommendations: true,
        offline: false,
        startedAtUtc: DateTime.utc(2026, 11, 7),
        endedAtUtc: DateTime.utc(2026, 11, 7, 0, 1),
        ingestedAtUtc: DateTime.utc(2026, 11, 7, 0, 1),
      );
      await (await SharedPreferences.getInstance()).setString(
        'music.history.play-events.v1.1',
        jsonEncode([event.toJson()]),
      );
      final snapshot = await PlaylistHubRepository().load(1);
      expect(snapshot.favorites.map((v) => v.id), contains(_song.id));
      expect(
        snapshot.recent.where((v) => v.type == HubMediaType.song),
        isEmpty,
      );
      expect(snapshot.playCounts, isEmpty);
    },
  );

  test(
    'bad source data is reported while other collections remain accessible',
    () async {
      await _seed(1);
      await (await SharedPreferences.getInstance()).setString(
        'music.favorites.v1.1',
        'broken',
      );
      final snapshot = await PlaylistHubRepository().load(1);
      expect(
        snapshot.warnings.join(),
        contains('Music collections could not load'),
      );
      expect(
        snapshot.favorites.any((v) => v.type == HubMediaType.podcast),
        isTrue,
      );
      expect(
        snapshot.favorites.any((v) => v.type == HubMediaType.movie),
        isTrue,
      );
      await expectLater(
        GlobalPlaylistStore().applySync(1, {
          'playlists': {
            'bad': {'id': 'bad'},
          },
        }),
        throwsFormatException,
      );
    },
  );

  test('destinations carry exact profile, source and media identifiers', () {
    for (final kind in ['movie', 'series', 'episode']) {
      final saved = _vod(kind, source: 'provider-2');
      final screen = hubDestination(7, vodHubItem(saved)) as LiveTvMediaScreen;
      expect(screen.profileId, 7);
      expect(screen.initialSourceId, saved.sourceId);
      expect(screen.initialLibraryItem!.key, saved.key);
    }
    final channel =
        hubDestination(7, vodHubItem(_vod('channel'))) as LiveTvScreen;
    expect(channel.profileId, 7);
    expect(channel.initialChannelId, 'same-id');
    expect(channel.initialSourceId, 'provider-1');
    final music = hubDestination(7, HubItem.song(_song)) as MusicScreen;
    expect(music.initialTrack!.id, _song.id);
    expect(music.profileId, 7);
    final podcast =
        hubDestination(7, HubItem.podcast(_podcast)) as PodcastsScreen;
    expect(podcast.initialEpisode!.key, _podcast.key);
    expect(podcast.profileId, 7);
    final video = hubDestination(7, HubItem.youtube(_video)) as YouTubeScreen;
    expect(video.initialVideo!.id, _video.id);
    expect(video.profileId, 7);
  });

  testWidgets('favorites tab searches, filters and opens every media type', (
    tester,
  ) async {
    await _seed(1);
    final opened = <HubItem>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistsScreen(
          profileId: 1,
          onOpenItem: (profile, item) async {
            expect(profile, 1);
            opened.add(item);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favorites (8)'));
    await tester.pumpAndSettle();
    for (final item in (await PlaylistHubRepository().load(1)).favorites) {
      await tester.enterText(find.byType(TextField), item.title);
      await tester.pumpAndSettle();
      final row = find.widgetWithText(ListTile, item.title);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(
        opened,
        isNotEmpty,
        reason: 'Tapping ${item.title} must open its saved media.',
      );
      expect(opened.last.key, item.key);
    }
    await tester.enterText(find.byType(TextField), 'does not exist');
    await tester.pumpAndSettle();
    expect(find.textContaining('No matching favorites'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Movies').first);
    await tester.tap(find.text('Movies').first);
    await tester.pumpAndSettle();
    expect(find.text(_song.title), findsNothing);
    expect(find.text(_vod('movie').title), findsOneWidget);
  });

  testWidgets(
    'creates a user-controlled playlist and adds a mixed media item',
    (tester) async {
      await _seed(1);
      await tester.pumpWidget(
        const MaterialApp(home: PlaylistsScreen(profileId: 1)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'My personal playlist',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        (await GlobalPlaylistStore().load(1)).playlists.values.single.name,
        'My personal playlist',
      );
      await tester.scrollUntilVisible(
        find.text('My personal playlist'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('My personal playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add saved media'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_podcast.title));
      await tester.pumpAndSettle();
      expect(find.text(_podcast.title), findsOneWidget);
      final library = await GlobalPlaylistStore().load(1);
      expect(
        library.playlists.values.single.items.single.type,
        HubMediaType.podcast,
      );
      await tester.tap(find.byTooltip('Add saved media'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, _song.title));
      await tester.pumpAndSettle();
      expect(
        (await GlobalPlaylistStore().load(
          1,
        )).playlists.values.single.items.map((v) => v.type),
        [HubMediaType.podcast, HubMediaType.song],
      );
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      expect(
        (await GlobalPlaylistStore().load(
          1,
        )).playlists.values.single.items.map((v) => v.type),
        [HubMediaType.song, HubMediaType.podcast],
      );
      await tester.tap(find.byTooltip('Remove from playlist').first);
      await tester.pumpAndSettle();
      expect(
        (await GlobalPlaylistStore().load(
          1,
        )).playlists.values.single.items.single.type,
        HubMediaType.podcast,
      );
    },
  );

  testWidgets(
    'source filtering preserves distinct movie IDs across providers',
    (tester) async {
      await _seed(1);
      await tester.pumpWidget(
        const MaterialApp(home: PlaylistsScreen(profileId: 1)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorites (8)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Favorite movie');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Provider provider-2').last);
      await tester.pumpAndSettle();
      expect(find.text(_vod('movie').title), findsNothing);
      expect(
        find.text(_vod('movie', source: 'provider-2').title),
        findsOneWidget,
      );
    },
  );

  testWidgets('TV directional keys move focus between controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      const MaterialApp(home: PlaylistsScreen(profileId: 1)),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final first = FocusManager.instance.primaryFocus;
    expect(first, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNot(same(first)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile change cannot show a previous user delayed result', (
    tester,
  ) async {
    final repository = _DelayedRepository();
    await tester.pumpWidget(
      MaterialApp(home: PlaylistsScreen(profileId: 1, repository: repository)),
    );
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(home: PlaylistsScreen(profileId: 2, repository: repository)),
    );
    repository.pending[1]!.complete(
      HubSnapshot(favorites: [HubItem.song(_song)]),
    );
    repository.pending[2]!.complete(const HubSnapshot());
    await tester.pumpAndSettle();
    expect(find.text('Favorites (0)'), findsOneWidget);
    expect(find.text(_song.title), findsNothing);
  });

  testWidgets('a playlist dialog cannot save into a newly selected profile', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: PlaylistsScreen(profileId: 1)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New playlist'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      const MaterialApp(home: PlaylistsScreen(profileId: 2)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField),
      'Previous user playlist',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await GlobalPlaylistStore().load(1)).playlists, isEmpty);
    expect((await GlobalPlaylistStore().load(2)).playlists, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home replaces Files and Settings retains folder access', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const MaterialApp(home: Launcher(profileId: 1)));
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsNothing);
    expect(find.text('Playlists'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistsScreen), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(home: AppSettingsScreen(profileId: 1)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Files'));
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaLibraryHome), findsOneWidget);
  });

  for (final size in [
    const Size(320, 640),
    const Size(360, 740),
    const Size(412, 915),
    const Size(740, 360),
    const Size(1280, 720),
    const Size(1920, 1080),
  ]) {
    for (final theme in MillitopThemeId.values) {
      testWidgets('populated Playlists fit $size in ${theme.name}', (
        tester,
      ) async {
        await _seed(1);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final themes = MillitopThemeController.instance;
        final previous = themes.current.id;
        themes.setTheme(theme);
        addTearDown(() => themes.setTheme(previous));
        await tester.pumpWidget(
          MaterialApp(
            theme: themes.materialTheme,
            home: PlaylistsScreen(profileId: 1, onOpenItem: (_, __) async {}),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Favorites (8)'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await GlobalPlaylistStore().savePlaylist(
          1,
          name: 'Mixed night',
          items: [
            HubItem.song(_song),
            HubItem.youtube(_video),
            HubItem.podcast(_podcast),
          ],
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            theme: themes.materialTheme,
            home: PlaylistsScreen(profileId: 1, onOpenItem: (_, __) async {}),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Playlists ('));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Mixed night'),
          200,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mixed night'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('playlist-play')), findsOneWidget);
        expect(find.byKey(const ValueKey('playlist-shuffle')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
