// SPDX-License-Identifier: GPL-3.0-only
// Adapted from prateekmedia/pstube; see ../UPSTREAM.md for revision and changes.
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

String webUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Expected an HTTP(S) URL without credentials.');
  }
  return value;
}

class TubeVideo {
  final String id, title, author, channelId, thumbnail, avatar, description;
  final int views, seconds;
  final bool live;
  final String published;
  const TubeVideo({
    required this.id,
    required this.title,
    required this.author,
    this.channelId = '',
    this.thumbnail = '',
    this.avatar = '',
    this.description = '',
    this.views = 0,
    this.seconds = 0,
    this.live = false,
    this.published = '',
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'channelId': channelId,
    'thumbnail': thumbnail,
    'avatar': avatar,
    'description': description,
    'views': views,
    'seconds': seconds,
    'live': live,
    'published': published,
  };
  factory TubeVideo.fromJson(Map<String, dynamic> value) => TubeVideo(
    id: value['id'] as String,
    title: value['title'] as String,
    author: value['author'] as String,
    channelId: value['channelId'] as String? ?? '',
    thumbnail: value['thumbnail'] as String? ?? '',
    avatar: value['avatar'] as String? ?? '',
    description: value['description'] as String? ?? '',
    views: (value['views'] as num? ?? 0).toInt(),
    seconds: (value['seconds'] as num? ?? 0).toInt(),
    live: value['live'] == true,
    published: value['published'] as String? ?? '',
  );
}

class TubeStream {
  final String url, quality;
  final bool videoOnly;
  final int height;
  const TubeStream({
    required this.url,
    required this.quality,
    this.videoOnly = false,
    this.height = 0,
  });
}

class TubeSubtitle {
  final String url, label;
  const TubeSubtitle(this.url, this.label);
}

class TubeDetails {
  final TubeVideo video;
  final List<TubeStream> videoStreams, audioStreams;
  final List<TubeSubtitle> subtitles;
  final List<TubeVideo> related;
  const TubeDetails({
    required this.video,
    required this.videoStreams,
    required this.audioStreams,
    this.subtitles = const [],
    this.related = const [],
  });
}

class TubePage {
  final List<TubeVideo> videos;
  final Future<TubePage?> Function()? next;
  const TubePage(this.videos, {this.next});
}

class TubeComment {
  final String author, text, published;
  final int likes;
  const TubeComment(this.author, this.text, this.published, this.likes);
}

class TubeComments {
  final List<TubeComment> comments;
  final Future<TubeComments?> Function()? next;
  const TubeComments(this.comments, {this.next});
}

abstract interface class TubeEngine {
  Future<TubePage> search(String query);
  Future<TubePage> trending();
  Future<TubePage> channel(String id);
  Future<TubePage> playlist(String id);
  Future<TubeDetails> details(String id);
  Future<TubeComments> comments(String id);
  void close();
}

typedef PipedFetch = Future<Object?> Function(Uri uri);

class PsTubeEngine implements TubeEngine {
  final yt.YoutubeExplode youtube;
  final http.Client _http;
  final PipedFetch? _fetch;
  final void Function(String message)? onFallback;
  String pipedUrl;
  final _playlistCursors = <StreamIterator<yt.Video>>[];
  PsTubeEngine({
    yt.YoutubeExplode? youtube,
    http.Client? client,
    PipedFetch? fetch,
    this.pipedUrl = 'https://api.piped.private.coffee',
    this.onFallback,
  }) : youtube = youtube ?? yt.YoutubeExplode(),
       _http = client ?? http.Client(),
       _fetch = fetch {
    webUrl(pipedUrl);
  }

  Future<Object?> _piped(
    String route, [
    Map<String, String> query = const {},
  ]) async {
    final uri = Uri.parse(
      '${webUrl(pipedUrl).replaceFirst(RegExp(r'/+$'), '')}/$route',
    ).replace(queryParameters: query.isEmpty ? null : query);
    if (_fetch != null) return _fetch(uri);
    final response = await _http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException('Piped HTTP ${response.statusCode}', uri);
    }
    if (response.bodyBytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Piped response exceeds 8 MB.');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<T> _fallback<T>(
    String operation,
    Future<T> Function() primary,
    Future<T> Function() fallback,
  ) async {
    try {
      return await primary().timeout(const Duration(seconds: 20));
    } catch (e) {
      onFallback?.call('$operation: YouTubeExplode failed; trying Piped. $e');
      try {
        return await fallback();
      } catch (secondary) {
        throw StateError(
          '$operation failed. YouTubeExplode: $e. Piped: $secondary',
        );
      }
    }
  }

  TubeVideo _video(yt.Video video) => TubeVideo(
    id: video.id.value,
    title: video.title,
    author: video.author,
    channelId: video.channelId.value,
    thumbnail: video.thumbnails.highResUrl,
    seconds: video.duration?.inSeconds ?? 0,
    views: video.engagement.viewCount,
    description: video.description.substring(
      0,
      video.description.length.clamp(0, 2000),
    ),
    published: video.uploadDate?.toIso8601String() ?? '',
    live: video.isLive,
  );

  static String _id(String value) {
    final uri = Uri.tryParse(value);
    return uri?.queryParameters['v'] ?? value.split('/').last;
  }

  static TubeVideo pipedVideo(Map<String, dynamic> item) => TubeVideo(
    id: _id(item['url'] as String? ?? item['id'] as String? ?? ''),
    title: item['title'] as String? ?? '',
    author: item['uploaderName'] as String? ?? '',
    channelId: (item['uploaderUrl'] as String? ?? '').split('/').last,
    thumbnail: item['thumbnail'] as String? ?? '',
    avatar: item['uploaderAvatar'] as String? ?? '',
    seconds: (item['duration'] as num? ?? 0).toInt().clamp(0, 1 << 31),
    views: (item['views'] as num? ?? 0).toInt(),
    live: item['isLive'] == true,
    published: item['uploadedDate'] as String? ?? '',
  );

  TubePage _page(
    Object? data,
    String route,
    Map<String, String> query, {
    String field = 'items',
  }) {
    final List<dynamic> items;
    String? next;
    if (data is List) {
      items = data;
    } else if (data is Map && data[field] is List) {
      items = data[field] as List;
      next = data['nextpage']?.toString();
    } else {
      throw const FormatException('Invalid Piped video list.');
    }
    final videos = items
        .whereType<Map>()
        .where((item) => item['type'] == null || item['type'] == 'stream')
        .map((item) => pipedVideo(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty)
        .toList();
    final token = next;
    return TubePage(
      videos,
      next: token == null || token.isEmpty || token == 'null'
          ? null
          : () async => _page(
              await _piped(route, {...query, 'nextpage': token}),
              route,
              query,
              field: field,
            ),
    );
  }

  Future<TubePage> _searchPage(yt.VideoSearchList results) async => TubePage(
    results.map(_video).toList(),
    next: () async {
      final next = await results.nextPage().timeout(
        const Duration(seconds: 20),
      );
      return next == null ? null : _searchPage(next);
    },
  );

  @override
  Future<TubePage> search(String query) {
    if (query.trim().isEmpty) {
      throw const FormatException('Enter a search query.');
    }
    return _fallback(
      'Search',
      () async => _searchPage(await youtube.search.search(query)),
      () async => _page(
        await _piped('search', {'q': query, 'filter': 'videos'}),
        'nextpage/search',
        {'q': query, 'filter': 'videos'},
      ),
    );
  }

  @override
  Future<TubePage> trending() async =>
      _page(await _piped('trending', {'region': 'US'}), 'trending', const {});

  @override
  Future<TubePage> channel(String id) => _fallback(
    'Channel',
    () async {
      return _channelPage(await youtube.channels.getUploadsFromPage(id));
    },
    () async => _page(
      await _piped('channel/$id'),
      'nextpage/channel/$id',
      const {},
      field: 'relatedStreams',
    ),
  );

  @override
  Future<TubePage> playlist(String id) => _fallback(
    'Playlist',
    () async {
      final cursor = StreamIterator(youtube.playlists.getVideos(id));
      _playlistCursors.add(cursor);
      return _playlistPage(cursor);
    },
    () async => _page(
      await _piped('playlists/$id'),
      'nextpage/playlists/$id',
      const {},
      field: 'relatedStreams',
    ),
  );

  Future<TubePage> _channelPage(yt.ChannelUploadsList results) async =>
      TubePage(
        results.map(_video).toList(),
        next: () async {
          final next = await results.nextPage().timeout(
            const Duration(seconds: 20),
          );
          return next == null ? null : _channelPage(next);
        },
      );

  Future<TubePage> _playlistPage(StreamIterator<yt.Video> cursor) async {
    final videos = <TubeVideo>[];
    try {
      while (videos.length < 30) {
        if (!await cursor.moveNext().timeout(const Duration(seconds: 20))) {
          _playlistCursors.remove(cursor);
          await cursor.cancel();
          return TubePage(videos);
        }
        videos.add(_video(cursor.current));
      }
      return TubePage(videos, next: () => _playlistPage(cursor));
    } catch (_) {
      _playlistCursors.remove(cursor);
      await cursor.cancel();
      rethrow;
    }
  }

  @override
  Future<TubeDetails> details(String id) =>
      _fallback('Video playback', () async {
        final video = await youtube.videos.get(id);
        final manifest = await youtube.videos.streamsClient.getManifest(id);
        final videos = <TubeStream>[
          ...manifest.muxed.map(
            (stream) => TubeStream(
              url: stream.url.toString(),
              quality: stream.qualityLabel,
              height: stream.videoResolution.height,
            ),
          ),
          ...manifest.videoOnly.map(
            (stream) => TubeStream(
              url: stream.url.toString(),
              quality: stream.videoQualityLabel,
              height: stream.videoResolution.height,
              videoOnly: true,
            ),
          ),
        ]..sort((a, b) => b.height.compareTo(a.height));
        if (videos.isEmpty) {
          throw StateError(
            'No playable video streams. This video may require sign-in.',
          );
        }
        final audio = manifest.audioOnly.toList()
          ..sort(
            (a, b) =>
                b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
          );
        return TubeDetails(
          video: _video(video),
          videoStreams: videos,
          audioStreams: audio
              .map(
                (stream) => TubeStream(
                  url: stream.url.toString(),
                  quality: '${stream.bitrate.kiloBitsPerSecond.round()} kbps',
                ),
              )
              .toList(),
        );
      }, () async => pipedDetails(id, await _piped('streams/$id')));

  static TubeDetails pipedDetails(String id, Object? data) {
    if (data is! Map) {
      throw const FormatException('Invalid Piped video details.');
    }
    List<TubeStream> streams(String field) => (data[field] as List? ?? [])
        .whereType<Map>()
        .where((item) => item['url'] is String)
        .map(
          (item) => TubeStream(
            url: webUrl(item['url'] as String),
            quality: item['quality']?.toString() ?? 'Auto',
            height: (item['height'] as num? ?? 0).toInt(),
            videoOnly: item['videoOnly'] == true,
          ),
        )
        .toList();
    final videos = streams('videoStreams')
      ..sort((a, b) => b.height.compareTo(a.height));
    final hls = data['hls'] as String?;
    if (hls != null && hls.isNotEmpty) {
      videos.insert(
        0,
        TubeStream(url: webUrl(hls), quality: 'Live / adaptive'),
      );
    }
    if (videos.isEmpty) {
      throw StateError('Piped returned no playable video streams.');
    }
    return TubeDetails(
      video: TubeVideo(
        id: id,
        title: data['title'] as String? ?? '',
        author: data['uploader'] as String? ?? '',
        channelId: (data['uploaderUrl'] as String? ?? '').split('/').last,
        thumbnail: data['thumbnailUrl'] as String? ?? '',
        avatar: data['uploaderAvatar'] as String? ?? '',
        description: data['description'] as String? ?? '',
        seconds: (data['duration'] as num? ?? 0).toInt(),
        live: data['livestream'] == true,
        views: (data['views'] as num? ?? 0).toInt(),
        published: data['uploadDate'] as String? ?? '',
      ),
      videoStreams: videos,
      audioStreams: streams('audioStreams'),
      subtitles: (data['subtitles'] as List? ?? [])
          .whereType<Map>()
          .where((item) => item['url'] is String)
          .map(
            (item) => TubeSubtitle(
              webUrl(item['url'] as String),
              item['name']?.toString() ?? 'Subtitles',
            ),
          )
          .toList(),
      related: (data['relatedStreams'] as List? ?? [])
          .whereType<Map>()
          .map((item) => pipedVideo(Map<String, dynamic>.from(item)))
          .toList(),
    );
  }

  @override
  Future<TubeComments> comments(String id) async {
    TubeComments parse(Object? data) {
      if (data is! Map || data['comments'] is! List) {
        throw const FormatException('Invalid Piped comments response.');
      }
      final token = data['nextpage']?.toString();
      return TubeComments(
        (data['comments'] as List)
            .whereType<Map>()
            .map(
              (item) => TubeComment(
                item['author']?.toString() ?? '',
                item['commentText']?.toString() ?? '',
                item['commentedTime']?.toString() ?? '',
                (item['likeCount'] as num? ?? 0).toInt(),
              ),
            )
            .toList(),
        next: token == null || token.isEmpty || token == 'null'
            ? null
            : () async => parse(
                await _piped('nextpage/comments/$id', {'nextpage': token}),
              ),
      );
    }

    return parse(await _piped('comments/$id'));
  }

  Future<List<TubeSubtitle>> captions(String id) async {
    final manifest = await youtube.videos.closedCaptions
        .getManifest(id)
        .timeout(const Duration(seconds: 15));
    return manifest.tracks
        .map((track) => TubeSubtitle(track.url.toString(), track.language.name))
        .toList();
  }

  @override
  void close() {
    for (final cursor in _playlistCursors) {
      unawaited(cursor.cancel());
    }
    _playlistCursors.clear();
    youtube.close();
    _http.close();
  }
}
