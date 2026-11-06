import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class VideoPlaybackMemory {
  static const _progressPrefix = 'video.progress.v1.';
  static const _prefsPrefix = 'video.prefs.v1.';
  static const _bookmarksPrefix = 'video.bookmarks.v1.';
  static const _handoffPrefix = 'video.handoff.v1.';
  static const _statsPrefix = 'video.stats.v1.';

  String _safeKey(String streamUrl) {
    final encoded = base64UrlEncode(utf8.encode(streamUrl));
    return encoded.length > 120 ? encoded.substring(0, 120) : encoded;
  }

  Future<Map<String, dynamic>> loadProgress(String streamUrl) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_progressPrefix${_safeKey(streamUrl)}',
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

  Future<void> saveProgress(
    String streamUrl, {
    required int positionMs,
    required int durationMs,
    required bool complete,
  }) async {
    final payload = {
      'positionMs': max(0, positionMs),
      'durationMs': max(0, durationMs),
      'complete': complete,
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_progressPrefix${_safeKey(streamUrl)}',
      jsonEncode(payload),
    )) {
      throw StateError('Could not save video progress.');
    }
  }

  Future<Map<String, dynamic>> loadPrefs(String profileKey) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_prefsPrefix$profileKey',
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

  Future<void> savePrefs(String profileKey, Map<String, dynamic> prefs) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_prefsPrefix$profileKey',
      jsonEncode(prefs),
    )) {
      throw StateError('Could not save video playback preferences.');
    }
  }

  Future<List<int>> loadBookmarks(String streamUrl) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_bookmarksPrefix${_safeKey(streamUrl)}',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const <int>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <int>[];
    }
    final values = <int>[];
    for (final item in decoded) {
      final parsed = int.tryParse(item.toString());
      if (parsed != null && parsed >= 0) {
        values.add(parsed);
      }
    }
    values.sort();
    return values.toSet().toList();
  }

  Future<void> saveBookmarks(String streamUrl, List<int> bookmarksMs) async {
    final normalized = bookmarksMs
        .where((item) => item >= 0)
        .toSet()
        .toList()
      ..sort();
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_bookmarksPrefix${_safeKey(streamUrl)}',
      jsonEncode(normalized),
    )) {
      throw StateError('Could not save bookmarks.');
    }
  }

  Future<String> createSessionHandoff({
    required String title,
    required String streamUrl,
    required int positionMs,
    required int durationMs,
  }) async {
    final code = DateTime.now()
        .microsecondsSinceEpoch
        .toRadixString(36)
        .toUpperCase()
        .substring(0, 8);
    final payload = {
      'code': code,
      'title': title,
      'streamUrl': streamUrl,
      'positionMs': max(0, positionMs),
      'durationMs': max(0, durationMs),
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'expiresAtUtc': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 24))
          .toIso8601String(),
    };
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_handoffPrefix$code',
      jsonEncode(payload),
    )) {
      throw StateError('Could not create playback handoff.');
    }
    return code;
  }

  Future<Map<String, dynamic>?> consumeSessionHandoff(String code) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      return null;
    }
    final key = '$_handoffPrefix$normalized';
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    await prefs.remove(key);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(decoded);
    final expires = DateTime.tryParse(map['expiresAtUtc']?.toString() ?? '')
        ?.toUtc();
    if (expires == null || expires.isBefore(DateTime.now().toUtc())) {
      return null;
    }
    return map;
  }

  Future<void> appendStatsEvent(
    String profileKey, {
    required String type,
    required Map<String, dynamic> payload,
  }) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_statsPrefix$profileKey',
    );
    final values = <Map<String, dynamic>>[];
    if (raw != null && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            values.add(Map<String, dynamic>.from(item));
          }
        }
      }
    }
    values.insert(0, {
      'type': type,
      'payload': payload,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
    if (!await (await SharedPreferences.getInstance()).setString(
      '$_statsPrefix$profileKey',
      jsonEncode(values.take(10000).toList()),
    )) {
      throw StateError('Could not persist video stats.');
    }
  }
}
