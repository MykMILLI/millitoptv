import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SharedFamilyAlbumSettings {
  final String proxyUrl;
  final String serverUrl;
  final String apiKey;
  final List<String> albumIds;
  final List<String> albumNames;
  final bool enabled;
  final int seconds;
  final bool shuffle;
  const SharedFamilyAlbumSettings({
    this.proxyUrl = '',
    this.serverUrl = '',
    this.apiKey = '',
    this.albumIds = const [],
    this.albumNames = const [],
    this.enabled = false,
    this.seconds = 8,
    this.shuffle = true,
  });

  bool get isConfigured =>
      enabled &&
      serverUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      albumIds.isNotEmpty;

  String get albumLabel {
    if (albumNames.isEmpty) {
      return '';
    }
    if (albumNames.length == 1) {
      return albumNames.first;
    }
    return '${albumNames.first} +${albumNames.length - 1} more';
  }

  SharedFamilyAlbumSettings copy({
    String? proxyUrl,
    String? serverUrl,
    String? apiKey,
    List<String>? albumIds,
    List<String>? albumNames,
    bool? enabled,
    int? seconds,
    bool? shuffle,
  }) => SharedFamilyAlbumSettings(
    proxyUrl: proxyUrl ?? this.proxyUrl,
    serverUrl: serverUrl ?? this.serverUrl,
    apiKey: apiKey ?? this.apiKey,
    albumIds: albumIds ?? this.albumIds,
    albumNames: albumNames ?? this.albumNames,
    enabled: enabled ?? this.enabled,
    seconds: seconds ?? this.seconds,
    shuffle: shuffle ?? this.shuffle,
  );

  Map<String, dynamic> toJson() => {
    'proxyUrl': proxyUrl,
    'serverUrl': serverUrl,
    'apiKey': apiKey,
    'albumIds': albumIds,
    'albumNames': albumNames,
    'enabled': enabled,
    'seconds': seconds,
    'shuffle': shuffle,
  };

  factory SharedFamilyAlbumSettings.fromJson(Map<String, dynamic> json) {
    final proxy = json['proxyUrl']?.toString().trim() ?? '';
    final server = json['serverUrl']?.toString().trim() ?? '';
    final key = json['apiKey']?.toString().trim() ?? '';
    final rawAlbumIds = json['albumIds'];
    final rawAlbumNames = json['albumNames'];
    final albumIds = <String>[
      if (rawAlbumIds is List)
        ...rawAlbumIds
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty),
    ];
    final albumNames = <String>[
      if (rawAlbumNames is List)
        ...rawAlbumNames
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty),
    ];
    final legacyAlbumId = json['albumId']?.toString().trim() ?? '';
    final legacyAlbumName = json['albumName']?.toString().trim() ?? '';
    if (albumIds.isEmpty && legacyAlbumId.isNotEmpty) {
      albumIds.add(legacyAlbumId);
    }
    if (albumNames.isEmpty && legacyAlbumName.isNotEmpty) {
      albumNames.add(legacyAlbumName);
    }
    final seconds = int.tryParse(json['seconds']?.toString() ?? '') ?? 8;
    return SharedFamilyAlbumSettings(
      proxyUrl: proxy,
      serverUrl: server,
      apiKey: key,
      albumIds: albumIds,
      albumNames: albumNames,
      enabled: json['enabled'] == true,
      seconds: seconds.clamp(3, 60),
      shuffle: json['shuffle'] != false,
    );
  }
}

class SharedFamilyAlbumInfo {
  final String id;
  final String name;
  final int assetCount;
  const SharedFamilyAlbumInfo({
    required this.id,
    required this.name,
    required this.assetCount,
  });
}

class SharedFamilyAsset {
  final String id;
  final String type;
  final String filename;
  final String thumbnailUrl;
  final String playbackUrl;
  final String originalUrl;
  const SharedFamilyAsset({
    required this.id,
    required this.type,
    required this.filename,
    required this.thumbnailUrl,
    required this.playbackUrl,
    required this.originalUrl,
  });

  bool get isVideo => type == 'VIDEO';
}

class SharedFamilyAlbumService {
  const SharedFamilyAlbumService();

  Uri _normalizeBaseUri(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !parsed.hasScheme ||
        parsed.host.trim().isEmpty ||
        !(parsed.scheme == 'http' || parsed.scheme == 'https')) {
      throw const FormatException('Immich host must be a valid http(s) URL.');
    }
    final normalizedPath = parsed.path.endsWith('/')
        ? parsed.path.substring(0, parsed.path.length - 1)
        : parsed.path;
    return parsed.replace(path: normalizedPath, query: '', fragment: '');
  }

  Uri _apiUri(Uri base, String suffix) {
    final clean = suffix.startsWith('/') ? suffix : '/$suffix';
    final root = base.path.toLowerCase().endsWith('/api')
        ? base.path
        : '${base.path}/api';
    return base.replace(path: '$root$clean');
  }

  Future<dynamic> _getJson(Uri url, String apiKey) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(url).timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set('x-api-key', apiKey);
      final res = await req.close().timeout(const Duration(seconds: 35));
      final body = await utf8.decodeStream(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException(
          'Immich request failed (${res.statusCode}) at ${url.path}.',
          uri: url,
        );
      }
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  Future<dynamic> _postJson(
    Uri url,
    String apiKey,
    Map<String, dynamic> payload,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client
          .postUrl(url)
          .timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set('x-api-key', apiKey);
      req.write(jsonEncode(payload));
      final res = await req.close().timeout(const Duration(seconds: 35));
      final body = await utf8.decodeStream(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException(
          'Immich request failed (${res.statusCode}) at ${url.path}.',
          uri: url,
        );
      }
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<SharedFamilyAlbumInfo>> albums({
    required String proxyUrl,
    required String host,
    required String apiKey,
  }) async {
    final cleanedKey = apiKey.trim();
    final cleanedHost = host.trim();
    final cleanedProxy = proxyUrl.trim();
    if (cleanedHost.isEmpty || cleanedKey.isEmpty) {
      return const <SharedFamilyAlbumInfo>[];
    }
    List<dynamic>? payloadList;
    Object? proxyError;
    Object? directError;
    if (cleanedProxy.isNotEmpty) {
      try {
        payloadList = await _albumsFromProxy(
          proxyUrl: cleanedProxy,
          immichHost: cleanedHost,
          apiKey: cleanedKey,
        );
      } catch (error) {
        proxyError = error;
      }
    }
    if (payloadList == null) {
      try {
        payloadList = await _albumsDirect(host: cleanedHost, apiKey: cleanedKey);
      } catch (error) {
        directError = error;
      }
    }
    if (payloadList == null) {
      throw FormatException(
        _albumsLoadErrorMessage(
          usedProxy: cleanedProxy.isNotEmpty,
          proxyError: proxyError,
          directError: directError,
        ),
      );
    }
    final values = <SharedFamilyAlbumInfo>[];
    for (final entry in payloadList) {
      if (entry is! Map) {
        continue;
      }
      final data = Map<String, dynamic>.from(entry);
      final id = data['id']?.toString().trim() ?? '';
      final name =
          data['albumName']?.toString().trim() ??
          data['name']?.toString().trim() ??
          '';
      final count = int.tryParse(data['assetCount']?.toString() ?? '') ?? 0;
      if (id.isEmpty || name.isEmpty) {
        continue;
      }
      values.add(SharedFamilyAlbumInfo(id: id, name: name, assetCount: count));
    }
    values.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return values;
  }

  Future<List<dynamic>?> _albumsDirect({
    required String host,
    required String apiKey,
  }) async {
    final base = _normalizeBaseUri(host);
    final payload = await _getJson(_apiUri(base, '/albums'), apiKey);
    if (payload is! List) {
      throw const FormatException('Immich albums response is invalid.');
    }
    return payload;
  }

  Future<List<dynamic>?> _albumsFromProxy({
    required String proxyUrl,
    required String immichHost,
    required String apiKey,
  }) async {
    final proxy = _normalizeBaseUri(proxyUrl);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client
          .getUrl(proxy.replace(path: '/api/immich/albums'))
          .timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set('x-immich-external-url', immichHost);
      req.headers.set('x-immich-api-key', apiKey);
      final res = await req.close().timeout(const Duration(seconds: 35));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return null;
      }
      final body = await utf8.decodeStream(res);
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['albums'] is List) {
        return (decoded['albums'] as List);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String _albumsLoadErrorMessage({
    required bool usedProxy,
    required Object? proxyError,
    required Object? directError,
  }) {
    final candidates = [proxyError, directError]
        .whereType<Object>()
        .map((error) => error.toString().toLowerCase())
        .toList();
    final timeoutHit = candidates.any(
      (text) => text.contains('timeout') || text.contains('future not completed'),
    );
    if (timeoutHit) {
      return usedProxy
          ? 'Connection timed out while loading albums. Confirm Proxy URL and Immich host are reachable, or paste album IDs manually and save.'
          : 'Connection timed out while loading albums. Add Proxy URL or paste album IDs manually and save.';
    }
    return usedProxy
        ? 'Could not load albums. Check Proxy URL, Immich host, API key, and permissions. You can still paste album IDs manually and save.'
        : 'Could not load albums. Check Immich host/API key and permissions, or paste album IDs manually and save.';
  }

  Future<List<SharedFamilyAsset>> assets({
    required String proxyUrl,
    required String host,
    required String apiKey,
    required List<String> albumIds,
  }) async {
    final key = apiKey.trim();
    final targets = albumIds
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
    if (key.isEmpty || targets.isEmpty) {
      return const <SharedFamilyAsset>[];
    }
    final base = _normalizeBaseUri(host);
    final proxyBase = proxyUrl.trim().isEmpty ? base : _normalizeBaseUri(proxyUrl);
    final proxyFirst = await _assetsFromProxy(
      base: proxyBase,
      immichHost: host,
      apiKey: key,
      albumIds: targets,
    );
    if (proxyFirst.isNotEmpty) {
      return proxyFirst;
    }
    return _assetsDirect(
      base: base,
      apiKey: key,
      albumIds: targets,
    );
  }

  Future<List<SharedFamilyAsset>> _assetsFromProxy({
    required Uri base,
    required String immichHost,
    required String apiKey,
    required List<String> albumIds,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client
          .getUrl(base.replace(path: '/api/immich/shared-family-album'))
          .timeout(const Duration(seconds: 12));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set('x-immich-external-url', immichHost);
      req.headers.set('x-immich-api-key', apiKey);
      req.headers.set('x-immich-album-ids', albumIds.join(','));
      final res = await req.close().timeout(const Duration(seconds: 25));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return const <SharedFamilyAsset>[];
      }
      final body = await utf8.decodeStream(res);
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const <SharedFamilyAsset>[];
      }
      final rawAssets = decoded['assets'];
      if (rawAssets is! List) {
        return const <SharedFamilyAsset>[];
      }
      final values = <SharedFamilyAsset>[];
      for (final item in rawAssets) {
        if (item is! Map) {
          continue;
        }
        final data = Map<String, dynamic>.from(item);
        final id = data['id']?.toString().trim() ?? '';
        final type = data['type']?.toString().trim().toUpperCase() ?? '';
        final filename = data['filename']?.toString().trim() ?? '';
        if (id.isEmpty ||
            filename.isEmpty ||
            !const {'IMAGE', 'VIDEO'}.contains(type)) {
          continue;
        }
        final thumbRaw = data['thumbnailUrl']?.toString().trim() ?? '';
        final playbackRaw = data['playbackUrl']?.toString().trim() ?? '';
        final originalRaw = data['originalUrl']?.toString().trim() ?? '';
        values.add(
          SharedFamilyAsset(
            id: id,
            type: type,
            filename: filename,
            thumbnailUrl: _resolveProxyAssetUrl(
              base,
              thumbRaw,
              '/api/immich/assets/$id/thumbnail',
            ),
            playbackUrl: _resolveProxyAssetUrl(
              base,
              playbackRaw,
              '/api/immich/assets/$id/playback',
            ),
            originalUrl: _resolveProxyAssetUrl(
              base,
              originalRaw,
              '/api/immich/assets/$id/original',
            ),
          ),
        );
      }
      return values;
    } catch (_) {
      return const <SharedFamilyAsset>[];
    } finally {
      client.close(force: true);
    }
  }

  String _resolveProxyAssetUrl(Uri base, String candidate, String fallbackPath) {
    if (candidate.isEmpty) {
      return base.replace(path: fallbackPath).toString();
    }
    final parsed = Uri.tryParse(candidate);
    if (parsed == null) {
      return base.replace(path: fallbackPath).toString();
    }
    if (parsed.hasScheme && parsed.host.trim().isNotEmpty) {
      return parsed.toString();
    }
    final resolvedPath = candidate.startsWith('/')
        ? candidate
        : '/${candidate.replaceFirst('./', '')}';
    return base.replace(path: resolvedPath).toString();
  }

  Future<List<SharedFamilyAsset>> _assetsDirect({
    required Uri base,
    required String apiKey,
    required List<String> albumIds,
  }) async {
    final seen = <String>{};
    final values = <SharedFamilyAsset>[];
    for (final targetAlbum in albumIds) {
      var page = 0;
      while (true) {
        final payload = await _postJson(
          _apiUri(base, '/search/metadata'),
          apiKey,
          {
            'size': 500,
            'page': page,
            'albumIds': [targetAlbum],
            'withArchived': false,
          },
        );
        final assets = payload is Map ? payload['assets'] : null;
        if (assets is! Map) {
          break;
        }
        final items = assets['items'];
        if (items is! List || items.isEmpty) {
          break;
        }
        for (final item in items) {
          if (item is! Map) {
            continue;
          }
          final data = Map<String, dynamic>.from(item);
          final id = data['id']?.toString().trim() ?? '';
          final type = data['type']?.toString().trim().toUpperCase() ?? '';
          final filename = data['originalFileName']?.toString().trim() ?? '';
          if (id.isEmpty ||
              filename.isEmpty ||
              !const {'IMAGE', 'VIDEO'}.contains(type) ||
              !seen.add(id)) {
            continue;
          }
          values.add(
            SharedFamilyAsset(
              id: id,
              type: type,
              filename: filename,
              thumbnailUrl: _apiUri(base, '/assets/$id/thumbnail').toString(),
              playbackUrl: _apiUri(base, '/assets/$id/video/playback').toString(),
              originalUrl: _apiUri(base, '/assets/$id/original').toString(),
            ),
          );
        }
        if (items.length < 500) {
          break;
        }
        page++;
      }
    }
    return values;
  }
}
