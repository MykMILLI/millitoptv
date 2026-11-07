import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'live_tv_playlist.dart';
import 'live_tv_source.dart';

/// A cached movie/series list for one source.
class MediaCatalogCacheEntry {
  final DateTime savedAt;
  final List<LiveTvMediaItem> movies;
  final List<LiveTvMediaItem> series;
  const MediaCatalogCacheEntry({
    required this.savedAt,
    required this.movies,
    required this.series,
  });

  Duration age(DateTime now) => now.difference(savedAt);
}

/// The dashboard (SMB) catalog response, cached as returned by the server.
class ManagedCatalogCacheEntry {
  final DateTime savedAt;
  final String? version;
  final Map<String, dynamic> response;
  const ManagedCatalogCacheEntry({
    required this.savedAt,
    required this.version,
    required this.response,
  });
}

/// Persists the Movies & Series catalog so reopening the screen is instant.
///
/// The catalog is kept in memory for the running app and written to the
/// app-support directory so it also survives restarts. Every entry is tied to
/// a fingerprint of the source configuration: editing a source's URL or login
/// invalidates its cache automatically.
class MediaCatalogCache {
  static const int schemaVersion = 1;

  /// How long a cached source is considered fresh. Within this window the
  /// screen opens from cache without checking the provider at all.
  static const Duration freshFor = Duration(minutes: 30);

  static final Map<String, Map<String, dynamic>> _memory = {};
  static final Map<String, Future<void>> _writes = {};

  final Future<Directory> Function()? _directory;
  final Map<String, Map<String, dynamic>> _store;
  final bool enabled;

  /// [directory] defaults to the app-support directory. Pass [memory] to use
  /// a private in-memory store (tests), and [persist] false to skip disk.
  MediaCatalogCache({
    Future<Directory> Function()? directory,
    Map<String, Map<String, dynamic>>? memory,
    bool persist = true,
  }) : _directory = persist
           ? (directory ?? getApplicationSupportDirectory)
           : null,
       _store = memory ?? _memory,
       enabled = true;

  /// A cache that never stores anything (every read is a miss).
  MediaCatalogCache.disabled()
    : _directory = null,
      _store = {},
      enabled = false;

  /// Test hook: forget the in-memory copy so the next read comes from disk.
  static void resetMemoryForTest() {
    _memory.clear();
    _decoded.clear();
  }

  static String sourceFingerprint(LiveTvSource source) {
    final material = [
      schemaVersion,
      source.id,
      source.type,
      source.serverUrl?.trim() ?? '',
      source.username?.trim() ?? '',
      source.password ?? '',
      source.m3uUrl?.trim() ?? '',
      source.m3uMoviesUrl?.trim() ?? '',
      ...source.m3uSeriesUrls.map((url) => url.trim()),
    ].join('\u0000');
    return sha256.convert(utf8.encode(material)).toString();
  }

  Future<File?> _file(int profileId) async {
    final directory = _directory;
    if (directory == null) {
      return null;
    }
    final root = await directory();
    return File(
      p.join(root.path, 'media_catalog_cache', 'profile-$profileId.json'),
    );
  }

  static final Map<String, Future<Map<String, dynamic>>> _loading = {};

  /// Decoded [MediaCatalogCacheEntry]s, reused while the stored entry is
  /// unchanged so reopening the screen does not rebuild thousands of items.
  static final Map<String, (Object, MediaCatalogCacheEntry)> _decoded = {};

  Future<Map<String, dynamic>> _document(int profileId) {
    final key = '$profileId';
    final cached = _store[key];
    if (cached != null) {
      return Future.value(cached);
    }
    if (!enabled) {
      return _readDocument(profileId);
    }
    // Sources load in parallel; they all share one disk read/decode.
    return _loading.putIfAbsent(
      '${identityHashCode(_store)}:$key',
      // Block body on purpose: returning the removed Future from
      // whenComplete would make the read wait on itself forever.
      () => _readDocument(profileId).whenComplete(() {
        _loading.remove('${identityHashCode(_store)}:$key');
      }),
    );
  }

  Future<Map<String, dynamic>> _readDocument(int profileId) async {
    final key = '$profileId';
    var doc = <String, dynamic>{'v': schemaVersion, 'sources': {}};
    try {
      final file = enabled ? await _file(profileId) : null;
      if (file != null && await file.exists()) {
        final text = await file.readAsString();
        final watch = Stopwatch()..start();
        // Big catalogs are decoded off the UI thread.
        final decoded = text.length > 256 * 1024
            ? await compute(_decodeJson, text)
            : jsonDecode(text);
        AppLog.debug(
          LogCategory.catalog,
          'Catalog cache read',
          details: {'chars': text.length, 'ms': watch.elapsedMilliseconds},
        );
        if (decoded is Map && decoded['v'] == schemaVersion) {
          doc = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (error, stack) {
      // A corrupt cache is just a cache miss; it is rewritten on next save.
      AppLog.warn(
        LogCategory.catalog,
        'Catalog cache unreadable; it will be rebuilt',
        error: error,
        stackTrace: stack,
      );
    }
    doc['sources'] = Map<String, dynamic>.from(doc['sources'] as Map? ?? {});
    if (!enabled) {
      return doc;
    }
    return _store[key] = doc;
  }

  Future<void> _persist(int profileId) {
    final key = '$profileId';
    if (!enabled || _directory == null) {
      return Future<void>.value();
    }
    // Several saves in a row (one per source) collapse into one write.
    final queued = _queuedWrites[key];
    if (queued != null) {
      return queued;
    }
    final previous = _writes[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) async {
      if (identical(_queuedWrites[key], next)) {
        _queuedWrites.remove(key);
      }
      final doc = _store[key];
      if (doc == null || !enabled) {
        return;
      }
      try {
        final file = await _file(profileId);
        if (file == null) {
          return;
        }
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        final sourceCount = (doc['sources'] as Map?)?.length ?? 0;
        final text = sourceCount > 0
            ? await compute(_encodeJson, doc)
            : jsonEncode(doc);
        await temp.writeAsString(text, flush: true);
        if (await file.exists()) {
          await file.delete();
        }
        await temp.rename(file.path);
      } catch (error, stack) {
        // Caching is best-effort; the catalog still works without it.
        AppLog.warn(
          LogCategory.catalog,
          'Could not save the catalog cache',
          error: error,
          stackTrace: stack,
        );
      }
    });
    _queuedWrites[key] = next;
    _writes[key] = next;
    return next;
  }

  static final Map<String, Future<void>> _queuedWrites = {};

  static Object? _decodeJson(String text) => jsonDecode(text);
  static String _encodeJson(Map<String, dynamic> doc) => jsonEncode(doc);

  Future<MediaCatalogCacheEntry?> source(
    int profileId,
    LiveTvSource source,
  ) async {
    final doc = await _document(profileId);
    final raw = (doc['sources'] as Map)[source.id];
    if (raw is! Map || raw['fingerprint'] != sourceFingerprint(source)) {
      return null;
    }
    final savedAt = DateTime.tryParse(raw['savedAt']?.toString() ?? '');
    if (savedAt == null) {
      return null;
    }
    final memoKey = '${identityHashCode(_store)}:$profileId:${source.id}';
    final memo = _decoded[memoKey];
    if (memo != null && identical(memo.$1, raw)) {
      return memo.$2;
    }
    final entry = MediaCatalogCacheEntry(
      savedAt: savedAt,
      movies: _items(raw['movies']),
      series: _items(raw['series']),
    );
    _decoded[memoKey] = (raw, entry);
    return entry;
  }

  static List<LiveTvMediaItem> _items(Object? value) => [
    for (final entry in (value as List? ?? const []))
      if (entry is Map) ?itemFromJson(Map<String, dynamic>.from(entry)),
  ];

  Future<void> saveSource(
    int profileId,
    LiveTvSource source, {
    required List<LiveTvMediaItem> movies,
    required List<LiveTvMediaItem> series,
    DateTime? savedAt,
  }) async {
    final doc = await _document(profileId);
    (doc['sources'] as Map)[source.id] = {
      'fingerprint': sourceFingerprint(source),
      'savedAt': (savedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'movies': movies.map(itemToJson).toList(),
      'series': series.map(itemToJson).toList(),
    };
    await _persist(profileId);
  }

  Future<ManagedCatalogCacheEntry?> managedCatalog(
    int profileId,
    String connectionKey,
  ) async {
    final doc = await _document(profileId);
    final raw = doc['managed'];
    if (raw is! Map || raw['connection'] != _connectionTag(connectionKey)) {
      return null;
    }
    final savedAt = DateTime.tryParse(raw['savedAt']?.toString() ?? '');
    final response = raw['response'];
    if (savedAt == null || response is! Map) {
      return null;
    }
    return ManagedCatalogCacheEntry(
      savedAt: savedAt,
      version: raw['version']?.toString(),
      response: Map<String, dynamic>.from(response),
    );
  }

  Future<void> saveManagedCatalog(
    int profileId,
    String connectionKey,
    Map<String, dynamic> response, {
    String? version,
  }) async {
    final doc = await _document(profileId);
    doc['managed'] = {
      'connection': _connectionTag(connectionKey),
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'version': version,
      'response': response,
    };
    await _persist(profileId);
  }

  Future<void> clearManagedCatalog(int profileId) async {
    final doc = await _document(profileId);
    if (doc.remove('managed') != null) {
      await _persist(profileId);
    }
  }

  /// Drops cached sources that are no longer configured.
  Future<void> retainSources(int profileId, Iterable<String> sourceIds) async {
    final doc = await _document(profileId);
    final keep = sourceIds.toSet();
    final map = doc['sources'] as Map;
    final before = map.length;
    map.removeWhere((key, _) => !keep.contains(key));
    if (map.length != before) {
      await _persist(profileId);
    }
  }

  // Never store the raw device credential; a hash is enough to notice that
  // the device was re-paired to another server or household.
  static String _connectionTag(String connectionKey) =>
      sha256.convert(utf8.encode(connectionKey)).toString().substring(0, 24);

  static Map<String, dynamic> itemToJson(LiveTvMediaItem item) => {
    'id': item.id,
    'title': item.title,
    'streamUrl': item.streamUrl,
    if (item.posterUrl != null) 'posterUrl': item.posterUrl,
    if (item.description != null) 'description': item.description,
    if (item.backdropUrl != null) 'backdropUrl': item.backdropUrl,
    if (item.group != null) 'group': item.group,
    if (item.series) 'series': true,
    if (item.seriesId != null) 'seriesId': item.seriesId,
    if (item.year != null) 'year': item.year,
    if (item.genres.isNotEmpty) 'genres': item.genres,
    if (item.releaseDate != null)
      'releaseDate': item.releaseDate!.toIso8601String(),
    if (item.addedAt != null) 'addedAt': item.addedAt!.toIso8601String(),
  };

  static LiveTvMediaItem? itemFromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final title = json['title']?.toString() ?? '';
    final streamUrl = json['streamUrl']?.toString() ?? '';
    if (id.isEmpty || title.isEmpty) {
      return null;
    }
    DateTime? date(Object? value) =>
        value == null ? null : DateTime.tryParse(value.toString());
    return LiveTvMediaItem(
      id: id,
      title: title,
      streamUrl: streamUrl,
      posterUrl: json['posterUrl']?.toString(),
      description: json['description']?.toString(),
      backdropUrl: json['backdropUrl']?.toString(),
      group: json['group']?.toString(),
      series: json['series'] == true,
      seriesId: json['seriesId']?.toString(),
      year: (json['year'] as num?)?.toInt(),
      genres: [...(json['genres'] as List? ?? const []).map((g) => '$g')],
      releaseDate: date(json['releaseDate']),
      addedAt: date(json['addedAt']),
    );
  }

  /// Applies a fresh provider list on top of the cached one: titles that were
  /// already enriched (TMDB posters, overviews, genres) keep that metadata, so
  /// only genuinely new titles need a metadata lookup.
  static List<LiveTvMediaItem> mergeKeepingMetadata(
    List<LiveTvMediaItem> fresh,
    List<LiveTvMediaItem> cached,
  ) {
    if (cached.isEmpty) {
      return fresh;
    }
    final byId = {for (final item in cached) item.id: item};
    String? pick(String? value, String? fallback) =>
        value == null || value.trim().isEmpty ? fallback : value;
    return [
      for (final item in fresh)
        if (byId[item.id] case final old?)
          LiveTvMediaItem(
            id: item.id,
            title: item.title,
            streamUrl: item.streamUrl,
            posterUrl: pick(item.posterUrl, old.posterUrl),
            description: pick(item.description, old.description),
            backdropUrl: pick(item.backdropUrl, old.backdropUrl),
            group: item.group,
            series: item.series,
            seriesId: item.seriesId,
            year: item.year ?? old.year,
            genres: item.genres.isNotEmpty ? item.genres : old.genres,
            releaseDate: item.releaseDate ?? old.releaseDate,
            addedAt: item.addedAt ?? old.addedAt,
          )
        else
          item,
    ];
  }

  /// A cheap signature to tell whether a refreshed list actually changed.
  static String signature(
    List<LiveTvMediaItem> movies,
    List<LiveTvMediaItem> series,
  ) {
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode([
          movies.map(itemToJson).toList(),
          series.map(itemToJson).toList(),
        ]),
      ),
    );
    return digest.toString();
  }
}
