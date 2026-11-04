import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
    if (id.isEmpty || name.isEmpty || seedTrackId.isEmpty || seedTitle.isEmpty) {
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
    final password = await _storage.read(
      key: '$_passwordKeyPrefix$profileId',
    );
    if (password == null || password.isEmpty) {
      return null;
    }
    map['password'] = password;
    return MusicServerConfig.fromJson(map);
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

  Future<Map<String, dynamic>> profileSyncState(int profileId) async {
    final cfg = await config(profileId);
    return {
      'server': cfg?.toJson(includePassword: true),
      'stations': (await stations(profileId))
          .map((station) => station.toJson())
          .toList(),
      'recentlyPlayed': (await recentlyPlayed(profileId))
          .map((track) => track.toJson())
          .toList(),
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
      final raw = jsonEncode(values.take(60).map((item) => item.toJson()).toList());
      if (!await (await SharedPreferences.getInstance()).setString(
        '$_recentKeyPrefix$profileId',
        raw,
      )) {
        throw StateError('Could not apply synced music recent list.');
      }
    }
  }
}

class NavidromeClient {
  final MusicServerConfig config;
  NavidromeClient(this.config);

  Uri _endpoint(
    String route, {
    Map<String, String>? query,
  }) {
    final base = Uri.parse(config.baseUrl);
    final salt = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    final token = md5.convert(utf8.encode('${config.password}$salt')).toString();
    return base.resolve('/rest/$route').replace(
      queryParameters: {
        'u': config.username,
        't': token,
        's': salt,
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
    Map<String, String>? query,
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

  Uri streamUri(String songId) => _endpoint('stream.view', query: {'id': songId});

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
      query: {'query': query, 'songCount': '$limit', 'albumCount': '0', 'artistCount': '0'},
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
    final merged = <MusicTrack>[
      seed,
      ...byArtist,
      ...byTitle,
      ...aroundEra,
    ];
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
}
