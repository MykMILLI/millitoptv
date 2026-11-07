import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

String _webUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Podcast URLs must be HTTP(S) without credentials.',
    );
  }
  return uri.toString();
}

class PodcastShow {
  final String id, title, author, feedUrl, artwork;
  const PodcastShow({
    required this.id,
    required this.title,
    required this.author,
    required this.feedUrl,
    required this.artwork,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'feedUrl': feedUrl,
    'artwork': artwork,
  };

  factory PodcastShow.fromJson(Map<String, dynamic> json) => PodcastShow(
    id: json['id'] as String,
    title: json['title'] as String,
    author: json['author'] as String,
    feedUrl: _webUrl(json['feedUrl'] as String),
    artwork: json['artwork'] as String,
  );
}

class PodcastEpisode {
  final String id, title, description, mediaUrl, artwork;
  final PodcastShow show;
  final bool video;
  final DateTime? published;
  final Duration duration;
  const PodcastEpisode({
    required this.id,
    required this.title,
    required this.description,
    required this.mediaUrl,
    required this.artwork,
    required this.show,
    required this.video,
    required this.published,
    required this.duration,
  });

  String get key => '${show.id}|$id';
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'mediaUrl': mediaUrl,
    'artwork': artwork,
    'show': show.toJson(),
    'video': video,
    'published': published?.toIso8601String(),
    'durationMs': duration.inMilliseconds,
  };

  factory PodcastEpisode.fromJson(Map<String, dynamic> json) => PodcastEpisode(
    id: json['id'] as String,
    title: json['title'] as String,
    description: json['description'] as String,
    mediaUrl: _webUrl(json['mediaUrl'] as String),
    artwork: json['artwork'] as String,
    show: PodcastShow.fromJson(Map<String, dynamic>.from(json['show'] as Map)),
    video: json['video'] == true,
    published: DateTime.tryParse(json['published']?.toString() ?? ''),
    duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
  );
}

class PodcastResumeEntry {
  final PodcastEpisode episode;
  final Duration position, duration;
  final DateTime updatedAtUtc;
  const PodcastResumeEntry({
    required this.episode, required this.position,
    required this.duration, required this.updatedAtUtc,
  });
}

typedef PodcastFetch = Future<String> Function(Uri uri);

DateTime? _podcastDate(String value) {
  if (value.isEmpty) return null;
  final iso = DateTime.tryParse(value);
  if (iso != null) return iso.toUtc();
  final offset = RegExp(r'([+-])(\d{2})(\d{2})$').firstMatch(value);
  var normalized = value;
  var offsetMinutes = 0;
  if (offset != null) {
    offsetMinutes =
        (int.parse(offset[2]!) * 60 + int.parse(offset[3]!)) *
        (offset[1] == '-' ? -1 : 1);
    normalized = '${value.substring(0, offset.start)}GMT';
  } else {
    normalized = value.replaceFirst(RegExp(r'\bUTC$'), 'GMT');
  }
  try {
    return HttpDate.parse(
      normalized,
    ).toUtc().subtract(Duration(minutes: offsetMinutes));
  } on HttpException {
    debugPrint('Podcast feed has an unsupported publication date: $value');
    return null;
  }
}

class PodcastCatalog {
  final PodcastFetch fetch;
  PodcastCatalog({PodcastFetch? fetch}) : fetch = fetch ?? _fetch;

  static Future<String> _fetch(Uri uri) async {
    _webUrl(uri.toString());
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'MILLITOPTV-Podcasts/1.0',
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException(
            'Podcast request failed (HTTP ${response.statusCode}).',
            uri: uri,
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024) {
            throw const FormatException('Podcast feed exceeds the 8 MB limit.');
          }
        }
        return utf8.decode(bytes);
      })().timeout(const Duration(seconds: 25));
    } finally {
      client.close(force: true);
    }
  }

  Future<List<PodcastShow>> search(String term) async {
    if (term.trim().isEmpty) {
      throw const FormatException('Enter a podcast name or topic.');
    }
    final uri = Uri.https('itunes.apple.com', '/search', {
      'term': term.trim(),
      'media': 'podcast',
      'entity': 'podcast',
      'limit': '24',
    });
    final data = jsonDecode(await fetch(uri));
    if (data is! Map || data['results'] is! List) {
      throw const FormatException(
        'Apple podcast directory returned an invalid response.',
      );
    }
    final shows = <PodcastShow>[];
    for (final item in data['results'] as List) {
      if (item is! Map || item['feedUrl'] is! String) continue;
      shows.add(
        PodcastShow(
          id: item['collectionId'].toString(),
          title: item['collectionName']?.toString() ?? 'Untitled podcast',
          author: item['artistName']?.toString() ?? '',
          feedUrl: _webUrl(item['feedUrl'] as String),
          artwork:
              item['artworkUrl600']?.toString() ??
              item['artworkUrl100']?.toString() ??
              '',
        ),
      );
    }
    return shows;
  }

  Future<List<PodcastEpisode>> episodes(PodcastShow show) async =>
      parseFeed(await fetch(Uri.parse(_webUrl(show.feedUrl))), show);

  static List<PodcastEpisode> parseFeed(String source, PodcastShow show) {
    final document = XmlDocument.parse(source);
    final episodes = <PodcastEpisode>[];
    final seen = <String>{};
    String childText(XmlElement element, String name) =>
        element.childElements
            .where((e) => e.name.local == name)
            .map((e) => e.innerText.trim())
            .firstOrNull ??
        '';
    for (final item in document.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'item',
    )) {
      final enclosure = item.childElements
          .where((e) => e.name.local == 'enclosure')
          .firstOrNull;
      final media = enclosure?.getAttribute('url') ?? '';
      if (media.isEmpty) continue;
      final url = _webUrl(Uri.parse(show.feedUrl).resolve(media).toString());
      final type = enclosure?.getAttribute('type')?.toLowerCase() ?? '';
      final extension = Uri.parse(url).path.toLowerCase();
      final video =
          type.startsWith('video/') ||
          RegExp(r'\.(mp4|m4v|mov|webm)$').hasMatch(extension);
      if (!video &&
          !type.startsWith('audio/') &&
          !RegExp(r'\.(mp3|m4a|aac|ogg|opus|wav)$').hasMatch(extension)) {
        continue;
      }
      final guid = childText(item, 'guid');
      final id = guid.isEmpty ? url : guid;
      if (!seen.add(id)) continue;
      final parts = childText(item, 'duration').split(':');
      var seconds = 0;
      for (final part in parts) {
        seconds = seconds * 60 + (double.tryParse(part)?.round() ?? 0);
      }
      final date = childText(item, 'pubDate');
      final published = _podcastDate(date);
      final image = item.childElements
          .where((e) => e.name.local == 'image')
          .firstOrNull;
      final rawDescription = childText(item, 'description');
      final description = rawDescription
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .trim();
      episodes.add(
        PodcastEpisode(
          id: id,
          title: childText(item, 'title'),
          description: description.substring(
            0,
            description.length.clamp(0, 1600),
          ),
          mediaUrl: url,
          artwork: image?.getAttribute('href') ?? show.artwork,
          show: show,
          video: video,
          published: published,
          duration: Duration(seconds: seconds),
        ),
      );
    }
    episodes.sort(
      (a, b) => (b.published ?? DateTime(1970)).compareTo(
        a.published ?? DateTime(1970),
      ),
    );
    return episodes;
  }
}

class PodcastLibrary {
  final List<PodcastShow> following;
  final List<PodcastEpisode> queue;
  final Map<String, dynamic> progress;
  final double speed;
  const PodcastLibrary({
    this.following = const [],
    this.queue = const [],
    this.progress = const {},
    this.speed = 1,
  });

  List<PodcastResumeEntry> get resumableEpisodes {
    final entries = <PodcastResumeEntry>[];
    for (final entry in progress.entries) {
      final raw = entry.value;
      if (raw is! Map || raw['positionMs'] is! int) {
        throw const FormatException('Podcast resume progress is invalid.');
      }
      final positionMs = raw['positionMs'] as int;
      if (positionMs < 0) {
        throw const FormatException('Podcast resume position is invalid.');
      }
      if (raw['completed'] == true || positionMs == 0) continue;
      if (raw['episode'] is! Map) {
        throw const FormatException('Podcast resume episode is missing.');
      }
      final episode = PodcastEpisode.fromJson(Map<String, dynamic>.from(raw['episode'] as Map));
      if (entry.key != episode.key) {
        throw const FormatException('Podcast resume episode identifier does not match.');
      }
      final rawDuration = raw['durationMs'];
      if (rawDuration != null && (rawDuration is! int || rawDuration < 0)) {
        throw const FormatException('Podcast resume duration is invalid.');
      }
      final durationMs = rawDuration is int && rawDuration > 0
          ? rawDuration : episode.duration.inMilliseconds;
      if (durationMs > 0 && positionMs >= durationMs) continue;
      final date = DateTime.tryParse(raw['updatedAtUtc']?.toString() ?? '');
      if (date == null) {
        throw const FormatException('Podcast resume timestamp is invalid.');
      }
      entries.add(PodcastResumeEntry(
        episode: episode, position: Duration(milliseconds: positionMs),
        duration: Duration(milliseconds: durationMs), updatedAtUtc: date.toUtc(),
      ));
    }
    entries.sort((a, b) => b.updatedAtUtc.compareTo(a.updatedAtUtc));
    return entries;
  }
  Map<String, dynamic> toJson() => {
    'following': following.map((e) => e.toJson()).toList(),
    'queue': queue.map((e) => e.toJson()).toList(),
    'progress': progress,
    'speed': speed,
  };
  factory PodcastLibrary.fromJson(Map<String, dynamic> json) {
    final speed = (json['speed'] as num? ?? 1).toDouble();
    return PodcastLibrary(
      following: (json['following'] as List? ?? [])
          .map((e) => PodcastShow.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      queue: (json['queue'] as List? ?? [])
          .map(
            (e) => PodcastEpisode.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      progress: Map<String, dynamic>.from(json['progress'] as Map? ?? {}),
      speed: speed.clamp(0.5, 3),
    );
  }
}

class PodcastStore {
  Future<PodcastLibrary> load(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'podcasts.v1.$profile',
    );
    return raw == null
        ? const PodcastLibrary()
        : PodcastLibrary.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw) as Map),
          );
  }

  Future<void> save(int profile, PodcastLibrary library) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      'podcasts.v1.$profile',
      jsonEncode(library.toJson()),
    )) {
      throw StateError('Could not save your podcast library.');
    }
  }

  Future<void> applySync(int profile, Map<String, dynamic> remote) async {
    final incoming = PodcastLibrary.fromJson(remote);
    final local = await load(profile);
    final merged = Map<String, dynamic>.from(incoming.progress);
    for (final entry in local.progress.entries) {
      final other = merged[entry.key];
      final localDate = DateTime.tryParse(
        (entry.value as Map)['updatedAtUtc']?.toString() ?? '',
      );
      final remoteDate = other is Map
          ? DateTime.tryParse(other['updatedAtUtc']?.toString() ?? '')
          : null;
      if (localDate != null &&
          (remoteDate == null || localDate.isAfter(remoteDate))) {
        merged[entry.key] = entry.value;
      }
    }
    await save(
      profile,
      PodcastLibrary(
        following: incoming.following,
        queue: incoming.queue,
        progress: merged,
        speed: incoming.speed,
      ),
    );
  }
}
