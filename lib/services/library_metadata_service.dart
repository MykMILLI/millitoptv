import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../library/library_models.dart';
import 'live_tv_playlist.dart';

class LibraryMetadataEntry {
  final String title;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final int? year;
  final bool series;
  final String updatedAtUtc;

  const LibraryMetadataEntry({
    required this.title,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.year,
    required this.series,
    required this.updatedAtUtc,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'overview': overview,
    'posterUrl': posterUrl,
    'backdropUrl': backdropUrl,
    'year': year,
    'series': series,
    'updatedAtUtc': updatedAtUtc,
  };

  static LibraryMetadataEntry? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final value = Map<String, dynamic>.from(raw);
    final title = value['title']?.toString().trim() ?? '';
    if (title.isEmpty) {
      return null;
    }
    return LibraryMetadataEntry(
      title: title,
      overview: value['overview']?.toString(),
      posterUrl: value['posterUrl']?.toString(),
      backdropUrl: value['backdropUrl']?.toString(),
      year: int.tryParse(value['year']?.toString() ?? ''),
      series: value['series'] == true,
      updatedAtUtc:
          value['updatedAtUtc']?.toString() ??
          DateTime.now().toUtc().toIso8601String(),
    );
  }
}

class LibraryMetadataScanReport {
  final int scanned;
  final int updated;
  final int matched;

  const LibraryMetadataScanReport({
    required this.scanned,
    required this.updated,
    required this.matched,
  });
}

class LibraryMetadataService {
  static const _cachePrefix = 'library.tmdb.cache.v1.';
  final LiveTvPlaylistService playlist;

  const LibraryMetadataService({this.playlist = const LiveTvPlaylistService()});

  Future<Map<String, LibraryMetadataEntry>> loadCache(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_cachePrefix$profileId',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return const {};
    }
    final values = <String, LibraryMetadataEntry>{};
    decoded.forEach((key, value) {
      final parsed = LibraryMetadataEntry.fromJson(value);
      if (parsed != null) {
        values[key.toString()] = parsed;
      }
    });
    return values;
  }

  Future<LibraryMetadataEntry?> lookup(int profileId, String path) async {
    final cache = await loadCache(profileId);
    return cache[path];
  }

  Future<LibraryMetadataScanReport> scanFolders({
    required int profileId,
    required List<LibraryFolder> folders,
    required String tmdbApiKey,
    int maxFiles = 500,
  }) async {
    final key = tmdbApiKey.trim();
    if (key.isEmpty) {
      throw const FormatException('TMDB API key is required.');
    }
    final cache = await loadCache(profileId);
    var scanned = 0;
    var updated = 0;
    var matched = 0;
    final now = DateTime.now().toUtc();
    final staleThreshold = now.subtract(const Duration(days: 14));
    var stop = false;
    for (final folder in folders) {
      final root = Directory(folder.path);
      if (!await root.exists()) {
        continue;
      }
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        if (libraryMediaKind(entity.path) != LibraryMediaKind.video) {
          continue;
        }
        scanned++;
        if (scanned > maxFiles) {
          stop = true;
          break;
        }
        final existing = cache[entity.path];
        if (existing != null) {
          final updatedAt = DateTime.tryParse(existing.updatedAtUtc)?.toUtc();
          if (updatedAt != null && updatedAt.isAfter(staleThreshold)) {
            continue;
          }
        }
        final normalized = _normalizeLookupTitle(entity.path);
        if (normalized.isEmpty) {
          continue;
        }
        final isSeries = _looksLikeSeries(normalized);
        final details = await playlist.loadTmdbMetadataDetails(
          title: normalized,
          series: isSeries,
          tmdbApiKey: key,
        );
        if (details == null) {
          continue;
        }
        matched++;
        cache[entity.path] = LibraryMetadataEntry(
          title: normalized,
          overview: details.overview,
          posterUrl: details.posterUrl,
          backdropUrl: details.backdropUrl,
          year: details.year,
          series: isSeries,
          updatedAtUtc: now.toIso8601String(),
        );
        updated++;
      }
      if (stop) {
        break;
      }
    }
    await _saveCache(profileId, cache);
    return LibraryMetadataScanReport(
      scanned: scanned.clamp(0, maxFiles),
      updated: updated,
      matched: matched,
    );
  }

  Future<void> _saveCache(
    int profileId,
    Map<String, LibraryMetadataEntry> values,
  ) async {
    final payload = <String, dynamic>{};
    for (final entry in values.entries) {
      payload[entry.key] = entry.value.toJson();
    }
    await (await SharedPreferences.getInstance()).setString(
      '$_cachePrefix$profileId',
      jsonEncode(payload),
    );
  }

  String _normalizeLookupTitle(String path) {
    final base = p.basenameWithoutExtension(path);
    final cleaned = base
        .replaceAll(RegExp(r'[._]'), ' ')
        .replaceAll(RegExp(r'\[[^\]]+\]'), ' ')
        .replaceAll(RegExp(r'\([^\)]+\)'), ' ')
        .replaceAll(RegExp(r'\b(1080p|720p|2160p|x264|x265|h264|h265)\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }

  bool _looksLikeSeries(String title) {
    final lower = title.toLowerCase();
    return RegExp(r's\d{1,2}e\d{1,2}').hasMatch(lower) ||
        lower.contains(' season ') ||
        lower.contains(' episode ');
  }
}
