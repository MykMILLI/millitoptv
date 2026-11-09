import 'package:shared_preferences/shared_preferences.dart';
import '../profiles/household_store.dart';
import 'live_tv_source.dart';
import 'music_service.dart';
import 'playback_performance.dart';
import 'jellyfin_client.dart';
import 'shared_family_album_service.dart';
import 'podcast_service.dart';
import 'podcast_downloads.dart';
import 'tube_library.dart';
import 'global_playlists.dart';
import 'tube_downloads.dart';
import 'dart:convert';
import 'dart:io';

const int _maxSyncedAvatarBytes = 32 * 1024 * 1024;

class LiveTvRecentChannel {
  final String sourceId;
  final String sourceName;
  final String channelId;
  final String channelName;
  final DateTime watchedAtUtc;
  const LiveTvRecentChannel({
    required this.sourceId,
    required this.sourceName,
    required this.channelId,
    required this.channelName,
    required this.watchedAtUtc,
  });

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'channelId': channelId,
    'channelName': channelName,
    'watchedAtUtc': watchedAtUtc.toIso8601String(),
  };

  static LiveTvRecentChannel fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId']?.toString().trim() ?? '';
    final channelId = json['channelId']?.toString().trim() ?? '';
    final channelName = json['channelName']?.toString().trim() ?? '';
    if (sourceId.isEmpty || channelId.isEmpty || channelName.isEmpty) {
      throw const FormatException('Recent channel entry is incomplete.');
    }
    final watchedRaw = json['watchedAtUtc']?.toString().trim() ?? '';
    final watchedAt = DateTime.tryParse(watchedRaw)?.toUtc();
    if (watchedAt == null) {
      throw const FormatException('Recent channel timestamp is invalid.');
    }
    return LiveTvRecentChannel(
      sourceId: sourceId,
      sourceName: json['sourceName']?.toString().trim() ?? sourceId,
      channelId: channelId,
      channelName: channelName,
      watchedAtUtc: watchedAt,
    );
  }
}

class LiveTvRecentMedia {
  final String sourceId;
  final String? sourceName;
  final String mediaType;
  final String mediaId;
  final String title;
  final String? subtitle;
  final String? posterUrl;
  final DateTime watchedAtUtc;
  const LiveTvRecentMedia({
    required this.sourceId,
    this.sourceName,
    required this.mediaType,
    required this.mediaId,
    required this.title,
    this.subtitle,
    this.posterUrl,
    required this.watchedAtUtc,
  });

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'mediaType': mediaType,
    'mediaId': mediaId,
    'title': title,
    'subtitle': subtitle,
    'posterUrl': posterUrl,
    'watchedAtUtc': watchedAtUtc.toIso8601String(),
  };

  static LiveTvRecentMedia fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId']?.toString().trim() ?? '';
    final mediaType = json['mediaType']?.toString().trim() ?? '';
    final mediaId = json['mediaId']?.toString().trim() ?? '';
    final title = json['title']?.toString().trim() ?? '';
    if (sourceId.isEmpty ||
        mediaType.isEmpty ||
        mediaId.isEmpty ||
        title.isEmpty) {
      throw const FormatException('Recent media entry is incomplete.');
    }
    final watchedRaw = json['watchedAtUtc']?.toString().trim() ?? '';
    final watchedAt = DateTime.tryParse(watchedRaw)?.toUtc();
    if (watchedAt == null) {
      throw const FormatException('Recent media timestamp is invalid.');
    }
    final subtitle = json['subtitle']?.toString().trim();
    final sourceName = json['sourceName']?.toString().trim();
    final posterUrl = json['posterUrl']?.toString().trim();
    return LiveTvRecentMedia(
      sourceId: sourceId,
      sourceName: sourceName == null || sourceName.isEmpty ? null : sourceName,
      mediaType: mediaType,
      mediaId: mediaId,
      title: title,
      subtitle: subtitle == null || subtitle.isEmpty ? null : subtitle,
      posterUrl: posterUrl == null || posterUrl.isEmpty ? null : posterUrl,
      watchedAtUtc: watchedAt,
    );
  }
}

class LiveTvLibraryItem {
  final String sourceId;
  final String sourceName;
  final String mediaType;
  final String mediaId;
  final String title;
  final String? subtitle;
  final String? posterUrl;
  final String? streamUrl;
  final String? seriesId;
  const LiveTvLibraryItem({
    required this.sourceId,
    required this.sourceName,
    required this.mediaType,
    required this.mediaId,
    required this.title,
    this.subtitle,
    this.posterUrl,
    this.streamUrl,
    this.seriesId,
  });

  String get key => '$sourceId|$mediaType|$mediaId';

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'mediaType': mediaType,
    'mediaId': mediaId,
    'title': title,
    'subtitle': subtitle,
    'posterUrl': posterUrl,
    'streamUrl': streamUrl,
    'seriesId': seriesId,
  };

  static LiveTvLibraryItem fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId']?.toString().trim() ?? '';
    final sourceName = json['sourceName']?.toString().trim() ?? sourceId;
    final mediaType = json['mediaType']?.toString().trim() ?? '';
    final mediaId = json['mediaId']?.toString().trim() ?? '';
    final title = json['title']?.toString().trim() ?? '';
    if (sourceId.isEmpty ||
        mediaType.isEmpty ||
        mediaId.isEmpty ||
        title.isEmpty) {
      throw const FormatException('Library item is incomplete.');
    }
    final subtitle = json['subtitle']?.toString().trim();
    final posterUrl = json['posterUrl']?.toString().trim();
    final streamUrl = json['streamUrl']?.toString().trim();
    final seriesId = json['seriesId']?.toString().trim();
    return LiveTvLibraryItem(
      sourceId: sourceId,
      sourceName: sourceName.isEmpty ? sourceId : sourceName,
      mediaType: mediaType,
      mediaId: mediaId,
      title: title,
      subtitle: subtitle == null || subtitle.isEmpty ? null : subtitle,
      posterUrl: posterUrl == null || posterUrl.isEmpty ? null : posterUrl,
      streamUrl: streamUrl == null || streamUrl.isEmpty ? null : streamUrl,
      seriesId: seriesId == null || seriesId.isEmpty ? null : seriesId,
    );
  }
}

class LiveTvUserPlaylist {
  final String id;
  final String name;
  final List<LiveTvLibraryItem> items;
  final DateTime updatedAtUtc;
  const LiveTvUserPlaylist({
    required this.id,
    required this.name,
    required this.items,
    required this.updatedAtUtc,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'items': items.map((item) => item.toJson()).toList(),
    'updatedAtUtc': updatedAtUtc.toIso8601String(),
  };

  static LiveTvUserPlaylist fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Playlist is incomplete.');
    }
    final rawItems = json['items'];
    final items = <LiveTvLibraryItem>[
      if (rawItems is List)
        ...rawItems.whereType<Map>().map(
          (item) => LiveTvLibraryItem.fromJson(Map<String, dynamic>.from(item)),
        ),
    ];
    final updatedRaw = json['updatedAtUtc']?.toString().trim() ?? '';
    final updatedAt =
        DateTime.tryParse(updatedRaw)?.toUtc() ?? DateTime.now().toUtc();
    return LiveTvUserPlaylist(
      id: id,
      name: name,
      items: items,
      updatedAtUtc: updatedAt,
    );
  }
}

class LiveTvTmdbOverride {
  final String sourceId;
  final String mediaType;
  final String mediaId;
  final int tmdbId;
  final bool series;
  final String? title;
  final String? posterUrl;
  final String? backdropUrl;
  final String? overview;
  final int? year;
  final List<String> genres;
  final DateTime? releaseDate;
  final DateTime updatedAtUtc;
  const LiveTvTmdbOverride({
    required this.sourceId,
    required this.mediaType,
    required this.mediaId,
    required this.tmdbId,
    required this.series,
    this.title,
    this.posterUrl,
    this.backdropUrl,
    this.overview,
    this.year,
    this.genres = const [],
    this.releaseDate,
    required this.updatedAtUtc,
  });

  String get key => tmdbOverrideKey(sourceId, mediaType, mediaId);

  static String tmdbOverrideKey(
    String sourceId,
    String mediaType,
    String mediaId,
  ) => '$sourceId|$mediaType|$mediaId';

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'mediaType': mediaType,
    'mediaId': mediaId,
    'tmdbId': tmdbId,
    'series': series,
    if (title != null) 'title': title,
    if (posterUrl != null) 'posterUrl': posterUrl,
    if (backdropUrl != null) 'backdropUrl': backdropUrl,
    if (overview != null) 'overview': overview,
    if (year != null) 'year': year,
    if (genres.isNotEmpty) 'genres': genres,
    if (releaseDate != null) 'releaseDate': releaseDate!.toIso8601String(),
    'updatedAtUtc': updatedAtUtc.toIso8601String(),
  };

  static LiveTvTmdbOverride fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId']?.toString().trim() ?? '';
    final mediaType = json['mediaType']?.toString().trim() ?? '';
    final mediaId = json['mediaId']?.toString().trim() ?? '';
    final tmdbId = int.tryParse(json['tmdbId']?.toString() ?? '') ?? 0;
    if (sourceId.isEmpty || mediaType.isEmpty || mediaId.isEmpty || tmdbId < 1) {
      throw const FormatException('TMDB override is incomplete.');
    }
    final updatedAt =
        DateTime.tryParse(json['updatedAtUtc']?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
    final releaseDate = DateTime.tryParse(
      json['releaseDate']?.toString() ?? '',
    )?.toUtc();
    final genres = [
      ...(json['genres'] as List? ?? const []),
    ].map((value) => value.toString().trim()).where((value) => value.isNotEmpty).toList();
    String? clean(String field) {
      final value = json[field]?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }

    return LiveTvTmdbOverride(
      sourceId: sourceId,
      mediaType: mediaType,
      mediaId: mediaId,
      tmdbId: tmdbId,
      series: json['series'] == true,
      title: clean('title'),
      posterUrl: clean('posterUrl'),
      backdropUrl: clean('backdropUrl'),
      overview: clean('overview'),
      year: int.tryParse(json['year']?.toString() ?? ''),
      genres: genres,
      releaseDate: releaseDate,
      updatedAtUtc: updatedAt,
    );
  }
}

List<String> mergeAppOrder(List<String> available, List<String> saved) {
  final allowed = available.toSet();
  return [
    ...saved.where(allowed.contains).toSet(),
    ...available.where((id) => !saved.contains(id)),
  ];
}

class HomePreferences {
  final music = MusicService();
  Future<String> visualTheme(int profile) async =>
      (await SharedPreferences.getInstance()).getString(
        'home.visualTheme.v1.$profile',
      ) ??
      'aurora-glass';

  Future<void> setVisualTheme(int profile, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Theme id cannot be empty.');
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.visualTheme.v1.$profile',
      normalized,
    )) {
      throw StateError('Could not save app theme.');
    }
  }

  Future<int?> lastActiveProfileId() async {
    final raw = (await SharedPreferences.getInstance()).getInt(
      'home.lastActiveProfileId.v1',
    );
    if (raw == null || raw < 1) {
      return null;
    }
    return raw;
  }

  Future<void> setLastActiveProfileId(int profileId) async {
    if (profileId < 1) {
      throw const FormatException('Profile ID is invalid.');
    }
    if (!await (await SharedPreferences.getInstance()).setInt(
      'home.lastActiveProfileId.v1',
      profileId,
    )) {
      throw StateError('Could not save active profile.');
    }
  }

  Future<DateTime?> launcherPromptSnoozeUntil(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.launcherPromptSnoozeUntil.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> setLauncherPromptSnoozeUntil(
    int profile,
    DateTime? value,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      if (!await prefs.remove('home.launcherPromptSnoozeUntil.v1.$profile')) {
        throw StateError('Could not clear launcher reminder.');
      }
      return;
    }
    if (!await prefs.setString(
      'home.launcherPromptSnoozeUntil.v1.$profile',
      value.toUtc().toIso8601String(),
    )) {
      throw StateError('Could not save launcher reminder.');
    }
  }

  Future<List<String>> order(int profile) async =>
      (await SharedPreferences.getInstance()).getStringList(
        'home.appOrder.v1.$profile',
      ) ??
      [];
  Future<void> saveOrder(int profile, List<String> ids) async {
    if (ids.toSet().length != ids.length) {
      throw ArgumentError('Duplicate tile IDs.');
    }
    if (!await (await SharedPreferences.getInstance()).setStringList(
      'home.appOrder.v1.$profile',
      ids,
    )) {
      throw StateError('Could not save app order.');
    }
  }

  Future<String> sleepUrl(int profile) async =>
      (await SharedPreferences.getInstance()).getString(
        'home.sleepUrl.v1.$profile',
      ) ??
      'https://sleep.millitop.net';
  Future<void> setSleepUrl(int profile, String url) async {
    final parsed = Uri.parse(url);
    if (parsed.scheme != 'https' ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty) {
      throw const FormatException(
        'Use an HTTPS website without embedded credentials.',
      );
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.sleepUrl.v1.$profile',
      url,
    )) {
      throw StateError('Could not save Sleep Sounds address.');
    }
  }

  Future<String> sleepSoundsPreset(int profile) async =>
      (await SharedPreferences.getInstance()).getString(
        'home.sleepSoundsPreset.v1.$profile',
      ) ??
      'rain';

  Future<void> setSleepSoundsPreset(int profile, String preset) async {
    final normalized = preset.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Sleep Sounds preset cannot be empty.');
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.sleepSoundsPreset.v1.$profile',
      normalized,
    )) {
      throw StateError('Could not save Sleep Sounds preset.');
    }
  }

  Future<double> sleepSoundsVolume(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getDouble(
      'home.sleepSoundsVolume.v1.$profile',
    );
    return (raw ?? 70).clamp(0, 100).toDouble();
  }

  Future<void> setSleepSoundsVolume(int profile, double value) async {
    final normalized = value.clamp(0, 100).toDouble();
    if (!await (await SharedPreferences.getInstance()).setDouble(
      'home.sleepSoundsVolume.v1.$profile',
      normalized,
    )) {
      throw StateError('Could not save Sleep Sounds volume.');
    }
  }

  Future<String> sleepSoundsBackend(int profile) async =>
      (await SharedPreferences.getInstance()).getString(
        'home.sleepSoundsBackend.v1.$profile',
      ) ??
      'browser';

  Future<void> setSleepSoundsBackend(int profile, String backend) async {
    final normalized = backend.trim().toLowerCase();
    if (normalized != 'browser' && normalized != 'embedded') {
      throw const FormatException(
        'Sleep Sounds backend must be "browser" or "embedded".',
      );
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.sleepSoundsBackend.v1.$profile',
      normalized,
    )) {
      throw StateError('Could not save Sleep Sounds backend.');
    }
  }

  Future<String> liveTvPlaylistUrl(int profile) async =>
      (await SharedPreferences.getInstance()).getString(
        'home.liveTvPlaylistUrl.v1.$profile',
      ) ??
      '';

  Future<void> setLiveTvPlaylistUrl(int profile, String url) async {
    final normalized = validateLiveTvSourceUrl(url);
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvPlaylistUrl.v1.$profile',
      normalized,
    )) {
      throw StateError('Could not save Live TV playlist address.');
    }
  }

  /// Adult titles (IPTV "XXX -" / "For Adults", Jellyfin "Adult") are
  /// hidden unless the profile turns this on. Synced with the profile.
  Future<bool> showAdultContent(int profile) async =>
      (await SharedPreferences.getInstance()).getBool(
        'media.showAdult.v1.$profile',
      ) ??
      false;

  Future<void> setShowAdultContent(int profile, bool value) async {
    await (await SharedPreferences.getInstance()).setBool(
      'media.showAdult.v1.$profile',
      value,
    );
  }

  Future<String> tmdbApiKey(int profile) async =>
      (await SharedPreferences.getInstance()).getString(
        'home.tmdbApiKey.v1.$profile',
      ) ??
      '';

  Future<void> setTmdbApiKey(int profile, String apiKey) async {
    final cleaned = apiKey.trim();
    if (cleaned.isNotEmpty && !RegExp(r'^[A-Za-z0-9]+$').hasMatch(cleaned)) {
      throw const FormatException(
        'TMDB API key must contain only letters and numbers.',
      );
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.tmdbApiKey.v1.$profile',
      cleaned,
    )) {
      throw StateError('Could not save TMDB API key.');
    }
  }

  Future<SharedFamilyAlbumSettings> sharedFamilyAlbumSettings(
    int profile,
  ) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.sharedFamilyAlbum.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const SharedFamilyAlbumSettings();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Shared Family Album settings are invalid.');
    }
    return SharedFamilyAlbumSettings.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<void> saveSharedFamilyAlbumSettings(
    int profile,
    SharedFamilyAlbumSettings settings,
  ) async {
    final encoded = jsonEncode(settings.toJson());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.sharedFamilyAlbum.v1.$profile',
      encoded,
    )) {
      throw StateError('Could not save Shared Family Album settings.');
    }
  }

  Future<PlaybackPerformanceSettings> playbackPerformance(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.playbackPerformance.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const PlaybackPerformanceSettings();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Playback performance settings are invalid.');
    }
    return PlaybackPerformanceSettings.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<void> savePlaybackPerformance(
    int profile,
    PlaybackPerformanceSettings value,
  ) async {
    final raw = jsonEncode(value.toJson());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.playbackPerformance.v1.$profile',
      raw,
    )) {
      throw StateError('Could not save playback performance settings.');
    }
  }

  Future<Map<String, dynamic>> subtitleProviderSettings(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.subtitleProviders.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Subtitle provider settings are invalid.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> saveSubtitleProviderSettings(
    int profile,
    Map<String, dynamic> settings,
  ) async {
    final sanitized = <String, dynamic>{};
    for (final entry in settings.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) {
        continue;
      }
      final value = entry.value;
      if (value == null) {
        continue;
      }
      if (value is String) {
        sanitized[key] = value.trim();
      } else if (value is num || value is bool) {
        sanitized[key] = value;
      }
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.subtitleProviders.v1.$profile',
      jsonEncode(sanitized),
    )) {
      throw StateError('Could not save subtitle provider settings.');
    }
  }

  Future<Map<String, dynamic>> liveTvPlayerDefaults(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.liveTvPlayerDefaults.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Live TV player defaults are invalid.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> saveLiveTvPlayerDefaults(
    int profile,
    Map<String, dynamic> settings,
  ) async {
    final sanitized = <String, dynamic>{};
    for (final entry in settings.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) {
        continue;
      }
      final value = entry.value;
      if (value == null) {
        continue;
      }
      if (value is String) {
        sanitized[key] = value.trim();
      } else if (value is num || value is bool) {
        sanitized[key] = value;
      }
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvPlayerDefaults.v1.$profile',
      jsonEncode(sanitized),
    )) {
      throw StateError('Could not save Live TV player defaults.');
    }
  }

  Future<List<LiveTvSource>> liveTvSources(int profile) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('home.liveTvSources.v1.$profile');
    if (raw == null || raw.trim().isEmpty) {
      final legacy = prefs.getString('home.liveTvPlaylistUrl.v1.$profile');
      if (legacy == null || legacy.trim().isEmpty) {
        return const [];
      }
      final migrated = [
        LiveTvSource(
          id: 'm3u-default',
          name: 'Default Playlist',
          type: 'm3u',
          m3uUrl: legacy.trim(),
        ),
      ];
      await saveLiveTvSources(profile, migrated);
      return migrated;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Live TV sources format is invalid.');
    }
    final values = decoded
        .map(
          (entry) =>
              LiveTvSource.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList();
    if (values.map((source) => source.id).toSet().length != values.length) {
      throw const FormatException('Live TV sources contain duplicate IDs.');
    }
    return values;
  }

  Future<void> saveLiveTvSources(
    int profile,
    List<LiveTvSource> sources,
  ) async {
    if (sources.map((source) => source.id).toSet().length != sources.length) {
      throw const FormatException('Live TV sources contain duplicate IDs.');
    }
    final raw = jsonEncode(sources.map((source) => source.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvSources.v1.$profile',
      raw,
    )) {
      throw StateError('Could not save Live TV sources.');
    }
  }

  Future<List<LiveTvRecentChannel>> liveTvRecentChannels(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.liveTvRecent.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Recent Live TV format is invalid.');
    }
    final values = <LiveTvRecentChannel>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(
          LiveTvRecentChannel.fromJson(Map<String, dynamic>.from(entry)),
        );
      } catch (_) {}
    }
    values.sort((a, b) => b.watchedAtUtc.compareTo(a.watchedAtUtc));
    return values;
  }

  Future<void> upsertLiveTvRecentChannel(
    int profile,
    LiveTvRecentChannel channel, {
    int keep = 40,
  }) async {
    final current = await liveTvRecentChannels(profile);
    final merged = [
      channel,
      ...current.where(
        (item) =>
            !(item.sourceId == channel.sourceId &&
                item.channelId == channel.channelId),
      ),
    ].take(keep).toList();
    await _saveLiveTvRecentChannels(profile, merged);
  }

  Future<void> removeLiveTvRecentChannel(
    int profile, {
    required String sourceId,
    required String channelId,
  }) async {
    final current = await liveTvRecentChannels(profile);
    final filtered = current
        .where(
          (item) => !(item.sourceId == sourceId && item.channelId == channelId),
        )
        .toList();
    await _saveLiveTvRecentChannels(profile, filtered);
  }

  Future<List<LiveTvRecentMedia>> liveTvRecentMedia(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.liveTvRecentMedia.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Recent media format is invalid.');
    }
    final values = <LiveTvRecentMedia>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(
          LiveTvRecentMedia.fromJson(Map<String, dynamic>.from(entry)),
        );
      } catch (_) {}
    }
    values.sort((a, b) => b.watchedAtUtc.compareTo(a.watchedAtUtc));
    return values;
  }

  Future<void> upsertLiveTvRecentMedia(
    int profile,
    LiveTvRecentMedia media, {
    int keep = 80,
  }) async {
    final current = await liveTvRecentMedia(profile);
    final merged = [
      media,
      ...current.where(
        (item) =>
            !(item.sourceId == media.sourceId &&
                item.mediaType == media.mediaType &&
                item.mediaId == media.mediaId),
      ),
    ].take(keep).toList();
    await _saveLiveTvRecentMedia(profile, merged);
  }

  Future<void> removeLiveTvRecentMedia(
    int profile, {
    required String sourceId,
    required String mediaType,
    required String mediaId,
  }) async {
    final current = await liveTvRecentMedia(profile);
    final filtered = current
        .where(
          (item) =>
              !(item.sourceId == sourceId &&
                  item.mediaType == mediaType &&
                  item.mediaId == mediaId),
        )
        .toList();
    await _saveLiveTvRecentMedia(profile, filtered);
  }

  Future<void> _saveLiveTvRecentChannels(
    int profile,
    List<LiveTvRecentChannel> values,
  ) async {
    final encoded = jsonEncode(values.map((item) => item.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvRecent.v1.$profile',
      encoded,
    )) {
      throw StateError('Could not save recent Live TV channels.');
    }
  }

  Future<void> _saveLiveTvRecentMedia(
    int profile,
    List<LiveTvRecentMedia> values,
  ) async {
    final encoded = jsonEncode(values.map((item) => item.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvRecentMedia.v1.$profile',
      encoded,
    )) {
      throw StateError('Could not save recent Live TV media.');
    }
  }

  Future<List<LiveTvLibraryItem>> liveTvFavorites(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.liveTvFavorites.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Favorites format is invalid.');
    }
    final items = <LiveTvLibraryItem>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        items.add(LiveTvLibraryItem.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    return items;
  }

  Future<void> upsertLiveTvFavorite(
    int profile,
    LiveTvLibraryItem item, {
    int keep = 300,
  }) async {
    final current = await liveTvFavorites(profile);
    final merged = [
      item,
      ...current.where((entry) => entry.key != item.key),
    ].take(keep).toList();
    await _saveLiveTvFavorites(profile, merged);
  }

  Future<void> removeLiveTvFavorite(
    int profile, {
    required String sourceId,
    required String mediaType,
    required String mediaId,
  }) async {
    final current = await liveTvFavorites(profile);
    final key = '$sourceId|$mediaType|$mediaId';
    final filtered = current.where((item) => item.key != key).toList();
    await _saveLiveTvFavorites(profile, filtered);
  }

  Future<void> _saveLiveTvFavorites(
    int profile,
    List<LiveTvLibraryItem> items,
  ) async {
    final encoded = jsonEncode(items.map((item) => item.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvFavorites.v1.$profile',
      encoded,
    )) {
      throw StateError('Could not save favorites.');
    }
  }

  Future<List<LiveTvUserPlaylist>> liveTvPlaylists(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.liveTvPlaylists.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Playlists format is invalid.');
    }
    final playlists = <LiveTvUserPlaylist>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        playlists.add(
          LiveTvUserPlaylist.fromJson(Map<String, dynamic>.from(entry)),
        );
      } catch (_) {}
    }
    playlists.sort((a, b) => b.updatedAtUtc.compareTo(a.updatedAtUtc));
    return playlists;
  }

  Future<void> upsertLiveTvPlaylist(
    int profile,
    LiveTvUserPlaylist playlist,
  ) async {
    final current = await liveTvPlaylists(profile);
    final merged = [
      playlist,
      ...current.where((entry) => entry.id != playlist.id),
    ];
    await _saveLiveTvPlaylists(profile, merged);
  }

  Future<void> removeLiveTvPlaylist(int profile, String playlistId) async {
    final current = await liveTvPlaylists(profile);
    final filtered = current.where((entry) => entry.id != playlistId).toList();
    await _saveLiveTvPlaylists(profile, filtered);
  }

  Future<void> _saveLiveTvPlaylists(
    int profile,
    List<LiveTvUserPlaylist> playlists,
  ) async {
    final encoded = jsonEncode(playlists.map((item) => item.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvPlaylists.v1.$profile',
      encoded,
    )) {
      throw StateError('Could not save playlists.');
    }
  }

  Future<Map<String, dynamic>> liveTvUiState(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.liveTvUiState.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Live TV UI state format is invalid.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> saveLiveTvUiState(
    int profile,
    Map<String, dynamic> state,
  ) async {
    final encoded = jsonEncode(state);
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvUiState.v1.$profile',
      encoded,
    )) {
      throw StateError('Could not save Live TV UI state.');
    }
  }

  Future<List<LiveTvTmdbOverride>> liveTvTmdbOverrides(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'home.liveTvTmdbOverrides.v1.$profile',
    );
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('TMDB overrides format is invalid.');
    }
    final values = <LiveTvTmdbOverride>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        values.add(LiveTvTmdbOverride.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {}
    }
    values.sort((a, b) => b.updatedAtUtc.compareTo(a.updatedAtUtc));
    return values;
  }

  Future<void> upsertLiveTvTmdbOverride(
    int profile,
    LiveTvTmdbOverride override,
  ) async {
    final current = await liveTvTmdbOverrides(profile);
    final merged = [
      override,
      ...current.where((entry) => entry.key != override.key),
    ];
    await _saveLiveTvTmdbOverrides(profile, merged.take(1500).toList());
  }

  Future<void> removeLiveTvTmdbOverride(
    int profile, {
    required String sourceId,
    required String mediaType,
    required String mediaId,
  }) async {
    final key = LiveTvTmdbOverride.tmdbOverrideKey(sourceId, mediaType, mediaId);
    final current = await liveTvTmdbOverrides(profile);
    final filtered = current.where((entry) => entry.key != key).toList();
    await _saveLiveTvTmdbOverrides(profile, filtered);
  }

  Future<void> _saveLiveTvTmdbOverrides(
    int profile,
    List<LiveTvTmdbOverride> values,
  ) async {
    final encoded = jsonEncode(values.map((item) => item.toJson()).toList());
    if (!await (await SharedPreferences.getInstance()).setString(
      'home.liveTvTmdbOverrides.v1.$profile',
      encoded,
    )) {
      throw StateError('Could not save TMDB overrides.');
    }
  }

  Future<Map<String, dynamic>> liveTvProfileSyncState(int profile) async {
    Map<String, dynamic>? profileIdentity;
    Map<String, dynamic>? jellyfinAccount;
    try {
      await HouseholdStore.instance.initialize();
      final profileRecord = await HouseholdStore.instance.profileById(profile);
      if (profileRecord != null) {
        String? avatarBase64;
        String? avatarExtension;
        final avatarPath = profileRecord.avatarPath?.trim();
        if (avatarPath != null && avatarPath.isNotEmpty) {
          final avatarFile = File(avatarPath);
          if (await avatarFile.exists()) {
            final bytes = await avatarFile.readAsBytes();
            if (bytes.length <= _maxSyncedAvatarBytes) {
              avatarBase64 = base64Encode(bytes);
              final dot = avatarPath.lastIndexOf('.');
              if (dot >= 0 && dot < avatarPath.length - 1) {
                avatarExtension = avatarPath.substring(dot + 1).toLowerCase();
              }
            }
          }
        }
        profileIdentity = {
          'id': profileRecord.id,
          'name': profileRecord.name,
          if (avatarBase64 != null) 'avatarBase64': avatarBase64,
          if (avatarExtension != null) 'avatarExtension': avatarExtension,
        };
      }
    } catch (_) {}
    try {
      final account = await JellyfinAccountStore.instance().load(profile);
      if (account != null) {
        jellyfinAccount = {
          ...account.toConfigJson(),
          'accessToken': account.accessToken,
        };
      }
    } catch (_) {}
    final libraryFolders = await _libraryFolderSyncPayload(profile);
    return {
      'visualTheme': await visualTheme(profile),
      'appOrder': await order(profile),
      'recentChannels': (await liveTvRecentChannels(
        profile,
      )).map((item) => item.toJson()).toList(),
      'recentMedia': (await liveTvRecentMedia(
        profile,
      )).map((item) => item.toJson()).toList(),
      'favorites': (await liveTvFavorites(
        profile,
      )).map((item) => item.toJson()).toList(),
      'playlists': (await liveTvPlaylists(
        profile,
      )).map((item) => item.toJson()).toList(),
      'tmdbOverrides': (await liveTvTmdbOverrides(
        profile,
      )).map((item) => item.toJson()).toList(),
      'uiState': await liveTvUiState(profile),
      'showAdultContent': await showAdultContent(profile),
      'playbackPerformance': (await playbackPerformance(profile)).toJson(),
      'subtitleProviders': await subtitleProviderSettings(profile),
      'playerDefaults': await liveTvPlayerDefaults(profile),
      'sharedFamilyAlbum': (await sharedFamilyAlbumSettings(profile)).toJson(),
      'music': await music.profileSyncState(profile),
      'podcasts': (await PodcastStore().load(profile)).toJson(),
      'youtube': (await TubeStore().load(profile)).toJson(),
      'globalPlaylists': (await GlobalPlaylistStore().load(profile)).toJson(),
      if (libraryFolders.isNotEmpty) 'libraryFolders': libraryFolders,
      'libraryPlayback': await libraryPlaybackState(profile),
      if (profileIdentity != null) 'profileIdentity': profileIdentity,
      if (jellyfinAccount != null) 'jellyfinAccount': jellyfinAccount,
      'syncedAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// The per-item, timestamp-merged parts of the profile sync state.
  Future<Map<String, dynamic>> collectionSyncState(int profile) async => {
    'youtube': (await TubeStore().load(profile)).toJson(),
    'globalPlaylists': (await GlobalPlaylistStore().load(profile)).toJson(),
    'podcasts': (await PodcastStore().load(profile)).toJson(),
  };

  /// Merges only the timestamped collections from [state]; settings that are
  /// last-writer-wins (theme, sources, ...) are left untouched.
  Future<void> mergeCollectionSyncState(
    int profile,
    Map<String, dynamic> state,
  ) async {
    final globalPlaylistsRaw = state['globalPlaylists'];
    if (globalPlaylistsRaw is Map) {
      await GlobalPlaylistStore().applySync(
        profile,
        Map<String, dynamic>.from(globalPlaylistsRaw),
      );
    }
    final youtubeRaw = state['youtube'];
    if (youtubeRaw is Map) {
      await TubeStore().applySync(
        profile,
        Map<String, dynamic>.from(youtubeRaw),
      );
    }
    final podcastsRaw = state['podcasts'];
    if (podcastsRaw is Map) {
      await PodcastStore().applySync(
        profile,
        Map<String, dynamic>.from(podcastsRaw),
      );
    }
  }

  Future<void> applyLiveTvProfileSyncState(
    int profile,
    Map<String, dynamic> state,
  ) async {
    final visualThemeRaw = state['visualTheme'];
    if (visualThemeRaw != null) {
      final value = visualThemeRaw.toString().trim();
      if (value.isNotEmpty) {
        await setVisualTheme(profile, value);
      }
    }

    final appOrderRaw = state['appOrder'];
    if (appOrderRaw is List) {
      final ids = <String>[];
      for (final entry in appOrderRaw) {
        final value = entry.toString().trim();
        if (value.isEmpty || ids.contains(value)) {
          continue;
        }
        ids.add(value);
      }
      await saveOrder(profile, ids);
    }

    final recentChannelsRaw = state['recentChannels'];
    if (recentChannelsRaw is List) {
      final channels = <LiveTvRecentChannel>[];
      for (final entry in recentChannelsRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          channels.add(
            LiveTvRecentChannel.fromJson(Map<String, dynamic>.from(entry)),
          );
        } catch (_) {}
      }
      channels.sort((a, b) => b.watchedAtUtc.compareTo(a.watchedAtUtc));
      await _saveLiveTvRecentChannels(profile, channels.take(40).toList());
    }

    final showAdultRaw = state['showAdultContent'];
    if (showAdultRaw is bool) {
      await setShowAdultContent(profile, showAdultRaw);
    }

    final recentMediaRaw = state['recentMedia'];
    if (recentMediaRaw is List) {
      final media = <LiveTvRecentMedia>[];
      for (final entry in recentMediaRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          media.add(
            LiveTvRecentMedia.fromJson(Map<String, dynamic>.from(entry)),
          );
        } catch (_) {}
      }
      media.sort((a, b) => b.watchedAtUtc.compareTo(a.watchedAtUtc));
      await _saveLiveTvRecentMedia(profile, media.take(80).toList());
    }

    final favoritesRaw = state['favorites'];
    if (favoritesRaw is List) {
      final favorites = <LiveTvLibraryItem>[];
      for (final entry in favoritesRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          favorites.add(
            LiveTvLibraryItem.fromJson(Map<String, dynamic>.from(entry)),
          );
        } catch (_) {}
      }
      await _saveLiveTvFavorites(profile, favorites.take(300).toList());
    }

    final playlistsRaw = state['playlists'];
    if (playlistsRaw is List) {
      final playlists = <LiveTvUserPlaylist>[];
      for (final entry in playlistsRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          playlists.add(
            LiveTvUserPlaylist.fromJson(Map<String, dynamic>.from(entry)),
          );
        } catch (_) {}
      }
      await _saveLiveTvPlaylists(profile, playlists);
    }

    final tmdbOverridesRaw = state['tmdbOverrides'];
    if (tmdbOverridesRaw is List) {
      final overrides = <LiveTvTmdbOverride>[];
      for (final entry in tmdbOverridesRaw) {
        if (entry is! Map) {
          continue;
        }
        try {
          overrides.add(
            LiveTvTmdbOverride.fromJson(Map<String, dynamic>.from(entry)),
          );
        } catch (_) {}
      }
      await _saveLiveTvTmdbOverrides(profile, overrides.take(1500).toList());
    }

    final uiStateRaw = state['uiState'];
    if (uiStateRaw is Map) {
      await saveLiveTvUiState(profile, Map<String, dynamic>.from(uiStateRaw));
    }

    final playbackRaw = state['playbackPerformance'];
    if (playbackRaw is Map) {
      await savePlaybackPerformance(
        profile,
        PlaybackPerformanceSettings.fromJson(
          Map<String, dynamic>.from(playbackRaw),
        ),
      );
    }

    final subtitleProviderRaw = state['subtitleProviders'];
    if (subtitleProviderRaw is Map) {
      await saveSubtitleProviderSettings(
        profile,
        Map<String, dynamic>.from(subtitleProviderRaw),
      );
    }

    final playerDefaultsRaw = state['playerDefaults'];
    if (playerDefaultsRaw is Map) {
      await saveLiveTvPlayerDefaults(
        profile,
        Map<String, dynamic>.from(playerDefaultsRaw),
      );
    }

    final familyAlbumRaw = state['sharedFamilyAlbum'];
    if (familyAlbumRaw is Map) {
      await saveSharedFamilyAlbumSettings(
        profile,
        SharedFamilyAlbumSettings.fromJson(
          Map<String, dynamic>.from(familyAlbumRaw),
        ),
      );
    }

    final musicRaw = state['music'];
    if (musicRaw is Map) {
      try {
        await music.applyProfileSyncState(
          profile,
          Map<String, dynamic>.from(musicRaw),
        );
      } catch (_) {}
    }

    final youtubeRaw = state['youtube'];
    final globalPlaylistsRaw = state['globalPlaylists'];
    if (globalPlaylistsRaw is Map) {
      await GlobalPlaylistStore().applySync(
        profile,
        Map<String, dynamic>.from(globalPlaylistsRaw),
      );
    }
    if (youtubeRaw is Map) {
      await TubeStore().applySync(
        profile,
        Map<String, dynamic>.from(youtubeRaw),
      );
    }
    final podcastsRaw = state['podcasts'];
    if (podcastsRaw is Map) {
      await PodcastStore().applySync(
        profile,
        Map<String, dynamic>.from(podcastsRaw),
      );
    }

    final libraryFoldersRaw = state['libraryFolders'];
    if (libraryFoldersRaw is List) {
      await _applyLibraryFolderSyncPayload(profile, libraryFoldersRaw);
    }

    final libraryPlaybackRaw = state['libraryPlayback'];
    if (libraryPlaybackRaw is Map) {
      await _applyLibraryPlaybackState(
        profile,
        Map<String, dynamic>.from(libraryPlaybackRaw),
      );
    }

    final identityRaw = state['profileIdentity'];
    if (identityRaw is Map) {
      try {
        await HouseholdStore.instance.initialize();
        final localProfile = await HouseholdStore.instance.profileById(profile);
        if (localProfile != null) {
          final name = identityRaw['name']?.toString().trim() ?? '';
          if (name.isNotEmpty && name != localProfile.name) {
            await HouseholdStore.instance.rename(profile, name);
          }
          final avatarBase64 =
              identityRaw['avatarBase64']?.toString().trim() ?? '';
          if (avatarBase64.isNotEmpty) {
            final bytes = base64Decode(avatarBase64);
            if (bytes.length <= _maxSyncedAvatarBytes) {
              final ext = identityRaw['avatarExtension']?.toString().trim();
              await HouseholdStore.instance.setAvatarBytes(
                profile,
                bytes,
                extension: ext == null || ext.isEmpty ? '.png' : ext,
              );
            }
          }

          final jellyfinRaw = state['jellyfinAccount'];
          if (jellyfinRaw is Map) {
            try {
              final payload = Map<String, dynamic>.from(jellyfinRaw);
              final accessToken = payload['accessToken']?.toString() ?? '';
              if (payload['signedOut'] == true) {
                await JellyfinAccountStore.instance().clear(profile);
              } else if (accessToken.isNotEmpty) {
                final account = JellyfinAccount.fromConfigJson(
                  payload,
                  accessToken,
                );
                if (account != null) {
                  await JellyfinAccountStore.instance().save(profile, account);
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
  }

  Future<List<Map<String, dynamic>>> _libraryFolderSyncPayload(
    int profile,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('library.folders.v1.$profile');
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [];
    }
    final values = <Map<String, dynamic>>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(entry);
      final id = map['id']?.toString().trim() ?? '';
      final label = map['label']?.toString().trim() ?? '';
      final path = map['path']?.toString().trim() ?? '';
      if (id.isEmpty || label.isEmpty || path.isEmpty) {
        continue;
      }
      values.add({
        'id': id,
        'label': label,
        'path': path,
        'recordings': map['recordings'] == true,
      });
      if (values.length >= 100) {
        break;
      }
    }
    return values;
  }

  Future<void> _applyLibraryFolderSyncPayload(
    int profile,
    List<dynamic> rawEntries,
  ) async {
    final values = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    for (final entry in rawEntries) {
      if (entry is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(entry);
      final id = map['id']?.toString().trim() ?? '';
      final label = map['label']?.toString().trim() ?? '';
      final path = map['path']?.toString().trim() ?? '';
      if (id.isEmpty || label.isEmpty || path.isEmpty || seenIds.contains(id)) {
        continue;
      }
      seenIds.add(id);
      values.add({
        'id': id,
        'label': label.length > 80 ? label.substring(0, 80) : label,
        'path': path,
        'recordings': map['recordings'] == true,
      });
      if (values.length >= 100) {
        break;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (values.isEmpty) {
      await prefs.remove('library.folders.v1.$profile');
      return;
    }
    await prefs.setString('library.folders.v1.$profile', jsonEncode(values));
  }

  Future<Map<String, dynamic>> libraryPlaybackState(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'library.playback.v1.$profile',
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

  Future<void> saveLibraryPlaybackState(
    int profile, {
    required String itemPath,
    required String title,
    required int positionMs,
    required int durationMs,
    required bool complete,
  }) async {
    final current = await libraryPlaybackState(profile);
    current[itemPath] = {
      'title': title,
      'positionMs': positionMs < 0 ? 0 : positionMs,
      'durationMs': durationMs < 0 ? 0 : durationMs,
      'complete': complete,
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    if (current.length > 1200) {
      final entries = current.entries.toList()
        ..sort((a, b) {
          final aTime =
              DateTime.tryParse(
                (a.value is Map ? (a.value as Map)['updatedAtUtc'] : null)
                        ?.toString() ??
                    '',
              )?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
          final bTime =
              DateTime.tryParse(
                (b.value is Map ? (b.value as Map)['updatedAtUtc'] : null)
                        ?.toString() ??
                    '',
              )?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
          return bTime.compareTo(aTime);
        });
      final trimmed = <String, dynamic>{};
      for (final entry in entries.take(1000)) {
        trimmed[entry.key] = entry.value;
      }
      current
        ..clear()
        ..addAll(trimmed);
    }
    await (await SharedPreferences.getInstance()).setString(
      'library.playback.v1.$profile',
      jsonEncode(current),
    );
  }

  Future<void> _applyLibraryPlaybackState(
    int profile,
    Map<String, dynamic> remote,
  ) async {
    final normalized = <String, dynamic>{};
    for (final entry in remote.entries) {
      final key = entry.key.trim();
      if (key.isEmpty || key.length > 2048 || entry.value is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(entry.value as Map);
      normalized[key] = {
        'title': map['title']?.toString() ?? '',
        'positionMs': int.tryParse(map['positionMs']?.toString() ?? '') ?? 0,
        'durationMs': int.tryParse(map['durationMs']?.toString() ?? '') ?? 0,
        'complete': map['complete'] == true,
        'updatedAtUtc':
            map['updatedAtUtc']?.toString() ??
            DateTime.now().toUtc().toIso8601String(),
      };
      if (normalized.length >= 1000) {
        break;
      }
    }
    await (await SharedPreferences.getInstance()).setString(
      'library.playback.v1.$profile',
      jsonEncode(normalized),
    );
  }

  Future<String> tubePipedUrl(int profile) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('youtube.pipedUrl.v1.$profile') ??
        'https://api.piped.private.coffee';
  }

  Future<void> setTubePipedUrl(int profile, String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException(
        'Piped server must be an HTTP(S) URL without credentials, query or fragment.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('youtube.pipedUrl.v1.$profile', value)) {
      throw StateError('Could not save the Piped server.');
    }
  }

  Future<void> clearProfileData(
    int profile, {
    PodcastDownloads? podcastDownloads,
    TubeDownloads? tubeDownloads,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = <String>[
      'home.visualTheme.v1.$profile',
      'podcasts.v1.$profile',
      'youtube.v1.$profile',
      'youtube.pipedUrl.v1.$profile',
      'home.appOrder.v1.$profile',
      'home.sleepUrl.v1.$profile',
      'home.sleepSoundsPreset.v1.$profile',
      'home.sleepSoundsVolume.v1.$profile',
      'home.sleepSoundsBackend.v1.$profile',
      'home.liveTvPlaylistUrl.v1.$profile',
      'home.tmdbApiKey.v1.$profile',
      'home.sharedFamilyAlbum.v1.$profile',
      'home.playbackPerformance.v1.$profile',
      'home.liveTvSources.v1.$profile',
      'home.liveTvRecent.v1.$profile',
      'home.liveTvRecentMedia.v1.$profile',
      'home.liveTvFavorites.v1.$profile',
      'home.liveTvPlaylists.v1.$profile',
      'home.liveTvTmdbOverrides.v1.$profile',
      'home.liveTvUiState.v1.$profile',
      'home.liveTvPlayerDefaults.v1.$profile',
      'weather.auto.v1.$profile.enabled',
      'weather.auto.v1.$profile.forecast',
      'library.folders.v1.$profile',
      'library.playback.v1.$profile',
      'library.tmdb.cache.v1.$profile',
    ];
    for (final key in keys) {
      if (!await prefs.remove(key)) {
        throw StateError('Could not clear profile data for key: $key');
      }
    }
    await (podcastDownloads ?? PodcastDownloads()).clearProfile(profile);
    await (tubeDownloads ?? TubeDownloads()).clearProfile(profile);
  }
}
