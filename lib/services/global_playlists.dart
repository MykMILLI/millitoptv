import 'dart:convert';
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:pstube_engine/pstube_engine.dart';

import 'music_service.dart';
import 'podcast_service.dart';

enum HubMediaType { channel, movie, series, episode, song, podcast, youtube }

class HubItem {
  final HubMediaType type;
  final String sourceId, id, title, sourceName, subtitle, artwork;
  final Map<String, dynamic> payload;

  const HubItem({
    required this.type,
    required this.sourceId,
    required this.id,
    required this.title,
    required this.sourceName,
    this.subtitle = '',
    this.artwork = '',
    required this.payload,
  });

  static String identity(HubMediaType type, String sourceId, String id) =>
      jsonEncode([type.name, sourceId, id]);
  String get key => identity(type, sourceId, id);
  String get label => switch (type) {
    HubMediaType.channel => 'Channel',
    HubMediaType.movie => 'Movie',
    HubMediaType.series => 'Series',
    HubMediaType.episode => 'Episode',
    HubMediaType.song => 'Song',
    HubMediaType.podcast => 'Podcast',
    HubMediaType.youtube => 'YouTube',
  };

  factory HubItem.song(MusicTrack track) => HubItem(
    type: HubMediaType.song,
    sourceId: 'music',
    id: track.id,
    title: track.title,
    sourceName: 'Music',
    subtitle: '${track.artist} · ${track.album}',
    payload: track.toJson(),
  );

  factory HubItem.podcast(PodcastEpisode episode) => HubItem(
    type: HubMediaType.podcast,
    sourceId: episode.show.id,
    id: episode.id,
    title: episode.title,
    sourceName: 'Podcasts',
    subtitle: episode.show.title,
    artwork: episode.artwork,
    payload: episode.toJson(),
  );

  factory HubItem.youtube(TubeVideo video) => HubItem(
    type: HubMediaType.youtube,
    sourceId: 'youtube',
    id: video.id,
    title: video.title,
    sourceName: 'YouTube',
    subtitle: video.author,
    artwork: video.thumbnail,
    payload: video.toJson(),
  );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'sourceId': sourceId,
    'id': id,
    'title': title,
    'sourceName': sourceName,
    'subtitle': subtitle,
    'artwork': artwork,
    'payload': payload,
  };

  factory HubItem.fromJson(Map<String, dynamic> json) {
    final type = HubMediaType.values.where((v) => v.name == json['type']);
    if (type.isEmpty ||
        json['sourceId'] is! String ||
        (json['sourceId'] as String).isEmpty ||
        json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        json['title'] is! String ||
        (json['title'] as String).trim().isEmpty ||
        json['payload'] is! Map) {
      throw const FormatException('Saved media is incomplete.');
    }
    return HubItem(
      type: type.first,
      sourceId: json['sourceId'] as String,
      id: json['id'] as String,
      title: json['title'] as String,
      sourceName: json['sourceName'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      artwork: json['artwork'] as String? ?? '',
      payload: Map<String, dynamic>.from(json['payload'] as Map),
    );
  }
}

DateTime _updatedAt(Map<String, dynamic> value) {
  final date = DateTime.tryParse(value['updatedAtUtc']?.toString() ?? '');
  if (date == null) {
    throw const FormatException('Playlist update timestamp is invalid.');
  }
  return date.toUtc();
}

class HubPlaylist {
  final String id, name;
  final List<HubItem> items;
  final DateTime updatedAtUtc;
  final bool deleted;
  final String origin;
  const HubPlaylist({
    required this.id,
    required this.name,
    required this.items,
    required this.updatedAtUtc,
    this.deleted = false,
    this.origin = 'global',
  });
  bool get editable => origin == 'global';
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'items': items.map((e) => e.toJson()).toList(),
    'updatedAtUtc': updatedAtUtc.toIso8601String(),
    'deleted': deleted,
  };
  factory HubPlaylist.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        json['name'] is! String ||
        (json['name'] as String).trim().isEmpty ||
        json['items'] is! List) {
      throw const FormatException('Global playlist is incomplete.');
    }
    return HubPlaylist(
      id: json['id'] as String,
      name: json['name'] as String,
      items: (json['items'] as List)
          .map((v) => HubItem.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
      updatedAtUtc: _updatedAt(json),
      deleted: json['deleted'] == true,
    );
  }
}

class HubFavorite {
  final HubItem item;
  final DateTime updatedAtUtc;
  final bool deleted;
  const HubFavorite(this.item, this.updatedAtUtc, {this.deleted = false});
  Map<String, dynamic> toJson() => {
    'item': item.toJson(),
    'updatedAtUtc': updatedAtUtc.toIso8601String(),
    'deleted': deleted,
  };
  factory HubFavorite.fromJson(Map<String, dynamic> json) => HubFavorite(
    HubItem.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
    _updatedAt(json),
    deleted: json['deleted'] == true,
  );
}

class HubLibrary {
  final Map<String, HubPlaylist> playlists;
  final Map<String, HubFavorite> favorites;
  const HubLibrary({this.playlists = const {}, this.favorites = const {}});
  Map<String, dynamic> toJson() => {
    'playlists': playlists.map((k, v) => MapEntry(k, v.toJson())),
    'favorites': favorites.map((k, v) => MapEntry(k, v.toJson())),
  };
  factory HubLibrary.fromJson(Map<String, dynamic> json) {
    final playlists = Map<String, dynamic>.from(json['playlists'] as Map? ?? {});
    final favorites = Map<String, dynamic>.from(json['favorites'] as Map? ?? {});
    final result = HubLibrary(
      playlists: playlists.map(
        (k, v) => MapEntry(k, HubPlaylist.fromJson(Map<String, dynamic>.from(v as Map))),
      ),
      favorites: favorites.map(
        (k, v) => MapEntry(k, HubFavorite.fromJson(Map<String, dynamic>.from(v as Map))),
      ),
    );
    if (result.playlists.entries.any((e) => e.key != e.value.id) ||
        result.favorites.entries.any((e) => e.key != e.value.item.key)) {
      throw const FormatException('Global collection identifiers do not match.');
    }
    return result;
  }
}

class GlobalPlaylistStore {
  static final Map<int, Future<void>> _writes = {};

  Future<T> _update<T>(int profile, Future<T> Function() action) {
    final pending = (_writes[profile] ?? Future<void>.value()).then((_) => action());
    final tail = pending.then<void>((_) {}, onError: (Object e, StackTrace stack) {
      debugPrint('Global playlists could not be updated for profile $profile: $e');
    });
    _writes[profile] = tail;
    unawaited(tail.then((_) {
      if (identical(_writes[profile], tail)) {
        _writes.remove(profile);
      }
    }));
    return pending;
  }
  Future<HubLibrary> load(int profile) async {
    final raw = (await SharedPreferences.getInstance())
        .getString('playlists.hub.v1.$profile');
    return raw == null
        ? const HubLibrary()
        : HubLibrary.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
  }

  Future<void> _save(int profile, HubLibrary library) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      'playlists.hub.v1.$profile',
      jsonEncode(library.toJson()),
    )) {
      throw StateError('Could not save your global playlists.');
    }
  }

  Future<HubPlaylist> savePlaylist(
    int profile, {
    String? id,
    required String name,
    required List<HubItem> items,
  }) => _update(profile, () async {
    if (name.trim().isEmpty) {
      throw const FormatException('Enter a playlist name.');
    }
    final library = await load(profile);
    final playlist = HubPlaylist(
      id: id ?? const Uuid().v4(),
      name: name.trim(),
      items: {for (final item in items) item.key: item}.values.toList(),
      updatedAtUtc: DateTime.now().toUtc(),
    );
    await _save(profile, HubLibrary(
      playlists: {...library.playlists, playlist.id: playlist},
      favorites: library.favorites,
    ));
    return playlist;
  });

  Future<void> deletePlaylist(int profile, String id) => _update(profile, () async {
    final library = await load(profile);
    final previous = library.playlists[id];
    if (previous == null) {
      throw StateError('This playlist no longer exists. Refresh your library.');
    }
    final deleted = HubPlaylist(
      id: id, name: previous.name, items: const [],
      updatedAtUtc: DateTime.now().toUtc(), deleted: true,
    );
    await _save(profile, HubLibrary(
      playlists: {...library.playlists, id: deleted},
      favorites: library.favorites,
    ));
  });

  Future<void> setFavorite(int profile, HubItem item, bool value) => _update(profile, () async {
    final library = await load(profile);
    await _save(profile, HubLibrary(
      playlists: library.playlists,
      favorites: {...library.favorites,
        item.key: HubFavorite(item, DateTime.now().toUtc(), deleted: !value)},
    ));
  });

  Future<void> applySync(int profile, Map<String, dynamic> json) => _update(profile, () async {
    final incoming = HubLibrary.fromJson(json);
    final local = await load(profile);
    final playlists = {...local.playlists};
    final favorites = {...local.favorites};
    for (final entry in incoming.playlists.entries) {
      final previous = playlists[entry.key];
      if (previous == null || entry.value.updatedAtUtc.isAfter(previous.updatedAtUtc)) {
        playlists[entry.key] = entry.value;
      }
    }
    for (final entry in incoming.favorites.entries) {
      final previous = favorites[entry.key];
      if (previous == null || entry.value.updatedAtUtc.isAfter(previous.updatedAtUtc)) {
        favorites[entry.key] = entry.value;
      }
    }
    await _save(profile, HubLibrary(playlists: playlists, favorites: favorites));
  });
}
