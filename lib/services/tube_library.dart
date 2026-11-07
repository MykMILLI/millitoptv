import 'dart:convert';
import 'package:pstube_engine/pstube_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TubeLibrary {
  final Map<String, dynamic> entries;
  final Map<String, dynamic> history;
  const TubeLibrary({this.entries = const {}, this.history = const {}});
  List<TubeVideo> list(String collection) => entries.entries
      .where((entry) => entry.key.startsWith('$collection:') && entry.value is Map &&
          (entry.value as Map)['deleted'] != true)
      .map((entry) => TubeVideo.fromJson(
        Map<String, dynamic>.from((entry.value as Map)['video'] as Map))).toList();
  List<String> get playlists => entries.keys.where((key) => key.startsWith('playlist/'))
      .map((key) => key.substring(0, key.indexOf(':'))).toSet().toList();
  List<TubeVideo> get watched {
    final values = history.values.whereType<Map>().toList()
      ..sort((a, b) => b['updatedAtUtc'].toString().compareTo(a['updatedAtUtc'].toString()));
    return values.map((value) => TubeVideo.fromJson(
      Map<String, dynamic>.from(value['video'] as Map))).toList();
  }
  bool contains(String collection, TubeVideo video) =>
      entries['$collection:${collection == 'subscriptions' ? video.channelId : video.id}'] is Map &&
      (entries['$collection:${collection == 'subscriptions' ? video.channelId : video.id}'] as Map)['deleted'] != true;
  TubeLibrary toggle(String collection, TubeVideo video) {
    if (collection == 'subscriptions' && video.channelId.isEmpty) {
      throw StateError('This video has no channel identifier.');
    }
    final key = '$collection:${collection == 'subscriptions' ? video.channelId : video.id}';
    return TubeLibrary(history: history, entries: {...entries, key: {
      'video': video.toJson(), 'deleted': contains(collection, video),
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    }});
  }
  TubeLibrary progress(TubeVideo video, Duration position, Duration duration) {
    final next = {...history, video.id: {
      'video': video.toJson(), 'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    }};
    final sorted = next.entries.toList()..sort((a, b) =>
      (b.value as Map)['updatedAtUtc'].toString().compareTo((a.value as Map)['updatedAtUtc'].toString()));
    return TubeLibrary(entries: entries, history: Map.fromEntries(sorted.take(100)));
  }
  Map<String, dynamic> toJson() => {'entries': entries, 'history': history};
  factory TubeLibrary.fromJson(Map<String, dynamic> value) => TubeLibrary(
    entries: Map<String, dynamic>.from(value['entries'] as Map? ?? {}),
    history: Map<String, dynamic>.from(value['history'] as Map? ?? {}));
}

class TubeStore {
  Future<TubeLibrary> load(int profile) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('youtube.v1.$profile');
    return raw == null ? const TubeLibrary() :
      TubeLibrary.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
  }
  Future<void> save(int profile, TubeLibrary library) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('youtube.v1.$profile', jsonEncode(library.toJson()))) {
      throw StateError('Could not save YouTube profile data.');
    }
  }
  Future<void> applySync(int profile, Map<String, dynamic> value) async {
    final local = await load(profile);
    final remote = TubeLibrary.fromJson(value);
    Map<String, dynamic> merge(Map<String, dynamic> a, Map<String, dynamic> b) {
      final merged = {...a};
      for (final entry in b.entries) {
        if (entry.value is! Map) throw const FormatException('Invalid YouTube sync entry.');
        final incoming = DateTime.parse((entry.value as Map)['updatedAtUtc'] as String);
        final previous = merged[entry.key];
        final date = previous is Map ? DateTime.parse(previous['updatedAtUtc'] as String) : null;
        if (date == null || incoming.isAfter(date)) merged[entry.key] = entry.value;
      }
      return merged;
    }
    await save(profile, TubeLibrary(entries: merge(local.entries, remote.entries),
      history: merge(local.history, remote.history)));
  }
}
