import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class MusicServerConfig {
  final String baseUrl;
  final String username;
  final String password;
  const MusicServerConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  Map<String, dynamic> toJson({bool includePassword = true}) => {
    'baseUrl': baseUrl,
    'username': username,
    if (includePassword) 'password': password,
  };

  static MusicServerConfig fromJson(Map<String, dynamic> json) {
    final baseUrl = json['baseUrl']?.toString().trim() ?? '';
    final username = json['username']?.toString().trim() ?? '';
    final password = json['password']?.toString() ?? '';
    if (baseUrl.isEmpty || username.isEmpty || password.isEmpty) {
      throw const FormatException('Music server settings are incomplete.');
    }
    return MusicServerConfig(
      baseUrl: validateMusicServerUrl(baseUrl),
      username: username,
      password: password,
    );
  }
}

class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String? genre;
  final int? year;
  final int durationSeconds;
  final String? coverArtId;
  final String? streamUrl;
  const MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    this.genre,
    this.year,
    this.coverArtId,
    this.streamUrl,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'genre': genre,
    'year': year,
    'durationSeconds': durationSeconds,
    'coverArtId': coverArtId,
    'streamUrl': streamUrl,
  };

  static MusicTrack fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final title = json['title']?.toString().trim() ?? '';
    final artist = json['artist']?.toString().trim() ?? '';
    final album = json['album']?.toString().trim() ?? '';
    if (id.isEmpty || title.isEmpty || artist.isEmpty || album.isEmpty) {
      throw const FormatException('Music track payload is incomplete.');
    }
    final duration = int.tryParse(json['durationSeconds']?.toString() ?? '');
    return MusicTrack(
      id: id,
      title: title,
      artist: artist,
      album: album,
      genre: json['genre']?.toString().trim(),
      year: int.tryParse(json['year']?.toString() ?? ''),
      durationSeconds: duration == null || duration < 0 ? 0 : duration,
      coverArtId: json['coverArtId']?.toString().trim(),
      streamUrl: json['streamUrl']?.toString().trim(),
    );
  }
}

class MusicStation {
  final String id;
  final String name;
  final String seedTrackId;
  final String seedTitle;
  final DateTime createdAtUtc;
  final List<MusicTrack> queue;
  const MusicStation({
    required this.id,
    required this.name,
    required this.seedTrackId,
    required this.seedTitle,
    required this.createdAtUtc,
    required this.queue,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'seedTrackId': seedTrackId,
    'seedTitle': seedTitle,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'queue': queue.map((track) => track.toJson()).toList(),
  };

  static MusicStation fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final seedTrackId = json['seedTrackId']?.toString().trim() ?? '';
    final seedTitle = json['seedTitle']?.toString().trim() ?? '';
    if (id.isEmpty ||
        name.isEmpty ||
        seedTrackId.isEmpty ||
        seedTitle.isEmpty) {
      throw const FormatException('Music station payload is incomplete.');
    }
    final createdAt =
        DateTime.tryParse(json['createdAtUtc']?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
    final queueRaw = json['queue'];
    final queue = <MusicTrack>[];
    if (queueRaw is List) {
      for (final entry in queueRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          queue.add(MusicTrack.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {}
      }
    }
    return MusicStation(
      id: id,
      name: name,
      seedTrackId: seedTrackId,
      seedTitle: seedTitle,
      createdAtUtc: createdAt,
      queue: queue,
    );
  }
}

class MusicPlaylist {
  final String id;
  final String name;
  final DateTime createdAtUtc;
  final List<MusicTrack> tracks;
  const MusicPlaylist({
    required this.id,
    required this.name,
    required this.createdAtUtc,
    required this.tracks,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'tracks': tracks.map((track) => track.toJson()).toList(),
  };

  static MusicPlaylist fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Music playlist payload is incomplete.');
    }
    final createdAt =
        DateTime.tryParse(json['createdAtUtc']?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
    final tracksRaw = json['tracks'];
    final tracks = <MusicTrack>[];
    if (tracksRaw is List) {
      for (final entry in tracksRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          tracks.add(MusicTrack.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {}
      }
    }

    return MusicPlaylist(
      id: id,
      name: name,
      createdAtUtc: createdAt,
      tracks: tracks,
    );
  }
}

class MusicDownloadEntry {
  final String trackId;
  final String filePath;
  final String sha256Hex;
  final int sizeBytes;
  final DateTime updatedAtUtc;
  const MusicDownloadEntry({
    required this.trackId,
    required this.filePath,
    required this.sha256Hex,
    required this.sizeBytes,
    required this.updatedAtUtc,
  });

  Map<String, dynamic> toJson() => {
    'trackId': trackId,
    'filePath': filePath,
    'sha256Hex': sha256Hex,
    'sizeBytes': sizeBytes,
    'updatedAtUtc': updatedAtUtc.toIso8601String(),
  };

  static MusicDownloadEntry fromJson(Map<String, dynamic> json) {
    final trackId = json['trackId']?.toString().trim() ?? '';
    final filePath = json['filePath']?.toString().trim() ?? '';
    final sha = json['sha256Hex']?.toString().trim() ?? '';
    if (trackId.isEmpty || filePath.isEmpty || sha.isEmpty) {
      throw const FormatException('Music download entry is incomplete.');
    }
    return MusicDownloadEntry(
      trackId: trackId,
      filePath: filePath,
      sha256Hex: sha,
      sizeBytes: int.tryParse(json['sizeBytes']?.toString() ?? '') ?? 0,
      updatedAtUtc:
          DateTime.tryParse(json['updatedAtUtc']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}

class MusicPlayEvent {
  final String eventId;
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final String? playlistId;
  final String? playlistName;
  final String sessionId;
  final int listenedMs;
  final int trackDurationMs;
  final bool countedAsPlay;
  final bool excludedFromRecommendations;
  final bool offline;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;
  final DateTime ingestedAtUtc;

  const MusicPlayEvent({
    required this.eventId,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.sessionId,
    required this.listenedMs,
    required this.trackDurationMs,
    required this.countedAsPlay,
    required this.excludedFromRecommendations,
    required this.offline,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.ingestedAtUtc,
    this.playlistId,
    this.playlistName,
  });

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'trackId': trackId,
    'title': title,
    'artist': artist,
    'album': album,
    'playlistId': playlistId,
    'playlistName': playlistName,
    'sessionId': sessionId,
    'listenedMs': listenedMs,
    'trackDurationMs': trackDurationMs,
    'countedAsPlay': countedAsPlay,
    'excludedFromRecommendations': excludedFromRecommendations,
    'offline': offline,
    'startedAtUtc': startedAtUtc.toIso8601String(),
    'endedAtUtc': endedAtUtc.toIso8601String(),
    'ingestedAtUtc': ingestedAtUtc.toIso8601String(),
  };

  static MusicPlayEvent fromJson(Map<String, dynamic> json) {
    final eventId = json['eventId']?.toString().trim() ?? '';
    final trackId = json['trackId']?.toString().trim() ?? '';
    final title = json['title']?.toString().trim() ?? '';
    final artist = json['artist']?.toString().trim() ?? '';
    final album = json['album']?.toString().trim() ?? '';
    final sessionId = json['sessionId']?.toString().trim() ?? '';
    if (eventId.isEmpty ||
        trackId.isEmpty ||
        title.isEmpty ||
        artist.isEmpty ||
        album.isEmpty ||
        sessionId.isEmpty) {
      throw const FormatException('Music play event payload is incomplete.');
    }
    final startedAt =
        DateTime.tryParse(json['startedAtUtc']?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
    final endedAt =
        DateTime.tryParse(json['endedAtUtc']?.toString() ?? '')?.toUtc() ??
        startedAt;
    final ingestedAt =
        DateTime.tryParse(json['ingestedAtUtc']?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
    return MusicPlayEvent(
      eventId: eventId,
      trackId: trackId,
      title: title,
      artist: artist,
      album: album,
      playlistId: json['playlistId']?.toString().trim(),
      playlistName: json['playlistName']?.toString().trim(),
      sessionId: sessionId,
      listenedMs: int.tryParse(json['listenedMs']?.toString() ?? '') ?? 0,
      trackDurationMs:
          int.tryParse(json['trackDurationMs']?.toString() ?? '') ?? 0,
      countedAsPlay: json['countedAsPlay'] == true,
      excludedFromRecommendations: json['excludedFromRecommendations'] == true,
      offline: json['offline'] == true,
      startedAtUtc: startedAt,
      endedAtUtc: endedAt.isBefore(startedAt) ? startedAt : endedAt,
      ingestedAtUtc: ingestedAt,
    );
  }
}

String validateMusicServerUrl(String input) {
  final parsed = Uri.tryParse(input.trim());
  if (parsed == null ||
      !parsed.hasAuthority ||
      parsed.host.trim().isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      (parsed.path.isNotEmpty && parsed.path != '/')) {
    throw const FormatException(
      'Use a server origin only, for example https://music.example.com',
    );
  }
  if (parsed.scheme != 'https' && parsed.scheme != 'http') {
    throw const FormatException('Use HTTP or HTTPS for the music server.');
  }
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
  ).toString();
}

class MusicService {
  static const _storage = FlutterSecureStorage();
  static const _passwordKeyPrefix = 'music.navidrome.password.v1.';
  static const _configKeyPrefix = 'music.navidrome.config.v1.';
  static const _stationsKeyPrefix = 'music.stations.v1.';
  static const _recentKeyPrefix = 'music.recent.v1.';
  static const _favoritesKeyPrefix = 'music.favorites.v1.';
  static const _playlistsKeyPrefix = 'music.playlists.v1.';
  static const _playCountsKeyPrefix = 'music.playcounts.v1.';
  static const _sessionKeyPrefix = 'music.session.v1.';
  static const _libraryCacheKeyPrefix = 'music.library.cache.v1.';
  static const _downloadsKeyPrefix = 'music.downloads.v1.';
  static const _savedQueuesKeyPrefix = 'music.saved.queues.v1.';
  static const _sharedQueuesKeyPrefix = 'music.shared.queues.v1.';
  static const _handoffsKeyPrefix = 'music.queue.handoffs.v1.';
  static const _uiStateKeyPrefix = 'music.ui.state.v1.';
  static const _homeSectionsKeyPrefix = 'music.home.sections.v1.';
  static const _pinsKeyPrefix = 'music.pins.v1.';
  static const _socialSharesKeyPrefix = 'music.social.shares.v1.';
  static const _publicProfileKeyPrefix = 'music.social.public-profile.v1.';
  static const _historyPrivacyKeyPrefix = 'music.social.history-privacy.v1.';
  static const _followingKeyPrefix = 'music.social.following.v1.';
  static const _collabPlaylistsKeyPrefix = 'music.social.collab-playlists.v1.';
  static const _sharedMixesKeyPrefix = 'music.social.shared-mixes.v1.';
  static const _sharedSessionsKeyPrefix = 'music.social.shared-sessions.v1.';
  static const _queueInvitationsKeyPrefix =
      'music.social.queue-invitations.v1.';
  static const _activityFeedKeyPrefix = 'music.social.activity.v1.';
  static const _reactionsKeyPrefix = 'music.social.reactions.v1.';
  static const _commentsKeyPrefix = 'music.social.comments.v1.';
  static const _publicPlaylistsKeyPrefix = 'music.social.public-playlists.v1.';
  static const _moderationKeyPrefix = 'music.social.moderation.v1.';
  static const _abuseReportsKeyPrefix = 'music.social.abuse-reports.v1.';
  static const _blockedUsersKeyPrefix = 'music.social.blocked-users.v1.';
  static const _inviteControlsKeyPrefix = 'music.social.invite-controls.v1.';
  static const _playEventsKeyPrefix = 'music.history.play-events.v1.';
  static const _historyPausedKeyPrefix = 'music.history.paused.v1.';
  static const _excludedSessionsKeyPrefix =
      'music.history.excluded-sessions.v1.';
  static const _sessionHistoryKeyPrefix = 'music.history.sessions.v1.';
  static const _scrobbleConfigKeyPrefix = 'music.history.scrobble.config.v1.';
  static const _scrobbleQueueKeyPrefix = 'music.history.scrobble.queue.v1.';

  Future<MusicServerConfig?> config(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_configKeyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Saved music server settings are invalid.');
    }
    final map = Map<String, dynamic>.from(decoded);
    final password = await _storage.read(key: '$_passwordKeyPrefix$profileId');
    if (password == null || password.isEmpty) {
      return null;
    }
    map['password'] = password;
    return MusicServerConfig.fromJson(map);
  }

  Future<List<Map<String, dynamic>>> _mapListByKey(String key) async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null || raw.trim().isEmpty) {
      return <Map<String, dynamic>>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return <Map<String, dynamic>>[];
    }
    final values = <Map<String, dynamic>>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      values.add(Map<String, dynamic>.from(entry));
    }
    return values;
  }

  Future<void> _saveMapList(
    String key,
    List<Map<String, dynamic>> values,
  ) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode(values),
    )) {
      throw StateError('Could not save music queue metadata.');
    }
  }

  Future<Map<String, dynamic>> _jsonObject(String key) async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const {};
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _saveJsonObject(String key, Map<String, dynamic> value) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode(value),
    )) {
      throw StateError('Could not save music social metadata.');
    }
  }

  String _normalizedSessionId(String? sessionId) {
    final value = sessionId?.trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
    final now = DateTime.now().toUtc();
    return 'session-${now.toIso8601String().replaceAll(RegExp(r'[^0-9]'), '')}';
  }

  int _playThresholdMs(int trackDurationMs) {
    final duration = trackDurationMs <= 0 ? 0 : trackDurationMs;
    final byPercent = (duration * 0.5).round();
    final threshold = min(30000, byPercent <= 0 ? 30000 : byPercent);
    return max(15000, threshold);
  }

  Future<List<MusicPlayEvent>> playEvents(
    int profileId, {
    bool includeExcluded = true,
    DateTime? fromUtc,
    DateTime? toUtc,
  }) async {
    final raw = await _mapListByKey('$_playEventsKeyPrefix$profileId');
    final values = <MusicPlayEvent>[];
    for (final item in raw) {
      try {
        values.add(MusicPlayEvent.fromJson(item));
      } catch (_) {}
    }
    values.sort((a, b) => b.endedAtUtc.compareTo(a.endedAtUtc));
    return values.where((event) {
      if (!includeExcluded && event.excludedFromRecommendations) {
        return false;
      }
      if (fromUtc != null && event.endedAtUtc.isBefore(fromUtc.toUtc())) {
        return false;
      }
      if (toUtc != null && event.endedAtUtc.isAfter(toUtc.toUtc())) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<bool> historyCollectionPaused(int profileId) async {
    final value = (await _jsonObject(
      '$_historyPausedKeyPrefix$profileId',
    ))['paused'];
    return value == true;
  }

  Future<void> setHistoryCollectionPaused(int profileId, bool paused) async {
    await _saveJsonObject('$_historyPausedKeyPrefix$profileId', {
      'paused': paused,
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<String>> excludedRecommendationSessions(int profileId) async {
    final raw = await _mapListByKey('$_excludedSessionsKeyPrefix$profileId');
    final values = <String>[];
    for (final item in raw) {
      final id = item['sessionId']?.toString().trim() ?? '';
      if (id.isNotEmpty) {
        values.add(id);
      }
    }
    return values;
  }

  Future<void> setSessionRecommendationExclusion(
    int profileId, {
    required String sessionId,
    required bool excluded,
  }) async {
    final normalized = sessionId.trim();
    if (normalized.isEmpty) {
      throw const FormatException(
        'Session id is required for exclusion policy.',
      );
    }
    final current = await _mapListByKey(
      '$_excludedSessionsKeyPrefix$profileId',
    );
    final next = current
        .where((item) => item['sessionId']?.toString() != normalized)
        .toList();
    if (excluded) {
      next.insert(0, {
        'sessionId': normalized,
        'excludedAtUtc': DateTime.now().toUtc().toIso8601String(),
      });
    }
    await _saveMapList(
      '$_excludedSessionsKeyPrefix$profileId',
      next.take(2000).toList(),
    );
  }

  Future<MusicPlayEvent> recordPlayEvent(
    int profileId, {
    required MusicTrack track,
    required int listenedMs,
    required int trackDurationMs,
    String? sessionId,
    String? playlistId,
    String? playlistName,
    bool offline = false,
    String? eventId,
    DateTime? startedAtUtc,
    DateTime? endedAtUtc,
    int deviceClockOffsetMs = 0,
  }) async {
    if (await historyCollectionPaused(profileId)) {
      throw StateError('History collection is paused for this profile.');
    }
    final now = DateTime.now().toUtc();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    final started = (startedAtUtc ?? now).toUtc();
    final ended = (endedAtUtc ?? now).toUtc();
    final adjustedEnded = ended.add(
      Duration(milliseconds: deviceClockOffsetMs),
    );
    final safeDuration = max(0, trackDurationMs);
    final safeListened = max(
      0,
      min(listenedMs, safeDuration <= 0 ? listenedMs : safeDuration),
    );
    final threshold = _playThresholdMs(safeDuration);
    final countedAsPlay = safeListened >= threshold;
    final excludedSessions = await excludedRecommendationSessions(profileId);
    final excluded = excludedSessions.contains(normalizedSessionId);
    final dedupeSeed = [
      track.id,
      normalizedSessionId,
      started.millisecondsSinceEpoch.toString(),
      adjustedEnded.millisecondsSinceEpoch.toString(),
      safeListened.toString(),
    ].join('|');
    final generatedEventId = sha1.convert(utf8.encode(dedupeSeed)).toString();
    final stableEventId = (eventId?.trim().isNotEmpty ?? false)
        ? eventId!.trim()
        : generatedEventId;
    final event = MusicPlayEvent(
      eventId: stableEventId,
      trackId: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      playlistId: playlistId?.trim().isEmpty ?? true
          ? null
          : playlistId!.trim(),
      playlistName: playlistName?.trim().isEmpty ?? true
          ? null
          : playlistName!.trim(),
      sessionId: normalizedSessionId,
      listenedMs: safeListened,
      trackDurationMs: safeDuration,
      countedAsPlay: countedAsPlay,
      excludedFromRecommendations: excluded,
      offline: offline,
      startedAtUtc: started,
      endedAtUtc: adjustedEnded.isBefore(started) ? started : adjustedEnded,
      ingestedAtUtc: now,
    );
    final current = await _mapListByKey('$_playEventsKeyPrefix$profileId');
    if (current.any((item) => item['eventId']?.toString() == stableEventId)) {
      return event;
    }
    final next = [event.toJson(), ...current].take(50000).toList();
    await _saveMapList('$_playEventsKeyPrefix$profileId', next);

    await _appendSessionHistoryEntry(
      profileId,
      sessionId: normalizedSessionId,
      track: track,
      listenedMs: safeListened,
      startedAtUtc: started,
      endedAtUtc: event.endedAtUtc,
      countedAsPlay: countedAsPlay,
      playlistId: event.playlistId,
      playlistName: event.playlistName,
    );
    await _enqueueScrobbleEvent(profileId, event);
    return event;
  }

  Future<void> _appendSessionHistoryEntry(
    int profileId, {
    required String sessionId,
    required MusicTrack track,
    required int listenedMs,
    required DateTime startedAtUtc,
    required DateTime endedAtUtc,
    required bool countedAsPlay,
    String? playlistId,
    String? playlistName,
  }) async {
    final current = await _mapListByKey('$_sessionHistoryKeyPrefix$profileId');
    final row = {
      'id': const Uuid().v4(),
      'sessionId': sessionId,
      'trackId': track.id,
      'title': track.title,
      'artist': track.artist,
      'album': track.album,
      'playlistId': playlistId,
      'playlistName': playlistName,
      'listenedMs': listenedMs,
      'countedAsPlay': countedAsPlay,
      'startedAtUtc': startedAtUtc.toUtc().toIso8601String(),
      'endedAtUtc': endedAtUtc.toUtc().toIso8601String(),
    };
    await _saveMapList(
      '$_sessionHistoryKeyPrefix$profileId',
      [row, ...current].take(20000).toList(),
    );
  }

  Future<List<Map<String, dynamic>>> replayableSessions(int profileId) async {
    final rows = await _mapListByKey('$_sessionHistoryKeyPrefix$profileId');
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final sessionId = row['sessionId']?.toString().trim() ?? '';
      if (sessionId.isEmpty) {
        continue;
      }
      grouped.putIfAbsent(sessionId, () => <Map<String, dynamic>>[]).add(row);
    }
    final values = <Map<String, dynamic>>[];
    for (final entry in grouped.entries) {
      final events = entry.value
        ..sort(
          (a, b) => (a['startedAtUtc']?.toString() ?? '').compareTo(
            b['startedAtUtc']?.toString() ?? '',
          ),
        );
      final first = events.first;
      values.add({
        'sessionId': entry.key,
        'startedAtUtc': first['startedAtUtc'],
        'trackCount': events.length,
        'tracks': events,
      });
    }
    values.sort(
      (a, b) => (b['startedAtUtc']?.toString() ?? '').compareTo(
        a['startedAtUtc']?.toString() ?? '',
      ),
    );
    return values;
  }

  Future<Map<String, dynamic>?> replaySessionById(
    int profileId,
    String sessionId,
  ) async {
    final normalized = sessionId.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final sessions = await replayableSessions(profileId);
    for (final entry in sessions) {
      if (entry['sessionId']?.toString() == normalized) {
        return entry;
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> recentlyPlayedAlbums(
    int profileId, {
    int limit = 30,
  }) async {
    final events = await playEvents(profileId);
    final byAlbum = <String, Map<String, dynamic>>{};
    for (final event in events) {
      final key = event.album.trim().toLowerCase();
      if (key.isEmpty || byAlbum.containsKey(key)) {
        continue;
      }
      byAlbum[key] = {
        'album': event.album,
        'artist': event.artist,
        'trackId': event.trackId,
        'lastPlayedAtUtc': event.endedAtUtc.toIso8601String(),
      };
      if (byAlbum.length >= limit) {
        break;
      }
    }
    return byAlbum.values.toList();
  }

  Future<List<Map<String, dynamic>>> recentlyPlayedPlaylists(
    int profileId, {
    int limit = 30,
  }) async {
    final events = await playEvents(profileId);
    final byPlaylist = <String, Map<String, dynamic>>{};
    for (final event in events) {
      final playlistId = event.playlistId?.trim() ?? '';
      if (playlistId.isEmpty || byPlaylist.containsKey(playlistId)) {
        continue;
      }
      byPlaylist[playlistId] = {
        'playlistId': playlistId,
        'playlistName': event.playlistName ?? playlistId,
        'lastPlayedAtUtc': event.endedAtUtc.toIso8601String(),
      };
      if (byPlaylist.length >= limit) {
        break;
      }
    }
    return byPlaylist.values.toList();
  }

  Future<void> deleteHistoryEntry(int profileId, String eventId) async {
    final normalized = eventId.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Event id is required to delete history.');
    }
    final rows = await _mapListByKey('$_playEventsKeyPrefix$profileId');
    await _saveMapList(
      '$_playEventsKeyPrefix$profileId',
      rows
          .where((entry) => entry['eventId']?.toString() != normalized)
          .toList(),
    );
    final sessions = await _mapListByKey('$_sessionHistoryKeyPrefix$profileId');
    await _saveMapList(
      '$_sessionHistoryKeyPrefix$profileId',
      sessions
          .where(
            (entry) =>
                entry['id']?.toString() != normalized &&
                entry['eventId']?.toString() != normalized,
          )
          .toList(),
    );
  }

  Future<Map<String, dynamic>> listeningStatistics(
    int profileId, {
    required String period,
    DateTime? referenceUtc,
  }) async {
    final now = (referenceUtc ?? DateTime.now()).toUtc();
    final start = switch (period) {
      'daily' => DateTime.utc(now.year, now.month, now.day),
      'weekly' => DateTime.utc(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: now.weekday - 1)),
      'monthly' => DateTime.utc(now.year, now.month, 1),
      'annual' => DateTime.utc(now.year, 1, 1),
      _ => throw const FormatException(
        'Period must be daily, weekly, monthly, or annual.',
      ),
    };
    final events = await playEvents(
      profileId,
      includeExcluded: true,
      fromUtc: start,
      toUtc: now,
    );
    final playedEvents = events.where((event) => event.countedAsPlay).toList();
    final trackPlays = <String, int>{};
    final artistPlays = <String, int>{};
    final albumPlays = <String, int>{};
    var listenedMs = 0;
    for (final event in events) {
      listenedMs += max(0, event.listenedMs);
      if (!event.countedAsPlay) {
        continue;
      }
      trackPlays[event.trackId] = (trackPlays[event.trackId] ?? 0) + 1;
      artistPlays[event.artist] = (artistPlays[event.artist] ?? 0) + 1;
      albumPlays[event.album] = (albumPlays[event.album] ?? 0) + 1;
    }
    List<Map<String, dynamic>> top(Map<String, int> source, {int limit = 10}) {
      final entries = source.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return entries
          .take(limit)
          .map((entry) => {'name': entry.key, 'plays': entry.value})
          .toList();
    }

    return {
      'period': period,
      'fromUtc': start.toIso8601String(),
      'toUtc': now.toIso8601String(),
      'listeningTimeMs': listenedMs,
      'listeningTimeMinutes': (listenedMs / 60000).round(),
      'playEvents': events.length,
      'countedPlays': playedEvents.length,
      'topTracks': top(trackPlays),
      'topArtists': top(artistPlays),
      'topAlbums': top(albumPlays),
    };
  }

  Future<Map<String, dynamic>> calendarHistoryView(
    int profileId, {
    DateTime? fromUtc,
    DateTime? toUtc,
  }) async {
    final to = (toUtc ?? DateTime.now()).toUtc();
    final from = (fromUtc ?? to.subtract(const Duration(days: 365))).toUtc();
    final events = await playEvents(
      profileId,
      includeExcluded: true,
      fromUtc: from,
      toUtc: to,
    );
    final days = <String, Map<String, dynamic>>{};
    for (final event in events) {
      final day = event.endedAtUtc.toIso8601String().substring(0, 10);
      final row = days.putIfAbsent(
        day,
        () => {
          'day': day,
          'plays': 0,
          'listeningTimeMs': 0,
          'tracks': <String>{},
        },
      );
      row['plays'] = (row['plays'] as int) + (event.countedAsPlay ? 1 : 0);
      row['listeningTimeMs'] =
          (row['listeningTimeMs'] as int) + max(0, event.listenedMs);
      (row['tracks'] as Set<String>).add(event.trackId);
    }
    final rows =
        days.values
            .map(
              (row) => {
                'day': row['day'],
                'plays': row['plays'],
                'listeningTimeMs': row['listeningTimeMs'],
                'uniqueTracks': (row['tracks'] as Set<String>).length,
              },
            )
            .toList()
          ..sort(
            (a, b) => (a['day']?.toString() ?? '').compareTo(
              b['day']?.toString() ?? '',
            ),
          );
    return {
      'fromUtc': from.toIso8601String(),
      'toUtc': to.toIso8601String(),
      'days': rows,
    };
  }

  Future<Map<String, dynamic>> recapPresentation(
    int profileId, {
    required int year,
  }) async {
    final start = DateTime.utc(year, 1, 1);
    final end = DateTime.utc(
      year + 1,
      1,
      1,
    ).subtract(const Duration(milliseconds: 1));
    final events = await playEvents(
      profileId,
      includeExcluded: true,
      fromUtc: start,
      toUtc: end,
    );
    final stats = await listeningStatistics(
      profileId,
      period: 'annual',
      referenceUtc: end,
    );
    final uniqueArtists = <String>{
      for (final event in events) event.artist,
    }.length;
    final uniqueAlbums = <String>{
      for (final event in events) event.album,
    }.length;
    return {
      'year': year,
      'listeningTimeMs': stats['listeningTimeMs'],
      'countedPlays': stats['countedPlays'],
      'uniqueArtists': uniqueArtists,
      'uniqueAlbums': uniqueAlbums,
      'topTracks': stats['topTracks'],
      'topArtists': stats['topArtists'],
      'topAlbums': stats['topAlbums'],
      'highlight': events.isEmpty
          ? 'No listening data for this year.'
          : 'You played ${stats['countedPlays']} tracks across $uniqueArtists artists.',
    };
  }

  Future<List<Map<String, dynamic>>> discoveryTimeline(int profileId) async {
    final events = await playEvents(profileId, includeExcluded: true);
    events.sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    final seenTracks = <String>{};
    final seenArtists = <String>{};
    final entries = <Map<String, dynamic>>[];
    for (final event in events) {
      if (!seenTracks.contains(event.trackId)) {
        seenTracks.add(event.trackId);
        entries.add({
          'type': 'track_discovery',
          'trackId': event.trackId,
          'title': event.title,
          'artist': event.artist,
          'atUtc': event.startedAtUtc.toIso8601String(),
        });
      }
      if (!seenArtists.contains(event.artist)) {
        seenArtists.add(event.artist);
        entries.add({
          'type': 'artist_discovery',
          'artist': event.artist,
          'atUtc': event.startedAtUtc.toIso8601String(),
        });
      }
    }
    entries.sort(
      (a, b) => (a['atUtc']?.toString() ?? '').compareTo(
        b['atUtc']?.toString() ?? '',
      ),
    );
    return entries;
  }

  Future<List<Map<String, dynamic>>> anniversaryReminders(
    int profileId, {
    DateTime? nowUtc,
    int windowDays = 7,
  }) async {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final events = await playEvents(profileId, includeExcluded: true);
    final reminders = <Map<String, dynamic>>[];
    for (final event in events) {
      final years = now.year - event.startedAtUtc.year;
      if (years <= 0) {
        continue;
      }
      final anniversary = DateTime.utc(
        now.year,
        event.startedAtUtc.month,
        event.startedAtUtc.day,
      );
      final delta = anniversary
          .difference(DateTime.utc(now.year, now.month, now.day))
          .inDays
          .abs();
      if (delta > windowDays) {
        continue;
      }
      reminders.add({
        'trackId': event.trackId,
        'title': event.title,
        'artist': event.artist,
        'firstHeardAtUtc': event.startedAtUtc.toIso8601String(),
        'yearsAgo': years,
      });
    }
    final deduped = <String, Map<String, dynamic>>{};
    for (final reminder in reminders) {
      final key = reminder['trackId']?.toString() ?? '';
      if (key.isNotEmpty && !deduped.containsKey(key)) {
        deduped[key] = reminder;
      }
    }
    return deduped.values.toList();
  }

  Future<List<Map<String, dynamic>>> listeningLastSummer(
    int profileId, {
    int? year,
  }) async {
    final targetYear = year ?? DateTime.now().toUtc().year - 1;
    final from = DateTime.utc(targetYear, 6, 1);
    final to = DateTime.utc(targetYear, 8, 31, 23, 59, 59);
    final events = await playEvents(
      profileId,
      includeExcluded: true,
      fromUtc: from,
      toUtc: to,
    );
    final counts = <String, Map<String, dynamic>>{};
    for (final event in events.where((item) => item.countedAsPlay)) {
      final row = counts.putIfAbsent(
        event.trackId,
        () => {
          'trackId': event.trackId,
          'title': event.title,
          'artist': event.artist,
          'plays': 0,
        },
      );
      row['plays'] = (row['plays'] as int) + 1;
    }
    final values = counts.values.toList()
      ..sort((a, b) => (b['plays'] as int).compareTo(a['plays'] as int));
    return values.take(100).toList();
  }

  Future<MusicPlaylist> rediscoveryPlaylist(
    int profileId, {
    int limit = 40,
    int dormancyDays = 90,
  }) async {
    final events = await playEvents(profileId, includeExcluded: false);
    final now = DateTime.now().toUtc();
    final byTrack = <String, List<MusicPlayEvent>>{};
    for (final event in events.where((item) => item.countedAsPlay)) {
      byTrack.putIfAbsent(event.trackId, () => <MusicPlayEvent>[]).add(event);
    }
    final candidates = <Map<String, dynamic>>[];
    for (final entry in byTrack.entries) {
      final list = entry.value
        ..sort((a, b) => b.endedAtUtc.compareTo(a.endedAtUtc));
      final latest = list.first;
      final daysSince = now.difference(latest.endedAtUtc).inDays;
      if (daysSince < dormancyDays) {
        continue;
      }
      candidates.add({
        'track': MusicTrack(
          id: latest.trackId,
          title: latest.title,
          artist: latest.artist,
          album: latest.album,
          durationSeconds: (latest.trackDurationMs / 1000).round(),
          streamUrl: null,
        ),
        'plays': list.length,
        'daysSince': daysSince,
      });
    }
    candidates.sort((a, b) {
      final byDays = (b['daysSince'] as int).compareTo(a['daysSince'] as int);
      if (byDays != 0) {
        return byDays;
      }
      return (b['plays'] as int).compareTo(a['plays'] as int);
    });
    final tracks = candidates
        .take(limit)
        .map((item) => item['track'] as MusicTrack)
        .toList();
    return MusicPlaylist(
      id: const Uuid().v4(),
      name:
          'Rediscovery · ${DateTime.now().toLocal().toIso8601String().substring(0, 10)}',
      createdAtUtc: DateTime.now().toUtc(),
      tracks: tracks,
    );
  }

  Future<List<Map<String, dynamic>>> listeningMilestones(int profileId) async {
    final events = await playEvents(profileId, includeExcluded: true);
    final counted = events.where((event) => event.countedAsPlay).toList();
    final minutes =
        events.fold<int>(0, (sum, event) => sum + max(0, event.listenedMs)) ~/
        60000;
    final uniqueTracks = <String>{
      for (final event in counted) event.trackId,
    }.length;
    final uniqueArtists = <String>{
      for (final event in counted) event.artist,
    }.length;
    final milestones = <Map<String, dynamic>>[];
    void addIfReached(String key, int current, List<int> thresholds) {
      for (final threshold in thresholds) {
        if (current >= threshold) {
          milestones.add({
            'metric': key,
            'threshold': threshold,
            'current': current,
          });
        }
      }
    }

    addIfReached('countedPlays', counted.length, const [
      100,
      500,
      1000,
      5000,
      10000,
    ]);
    addIfReached('listeningMinutes', minutes, const [1000, 5000, 10000, 50000]);
    addIfReached('uniqueTracks', uniqueTracks, const [100, 500, 1000, 3000]);
    addIfReached('uniqueArtists', uniqueArtists, const [25, 100, 250, 500]);
    milestones.sort(
      (a, b) => (a['metric']?.toString() ?? '').compareTo(
        b['metric']?.toString() ?? '',
      ),
    );
    return milestones;
  }

  Future<Map<String, dynamic>> exportHistory(
    int profileId, {
    String format = 'json',
    String? outputDirectoryPath,
  }) async {
    final events = await playEvents(profileId, includeExcluded: true);
    final directory =
        outputDirectoryPath == null || outputDirectoryPath.trim().isEmpty
        ? await getApplicationDocumentsDirectory()
        : Directory(outputDirectoryPath.trim());
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    if (format == 'csv') {
      final file = File(
        '${directory.path}${Platform.pathSeparator}music-history-$profileId-$stamp.csv',
      );
      final lines = <String>[
        'eventId,trackId,title,artist,album,playlistId,playlistName,sessionId,listenedMs,trackDurationMs,countedAsPlay,excludedFromRecommendations,offline,startedAtUtc,endedAtUtc,ingestedAtUtc',
        for (final event in events)
          '"${event.eventId.replaceAll('"', '""')}","${event.trackId.replaceAll('"', '""')}","${event.title.replaceAll('"', '""')}","${event.artist.replaceAll('"', '""')}","${event.album.replaceAll('"', '""')}","${(event.playlistId ?? '').replaceAll('"', '""')}","${(event.playlistName ?? '').replaceAll('"', '""')}","${event.sessionId.replaceAll('"', '""')}",${event.listenedMs},${event.trackDurationMs},${event.countedAsPlay},${event.excludedFromRecommendations},${event.offline},"${event.startedAtUtc.toIso8601String()}","${event.endedAtUtc.toIso8601String()}","${event.ingestedAtUtc.toIso8601String()}"',
      ];
      await file.writeAsString('${lines.join('\n')}\n', flush: true);
      return {'path': file.path, 'format': 'csv', 'count': events.length};
    }
    final file = File(
      '${directory.path}${Platform.pathSeparator}music-history-$profileId-$stamp.json',
    );
    await file.writeAsString(
      jsonEncode(events.map((event) => event.toJson()).toList()),
      flush: true,
    );
    return {'path': file.path, 'format': 'json', 'count': events.length};
  }

  Future<Map<String, dynamic>> scrobbleConfig(int profileId) async {
    final current = await _jsonObject('$_scrobbleConfigKeyPrefix$profileId');
    return {
      'enabled': current['enabled'] == true,
      'provider': current['provider']?.toString() ?? '',
      'endpoint': current['endpoint']?.toString() ?? '',
      'token': current['token']?.toString() ?? '',
      'updatedAtUtc': current['updatedAtUtc']?.toString() ?? '',
    };
  }

  Future<void> saveScrobbleConfig(
    int profileId, {
    required bool enabled,
    required String provider,
    required String endpoint,
    required String token,
  }) async {
    await _saveJsonObject('$_scrobbleConfigKeyPrefix$profileId', {
      'enabled': enabled,
      'provider': provider.trim(),
      'endpoint': endpoint.trim(),
      'token': token.trim(),
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _enqueueScrobbleEvent(
    int profileId,
    MusicPlayEvent event,
  ) async {
    final cfg = await scrobbleConfig(profileId);
    if (cfg['enabled'] != true) {
      return;
    }
    final queue = await _mapListByKey('$_scrobbleQueueKeyPrefix$profileId');
    queue.insert(0, {
      'eventId': event.eventId,
      'payload': event.toJson(),
      'attempts': 0,
      'queuedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
    await _saveMapList(
      '$_scrobbleQueueKeyPrefix$profileId',
      queue.take(5000).toList(),
    );
  }

  Future<Map<String, dynamic>> syncScrobbles(int profileId) async {
    final cfg = await scrobbleConfig(profileId);
    if (cfg['enabled'] != true) {
      return const {'synced': 0, 'remaining': 0, 'status': 'disabled'};
    }
    final endpoint = cfg['endpoint']?.toString().trim() ?? '';
    if (endpoint.isEmpty) {
      throw const FormatException('Scrobble endpoint is not configured.');
    }
    final token = cfg['token']?.toString() ?? '';
    final queue = await _mapListByKey('$_scrobbleQueueKeyPrefix$profileId');
    if (queue.isEmpty) {
      return const {'synced': 0, 'remaining': 0, 'status': 'ok'};
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final remaining = <Map<String, dynamic>>[];
    var synced = 0;
    try {
      for (final item in queue) {
        final payload = item['payload'];
        if (payload is! Map) {
          continue;
        }
        final uri = Uri.tryParse(endpoint);
        if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
          throw const FormatException('Scrobble endpoint URI is invalid.');
        }
        try {
          final request = await client.postUrl(uri);
          request.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/json',
          );
          if (token.trim().isNotEmpty) {
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer $token',
            );
          }
          request.add(utf8.encode(jsonEncode({'playEvent': payload})));
          final response = await request.close();
          if (response.statusCode >= 200 && response.statusCode < 300) {
            synced += 1;
            continue;
          }
          final attempts =
              (int.tryParse(item['attempts']?.toString() ?? '') ?? 0) + 1;
          remaining.add({...item, 'attempts': attempts});
        } catch (_) {
          final attempts =
              (int.tryParse(item['attempts']?.toString() ?? '') ?? 0) + 1;
          remaining.add({...item, 'attempts': attempts});
        }
      }
    } finally {
      client.close(force: true);
    }
    await _saveMapList('$_scrobbleQueueKeyPrefix$profileId', remaining);
    return {'synced': synced, 'remaining': remaining.length, 'status': 'ok'};
  }

  Map<String, dynamic> playCountingRules() {
    return {
      'whatCountsAsPlay':
          'A play counts when listenedMs >= max(15_000ms, min(30_000ms, 50% of track duration)).',
      'partialListeningToTime':
          'Listening time always includes partial progress and is capped to track duration when duration is known.',
      'repeatCounting':
          'Repeats count as additional plays when they produce distinct play events past the play threshold.',
      'offlineSynchronization':
          'Offline events are stored locally with offline=true and queued for scrobble sync when integration is enabled.',
      'duplicatePrevention':
          'Each play event has a stable eventId and dedupe hash; duplicate eventId submissions are ignored.',
      'clockDifferences':
          'Device clock offsets are normalized into endedAtUtc via deviceClockOffsetMs before persistence.',
    };
  }

  Future<Map<String, dynamic>> uiState(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_uiStateKeyPrefix$profileId',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const {};
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> saveUiState(int profileId, Map<String, dynamic> state) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_uiStateKeyPrefix$profileId',
      jsonEncode(state),
    )) {
      throw StateError('Could not save music UI state.');
    }
  }

  Future<List<String>> homeSections(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_homeSectionsKeyPrefix$profileId',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const ['recents', 'favorites', 'mostPlayed', 'pinned'];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const ['recents', 'favorites', 'mostPlayed', 'pinned'];
    }
    final values = <String>[];
    for (final item in decoded) {
      final value = item.toString().trim();
      if (value.isNotEmpty) {
        values.add(value);
      }
    }
    return values.isEmpty
        ? const ['recents', 'favorites', 'mostPlayed', 'pinned']
        : values;
  }

  Future<void> saveHomeSections(int profileId, List<String> sections) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_homeSectionsKeyPrefix$profileId',
      jsonEncode(sections),
    )) {
      throw StateError('Could not save music home sections.');
    }
  }

  Future<Map<String, List<String>>> pins(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_pinsKeyPrefix$profileId',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const {
        'albums': <String>[],
        'artists': <String>[],
        'playlists': <String>[],
      };
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const {
        'albums': <String>[],
        'artists': <String>[],
        'playlists': <String>[],
      };
    }
    List<String> readList(String key) {
      final value = decoded[key];
      if (value is! List) {
        return <String>[];
      }
      final out = <String>[];
      for (final item in value) {
        final text = item.toString().trim();
        if (text.isNotEmpty) {
          out.add(text);
        }
      }
      return out;
    }

    return {
      'albums': readList('albums'),
      'artists': readList('artists'),
      'playlists': readList('playlists'),
    };
  }

  Future<void> savePins(int profileId, Map<String, List<String>> pins) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_pinsKeyPrefix$profileId',
      jsonEncode({
        'albums': pins['albums'] ?? const <String>[],
        'artists': pins['artists'] ?? const <String>[],
        'playlists': pins['playlists'] ?? const <String>[],
      }),
    )) {
      throw StateError('Could not save music pins.');
    }
  }

  Future<void> saveConfig(int profileId, MusicServerConfig value) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(value.toJson(includePassword: false));
    if (!await prefs.setString('$_configKeyPrefix$profileId', payload)) {
      throw StateError('Could not save music server settings.');
    }
    await _storage.write(
      key: '$_passwordKeyPrefix$profileId',
      value: value.password,
    );
  }

  Future<void> clearConfig(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove('$_configKeyPrefix$profileId')) {
      throw StateError('Could not clear music server settings.');
    }
    await _storage.delete(key: '$_passwordKeyPrefix$profileId');
  }

  Future<List<MusicStation>> stations(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_stationsKeyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Music station list is invalid.');
    }
    final values = <MusicStation>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(MusicStation.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    values.sort((a, b) => b.createdAtUtc.compareTo(a.createdAtUtc));
    return values;
  }

  Future<void> saveStations(int profileId, List<MusicStation> values) async {
    final raw = jsonEncode(values.map((station) => station.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_stationsKeyPrefix$profileId',
      raw,
    )) {
      throw StateError('Could not save music stations.');
    }
  }

  Future<void> upsertStation(int profileId, MusicStation station) async {
    final current = await stations(profileId);
    final merged = [
      station,
      ...current.where((item) => item.id != station.id),
    ].take(20).toList();
    await saveStations(profileId, merged);
  }

  Future<void> removeStation(int profileId, String stationId) async {
    final current = await stations(profileId);
    await saveStations(
      profileId,
      current.where((item) => item.id != stationId).toList(),
    );
  }

  Future<List<MusicTrack>> recentlyPlayed(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_recentKeyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Music recent list is invalid.');
    }
    final values = <MusicTrack>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(MusicTrack.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    return values;
  }

  Future<void> upsertRecentlyPlayed(int profileId, MusicTrack track) async {
    final current = await recentlyPlayed(profileId);
    final merged = [
      track,
      ...current.where((item) => item.id != track.id),
    ].take(60).toList();
    final raw = jsonEncode(merged.map((item) => item.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_recentKeyPrefix$profileId',
      raw,
    )) {
      throw StateError('Could not save music recently played list.');
    }
  }

  Future<Map<String, int>> playCounts(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_playCountsKeyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Music play count map is invalid.');
    }
    final values = <String, int>{};
    for (final entry in decoded.entries) {
      final key = entry.key.toString().trim();
      if (key.isEmpty) {
        continue;
      }
      final count = int.tryParse(entry.value.toString()) ?? 0;
      if (count > 0) {
        values[key] = count;
      }
    }
    return values;
  }

  Future<void> recordPlay(
    int profileId,
    MusicTrack track, {
    int? listenedMs,
    int? trackDurationMs,
    String? sessionId,
    String? playlistId,
    String? playlistName,
    bool offline = false,
    DateTime? startedAtUtc,
    DateTime? endedAtUtc,
    int deviceClockOffsetMs = 0,
  }) async {
    final event = await recordPlayEvent(
      profileId,
      track: track,
      listenedMs: max(0, listenedMs ?? track.durationSeconds * 1000),
      trackDurationMs: max(0, trackDurationMs ?? track.durationSeconds * 1000),
      sessionId: sessionId,
      playlistId: playlistId,
      playlistName: playlistName,
      offline: offline,
      startedAtUtc: startedAtUtc,
      endedAtUtc: endedAtUtc,
      deviceClockOffsetMs: deviceClockOffsetMs,
    );
    if (!event.countedAsPlay) {
      return;
    }
    final current = await playCounts(profileId);
    current[track.id] = (current[track.id] ?? 0) + 1;
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_playCountsKeyPrefix$profileId',
      jsonEncode(current),
    )) {
      throw StateError('Could not save music play count data.');
    }
  }

  Future<List<MusicTrack>> favorites(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_favoritesKeyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Music favorites list is invalid.');
    }
    final values = <MusicTrack>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(MusicTrack.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    return values;
  }

  Future<void> setFavorite(
    int profileId,
    MusicTrack track,
    bool isFavorite,
  ) async {
    final current = await favorites(profileId);
    final next = <MusicTrack>[
      if (isFavorite) track,
      ...current.where((item) => item.id != track.id),
    ].take(200).toList();
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_favoritesKeyPrefix$profileId',
      jsonEncode(next.map((item) => item.toJson()).toList()),
    )) {
      throw StateError('Could not save music favorites.');
    }
  }

  Future<void> saveFavorites(int profileId, List<MusicTrack> values) async {
    final deduped = <String, MusicTrack>{};
    for (final track in values) {
      deduped[track.id] = track;
    }
    final next = deduped.values.take(500).toList();
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_favoritesKeyPrefix$profileId',
      jsonEncode(next.map((item) => item.toJson()).toList()),
    )) {
      throw StateError('Could not save synced music favorites.');
    }
  }

  Future<List<MusicPlaylist>> playlists(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_playlistsKeyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Music playlist list is invalid.');
    }
    final values = <MusicPlaylist>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(MusicPlaylist.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    values.sort((a, b) => b.createdAtUtc.compareTo(a.createdAtUtc));
    return values;
  }

  Future<void> savePlaylists(int profileId, List<MusicPlaylist> values) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_playlistsKeyPrefix$profileId',
      jsonEncode(values.map((item) => item.toJson()).toList()),
    )) {
      throw StateError('Could not save music playlists.');
    }
  }

  Future<void> upsertPlaylist(int profileId, MusicPlaylist playlist) async {
    final current = await playlists(profileId);
    final next = [
      playlist,
      ...current.where((item) => item.id != playlist.id),
    ].take(60).toList();
    await savePlaylists(profileId, next);
  }

  Future<void> removePlaylist(int profileId, String playlistId) async {
    final current = await playlists(profileId);
    await savePlaylists(
      profileId,
      current.where((item) => item.id != playlistId).toList(),
    );
  }

  Future<String> createShareLink(
    int profileId, {
    required String contentType,
    required String contentId,
    required String label,
    bool accessRequired = true,
    Map<String, dynamic> metadata = const {},
  }) async {
    final normalizedType = contentType.trim().toLowerCase();
    if (!const {
      'track',
      'album',
      'artist',
      'playlist',
    }.contains(normalizedType)) {
      throw const FormatException(
        'Share content type must be track, album, artist, or playlist.',
      );
    }
    final id = contentId.trim();
    final name = label.trim();
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Share content id and label are required.');
    }
    final token = const Uuid().v4().replaceAll('-', '');
    final current = await _mapListByKey('$_socialSharesKeyPrefix$profileId');
    final now = DateTime.now().toUtc().toIso8601String();
    final next = [
      {
        'token': token,
        'contentType': normalizedType,
        'contentId': id,
        'label': name,
        'accessRequired': accessRequired,
        'metadata': metadata,
        'createdAtUtc': now,
      },
      ...current.where((entry) => entry['token']?.toString() != token),
    ].take(1000).toList();
    await _saveMapList('$_socialSharesKeyPrefix$profileId', next);
    return Uri(
      scheme: 'millitop',
      host: 'music',
      path: '/share/$normalizedType/$id',
      queryParameters: {'token': token, 'owner': '$profileId'},
    ).toString();
  }

  Future<Map<String, dynamic>> resolveShareLink(
    int profileId,
    Uri uri, {
    required bool recipientSignedIn,
    bool recipientHasAccess = true,
  }) async {
    final token = uri.queryParameters['token']?.trim() ?? '';
    if (token.isEmpty) {
      throw const FormatException('Share link token is missing.');
    }
    final owner =
        int.tryParse(uri.queryParameters['owner']?.trim() ?? '') ?? profileId;
    final shares = await _mapListByKey('$_socialSharesKeyPrefix$owner');
    final match = shares.where((entry) => entry['token']?.toString() == token);
    if (match.isEmpty) {
      return const {
        'status': 'not_found',
        'message': 'This shared item is no longer available.',
      };
    }
    final record = Map<String, dynamic>.from(match.first);
    final requiresAccess = record['accessRequired'] == true;
    if (!recipientSignedIn) {
      return const {
        'status': 'sign_in_required',
        'message': 'Sign in to open this shared item.',
      };
    }
    if (requiresAccess && !recipientHasAccess) {
      return const {
        'status': 'access_denied',
        'message': 'You do not have access to this shared content.',
      };
    }
    return {
      'status': 'ok',
      'ownerProfileId': owner,
      'contentType': record['contentType'],
      'contentId': record['contentId'],
      'label': record['label'],
      'metadata': record['metadata'],
    };
  }

  Future<File> exportPlaylistAsM3u(
    int profileId, {
    required String playlistId,
    String? outputDirectoryPath,
  }) async {
    final targetId = playlistId.trim();
    if (targetId.isEmpty) {
      throw const FormatException('Playlist id is required for export.');
    }
    final list = await playlists(profileId);
    MusicPlaylist? playlist;
    for (final item in list) {
      if (item.id == targetId) {
        playlist = item;
        break;
      }
    }
    if (playlist == null) {
      throw StateError('Playlist not found for export.');
    }
    final baseDir =
        outputDirectoryPath == null || outputDirectoryPath.trim().isEmpty
        ? await getApplicationDocumentsDirectory()
        : Directory(outputDirectoryPath.trim());
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
    final safeName = playlist.name
        .replaceAll(RegExp(r'[^a-zA-Z0-9 _.-]'), '')
        .trim()
        .replaceAll(' ', '_');
    final file = File(
      '${baseDir.path}${Platform.pathSeparator}${safeName.isEmpty ? 'playlist' : safeName}.m3u',
    );
    final lines = <String>[
      '#EXTM3U',
      for (final track in playlist.tracks) ...[
        '#EXTINF:${track.durationSeconds},${track.artist} - ${track.title}',
        track.streamUrl ?? '',
      ],
    ];
    await file.writeAsString(
      '${lines.join('\n')}\n',
      mode: FileMode.writeOnly,
      flush: true,
    );
    return file;
  }

  Future<Map<String, dynamic>> publicProfile(int profileId) async {
    final current = await _jsonObject('$_publicProfileKeyPrefix$profileId');
    return {
      'enabled': current['enabled'] == true,
      'displayName': current['displayName']?.toString() ?? '',
      'bio': current['bio']?.toString() ?? '',
      'avatarUrl': current['avatarUrl']?.toString() ?? '',
      'updatedAtUtc': current['updatedAtUtc']?.toString() ?? '',
    };
  }

  Future<void> savePublicProfile(
    int profileId, {
    required bool enabled,
    String displayName = '',
    String bio = '',
    String avatarUrl = '',
  }) async {
    await _saveJsonObject('$_publicProfileKeyPrefix$profileId', {
      'enabled': enabled,
      'displayName': displayName.trim(),
      'bio': bio.trim(),
      'avatarUrl': avatarUrl.trim(),
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<String> personalHistoryVisibility(int profileId) async {
    final current = await _jsonObject('$_historyPrivacyKeyPrefix$profileId');
    final value =
        current['value']?.toString().trim().toLowerCase() ?? 'private';
    return value == 'public' ? 'public' : 'private';
  }

  Future<void> setPersonalHistoryVisibility(
    int profileId,
    String visibility,
  ) async {
    final normalized = visibility.trim().toLowerCase();
    if (normalized != 'private' && normalized != 'public') {
      throw const FormatException(
        'History visibility must be private or public.',
      );
    }
    await _saveJsonObject('$_historyPrivacyKeyPrefix$profileId', {
      'value': normalized,
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> followUser(int profileId, String userId) async {
    final target = userId.trim();
    if (target.isEmpty) {
      throw const FormatException('User id is required to follow.');
    }
    final current = await _mapListByKey('$_followingKeyPrefix$profileId');
    if (current.any((entry) => entry['userId']?.toString() == target)) {
      return;
    }
    await _saveMapList('$_followingKeyPrefix$profileId', [
      {
        'userId': target,
        'followedAtUtc': DateTime.now().toUtc().toIso8601String(),
      },
      ...current,
    ]);
  }

  Future<void> unfollowUser(int profileId, String userId) async {
    final target = userId.trim();
    final current = await _mapListByKey('$_followingKeyPrefix$profileId');
    await _saveMapList(
      '$_followingKeyPrefix$profileId',
      current.where((entry) => entry['userId']?.toString() != target).toList(),
    );
  }

  Future<List<String>> followedUsers(int profileId) async {
    final current = await _mapListByKey('$_followingKeyPrefix$profileId');
    final values = <String>[];
    for (final entry in current) {
      final id = entry['userId']?.toString().trim() ?? '';
      if (id.isNotEmpty) {
        values.add(id);
      }
    }
    return values;
  }

  Future<void> setCollaborativePlaylist(
    int profileId, {
    required String playlistId,
    required bool enabled,
    required List<String> editorUserIds,
  }) async {
    final id = playlistId.trim();
    if (id.isEmpty) {
      throw const FormatException('Playlist id is required.');
    }
    final current = await _mapListByKey('$_collabPlaylistsKeyPrefix$profileId');
    final next = [
      {
        'playlistId': id,
        'enabled': enabled,
        'editorUserIds': editorUserIds
            .map((entry) => entry.trim())
            .where((entry) => entry.isNotEmpty)
            .toSet()
            .toList(),
        'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      },
      ...current.where((entry) => entry['playlistId']?.toString() != id),
    ].take(500).toList();
    await _saveMapList('$_collabPlaylistsKeyPrefix$profileId', next);
  }

  Future<List<Map<String, dynamic>>> collaborativePlaylists(
    int profileId,
  ) async {
    return _mapListByKey('$_collabPlaylistsKeyPrefix$profileId');
  }

  Future<void> createSharedMix(
    int profileId, {
    required String name,
    required List<MusicTrack> tracks,
    bool isPublic = false,
  }) async {
    final mixName = name.trim();
    if (mixName.isEmpty) {
      throw const FormatException('Shared mix name is required.');
    }
    final entry = {
      'id': const Uuid().v4(),
      'name': mixName,
      'isPublic': isPublic,
      'tracks': tracks.map((track) => track.toJson()).toList(),
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    final current = await _mapListByKey('$_sharedMixesKeyPrefix$profileId');
    await _saveMapList(
      '$_sharedMixesKeyPrefix$profileId',
      [entry, ...current].take(400).toList(),
    );
  }

  Future<List<Map<String, dynamic>>> sharedMixes(int profileId) async {
    return _mapListByKey('$_sharedMixesKeyPrefix$profileId');
  }

  Future<void> upsertSharedSession(
    int profileId, {
    required String sessionId,
    required String title,
    required Map<String, dynamic> snapshot,
    required List<String> participantUserIds,
  }) async {
    final id = sessionId.trim();
    final name = title.trim();
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Shared session id and title are required.');
    }
    final current = await _mapListByKey('$_sharedSessionsKeyPrefix$profileId');
    final next = [
      {
        'id': id,
        'title': name,
        'snapshot': snapshot,
        'participantUserIds': participantUserIds
            .map((entry) => entry.trim())
            .where((entry) => entry.isNotEmpty)
            .toSet()
            .toList(),
        'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      },
      ...current.where((entry) => entry['id']?.toString() != id),
    ].take(300).toList();
    await _saveMapList('$_sharedSessionsKeyPrefix$profileId', next);
  }

  Future<List<Map<String, dynamic>>> sharedSessions(int profileId) async {
    return _mapListByKey('$_sharedSessionsKeyPrefix$profileId');
  }

  Future<void> inviteToQueue(
    int profileId, {
    required String queueId,
    required String invitedUserId,
    String role = 'listener',
  }) async {
    final qid = queueId.trim();
    final uid = invitedUserId.trim();
    if (qid.isEmpty || uid.isEmpty) {
      throw const FormatException('Queue id and invited user are required.');
    }
    final controls = await invitationControls(profileId);
    if (controls['allowInvites'] != true) {
      throw StateError('Queue invitations are disabled for this profile.');
    }
    if (await isUserBlocked(profileId, uid)) {
      throw StateError('Cannot invite a blocked user.');
    }
    final invitation = {
      'id': const Uuid().v4(),
      'queueId': qid,
      'invitedUserId': uid,
      'role': role.trim().isEmpty ? 'listener' : role.trim(),
      'status': 'pending',
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    final current = await _mapListByKey(
      '$_queueInvitationsKeyPrefix$profileId',
    );
    await _saveMapList(
      '$_queueInvitationsKeyPrefix$profileId',
      [invitation, ...current].take(800).toList(),
    );
  }

  Future<List<Map<String, dynamic>>> queueInvitations(int profileId) async {
    return _mapListByKey('$_queueInvitationsKeyPrefix$profileId');
  }

  Future<void> respondToQueueInvitation(
    int profileId, {
    required String invitationId,
    required bool accept,
  }) async {
    final id = invitationId.trim();
    if (id.isEmpty) {
      throw const FormatException('Invitation id is required.');
    }
    final current = await queueInvitations(profileId);
    final next = current.map((entry) {
      if (entry['id']?.toString() != id) {
        return entry;
      }
      return {
        ...entry,
        'status': accept ? 'accepted' : 'declined',
        'respondedAtUtc': DateTime.now().toUtc().toIso8601String(),
      };
    }).toList();
    await _saveMapList('$_queueInvitationsKeyPrefix$profileId', next);
  }

  Future<void> appendActivity(
    int profileId, {
    required String actorUserId,
    required String type,
    required String targetType,
    required String targetId,
    String visibility = 'private',
    Map<String, dynamic> metadata = const {},
  }) async {
    final actor = actorUserId.trim();
    final eventType = type.trim();
    final tType = targetType.trim();
    final tId = targetId.trim();
    if (actor.isEmpty || eventType.isEmpty || tType.isEmpty || tId.isEmpty) {
      throw const FormatException(
        'Activity event has missing required fields.',
      );
    }
    final historyVisibility = await personalHistoryVisibility(profileId);
    final resolvedVisibility =
        visibility == 'public' && historyVisibility == 'public'
        ? 'public'
        : 'private';
    final current = await _mapListByKey('$_activityFeedKeyPrefix$profileId');
    await _saveMapList(
      '$_activityFeedKeyPrefix$profileId',
      [
        {
          'id': const Uuid().v4(),
          'actorUserId': actor,
          'type': eventType,
          'targetType': tType,
          'targetId': tId,
          'visibility': resolvedVisibility,
          'metadata': metadata,
          'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
        },
        ...current,
      ].take(3000).toList(),
    );
  }

  Future<List<Map<String, dynamic>>> activityFeed(
    int profileId, {
    bool includePrivate = false,
  }) async {
    final values = await _mapListByKey('$_activityFeedKeyPrefix$profileId');
    if (includePrivate) {
      return values;
    }
    return values
        .where((entry) => entry['visibility']?.toString() == 'public')
        .toList();
  }

  Future<void> addReaction(
    int profileId, {
    required String targetType,
    required String targetId,
    required String userId,
    required String reaction,
  }) async {
    final entry = {
      'id': const Uuid().v4(),
      'targetType': targetType.trim(),
      'targetId': targetId.trim(),
      'userId': userId.trim(),
      'reaction': reaction.trim(),
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    if (entry.values.any((value) => value.toString().isEmpty)) {
      throw const FormatException('Reaction has missing required fields.');
    }
    final current = await _mapListByKey('$_reactionsKeyPrefix$profileId');
    await _saveMapList(
      '$_reactionsKeyPrefix$profileId',
      [entry, ...current].take(3000).toList(),
    );
  }

  Future<void> addComment(
    int profileId, {
    required String targetType,
    required String targetId,
    required String userId,
    required String text,
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      throw const FormatException('Comment text is required.');
    }
    final entry = {
      'id': const Uuid().v4(),
      'targetType': targetType.trim(),
      'targetId': targetId.trim(),
      'userId': userId.trim(),
      'text': trimmedText,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    if ((entry['targetType']?.toString().isEmpty ?? true) ||
        (entry['targetId']?.toString().isEmpty ?? true) ||
        (entry['userId']?.toString().isEmpty ?? true)) {
      throw const FormatException('Comment has missing required fields.');
    }
    final current = await _mapListByKey('$_commentsKeyPrefix$profileId');
    await _saveMapList(
      '$_commentsKeyPrefix$profileId',
      [entry, ...current].take(3000).toList(),
    );
  }

  Future<List<Map<String, dynamic>>> reactionsForTarget(
    int profileId, {
    required String targetType,
    required String targetId,
  }) async {
    final current = await _mapListByKey('$_reactionsKeyPrefix$profileId');
    return current
        .where(
          (entry) =>
              entry['targetType']?.toString() == targetType &&
              entry['targetId']?.toString() == targetId,
        )
        .toList();
  }

  Future<List<Map<String, dynamic>>> commentsForTarget(
    int profileId, {
    required String targetType,
    required String targetId,
  }) async {
    final current = await _mapListByKey('$_commentsKeyPrefix$profileId');
    return current
        .where(
          (entry) =>
              entry['targetType']?.toString() == targetType &&
              entry['targetId']?.toString() == targetId,
        )
        .toList();
  }

  Future<void> setPlaylistPublic(
    int profileId, {
    required String playlistId,
    required bool isPublic,
  }) async {
    final id = playlistId.trim();
    if (id.isEmpty) {
      throw const FormatException('Playlist id is required.');
    }
    final current = await _jsonObject('$_publicPlaylistsKeyPrefix$profileId');
    current[id] = isPublic;
    current['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    await _saveJsonObject('$_publicPlaylistsKeyPrefix$profileId', current);
  }

  Future<bool> isPlaylistPublic(int profileId, String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) {
      return false;
    }
    final current = await _jsonObject('$_publicPlaylistsKeyPrefix$profileId');
    return current[id] == true;
  }

  Future<void> addModerationAction(
    int profileId, {
    required String moderatorUserId,
    required String action,
    required String targetType,
    required String targetId,
    String reason = '',
  }) async {
    final entry = {
      'id': const Uuid().v4(),
      'moderatorUserId': moderatorUserId.trim(),
      'action': action.trim(),
      'targetType': targetType.trim(),
      'targetId': targetId.trim(),
      'reason': reason.trim(),
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    if ((entry['moderatorUserId']?.toString().isEmpty ?? true) ||
        (entry['action']?.toString().isEmpty ?? true) ||
        (entry['targetType']?.toString().isEmpty ?? true) ||
        (entry['targetId']?.toString().isEmpty ?? true)) {
      throw const FormatException(
        'Moderation action has missing required fields.',
      );
    }
    final current = await _mapListByKey('$_moderationKeyPrefix$profileId');
    await _saveMapList(
      '$_moderationKeyPrefix$profileId',
      [entry, ...current].take(2000).toList(),
    );
  }

  Future<List<Map<String, dynamic>>> moderationActions(int profileId) async {
    return _mapListByKey('$_moderationKeyPrefix$profileId');
  }

  Future<void> fileAbuseReport(
    int profileId, {
    required String reporterUserId,
    required String targetType,
    required String targetId,
    required String details,
  }) async {
    final text = details.trim();
    final entry = {
      'id': const Uuid().v4(),
      'reporterUserId': reporterUserId.trim(),
      'targetType': targetType.trim(),
      'targetId': targetId.trim(),
      'details': text,
      'status': 'open',
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    if ((entry['reporterUserId']?.toString().isEmpty ?? true) ||
        (entry['targetType']?.toString().isEmpty ?? true) ||
        (entry['targetId']?.toString().isEmpty ?? true) ||
        text.isEmpty) {
      throw const FormatException('Abuse report has missing required fields.');
    }
    final current = await _mapListByKey('$_abuseReportsKeyPrefix$profileId');
    await _saveMapList(
      '$_abuseReportsKeyPrefix$profileId',
      [entry, ...current].take(3000).toList(),
    );
  }

  Future<List<Map<String, dynamic>>> abuseReports(int profileId) async {
    return _mapListByKey('$_abuseReportsKeyPrefix$profileId');
  }

  Future<void> blockUser(int profileId, String userId) async {
    final target = userId.trim();
    if (target.isEmpty) {
      throw const FormatException('User id is required to block.');
    }
    final blocked = await blockedUsers(profileId);
    if (blocked.contains(target)) {
      return;
    }
    await _saveMapList('$_blockedUsersKeyPrefix$profileId', [
      {
        'userId': target,
        'blockedAtUtc': DateTime.now().toUtc().toIso8601String(),
      },
      ...(await _mapListByKey('$_blockedUsersKeyPrefix$profileId')),
    ]);
  }

  Future<void> unblockUser(int profileId, String userId) async {
    final target = userId.trim();
    final current = await _mapListByKey('$_blockedUsersKeyPrefix$profileId');
    await _saveMapList(
      '$_blockedUsersKeyPrefix$profileId',
      current.where((entry) => entry['userId']?.toString() != target).toList(),
    );
  }

  Future<List<String>> blockedUsers(int profileId) async {
    final current = await _mapListByKey('$_blockedUsersKeyPrefix$profileId');
    final values = <String>[];
    for (final entry in current) {
      final id = entry['userId']?.toString().trim() ?? '';
      if (id.isNotEmpty) {
        values.add(id);
      }
    }
    return values;
  }

  Future<bool> isUserBlocked(int profileId, String userId) async {
    final target = userId.trim();
    if (target.isEmpty) {
      return false;
    }
    final blocked = await blockedUsers(profileId);
    return blocked.contains(target);
  }

  Future<Map<String, dynamic>> invitationControls(int profileId) async {
    final current = await _jsonObject('$_inviteControlsKeyPrefix$profileId');
    return {
      'allowInvites': current['allowInvites'] != false,
      'invitePolicy': current['invitePolicy']?.toString() ?? 'everyone',
      'updatedAtUtc': current['updatedAtUtc']?.toString() ?? '',
    };
  }

  Future<void> saveInvitationControls(
    int profileId, {
    required bool allowInvites,
    required String invitePolicy,
  }) async {
    final normalized = invitePolicy.trim().toLowerCase();
    if (!const {'everyone', 'following', 'none'}.contains(normalized)) {
      throw const FormatException(
        'Invite policy must be everyone, following, or none.',
      );
    }
    await _saveJsonObject('$_inviteControlsKeyPrefix$profileId', {
      'allowInvites': allowInvites,
      'invitePolicy': normalized,
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<MusicTrack>> mostPlayed(int profileId, {int limit = 20}) async {
    final counts = await playCounts(profileId);
    if (counts.isEmpty) {
      return const [];
    }
    final recent = await recentlyPlayed(profileId);
    final favoritesList = await favorites(profileId);
    final stationsList = await stations(profileId);
    final lookup = <String, MusicTrack>{};
    for (final item in recent) {
      lookup[item.id] = item;
    }
    for (final item in favoritesList) {
      lookup[item.id] = item;
    }
    for (final station in stationsList) {
      for (final item in station.queue) {
        lookup[item.id] = item;
      }
    }
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final result = <MusicTrack>[];
    for (final entry in ranked) {
      final track = lookup[entry.key];
      if (track == null) {
        continue;
      }
      result.add(track);
      if (result.length >= limit) {
        break;
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> profileSyncState(int profileId) async {
    final cfg = await config(profileId);
    return {
      'server': cfg?.toJson(includePassword: true),
      'stations': (await stations(
        profileId,
      )).map((station) => station.toJson()).toList(),
      'recentlyPlayed': (await recentlyPlayed(
        profileId,
      )).map((track) => track.toJson()).toList(),
      'favorites': (await favorites(
        profileId,
      )).map((track) => track.toJson()).toList(),
      'playlists': (await playlists(
        profileId,
      )).map((playlist) => playlist.toJson()).toList(),
      'playCounts': await playCounts(profileId),
      'savedQueues': await savedQueues(profileId),
      'sharedQueues': await sharedQueues(profileId),
      'queueHandoffs': await _mapListByKey('$_handoffsKeyPrefix$profileId'),
      'playEvents': (await playEvents(
        profileId,
        includeExcluded: true,
      )).map((event) => event.toJson()).toList(),
      'sessionHistory': await _mapListByKey(
        '$_sessionHistoryKeyPrefix$profileId',
      ),
      'historyPaused': await historyCollectionPaused(profileId),
      'excludedSessions': await _mapListByKey(
        '$_excludedSessionsKeyPrefix$profileId',
      ),
      'scrobbleConfig': await scrobbleConfig(profileId),
      'scrobbleQueue': await _mapListByKey(
        '$_scrobbleQueueKeyPrefix$profileId',
      ),
      'uiState': await uiState(profileId),
      'homeSections': await homeSections(profileId),
      'pins': await pins(profileId),
    };
  }

  Future<void> applyProfileSyncState(
    int profileId,
    Map<String, dynamic> state,
  ) async {
    final serverRaw = state['server'];
    if (serverRaw is Map) {
      final payload = Map<String, dynamic>.from(serverRaw);
      final password = payload['password']?.toString() ?? '';
      if (password.isNotEmpty) {
        await saveConfig(profileId, MusicServerConfig.fromJson(payload));
      }
    }
    final stationsRaw = state['stations'];
    if (stationsRaw is List) {
      final values = <MusicStation>[];
      for (final entry in stationsRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          values.add(MusicStation.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {}
      }
      await saveStations(profileId, values.take(20).toList());
    }
    final recentRaw = state['recentlyPlayed'];
    if (recentRaw is List) {
      final values = <MusicTrack>[];
      for (final entry in recentRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          values.add(MusicTrack.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {}
      }
      final raw = jsonEncode(
        values.take(60).map((item) => item.toJson()).toList(),
      );
      if (!await (await SharedPreferences.getInstance()).setString(
        '$_recentKeyPrefix$profileId',
        raw,
      )) {
        throw StateError('Could not apply synced music recent list.');
      }
    }
    final favoritesRaw = state['favorites'];
    if (favoritesRaw is List) {
      final values = <MusicTrack>[];
      for (final entry in favoritesRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          values.add(MusicTrack.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {}
      }
      if (!await (await SharedPreferences.getInstance()).setString(
        '$_favoritesKeyPrefix$profileId',
        jsonEncode(values.take(200).map((item) => item.toJson()).toList()),
      )) {
        throw StateError('Could not apply synced music favorites list.');
      }
    }
    final playlistsRaw = state['playlists'];
    if (playlistsRaw is List) {
      final values = <MusicPlaylist>[];
      for (final entry in playlistsRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          values.add(MusicPlaylist.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {}
      }
      await savePlaylists(profileId, values.take(60).toList());
    }
    final playCountsRaw = state['playCounts'];
    if (playCountsRaw is Map) {
      final values = <String, int>{};
      for (final entry in playCountsRaw.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) {
          continue;
        }
        final count = int.tryParse(entry.value.toString()) ?? 0;
        if (count > 0) {
          values[key] = count;
        }
      }
      if (!await (await SharedPreferences.getInstance()).setString(
        '$_playCountsKeyPrefix$profileId',
        jsonEncode(values),
      )) {
        throw StateError('Could not apply synced music play counts.');
      }
    }
    final savedQueuesRaw = state['savedQueues'];
    if (savedQueuesRaw is List) {
      final values = <Map<String, dynamic>>[];
      for (final entry in savedQueuesRaw) {
        if (entry is! Map) {
          continue;
        }
        values.add(Map<String, dynamic>.from(entry));
      }
      await _saveMapList(
        '$_savedQueuesKeyPrefix$profileId',
        values.take(60).toList(),
      );
    }
    final sharedQueuesRaw = state['sharedQueues'];
    if (sharedQueuesRaw is List) {
      final values = <Map<String, dynamic>>[];
      for (final entry in sharedQueuesRaw) {
        if (entry is! Map) {
          continue;
        }
        values.add(Map<String, dynamic>.from(entry));
      }
      await _saveMapList(
        '$_sharedQueuesKeyPrefix$profileId',
        values.take(40).toList(),
      );
    }
    final handoffsRaw = state['queueHandoffs'];
    if (handoffsRaw is List) {
      final values = <Map<String, dynamic>>[];
      for (final entry in handoffsRaw) {
        if (entry is! Map) {
          continue;
        }
        values.add(Map<String, dynamic>.from(entry));
      }
      await _saveMapList(
        '$_handoffsKeyPrefix$profileId',
        values.take(100).toList(),
      );
    }
    final playEventsRaw = state['playEvents'];
    if (playEventsRaw is List) {
      final values = <Map<String, dynamic>>[];
      for (final entry in playEventsRaw) {
        if (entry is! Map) {
          continue;
        }
        values.add(Map<String, dynamic>.from(entry));
      }
      await _saveMapList(
        '$_playEventsKeyPrefix$profileId',
        values.take(50000).toList(),
      );
    }
    final sessionHistoryRaw = state['sessionHistory'];
    if (sessionHistoryRaw is List) {
      final values = <Map<String, dynamic>>[];
      for (final entry in sessionHistoryRaw) {
        if (entry is! Map) {
          continue;
        }
        values.add(Map<String, dynamic>.from(entry));
      }
      await _saveMapList(
        '$_sessionHistoryKeyPrefix$profileId',
        values.take(20000).toList(),
      );
    }
    final historyPausedRaw = state['historyPaused'];
    if (historyPausedRaw is bool) {
      await setHistoryCollectionPaused(profileId, historyPausedRaw);
    }
    final excludedSessionsRaw = state['excludedSessions'];
    if (excludedSessionsRaw is List) {
      final values = <Map<String, dynamic>>[];
      for (final entry in excludedSessionsRaw) {
        if (entry is! Map) {
          continue;
        }
        values.add(Map<String, dynamic>.from(entry));
      }
      await _saveMapList(
        '$_excludedSessionsKeyPrefix$profileId',
        values.take(2000).toList(),
      );
    }
    final scrobbleConfigRaw = state['scrobbleConfig'];
    if (scrobbleConfigRaw is Map) {
      final configMap = Map<String, dynamic>.from(scrobbleConfigRaw);
      await saveScrobbleConfig(
        profileId,
        enabled: configMap['enabled'] == true,
        provider: configMap['provider']?.toString() ?? '',
        endpoint: configMap['endpoint']?.toString() ?? '',
        token: configMap['token']?.toString() ?? '',
      );
    }
    final scrobbleQueueRaw = state['scrobbleQueue'];
    if (scrobbleQueueRaw is List) {
      final values = <Map<String, dynamic>>[];
      for (final entry in scrobbleQueueRaw) {
        if (entry is! Map) {
          continue;
        }
        values.add(Map<String, dynamic>.from(entry));
      }
      await _saveMapList(
        '$_scrobbleQueueKeyPrefix$profileId',
        values.take(5000).toList(),
      );
    }
    final uiStateRaw = state['uiState'];
    if (uiStateRaw is Map) {
      await saveUiState(profileId, Map<String, dynamic>.from(uiStateRaw));
    }
    final homeSectionsRaw = state['homeSections'];
    if (homeSectionsRaw is List) {
      final values = <String>[];
      for (final item in homeSectionsRaw) {
        final value = item.toString().trim();
        if (value.isNotEmpty) {
          values.add(value);
        }
      }
      if (values.isNotEmpty) {
        await saveHomeSections(profileId, values);
      }
    }
    final pinsRaw = state['pins'];
    if (pinsRaw is Map) {
      final map = Map<String, dynamic>.from(pinsRaw);
      List<String> valuesFor(String key) {
        final value = map[key];
        if (value is! List) {
          return <String>[];
        }
        final out = <String>[];
        for (final item in value) {
          final text = item.toString().trim();
          if (text.isNotEmpty) {
            out.add(text);
          }
        }
        return out;
      }

      await savePins(profileId, {
        'albums': valuesFor('albums'),
        'artists': valuesFor('artists'),
        'playlists': valuesFor('playlists'),
      });
    }
  }

  Future<void> savePlaybackSession(
    int profileId, {
    required List<MusicTrack> queue,
    required int index,
    required int positionMs,
    required bool shuffleEnabled,
    required List<int> shuffleOrder,
    required String repeatMode,
    List<Map<String, dynamic>>? queueEntries,
    List<Map<String, dynamic>>? playedHistoryEntries,
    String? queueContextLabel,
  }) async {
    final payload = {
      'queue': queue.map((item) => item.toJson()).toList(),
      'index': index,
      'positionMs': positionMs,
      'shuffleEnabled': shuffleEnabled,
      'shuffleOrder': shuffleOrder,
      'repeatMode': repeatMode,
      if (queueEntries != null) 'queueEntries': queueEntries,
      if (playedHistoryEntries != null)
        'playedHistoryEntries': playedHistoryEntries,
      if (queueContextLabel != null) 'queueContextLabel': queueContextLabel,
      'savedAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_sessionKeyPrefix$profileId',
      jsonEncode(payload),
    )) {
      throw StateError('Could not save music playback session.');
    }
  }

  Future<Map<String, dynamic>?> loadPlaybackSession(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_sessionKeyPrefix$profileId',
    );
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<List<Map<String, dynamic>>> savedQueues(int profileId) async {
    final values = await _mapListByKey('$_savedQueuesKeyPrefix$profileId');
    values.sort(
      (a, b) => (b['updatedAtUtc']?.toString() ?? '').compareTo(
        a['updatedAtUtc']?.toString() ?? '',
      ),
    );
    return values;
  }

  Future<void> upsertSavedQueue(
    int profileId,
    Map<String, dynamic> payload,
  ) async {
    final id = payload['id']?.toString().trim() ?? '';
    final name = payload['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Saved queue requires id and name.');
    }
    final current = await savedQueues(profileId);
    final next = [
      {
        ...payload,
        'id': id,
        'name': name,
        'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      },
      ...current.where((item) => item['id']?.toString() != id),
    ].take(60).toList();
    await _saveMapList('$_savedQueuesKeyPrefix$profileId', next);
  }

  Future<void> removeSavedQueue(int profileId, String queueId) async {
    final current = await savedQueues(profileId);
    final next = current
        .where((item) => item['id']?.toString() != queueId)
        .toList();
    await _saveMapList('$_savedQueuesKeyPrefix$profileId', next);
  }

  Future<List<Map<String, dynamic>>> sharedQueues(int profileId) async {
    final values = await _mapListByKey('$_sharedQueuesKeyPrefix$profileId');
    values.sort(
      (a, b) => (b['updatedAtUtc']?.toString() ?? '').compareTo(
        a['updatedAtUtc']?.toString() ?? '',
      ),
    );
    return values;
  }

  Future<void> upsertSharedQueue(
    int profileId,
    Map<String, dynamic> payload,
  ) async {
    final id = payload['id']?.toString().trim() ?? '';
    final name = payload['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Shared queue requires id and name.');
    }
    final current = await sharedQueues(profileId);
    final next = [
      {
        ...payload,
        'id': id,
        'name': name,
        'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      },
      ...current.where((item) => item['id']?.toString() != id),
    ].take(40).toList();
    await _saveMapList('$_sharedQueuesKeyPrefix$profileId', next);
  }

  Future<void> removeSharedQueue(int profileId, String queueId) async {
    final current = await sharedQueues(profileId);
    final next = current
        .where((item) => item['id']?.toString() != queueId)
        .toList();
    await _saveMapList('$_sharedQueuesKeyPrefix$profileId', next);
  }

  Future<void> voteSharedQueueEntry(
    int profileId, {
    required String queueId,
    required String entryId,
    required int delta,
  }) async {
    if (delta != 1 && delta != -1) {
      throw const FormatException('Queue vote delta must be +1 or -1.');
    }
    final queues = await sharedQueues(profileId);
    final targetIndex = queues.indexWhere(
      (item) => item['id']?.toString() == queueId,
    );
    if (targetIndex < 0) {
      throw StateError('Shared queue not found for vote.');
    }
    final target = Map<String, dynamic>.from(queues[targetIndex]);
    final votesRaw = target['votes'];
    final votes = <String, int>{};
    if (votesRaw is Map) {
      for (final item in votesRaw.entries) {
        final key = item.key.toString().trim();
        if (key.isEmpty) {
          continue;
        }
        votes[key] = int.tryParse(item.value.toString()) ?? 0;
      }
    }
    votes[entryId] = (votes[entryId] ?? 0) + delta;
    target['votes'] = votes;
    await upsertSharedQueue(profileId, target);
  }

  Future<String> createQueueHandoff(
    int profileId, {
    required Map<String, dynamic> snapshot,
    String? label,
  }) async {
    final now = DateTime.now().toUtc();
    final code = const Uuid()
        .v4()
        .replaceAll('-', '')
        .substring(0, 8)
        .toUpperCase();
    final entry = {
      'code': code,
      'fromProfileId': profileId,
      'label': (label ?? 'Listening session').trim(),
      'snapshot': snapshot,
      'createdAtUtc': now.toIso8601String(),
      'expiresAtUtc': now.add(const Duration(hours: 24)).toIso8601String(),
    };
    final current = await _mapListByKey('$_handoffsKeyPrefix$profileId');
    final next = [entry, ...current].take(100).toList();
    await _saveMapList('$_handoffsKeyPrefix$profileId', next);
    return code;
  }

  Future<Map<String, dynamic>?> consumeQueueHandoff(
    int profileId,
    String code,
  ) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      return null;
    }
    final current = await _mapListByKey('$_handoffsKeyPrefix$profileId');
    Map<String, dynamic>? found;
    final now = DateTime.now().toUtc();
    final remaining = <Map<String, dynamic>>[];
    for (final item in current) {
      final expires = DateTime.tryParse(
        item['expiresAtUtc']?.toString() ?? '',
      )?.toUtc();
      if (expires != null && expires.isBefore(now)) {
        continue;
      }
      final itemCode = item['code']?.toString().toUpperCase() ?? '';
      if (found == null && itemCode == normalized) {
        found = item;
        continue;
      }
      remaining.add(item);
    }
    await _saveMapList('$_handoffsKeyPrefix$profileId', remaining);
    if (found == null) {
      return null;
    }
    final snapshot = found['snapshot'];
    if (snapshot is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(snapshot);
  }

  Future<void> saveLibraryCache(int profileId, List<MusicTrack> tracks) async {
    final raw = jsonEncode(tracks.map((item) => item.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_libraryCacheKeyPrefix$profileId',
      raw,
    )) {
      throw StateError('Could not save local music library cache.');
    }
  }

  Future<List<MusicTrack>> loadLibraryCache(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_libraryCacheKeyPrefix$profileId',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [];
    }
    final values = <MusicTrack>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(MusicTrack.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    return values;
  }

  Future<List<MusicDownloadEntry>> downloads(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_downloadsKeyPrefix$profileId',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [];
    }
    final values = <MusicDownloadEntry>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(
          MusicDownloadEntry.fromJson(Map<String, dynamic>.from(entry)),
        );
      } catch (_) {}
    }
    return values;
  }

  Future<void> saveDownloads(
    int profileId,
    List<MusicDownloadEntry> values,
  ) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_downloadsKeyPrefix$profileId',
      jsonEncode(values.map((item) => item.toJson()).toList()),
    )) {
      throw StateError('Could not save music download metadata.');
    }
  }

  Future<File?> downloadedFileForTrack(int profileId, MusicTrack track) async {
    final current = await downloads(profileId);
    MusicDownloadEntry? entry;
    for (final item in current) {
      if (item.trackId == track.id) {
        entry = item;
        break;
      }
    }
    if (entry == null) {
      return null;
    }
    final file = File(entry.filePath);
    if (!await file.exists()) {
      return null;
    }
    return file;
  }

  Future<MusicDownloadEntry> downloadTrack(
    int profileId,
    MusicTrack track,
  ) async {
    final streamUrl = track.streamUrl;
    if (streamUrl == null || streamUrl.trim().isEmpty) {
      throw StateError(
        'This track cannot be downloaded because no stream URL was provided.',
      );
    }
    final uri = Uri.parse(streamUrl);
    final appDir = await getApplicationSupportDirectory();
    final root = Directory(
      '${appDir.path}${Platform.pathSeparator}music-cache${Platform.pathSeparator}profile-$profileId',
    );
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final safeName = track.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File('${root.path}${Platform.pathSeparator}$safeName.bin');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}.',
        );
      }
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      final bytes = chunks;
      await file.writeAsBytes(bytes, flush: true);
      final sha = sha256.convert(bytes).toString();
      final entry = MusicDownloadEntry(
        trackId: track.id,
        filePath: file.path,
        sha256Hex: sha,
        sizeBytes: bytes.length,
        updatedAtUtc: DateTime.now().toUtc(),
      );
      final current = await downloads(profileId);
      final next = [
        entry,
        ...current.where((item) => item.trackId != track.id),
      ];
      await saveDownloads(profileId, next.take(2000).toList());
      return entry;
    } finally {
      client.close(force: true);
    }
  }
}

class NavidromeClient {
  final MusicServerConfig config;
  final String _salt = const Uuid().v4().replaceAll('-', '').substring(0, 12);
  late final String _token = md5
      .convert(utf8.encode('${config.password}$_salt'))
      .toString();
  NavidromeClient(this.config);

  Uri _endpoint(String route, {Map<String, dynamic>? query}) {
    final base = Uri.parse(config.baseUrl);
    return base
        .resolve('/rest/$route')
        .replace(
          queryParameters: {
            'u': config.username,
            't': _token,
            's': _salt,
            'v': '1.16.1',
            'c': 'millitoptv',
            'f': 'json',
            ...?query,
          },
        );
  }

  Map<String, dynamic> _unwrap(Map<String, dynamic> payload) {
    final root = payload['subsonic-response'];
    if (root is! Map) {
      throw const FormatException('Music server returned an invalid payload.');
    }
    final response = Map<String, dynamic>.from(root);
    if (response['status']?.toString() != 'ok') {
      final error = response['error'];
      if (error is Map) {
        throw StateError(
          error['message']?.toString() ??
              'Music server returned an unsuccessful status.',
        );
      }
      throw StateError('Music server returned an unsuccessful status.');
    }
    return response;
  }

  Future<Map<String, dynamic>> _get(
    String route, {
    Map<String, dynamic>? query,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = _endpoint(route, query: query);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Music server request failed with HTTP ${response.statusCode}.',
        );
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('Music server response is invalid.');
      }
      return _unwrap(Map<String, dynamic>.from(decoded));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> ping() async {
    await _get('ping.view');
  }

  /// Creates a native Navidrome/Subsonic share for one or more song ids,
  /// mirroring the "Share" action in Navidrome's web console. Returns the
  /// parsed `share` entry from the server, including the real public `url`
  /// that recipients (even without an account) can open to stream and,
  /// if the server has downloads enabled, download the shared tracks.
  Future<Map<String, dynamic>> createShare({
    required List<String> ids,
    String? description,
    DateTime? expires,
  }) async {
    final trimmedIds = ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (trimmedIds.isEmpty) {
      throw const FormatException(
        'At least one track id is required to create a share.',
      );
    }
    final payload = await _get(
      'createShare.view',
      query: {
        'id': trimmedIds,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (expires != null)
          'expires': '${expires.toUtc().millisecondsSinceEpoch}',
      },
    );
    final shares = payload['shares'];
    final list = shares is Map ? shares['share'] : null;
    if (list is! List || list.isEmpty || list.first is! Map) {
      throw StateError('Music server did not return a share link.');
    }
    return Map<String, dynamic>.from(list.first as Map);
  }

  Future<void> deleteShare(String shareId) async {
    final id = shareId.trim();
    if (id.isEmpty) {
      throw const FormatException('Share id is required to delete a share.');
    }
    await _get('deleteShare.view', query: {'id': id});
  }

  Future<void> setSongFavorite(String songId, bool isFavorite) async {
    final id = songId.trim();
    if (id.isEmpty) {
      throw const FormatException(
        'Song id is required to update favorite state.',
      );
    }
    await _get(isFavorite ? 'star.view' : 'unstar.view', query: {'id': id});
  }

  Future<List<MusicTrack>> starredSongs() async {
    final payload = await _get('getStarred2.view');
    final root = payload['starred2'];
    if (root is! Map) {
      return const [];
    }
    final songsRaw = root['song'];
    if (songsRaw is! List) {
      return const [];
    }
    final values = <MusicTrack>[];
    for (final entry in songsRaw) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(_parseTrack(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    return values;
  }

  Uri streamUri(String songId) =>
      _endpoint('stream.view', query: {'id': songId});

  Uri coverArtUri(String coverArtId) =>
      _endpoint('getCoverArt.view', query: {'id': coverArtId});

  MusicTrack _parseTrack(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const FormatException('Music track id is missing.');
    }
    final title = json['title']?.toString().trim() ?? '';
    final artist = json['artist']?.toString().trim() ?? '';
    final album = json['album']?.toString().trim() ?? '';
    if (title.isEmpty || artist.isEmpty || album.isEmpty) {
      throw const FormatException('Music track metadata is incomplete.');
    }
    return MusicTrack(
      id: id,
      title: title,
      artist: artist,
      album: album,
      genre: json['genre']?.toString().trim(),
      year: int.tryParse(json['year']?.toString() ?? ''),
      durationSeconds: int.tryParse(json['duration']?.toString() ?? '') ?? 0,
      coverArtId: json['coverArt']?.toString().trim(),
      streamUrl: streamUri(id).toString(),
    );
  }

  Future<List<MusicTrack>> searchSongs(String query, {int limit = 30}) async {
    final payload = await _get(
      'search3.view',
      query: {
        'query': query,
        'songCount': '$limit',
        'albumCount': '0',
        'artistCount': '0',
      },
    );
    final result = payload['searchResult3'];
    if (result is! Map) {
      return const [];
    }
    final songs = result['song'];
    if (songs is! List) {
      return const [];
    }
    final values = <MusicTrack>[];
    for (final entry in songs) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(_parseTrack(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    return values;
  }

  Future<List<MusicTrack>> randomSongs({
    int limit = 24,
    String? genre,
    int? fromYear,
    int? toYear,
  }) async {
    final payload = await _get(
      'getRandomSongs.view',
      query: {
        'size': '$limit',
        if (genre != null && genre.trim().isNotEmpty) 'genre': genre.trim(),
        if (fromYear != null) 'fromYear': '$fromYear',
        if (toYear != null) 'toYear': '$toYear',
      },
    );
    final random = payload['randomSongs'];
    if (random is! Map) {
      return const [];
    }
    final songs = random['song'];
    if (songs is! List) {
      return const [];
    }
    final values = <MusicTrack>[];
    for (final entry in songs) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(_parseTrack(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    return values;
  }

  Future<List<MusicTrack>> stationFromSeed(
    MusicTrack seed, {
    int limit = 30,
  }) async {
    final byArtist = await searchSongs(seed.artist, limit: 120);
    final byTitle = await searchSongs(seed.title, limit: 80);
    final aroundEra = await randomSongs(
      limit: 60,
      genre: seed.genre,
      fromYear: seed.year == null ? null : seed.year! - 4,
      toYear: seed.year == null ? null : seed.year! + 4,
    );
    final merged = <MusicTrack>[seed, ...byArtist, ...byTitle, ...aroundEra];
    final deduped = <String, MusicTrack>{};
    for (final entry in merged) {
      if (entry.id == seed.id) {
        continue;
      }
      deduped[entry.id] = entry;
    }
    final values = deduped.values.toList();
    values.shuffle(Random());
    return values.take(limit).toList();
  }

  Future<Map<String, dynamic>> lyricsForSong(MusicTrack track) async {
    Map<String, dynamic> payload;
    try {
      payload = await _get('getLyricsBySongId.view', query: {'id': track.id});
    } catch (_) {
      payload = await _get(
        'getLyrics.view',
        query: {'artist': track.artist, 'title': track.title},
      );
    }
    final timed = <Map<String, dynamic>>[];
    final credits = <String>[];
    var plain = '';

    void parseLyricObject(Map<String, dynamic> raw) {
      final text = raw['value']?.toString() ?? raw['text']?.toString() ?? '';
      final cleaned = text.trim();
      if (cleaned.isNotEmpty && plain.isEmpty) {
        plain = cleaned;
      }
      final linesRaw = raw['line'] ?? raw['lines'];
      if (linesRaw is List) {
        for (final entry in linesRaw) {
          if (entry is! Map) {
            continue;
          }
          final lineMap = Map<String, dynamic>.from(entry);
          final lineText =
              lineMap['value']?.toString().trim() ??
              lineMap['text']?.toString().trim() ??
              '';
          final startRaw = lineMap['start'] ?? lineMap['time'];
          final startMs = int.tryParse(startRaw?.toString() ?? '');
          if (lineText.isEmpty || startMs == null || startMs < 0) {
            continue;
          }
          timed.add({'timeMs': startMs, 'text': lineText});
        }
      }
      final by = raw['artist']?.toString().trim() ?? '';
      if (by.isNotEmpty) {
        credits.add('Lyrics by $by');
      }
      final provider = raw['provider']?.toString().trim() ?? '';
      if (provider.isNotEmpty) {
        credits.add('Source: $provider');
      }
    }

    final listRoot = payload['lyricsList'];
    if (listRoot is Map) {
      final lyric = listRoot['structuredLyrics'] ?? listRoot['lyrics'];
      if (lyric is Map) {
        parseLyricObject(Map<String, dynamic>.from(lyric));
      } else if (lyric is List) {
        for (final item in lyric) {
          if (item is! Map) {
            continue;
          }
          parseLyricObject(Map<String, dynamic>.from(item));
        }
      }
    }
    final lyricsRoot = payload['lyrics'];
    if (lyricsRoot is Map) {
      parseLyricObject(Map<String, dynamic>.from(lyricsRoot));
    }
    if (timed.isNotEmpty) {
      timed.sort((a, b) => (a['timeMs'] as int).compareTo(b['timeMs'] as int));
    }
    return {
      'plain': plain,
      'timed': timed,
      'credits': credits.toSet().toList(),
    };
  }

  Future<List<MusicTrack>> allSongs({int limit = 1200}) async {
    final deduped = <String, MusicTrack>{};
    final albumIds = <String>[];
    const pageSize = 200;
    for (var offset = 0; offset < 5000; offset += pageSize) {
      final payload = await _get(
        'getAlbumList2.view',
        query: {
          'type': 'alphabeticalByName',
          'size': '$pageSize',
          'offset': '$offset',
        },
      );
      final albumListRoot = payload['albumList2'];
      if (albumListRoot is! Map) {
        break;
      }
      final albumEntries = albumListRoot['album'];
      if (albumEntries is! List || albumEntries.isEmpty) {
        break;
      }
      for (final entry in albumEntries) {
        if (entry is! Map) {
          continue;
        }
        final id = entry['id']?.toString().trim() ?? '';
        if (id.isNotEmpty) {
          albumIds.add(id);
        }
      }
      if (albumEntries.length < pageSize) {
        break;
      }
    }
    for (final albumId in albumIds) {
      final payload = await _get('getAlbum.view', query: {'id': albumId});
      final albumRoot = payload['album'];
      if (albumRoot is! Map) {
        continue;
      }
      final songs = albumRoot['song'];
      if (songs is! List) {
        continue;
      }
      for (final item in songs) {
        if (item is! Map) {
          continue;
        }
        try {
          final parsed = _parseTrack(Map<String, dynamic>.from(item));
          deduped[parsed.id] = parsed;
        } catch (_) {}
      }
      if (deduped.length >= limit) {
        break;
      }
    }
    if (deduped.isEmpty) {
      final fallback = await randomSongs(limit: limit.clamp(24, 240));
      for (final track in fallback) {
        deduped[track.id] = track;
      }
    }
    final values = deduped.values.toList();
    values.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return values.take(limit).toList();
  }
}
