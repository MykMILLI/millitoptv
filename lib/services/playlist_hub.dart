import 'package:flutter/foundation.dart';
import 'package:pstube_engine/pstube_engine.dart';

import 'global_playlists.dart';
import 'home_preferences.dart';
import 'music_service.dart';
import 'podcast_service.dart';
import 'tube_library.dart';

HubItem vodHubItem(LiveTvLibraryItem item) => HubItem(
  type: switch (item.mediaType) {
    'channel' => HubMediaType.channel,
    'movie' => HubMediaType.movie,
    'series' => HubMediaType.series,
    'episode' => HubMediaType.episode,
    _ => throw FormatException(
      'Unsupported saved media type: ${item.mediaType}',
    ),
  },
  sourceId: item.sourceId,
  id: item.mediaId,
  title: item.title,
  sourceName: item.sourceName,
  subtitle: item.subtitle ?? '',
  artwork: item.posterUrl ?? '',
  payload: item.toJson(),
);

Future<Set<String>> channelFavoriteKeys(int profile) async {
  final legacy = await HomePreferences().liveTvFavorites(profile);
  final records = (await GlobalPlaylistStore().load(profile)).favorites.values;
  final keys = {
    for (final item in legacy.where((v) => v.mediaType == 'channel'))
      '${item.sourceId}|${item.mediaId}',
  };
  for (final favorite in records.where((v) => v.item.type == HubMediaType.channel)) {
    final key = '${favorite.item.sourceId}|${favorite.item.id}';
    if (favorite.deleted) {
      keys.remove(key);
    } else {
      keys.add(key);
    }
  }
  return keys;
}

class HubSnapshot {
  final List<HubItem> favorites, recent;
  final List<HubPlaylist> playlists;
  final List<String> warnings;
  final Map<String, int> playCounts;
  const HubSnapshot({
    this.favorites = const [],
    this.recent = const [],
    this.playlists = const [],
    this.warnings = const [],
    this.playCounts = const {},
  });

  List<HubItem> get available => {
    for (final item in [
      ...recent,
      ...playlists.expand((p) => p.items),
      ...favorites,
    ])
      item.key: item,
  }.values.toList();

  List<HubItem> get forYou {
    final affinity = <HubMediaType, int>{};
    final interests = <(HubMediaType, String), int>{};
    (HubMediaType, String) interest(HubItem item) => (
      item.type,
      switch (item.type) {
        HubMediaType.song => item.payload['artist']?.toString() ?? '',
        HubMediaType.youtube => item.payload['channelId']?.toString() ?? '',
        _ => item.sourceId,
      },
    );
    for (final item in recent) {
      affinity.update(item.type, (n) => n + 1, ifAbsent: () => 1);
      interests.update(interest(item), (n) => n + 1, ifAbsent: () => 1);
    }
    final recency = {for (var i = 0; i < recent.length; i++) recent[i].key: i};
    double score(HubItem item) =>
        (affinity[item.type] ?? 0) * 2 +
        (interests[interest(item)] ?? 0) * 3 +
        (playCounts[item.key] ?? 0) * 4 +
        (recency.containsKey(item.key) ? 30 / (1 + recency[item.key]!) : 0);
    final ranked = List<HubItem>.from(favorites)
      ..sort((a, b) {
        final compared = score(b).compareTo(score(a));
        return compared != 0 ? compared : a.title.compareTo(b.title);
      });
    return ranked.take(12).toList();
  }
}

class PlaylistHubRepository {
  final preferences = HomePreferences();
  final music = MusicService();
  final podcasts = PodcastStore();
  final tube = TubeStore();
  final store = GlobalPlaylistStore();

  Future<HubSnapshot> load(int profile) async {
    final favorites = <HubItem>[], recent = <HubItem>[];
    final playlists = <HubPlaylist>[];
    final warnings = <String>[];
    final counts = <String, int>{};
    HubLibrary? global;
    final dated = <({HubItem item, DateTime date})>[];
    Future<void> read(String label, Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        debugPrint('$label collections could not load: $e');
        warnings.add('$label collections could not load. $e');
      }
    }

    await Future.wait([
      read('Global playlists', () async {
        final library = await store.load(profile);
        global = library;
        favorites.addAll(
          library.favorites.values.where((f) => !f.deleted).map((f) => f.item),
        );
        playlists.addAll(library.playlists.values.where((p) => !p.deleted));
      }),
      read('Movies & TV', () async {
        favorites.addAll(
          (await preferences.liveTvFavorites(profile)).map(vodHubItem),
        );
        playlists.addAll(
          (await preferences.liveTvPlaylists(profile)).map(
            (p) => HubPlaylist(
              id: 'vod:${p.id}',
              name: p.name,
              items: p.items.map(vodHubItem).toList(),
              updatedAtUtc: p.updatedAtUtc,
              origin: 'Movies & TV',
            ),
          ),
        );
        for (final item in await preferences.liveTvRecentMedia(profile)) {
          dated.add((
            item: vodHubItem(
              LiveTvLibraryItem(
                sourceId: item.sourceId,
                sourceName: item.sourceName ?? item.sourceId,
                mediaType: item.mediaType,
                mediaId: item.mediaId,
                title: item.title,
                subtitle: item.subtitle,
                posterUrl: item.posterUrl,
              ),
            ),
            date: item.watchedAtUtc,
          ));
        }
        for (final item in await preferences.liveTvRecentChannels(profile)) {
          dated.add((
            item: vodHubItem(
              LiveTvLibraryItem(
                sourceId: item.sourceId,
                sourceName: item.sourceName,
                mediaType: 'channel',
                mediaId: item.channelId,
                title: item.channelName,
              ),
            ),
            date: item.watchedAtUtc,
          ));
        }
      }),
      read('Music', () async {
        favorites.addAll((await music.favorites(profile)).map(HubItem.song));
        playlists.addAll(
          (await music.playlists(profile)).map(
            (p) => HubPlaylist(
              id: 'music:${p.id}',
              name: p.name,
              items: p.tracks.map(HubItem.song).toList(),
              updatedAtUtc: p.createdAtUtc,
              origin: 'Music',
            ),
          ),
        );
        final tracks = await music.recentlyPlayed(profile);
        final events = await music.playEvents(profile);
        final excluded = (await music.excludedRecommendationSessions(
          profile,
        )).toSet();
        if (events.isEmpty && excluded.isEmpty) {
          recent.addAll(tracks.map(HubItem.song));
          counts.addAll(
            (await music.playCounts(profile)).map(
              (id, n) =>
                  MapEntry(HubItem.identity(HubMediaType.song, 'music', id), n),
            ),
          );
        } else {
          final allowed = events
              .where(
                (event) =>
                    !event.excludedFromRecommendations &&
                    !excluded.contains(event.sessionId),
              )
              .toList();
          for (final track in tracks) {
            final matches = allowed.where((event) => event.trackId == track.id);
            if (matches.isNotEmpty) {
              dated.add((
                item: HubItem.song(track),
                date: matches.first.endedAtUtc,
              ));
            }
          }
          for (final event in allowed.where((event) => event.countedAsPlay)) {
            counts.update(
              HubItem.identity(HubMediaType.song, 'music', event.trackId),
              (n) => n + 1,
              ifAbsent: () => 1,
            );
          }
        }
      }),
      read('Podcasts', () async {
        final library = await podcasts.load(profile);
        if (library.queue.isNotEmpty) {
          playlists.add(
            HubPlaylist(
              id: 'podcasts:queue',
              name: 'Podcast queue',
              items: library.queue.map(HubItem.podcast).toList(),
              updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              origin: 'Podcasts',
            ),
          );
        }
        for (final value in library.progress.values) {
          if (value is! Map || value['episode'] is! Map) {
            throw const FormatException('Podcast history entry is invalid.');
          }
          final date = DateTime.tryParse(
            value['updatedAtUtc']?.toString() ?? '',
          );
          if (date == null) {
            throw const FormatException(
              'Podcast history timestamp is invalid.',
            );
          }
          dated.add((
            item: HubItem.podcast(
              PodcastEpisode.fromJson(
                Map<String, dynamic>.from(value['episode'] as Map),
              ),
            ),
            date: date,
          ));
        }
      }),
      read('YouTube', () async {
        final library = await tube.load(profile);
        favorites.addAll(library.list('liked').map(HubItem.youtube));
        for (final name in [...library.playlists, 'later']) {
          final items = library.list(name);
          if (items.isEmpty) continue;
          playlists.add(
            HubPlaylist(
              id: 'youtube:$name',
              name: name == 'later' ? 'Watch later' : name.substring(9),
              items: items.map(HubItem.youtube).toList(),
              updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              origin: 'YouTube',
            ),
          );
        }
        for (final video in library.watched) {
          final value = library.history[video.id];
          final date = value is Map
              ? DateTime.tryParse(value['updatedAtUtc']?.toString() ?? '')
              : null;
          if (date == null) {
            throw const FormatException(
              'YouTube history timestamp is invalid.',
            );
          }
          dated.add((item: HubItem.youtube(video), date: date));
        }
      }),
    ]);
    dated.sort((a, b) => b.date.compareTo(a.date));
    recent.insertAll(0, dated.map((v) => v.item));
    playlists.sort((a, b) => b.updatedAtUtc.compareTo(a.updatedAtUtc));
    final mergedFavorites = {for (final item in favorites) item.key: item};
    for (final record in global?.favorites.values ?? <HubFavorite>[]) {
      if (record.deleted) {
        mergedFavorites.remove(record.item.key);
      } else {
        mergedFavorites[record.item.key] = record.item;
      }
    }
    return HubSnapshot(
      favorites: mergedFavorites.values.toList(),
      recent: {for (final item in recent) item.key: item}.values.toList(),
      playlists: playlists,
      warnings: warnings,
      playCounts: counts,
    );
  }

  Future<void> setFavorite(int profile, HubItem item, bool value) async {
    switch (item.type) {
      case HubMediaType.song:
        await music.setFavorite(
          profile,
          MusicTrack.fromJson(item.payload),
          value,
        );
      case HubMediaType.youtube:
        final video = TubeVideo.fromJson(item.payload);
        final library = await tube.load(profile);
        final target = library.list('liked').any((v) => v.id == video.id);
        if (target != value) {
          await tube.save(profile, library.toggle('liked', video));
        }
      case HubMediaType.podcast:
        await store.setFavorite(profile, item, value);
      case HubMediaType.channel:
        await store.setFavorite(profile, item, value);
        final saved = LiveTvLibraryItem.fromJson(item.payload);
        if (value) {
          await preferences.upsertLiveTvFavorite(profile, saved);
        } else {
          await preferences.removeLiveTvFavorite(profile, sourceId: saved.sourceId,
            mediaType: saved.mediaType, mediaId: saved.mediaId);
        }
      case HubMediaType.movie:
      case HubMediaType.series:
      case HubMediaType.episode:
        final saved = LiveTvLibraryItem.fromJson(item.payload);
        if (value) {
          await preferences.upsertLiveTvFavorite(profile, saved);
        } else {
          await preferences.removeLiveTvFavorite(
            profile,
            sourceId: saved.sourceId,
            mediaType: saved.mediaType,
            mediaId: saved.mediaId,
          );
        }
    }
  }
}
