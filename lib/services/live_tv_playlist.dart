import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'live_tv_epg.dart';
import 'live_tv_source.dart';

class LiveTvChannel {
  final String title;
  final String streamUrl;
  final String? group;
  final String? logo;
  final String? tvgId;
  final String? streamId;
  final String? sourceId;
  final String? sourceName;
  const LiveTvChannel({
    required this.title,
    required this.streamUrl,
    this.group,
    this.logo,
    this.tvgId,
    this.streamId,
    this.sourceId,
    this.sourceName,
  });
}

class LiveTvPlaylist {
  final List<LiveTvChannel> channels;
  const LiveTvPlaylist(this.channels);

  static LiveTvPlaylist parse(String text) {
    final channels = <LiveTvChannel>[];
    final lines = const LineSplitter().convert(text);
    String? pendingTitle;
    Map<String, String>? pendingAttrs;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        final comma = line.indexOf(',');
        final metadata = comma < 0
            ? line.substring(8).trim()
            : line.substring(8, comma).trim();
        final title = comma < 0 ? '' : line.substring(comma + 1).trim();
        pendingTitle = title;
        pendingAttrs = _attributes(metadata);
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      final uri = Uri.tryParse(line);
      final absolute = uri?.isAbsolute == true;
      final allowedScheme =
          uri != null &&
          const {
            'http',
            'https',
            'rtsp',
            'rtmp',
            'udp',
            'rtp',
          }.contains(uri.scheme.toLowerCase());
      if (!absolute || !allowedScheme) {
        pendingTitle = null;
        pendingAttrs = null;
        continue;
      }
      final title = (pendingTitle?.trim().isNotEmpty ?? false)
          ? pendingTitle!.trim()
          : 'Channel ${channels.length + 1}';
      channels.add(
        LiveTvChannel(
          title: title,
          streamUrl: uri.toString(),
          group: pendingAttrs?['group-title'],
          logo: pendingAttrs?['tvg-logo'],
          tvgId: pendingAttrs?['tvg-id'],
          streamId: null,
        ),
      );
      pendingTitle = null;
      pendingAttrs = null;
    }
    if (channels.isEmpty) {
      throw const FormatException(
        'No playable channels were found in this playlist.',
      );
    }
    return LiveTvPlaylist(channels);
  }

  static Map<String, String> _attributes(String text) {
    final values = <String, String>{};
    final match = RegExp(r'([a-zA-Z0-9_-]+)\s*=\s*"([^"]*)"').allMatches(text);
    for (final entry in match) {
      values[entry.group(1)!.toLowerCase()] = entry.group(2)!.trim();
    }
    return values;
  }
}

class LiveTvMediaItem {
  final String id;
  final String title;
  final String streamUrl;
  final String? posterUrl;
  final String? description;
  final String? backdropUrl;
  final String? group;
  final bool series;
  final String? seriesId;
  const LiveTvMediaItem({
    required this.id,
    required this.title,
    required this.streamUrl,
    this.posterUrl,
    this.description,
    this.backdropUrl,
    this.group,
    this.series = false,
    this.seriesId,
  });
}

class LiveTvSeriesEpisode {
  final String id;
  final String title;
  final String streamUrl;
  final int season;
  final int episode;
  final String? posterUrl;
  final String? description;
  const LiveTvSeriesEpisode({
    required this.id,
    required this.title,
    required this.streamUrl,
    required this.season,
    required this.episode,
    this.posterUrl,
    this.description,
  });
}

class LiveTvSeriesDetails {
  final String seriesId;
  final String title;
  final String? description;
  final String? posterUrl;
  final String? backdropUrl;
  final List<LiveTvSeriesEpisode> episodes;
  const LiveTvSeriesDetails({
    required this.seriesId,
    required this.title,
    this.description,
    this.posterUrl,
    this.backdropUrl,
    required this.episodes,
  });
}

class LiveTvMetadataDetails {
  final String? posterUrl;
  final String? backdropUrl;
  final String? overview;
  final int? year;
  final int? runtimeMinutes;
  final String? status;
  final String? ratingSystem;
  final String? contentRating;
  final List<String> advisories;
  final List<String> genres;
  final List<String> cast;
  final List<String> crew;
  final List<String> relatedTitles;
  final List<LiveTvMediaExtraLink> extras;
  final String? trailerUrl;
  const LiveTvMetadataDetails({
    this.posterUrl,
    this.backdropUrl,
    this.overview,
    this.year,
    this.runtimeMinutes,
    this.status,
    this.ratingSystem,
    this.contentRating,
    this.advisories = const [],
    this.genres = const [],
    this.cast = const [],
    this.crew = const [],
    this.relatedTitles = const [],
    this.extras = const [],
    this.trailerUrl,
  });
}

class LiveTvMediaExtraLink {
  final String label;
  final String url;
  const LiveTvMediaExtraLink({required this.label, required this.url});
}

class _ParsedM3uEntry {
  final String title;
  final String streamUrl;
  final Map<String, String> attrs;
  const _ParsedM3uEntry({
    required this.title,
    required this.streamUrl,
    required this.attrs,
  });
}

class LiveTvPlaylistService {
  static final Map<String, _TmdbSearchResult?> _tmdbCache = {};
  const LiveTvPlaylistService();

  Future<LiveTvPlaylist> loadFromSource(LiveTvSource source) async {
    if (source.isM3u) {
      return loadFromUrl(source.m3uUrl ?? '');
    }
    if (source.isXtream) {
      return _loadFromXtream(source);
    }
    throw const FormatException('Unsupported Live TV source type.');
  }

  Future<LiveTvPlaylist> loadFromUrl(String playlistUrl) async {
    final target = Uri.parse(playlistUrl);
    if (!target.isAbsolute ||
        target.userInfo.isNotEmpty ||
        !const {'http', 'https'}.contains(target.scheme.toLowerCase())) {
      throw const FormatException(
        'Use an HTTP or HTTPS playlist URL without embedded credentials.',
      );
    }
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(target)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptHeader, 'audio/x-mpegurl,*/*');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Playlist server returned HTTP ${response.statusCode}.',
        );
      }
      final body = await utf8.decoder.bind(response).join();
      return LiveTvPlaylist.parse(body);
    } on TimeoutException {
      throw StateError(
        'Playlist server timed out. Check network access and try again.',
      );
    } on SocketException {
      throw StateError(
        'Playlist server is unreachable. Check network access and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<LiveTvPlaylist> _loadFromXtream(LiveTvSource source) async {
    final server = Uri.parse(source.serverUrl!.trim());
    if (!server.isAbsolute ||
        server.userInfo.isNotEmpty ||
        !const {'http', 'https'}.contains(server.scheme.toLowerCase())) {
      throw const FormatException(
        'Xtream server must be an HTTP or HTTPS URL without embedded credentials.',
      );
    }
    final base = server.replace(
      path: server.path.replaceAll(RegExp(r'/+$'), ''),
    );
    final username = source.username!.trim();
    final password = source.password!.trim();
    final client = HttpClient();
    try {
      final categories = await _xtreamCategories(
        client: client,
        base: base,
        username: username,
        password: password,
      );
      final streamsUri = base.replace(
        path: '${base.path}/player_api.php',
        queryParameters: {
          'username': username,
          'password': password,
          'action': 'get_live_streams',
        },
      );
      final streamsRaw = await _getJson(client, streamsUri);
      if (streamsRaw is! List) {
        throw const FormatException('Xtream response is not a channel list.');
      }
      final channels = <LiveTvChannel>[];
      for (final row in streamsRaw) {
        if (row is! Map) {
          continue;
        }
        final data = Map<String, dynamic>.from(row);
        final id = data['stream_id']?.toString().trim() ?? '';
        final name = data['name']?.toString().trim() ?? '';
        if (id.isEmpty || name.isEmpty) {
          continue;
        }
        final ext =
            (data['container_extension']?.toString().trim().isNotEmpty ?? false)
            ? data['container_extension'].toString().trim()
            : 'ts';
        final streamUrl = base.replace(
          path: '${base.path}/live/$username/$password/$id.$ext',
          queryParameters: null,
        );
        final categoryId = data['category_id']?.toString().trim();
        final epgCandidates = <String>[
          data['epg_channel_id']?.toString().trim() ?? '',
          data['custom_sid']?.toString().trim() ?? '',
          data['tvg_id']?.toString().trim() ?? '',
          id,
          name,
        ].where((value) => value.isNotEmpty).toList();
        channels.add(
          LiveTvChannel(
            title: name,
            streamUrl: streamUrl.toString(),
            group: data['category_name']?.toString().trim().isNotEmpty == true
                ? data['category_name'].toString().trim()
                : (categoryId != null ? categories[categoryId] : null),
            logo: data['stream_icon']?.toString(),
            tvgId: epgCandidates.join('|'),
            streamId: id,
          ),
        );
      }
      if (channels.isEmpty) {
        throw const FormatException(
          'Xtream returned no playable live channels.',
        );
      }
      channels.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      return LiveTvPlaylist(channels);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<LiveTvMediaItem>> loadMovies(LiveTvSource source) async {
    if (source.isXtream) {
      return _loadXtreamVod(source);
    }
    if (source.isM3u) {
      final hasDedicatedMoviesUrl =
          source.m3uMoviesUrl?.trim().isNotEmpty == true;
      return _loadM3uMedia(
        source,
        series: false,
        enforceMediaTypeHeuristics: !hasDedicatedMoviesUrl,
        playlistUrls: [
          if (hasDedicatedMoviesUrl)
            source.m3uMoviesUrl!.trim()
          else
            source.m3uUrl!.trim(),
        ],
      );
    }
    throw const FormatException('Unsupported source type for movies.');
  }

  Future<List<LiveTvProgram>> loadXtreamShortEpg(
    LiveTvSource source,
    String streamId,
  ) async {
    if (!source.isXtream) {
      return const [];
    }
    final server = Uri.parse(source.serverUrl!.trim());
    final base = server.replace(
      path: server.path.replaceAll(RegExp(r'/+$'), ''),
    );
    final username = source.username!.trim();
    final password = source.password!.trim();
    final client = HttpClient();
    try {
      final uri = base.replace(
        path: '${base.path}/player_api.php',
        queryParameters: {
          'username': username,
          'password': password,
          'action': 'get_short_epg',
          'stream_id': streamId,
          'limit': '12',
        },
      );
      final raw = await _getJson(client, uri);
      if (raw is! Map) {
        return const [];
      }
      final data = Map<String, dynamic>.from(raw);
      final rows = data['epg_listings'];
      if (rows is! List) {
        return const [];
      }
      final values = <LiveTvProgram>[];
      for (final row in rows) {
        if (row is! Map) {
          continue;
        }
        final item = Map<String, dynamic>.from(row);
        final title = _decodeMaybeBase64(
          item['title']?.toString() ?? item['name']?.toString() ?? '',
        ).trim();
        final start =
            _parseXtreamDate(item['start']?.toString()) ??
            _parseXtreamDate(item['start_timestamp']?.toString());
        final end =
            _parseXtreamDate(item['end']?.toString()) ??
            _parseXtreamDate(item['stop']?.toString()) ??
            _parseXtreamDate(item['stop_timestamp']?.toString());
        if (title.isEmpty ||
            start == null ||
            end == null ||
            !end.isAfter(start)) {
          continue;
        }
        values.add(LiveTvProgram(title: title, start: start, end: end));
      }
      values.sort((a, b) => a.start.compareTo(b.start));
      return values;
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  Future<List<LiveTvMediaItem>> loadSeries(LiveTvSource source) async {
    if (source.isXtream) {
      return _loadXtreamSeries(source);
    }
    if (source.isM3u) {
      final hasDedicatedSeriesUrls = source.m3uSeriesUrls.isNotEmpty;
      final urls = hasDedicatedSeriesUrls
          ? source.m3uSeriesUrls
          : [source.m3uUrl!.trim()];
      return _loadM3uMedia(
        source,
        series: true,
        playlistUrls: urls,
        enforceMediaTypeHeuristics: !hasDedicatedSeriesUrls,
      );
    }
    throw const FormatException('Unsupported source type for series.');
  }

  Future<List<LiveTvMediaItem>> enrichM3uMetadata({
    required List<LiveTvMediaItem> items,
    required bool series,
    required String tmdbApiKey,
    int maxItems = 220,
  }) async {
    final key = tmdbApiKey.trim();
    if (key.isEmpty || items.isEmpty) {
      return items;
    }
    final candidates = <int>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final missingPoster =
          item.posterUrl == null || item.posterUrl!.trim().isEmpty;
      final missingOverview =
          item.description == null || item.description!.trim().isEmpty;
      if (missingPoster || missingOverview) {
        candidates.add(i);
      }
      if (candidates.length >= maxItems) {
        break;
      }
    }
    if (candidates.isEmpty) {
      return items;
    }
    final updated = [...items];
    final client = HttpClient();
    try {
      for (final index in candidates) {
        final item = updated[index];
        final query = _normalizeMediaLookupTitle(item.title);
        if (query.isEmpty) {
          continue;
        }
        final result = await _searchTmdb(
          client: client,
          apiKey: key,
          query: query,
          series: series,
        );
        if (result == null) {
          continue;
        }
        updated[index] = LiveTvMediaItem(
          id: item.id,
          title: item.title,
          streamUrl: item.streamUrl,
          posterUrl: (item.posterUrl == null || item.posterUrl!.trim().isEmpty)
              ? result.posterUrl
              : item.posterUrl,
          description:
              (item.description == null || item.description!.trim().isEmpty)
              ? result.overview
              : item.description,
          backdropUrl:
              (item.backdropUrl == null || item.backdropUrl!.trim().isEmpty)
              ? result.backdropUrl
              : item.backdropUrl,
          group: item.group,
          series: item.series,
          seriesId: item.seriesId,
        );
      }
    } finally {
      client.close(force: true);
    }
    return updated;
  }

  Future<LiveTvMetadataDetails?> loadTmdbMetadataDetails({
    required String title,
    required bool series,
    required String tmdbApiKey,
  }) async {
    final key = tmdbApiKey.trim();
    final query = _normalizeMediaLookupTitle(title);
    if (key.isEmpty || query.isEmpty) {
      return null;
    }
    final client = HttpClient();
    try {
      final result = await _searchTmdb(
        client: client,
        apiKey: key,
        query: query,
        series: series,
      );
      if (result == null) {
        return null;
      }
      final cast = await _loadTmdbCast(
        client: client,
        apiKey: key,
        mediaId: result.mediaId,
        series: series,
      );
      final crew = await _loadTmdbCrew(
        client: client,
        apiKey: key,
        mediaId: result.mediaId,
        series: series,
      );
      final trailerUrl = await _loadTmdbTrailerUrl(
        client: client,
        apiKey: key,
        mediaId: result.mediaId,
        series: series,
      );
      final details = await _loadTmdbDetailPayload(
        client: client,
        apiKey: key,
        mediaId: result.mediaId,
        series: series,
      );
      final contentRating = await _loadTmdbContentRating(
        client: client,
        apiKey: key,
        mediaId: result.mediaId,
        series: series,
      );
      final related = await _loadTmdbRelatedTitles(
        client: client,
        apiKey: key,
        mediaId: result.mediaId,
        series: series,
      );
      final extras = await _loadTmdbExtras(
        client: client,
        apiKey: key,
        mediaId: result.mediaId,
        series: series,
      );
      final advisories = _advisoriesForRating(contentRating);
      final runtime = _runtimeFromTmdbPayload(details, series);
      final genres = _genresFromTmdbPayload(details);
      final status = details?['status']?.toString().trim();
      return LiveTvMetadataDetails(
        posterUrl: result.posterUrl,
        backdropUrl: result.backdropUrl,
        overview: result.overview,
        year: result.year,
        runtimeMinutes: runtime,
        status: status == null || status.isEmpty ? null : status,
        ratingSystem: contentRating == null ? null : (series ? 'TV' : 'MPA'),
        contentRating: contentRating,
        advisories: advisories,
        genres: genres,
        cast: cast,
        crew: crew,
        relatedTitles: related,
        extras: extras,
        trailerUrl: trailerUrl,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<LiveTvSeriesDetails?> loadSeriesDetails(
    LiveTvSource source,
    String seriesId,
    String fallbackTitle,
  ) async {
    if (!source.isXtream) {
      return null;
    }
    final server = Uri.parse(source.serverUrl!.trim());
    final base = server.replace(
      path: server.path.replaceAll(RegExp(r'/+$'), ''),
    );
    final username = source.username!.trim();
    final password = source.password!.trim();
    final client = HttpClient();
    try {
      final uri = base.replace(
        path: '${base.path}/player_api.php',
        queryParameters: {
          'username': username,
          'password': password,
          'action': 'get_series_info',
          'series_id': seriesId,
        },
      );
      final raw = await _getJson(client, uri);
      if (raw is! Map) {
        return null;
      }
      final data = Map<String, dynamic>.from(raw);
      final episodes = data['episodes'];
      final info = data['info'] is Map
          ? Map<String, dynamic>.from(data['info'])
          : <String, dynamic>{};
      final cover = info['cover']?.toString();
      final description = info['plot']?.toString().trim().isNotEmpty == true
          ? info['plot'].toString().trim()
          : null;
      String? backdrop;
      final backdropRaw = info['backdrop_path'];
      if (backdropRaw is List && backdropRaw.isNotEmpty) {
        backdrop = backdropRaw.first?.toString();
      } else if (backdropRaw != null) {
        backdrop = backdropRaw.toString();
      }
      final title = info['name']?.toString().trim().isNotEmpty == true
          ? info['name'].toString().trim()
          : fallbackTitle;
      final values = <LiveTvSeriesEpisode>[];
      if (episodes is Map) {
        for (final seasonEntry in episodes.entries) {
          final season = int.tryParse(seasonEntry.key.toString()) ?? 0;
          final rows = seasonEntry.value;
          if (rows is! List) {
            continue;
          }
          for (final row in rows) {
            if (row is! Map) {
              continue;
            }
            final episodeData = Map<String, dynamic>.from(row);
            final id = episodeData['id']?.toString().trim() ?? '';
            final title = episodeData['title']?.toString().trim() ?? '';
            final episodeNum =
                int.tryParse(episodeData['episode_num']?.toString() ?? '') ?? 0;
            final ext =
                (episodeData['container_extension']
                        ?.toString()
                        .trim()
                        .isNotEmpty ??
                    false)
                ? episodeData['container_extension'].toString().trim()
                : 'mp4';
            if (id.isEmpty || title.isEmpty) {
              continue;
            }
            final streamUrl = base.replace(
              path: '${base.path}/series/$username/$password/$id.$ext',
              queryParameters: null,
            );
            final episodeInfo = episodeData['info'] is Map
                ? Map<String, dynamic>.from(episodeData['info'])
                : <String, dynamic>{};
            final episodePoster = episodeInfo['movie_image']?.toString();
            final episodeDescription =
                episodeInfo['plot']?.toString().trim().isNotEmpty == true
                ? episodeInfo['plot'].toString().trim()
                : null;
            values.add(
              LiveTvSeriesEpisode(
                id: id,
                title: title,
                streamUrl: streamUrl.toString(),
                season: season,
                episode: episodeNum,
                posterUrl: episodePoster ?? cover,
                description: episodeDescription,
              ),
            );
          }
        }
      }
      values.sort((a, b) {
        final bySeason = a.season.compareTo(b.season);
        if (bySeason != 0) {
          return bySeason;
        }
        return a.episode.compareTo(b.episode);
      });
      return LiveTvSeriesDetails(
        seriesId: seriesId,
        title: title,
        description: description,
        posterUrl: cover,
        backdropUrl: backdrop,
        episodes: values,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<LiveTvMediaItem>> _loadXtreamVod(LiveTvSource source) async {
    final server = Uri.parse(source.serverUrl!.trim());
    final base = server.replace(
      path: server.path.replaceAll(RegExp(r'/+$'), ''),
    );
    final username = source.username!.trim();
    final password = source.password!.trim();
    final client = HttpClient();
    try {
      final categories = await _xtreamCategoriesByAction(
        client: client,
        base: base,
        username: username,
        password: password,
        action: 'get_vod_categories',
      );
      final uri = base.replace(
        path: '${base.path}/player_api.php',
        queryParameters: {
          'username': username,
          'password': password,
          'action': 'get_vod_streams',
        },
      );
      final raw = await _getJson(client, uri);
      if (raw is! List) {
        return const [];
      }
      final values = <LiveTvMediaItem>[];
      for (final row in raw) {
        if (row is! Map) {
          continue;
        }
        final data = Map<String, dynamic>.from(row);
        final id = data['stream_id']?.toString().trim() ?? '';
        final title = data['name']?.toString().trim() ?? '';
        if (id.isEmpty || title.isEmpty) {
          continue;
        }
        final ext =
            (data['container_extension']?.toString().trim().isNotEmpty ?? false)
            ? data['container_extension'].toString().trim()
            : 'mp4';
        final streamUrl = base.replace(
          path: '${base.path}/movie/$username/$password/$id.$ext',
          queryParameters: null,
        );
        final categoryId = data['category_id']?.toString().trim();
        values.add(
          LiveTvMediaItem(
            id: 'vod:$id',
            title: title,
            streamUrl: streamUrl.toString(),
            posterUrl: data['stream_icon']?.toString(),
            description: data['plot']?.toString(),
            group: categoryId == null ? null : categories[categoryId],
          ),
        );
      }
      values.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      return values;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<LiveTvMediaItem>> _loadXtreamSeries(LiveTvSource source) async {
    final server = Uri.parse(source.serverUrl!.trim());
    final base = server.replace(
      path: server.path.replaceAll(RegExp(r'/+$'), ''),
    );
    final username = source.username!.trim();
    final password = source.password!.trim();
    final client = HttpClient();
    try {
      final categories = await _xtreamCategoriesByAction(
        client: client,
        base: base,
        username: username,
        password: password,
        action: 'get_series_categories',
      );
      final uri = base.replace(
        path: '${base.path}/player_api.php',
        queryParameters: {
          'username': username,
          'password': password,
          'action': 'get_series',
        },
      );
      final raw = await _getJson(client, uri);
      if (raw is! List) {
        return const [];
      }
      final values = <LiveTvMediaItem>[];
      for (final row in raw) {
        if (row is! Map) {
          continue;
        }
        final data = Map<String, dynamic>.from(row);
        final id = data['series_id']?.toString().trim() ?? '';
        final title = data['name']?.toString().trim() ?? '';
        if (id.isEmpty || title.isEmpty) {
          continue;
        }
        final categoryId = data['category_id']?.toString().trim();
        values.add(
          LiveTvMediaItem(
            id: 'series:$id',
            title: title,
            streamUrl: '',
            posterUrl: data['cover']?.toString(),
            description: data['plot']?.toString(),
            backdropUrl: data['backdrop_path']?.toString(),
            group: categoryId == null ? null : categories[categoryId],
            series: true,
            seriesId: id,
          ),
        );
      }
      values.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      return values;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<LiveTvMediaItem>> _loadM3uMedia(
    LiveTvSource source, {
    required bool series,
    required List<String> playlistUrls,
    required bool enforceMediaTypeHeuristics,
  }) async {
    final entries = await _loadM3uEntriesFromUrls(playlistUrls);
    final values = <LiveTvMediaItem>[];
    for (final entry in entries) {
      final group = (entry.attrs['group-title'] ?? '').toLowerCase();
      final matches = !enforceMediaTypeHeuristics
          ? true
          : series
          ? (group.contains('series') ||
                group.contains('tv show') ||
                group.contains('shows') ||
                group.contains('episode'))
          : (group.contains('movie') ||
                group.contains('vod') ||
                group.contains('film') ||
                group.contains('cinema'));
      if (!matches) {
        continue;
      }
      values.add(
        LiveTvMediaItem(
          id: 'm3u:${entry.title.toLowerCase()}',
          title: entry.title,
          streamUrl: entry.streamUrl,
          posterUrl: entry.attrs['tvg-logo'],
          description: entry.attrs['tvg-name'],
          group: entry.attrs['group-title'],
          series: series,
        ),
      );
    }
    values.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return values;
  }

  Future<List<_ParsedM3uEntry>> _loadM3uEntriesFromUrls(
    List<String> urls,
  ) async {
    final values = <_ParsedM3uEntry>[];
    final seen = <String>{};
    final client = HttpClient();
    try {
      for (final raw in urls) {
        final text = raw.trim();
        if (text.isEmpty) {
          continue;
        }
        final uri = Uri.parse(text);
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        request.headers.set(HttpHeaders.acceptHeader, 'audio/x-mpegurl,*/*');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final body = await utf8.decoder.bind(response).join();
        for (final entry in _parseM3uEntries(body)) {
          final key = '${entry.title.toLowerCase()}|${entry.streamUrl}';
          if (seen.add(key)) {
            values.add(entry);
          }
        }
      }
    } finally {
      client.close(force: true);
    }
    return values;
  }

  List<_ParsedM3uEntry> _parseM3uEntries(String text) {
    final values = <_ParsedM3uEntry>[];
    final lines = const LineSplitter().convert(text);
    String? pendingTitle;
    Map<String, String>? pendingAttrs;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        final comma = line.indexOf(',');
        final metadata = comma < 0
            ? line.substring(8).trim()
            : line.substring(8, comma).trim();
        final title = comma < 0 ? '' : line.substring(comma + 1).trim();
        pendingTitle = title;
        pendingAttrs = LiveTvPlaylist._attributes(metadata);
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      final uri = Uri.tryParse(line);
      final absolute = uri?.isAbsolute == true;
      final allowedScheme =
          uri != null &&
          const {
            'http',
            'https',
            'rtsp',
            'rtmp',
            'udp',
            'rtp',
          }.contains(uri.scheme.toLowerCase());
      if (!absolute || !allowedScheme) {
        pendingTitle = null;
        pendingAttrs = null;
        continue;
      }
      values.add(
        _ParsedM3uEntry(
          title: (pendingTitle?.trim().isNotEmpty ?? false)
              ? pendingTitle!.trim()
              : 'Item ${values.length + 1}',
          streamUrl: uri.toString(),
          attrs: pendingAttrs ?? const {},
        ),
      );
      pendingTitle = null;
      pendingAttrs = null;
    }
    return values;
  }

  Future<Map<String, String>> _xtreamCategoriesByAction({
    required HttpClient client,
    required Uri base,
    required String username,
    required String password,
    required String action,
  }) async {
    final uri = base.replace(
      path: '${base.path}/player_api.php',
      queryParameters: {
        'username': username,
        'password': password,
        'action': action,
      },
    );
    try {
      final raw = await _getJson(client, uri);
      if (raw is! List) {
        return const {};
      }
      final map = <String, String>{};
      for (final item in raw) {
        if (item is! Map) {
          continue;
        }
        final data = Map<String, dynamic>.from(item);
        final id = data['category_id']?.toString().trim() ?? '';
        final name = data['category_name']?.toString().trim() ?? '';
        if (id.isNotEmpty && name.isNotEmpty) {
          map[id] = name;
        }
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  Future<Map<String, String>> _xtreamCategories({
    required HttpClient client,
    required Uri base,
    required String username,
    required String password,
  }) async {
    final uri = base.replace(
      path: '${base.path}/player_api.php',
      queryParameters: {
        'username': username,
        'password': password,
        'action': 'get_live_categories',
      },
    );
    try {
      final raw = await _getJson(client, uri);
      if (raw is! List) {
        return const {};
      }
      final map = <String, String>{};
      for (final item in raw) {
        if (item is! Map) {
          continue;
        }
        final data = Map<String, dynamic>.from(item);
        final id = data['category_id']?.toString().trim() ?? '';
        final name = data['category_name']?.toString().trim() ?? '';
        if (id.isNotEmpty && name.isNotEmpty) {
          map[id] = name;
        }
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  Future<dynamic> _getJson(HttpClient client, Uri uri) async {
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json,*/*');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Source server returned HTTP ${response.statusCode}.');
      }
      final body = await utf8.decoder.bind(response).join();
      return jsonDecode(body);
    } on TimeoutException {
      throw StateError('Source server timed out. Check network and try again.');
    } on SocketException {
      throw StateError(
        'Source server is unreachable. Check network and try again.',
      );
    } on FormatException {
      throw const FormatException(
        'Source response was not valid JSON. Check the source endpoint.',
      );
    }
  }

  DateTime? _parseXtreamDate(String? input) {
    final raw = (input ?? '').trim();
    if (raw.isEmpty) {
      return null;
    }
    final unix = int.tryParse(raw);
    if (unix != null) {
      return DateTime.fromMillisecondsSinceEpoch(unix * 1000, isUtc: true);
    }
    final normalized = raw.replaceFirst(' ', 'T');
    final parsed = DateTime.tryParse(normalized);
    if (parsed == null) {
      return null;
    }
    return parsed.isUtc ? parsed : parsed.toUtc();
  }

  String _decodeMaybeBase64(String value) {
    final raw = value.trim();
    if (raw.isEmpty) {
      return '';
    }
    try {
      final decoded = utf8.decode(base64.decode(raw));
      if (decoded.trim().isNotEmpty) {
        return decoded;
      }
    } catch (_) {}
    return raw;
  }

  Future<_TmdbSearchResult?> _searchTmdb({
    required HttpClient client,
    required String apiKey,
    required String query,
    required bool series,
  }) async {
    final cacheKey = '${series ? 'tv' : 'movie'}:$query';
    if (_tmdbCache.containsKey(cacheKey)) {
      return _tmdbCache[cacheKey];
    }
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/search/${series ? 'tv' : 'movie'}',
      {
        'api_key': apiKey,
        'query': query,
        'include_adult': 'false',
        'language': 'en-US',
        'page': '1',
      },
    );
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _tmdbCache[cacheKey] = null;
        return null;
      }
      final payload = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        _tmdbCache[cacheKey] = null;
        return null;
      }
      final rawResults = decoded['results'];
      if (rawResults is! List || rawResults.isEmpty) {
        _tmdbCache[cacheKey] = null;
        return null;
      }
      final top = rawResults.first;
      if (top is! Map) {
        _tmdbCache[cacheKey] = null;
        return null;
      }
      final item = Map<String, dynamic>.from(top);
      final mediaId = item['id'];
      final parsedId = mediaId is int ? mediaId : int.tryParse('$mediaId');
      if (parsedId == null) {
        _tmdbCache[cacheKey] = null;
        return null;
      }
      final posterPath = item['poster_path']?.toString().trim();
      final backdropPath = item['backdrop_path']?.toString().trim();
      final overview = item['overview']?.toString().trim();
      final result = _TmdbSearchResult(
        mediaId: parsedId,
        posterUrl: (posterPath == null || posterPath.isEmpty)
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        backdropUrl: (backdropPath == null || backdropPath.isEmpty)
            ? null
            : 'https://image.tmdb.org/t/p/w780$backdropPath',
        overview: (overview == null || overview.isEmpty) ? null : overview,
        year: _extractTmdbYear(item, series),
      );
      _tmdbCache[cacheKey] = result;
      return result;
    } catch (_) {
      _tmdbCache[cacheKey] = null;
      return null;
    }
  }

  String _normalizeMediaLookupTitle(String title) {
    var cleaned = title.trim();
    if (cleaned.isEmpty) {
      return '';
    }
    cleaned = cleaned.replaceAll(RegExp(r'\[[^\]]+\]'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\([^\)]*\d{4}[^\)]*\)'), ' ');
    cleaned = cleaned.replaceAll(
      RegExp(
        r'\b(uhd|fhd|hd|sd|hevc|x265|x264|h264|h265|web-dl|webrip|web rip|bluray|brrip|dvdrip|hdrip|remux|dubbed|multi|xvid|aac|ac3|dts|proper|repack|yify|rarbg|1080p|720p|2160p|480p)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned;
  }

  Future<List<String>> _loadTmdbCast({
    required HttpClient client,
    required String apiKey,
    required int mediaId,
    required bool series,
  }) async {
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/${series ? 'tv' : 'movie'}/$mediaId/credits',
      {'api_key': apiKey, 'language': 'en-US'},
    );
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const [];
      }
      final rawCast = decoded['cast'];
      if (rawCast is! List) {
        return const [];
      }
      return rawCast
          .whereType<Map>()
          .map((item) => item['name']?.toString().trim() ?? '')
          .where((name) => name.isNotEmpty)
          .take(8)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _loadTmdbCrew({
    required HttpClient client,
    required String apiKey,
    required int mediaId,
    required bool series,
  }) async {
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/${series ? 'tv' : 'movie'}/$mediaId/credits',
      {'api_key': apiKey, 'language': 'en-US'},
    );
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const [];
      }
      final rawCrew = decoded['crew'];
      if (rawCrew is! List) {
        return const [];
      }
      final wanted = {'director', 'writer', 'screenplay', 'creator', 'producer'};
      final values = <String>{};
      for (final entry in rawCrew.whereType<Map>()) {
        final job = entry['job']?.toString().trim().toLowerCase() ?? '';
        final name = entry['name']?.toString().trim() ?? '';
        if (name.isEmpty) {
          continue;
        }
        if (wanted.contains(job)) {
          values.add('$name (${entry['job']})');
        }
      }
      return values.take(8).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _loadTmdbTrailerUrl({
    required HttpClient client,
    required String apiKey,
    required int mediaId,
    required bool series,
  }) async {
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/${series ? 'tv' : 'movie'}/$mediaId/videos',
      {'api_key': apiKey, 'language': 'en-US'},
    );
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      final rawResults = decoded['results'];
      if (rawResults is! List) {
        return null;
      }
      for (final entry in rawResults.whereType<Map>()) {
        final site = entry['site']?.toString().trim().toLowerCase();
        final type = entry['type']?.toString().trim().toLowerCase();
        final key = entry['key']?.toString().trim();
        if (site == 'youtube' &&
            key != null &&
            key.isNotEmpty &&
            (type == 'trailer' || type == 'teaser')) {
          return 'https://www.youtube.com/watch?v=$key';
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _loadTmdbDetailPayload({
    required HttpClient client,
    required String apiKey,
    required int mediaId,
    required bool series,
  }) async {
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/${series ? 'tv' : 'movie'}/$mediaId',
      {'api_key': apiKey, 'language': 'en-US'},
    );
    try {
      final data = await _getJson(client, uri);
      if (data is! Map) {
        return null;
      }
      return Map<String, dynamic>.from(data);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _loadTmdbContentRating({
    required HttpClient client,
    required String apiKey,
    required int mediaId,
    required bool series,
  }) async {
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/${series ? 'tv' : 'movie'}/$mediaId/${series ? 'content_ratings' : 'release_dates'}',
      {'api_key': apiKey},
    );
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      final raw = decoded['results'];
      if (raw is! List) {
        return null;
      }
      for (final entry in raw.whereType<Map>()) {
        final iso = entry['iso_3166_1']?.toString().trim().toUpperCase();
        if (iso != 'US') {
          continue;
        }
        if (series) {
          final rating = entry['rating']?.toString().trim();
          if (rating != null && rating.isNotEmpty) {
            return rating;
          }
        } else {
          final releaseDates = entry['release_dates'];
          if (releaseDates is! List) {
            continue;
          }
          for (final date in releaseDates.whereType<Map>()) {
            final cert = date['certification']?.toString().trim();
            if (cert != null && cert.isNotEmpty) {
              return cert;
            }
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _loadTmdbRelatedTitles({
    required HttpClient client,
    required String apiKey,
    required int mediaId,
    required bool series,
  }) async {
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/${series ? 'tv' : 'movie'}/$mediaId/recommendations',
      {'api_key': apiKey, 'language': 'en-US', 'page': '1'},
    );
    try {
      final payload = await _getJson(client, uri);
      if (payload is! Map) {
        return const [];
      }
      final results = payload['results'];
      if (results is! List) {
        return const [];
      }
      return results
          .whereType<Map>()
          .map(
            (entry) =>
                (entry['title'] ?? entry['name'] ?? '').toString().trim(),
          )
          .where((value) => value.isNotEmpty)
          .take(8)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<LiveTvMediaExtraLink>> _loadTmdbExtras({
    required HttpClient client,
    required String apiKey,
    required int mediaId,
    required bool series,
  }) async {
    final uri = Uri.https(
      'api.themoviedb.org',
      '/3/${series ? 'tv' : 'movie'}/$mediaId/videos',
      {'api_key': apiKey, 'language': 'en-US'},
    );
    try {
      final payload = await _getJson(client, uri);
      if (payload is! Map) {
        return const [];
      }
      final results = payload['results'];
      if (results is! List) {
        return const [];
      }
      final extras = <LiveTvMediaExtraLink>[];
      for (final entry in results.whereType<Map>()) {
        final site = entry['site']?.toString().trim().toLowerCase();
        final key = entry['key']?.toString().trim();
        final type = entry['type']?.toString().trim();
        final name = entry['name']?.toString().trim();
        if (site != 'youtube' || key == null || key.isEmpty) {
          continue;
        }
        final label = [
          if (type != null && type.isNotEmpty) type,
          if (name != null && name.isNotEmpty) name,
        ].join(' · ');
        extras.add(
          LiveTvMediaExtraLink(
            label: label.isEmpty ? 'Extra' : label,
            url: 'https://www.youtube.com/watch?v=$key',
          ),
        );
      }
      return extras.take(8).toList();
    } catch (_) {
      return const [];
    }
  }

  int? _extractTmdbYear(Map<String, dynamic> item, bool series) {
    final primary = series
        ? item['first_air_date']?.toString()
        : item['release_date']?.toString();
    if (primary != null && primary.length >= 4) {
      final parsed = int.tryParse(primary.substring(0, 4));
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  int? _runtimeFromTmdbPayload(Map<String, dynamic>? payload, bool series) {
    if (payload == null) {
      return null;
    }
    if (!series) {
      final runtime = int.tryParse(payload['runtime']?.toString() ?? '');
      if (runtime != null && runtime > 0) {
        return runtime;
      }
      return null;
    }
    final runtimes = payload['episode_run_time'];
    if (runtimes is List && runtimes.isNotEmpty) {
      final first = int.tryParse(runtimes.first.toString());
      if (first != null && first > 0) {
        return first;
      }
    }
    return null;
  }

  List<String> _genresFromTmdbPayload(Map<String, dynamic>? payload) {
    if (payload == null) {
      return const [];
    }
    final raw = payload['genres'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((entry) => entry['name']?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .take(6)
        .toList();
  }

  List<String> _advisoriesForRating(String? rating) {
    final value = (rating ?? '').toUpperCase();
    if (value.isEmpty) {
      return const [];
    }
    if (value.contains('R') || value.contains('TV-MA') || value.contains('NC-17')) {
      return const ['Mature themes', 'Strong language or violence may be present'];
    }
    if (value.contains('PG-13') || value.contains('TV-14')) {
      return const ['Parental guidance suggested for younger audiences'];
    }
    if (value.contains('PG') || value.contains('TV-PG')) {
      return const ['Some material may not be suitable for children'];
    }
    return const [];
  }
}

class _TmdbSearchResult {
  final int mediaId;
  final String? posterUrl;
  final String? backdropUrl;
  final String? overview;
  final int? year;
  const _TmdbSearchResult({
    required this.mediaId,
    this.posterUrl,
    this.backdropUrl,
    this.overview,
    this.year,
  });
}
