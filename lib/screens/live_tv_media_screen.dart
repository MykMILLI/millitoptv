import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../services/device_connection.dart';
import '../services/firefox_browser.dart';
import '../services/home_preferences.dart';
import '../services/live_tv_control.dart';
import '../services/live_tv_playlist.dart';
import '../services/playback_performance.dart';
import '../services/pip_playback.dart';
import '../services/live_tv_source.dart';

enum _MediaTab { movies, series }

class LiveTvMediaScreen extends StatefulWidget {
  final int profileId;
  final String? initialSourceId;
  final String? initialMediaType;
  final String? initialMediaId;
  final bool autoResume;
  const LiveTvMediaScreen({
    super.key,
    required this.profileId,
    this.initialSourceId,
    this.initialMediaType,
    this.initialMediaId,
    this.autoResume = false,
  });

  @override
  State<LiveTvMediaScreen> createState() => _LiveTvMediaScreenState();
}

class _LiveTvMediaScreenState extends State<LiveTvMediaScreen> {
  final service = const LiveTvPlaylistService();
  final liveTvControl = LiveTvControlService();
  final search = TextEditingController();
  final Map<LiveTvMediaItem, LiveTvSource> mediaItemSources = {};
  List<LiveTvSource> sources = [];
  LiveTvSource? source;
  List<LiveTvMediaItem> movies = [];
  List<LiveTvMediaItem> series = [];
  List<LiveTvRecentMedia> history = [];
  List<LiveTvLibraryItem> favorites = [];
  List<LiveTvUserPlaylist> playlists = [];
  _MediaTab tab = _MediaTab.movies;
  String groupFilter = 'All';
  bool loading = true;
  bool resumedInitial = false;
  bool allSourcesSelected = false;
  int catalogLoadGeneration = 0;
  String status = '';
  String error = '';
  Timer? profileSyncDebounce;
  PlaybackPerformanceSettings playbackPerformance =
      const PlaybackPerformanceSettings();

  @override
  void initState() {
    super.initState();
    search.addListener(() => setState(() {}));
    unawaited(_initialize());
  }

  @override
  void dispose() {
    profileSyncDebounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> _pullRemoteProfileSnapshot() async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      final remote = await liveTvControl.pullConfig(
        expectedConnection: connection,
        profileId: widget.profileId,
      );
      final tmdbApiKey = remote['tmdbApiKey']?.toString().trim() ?? '';
      if (tmdbApiKey.isNotEmpty) {
        await HomePreferences().setTmdbApiKey(widget.profileId, tmdbApiKey);
      }
      final profileState = remote['profileState'];
      if (profileState is Map) {
        await HomePreferences().applyLiveTvProfileSyncState(
          widget.profileId,
          Map<String, dynamic>.from(profileState),
        );
      }
    } catch (_) {}
  }

  Future<void> _scheduleProfileSync() async {
    profileSyncDebounce?.cancel();
    profileSyncDebounce = Timer(const Duration(milliseconds: 900), () async {
      final connection = DeviceConnection.instance.connectionKey;
      if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
        return;
      }
      try {
        await liveTvControl.pushConfig(
          expectedConnection: connection,
          profileId: widget.profileId,
          sources: await HomePreferences().liveTvSources(widget.profileId),
          tmdbApiKey: await HomePreferences().tmdbApiKey(widget.profileId),
          profileState: await HomePreferences().liveTvProfileSyncState(
            widget.profileId,
          ),
        );
      } catch (_) {}
    });
  }

  Future<void> _initialize() async {
    try {
      await _pullRemoteProfileSnapshot();
      playbackPerformance = await HomePreferences().playbackPerformance(
        widget.profileId,
      );
      sources = await HomePreferences().liveTvSources(widget.profileId);
      history = await HomePreferences().liveTvRecentMedia(widget.profileId);
      favorites = await HomePreferences().liveTvFavorites(widget.profileId);
      playlists = await HomePreferences().liveTvPlaylists(widget.profileId);
      if (!mounted) {
        return;
      }
      if (sources.isEmpty) {
        setState(() {
          loading = false;
          error = 'Add a source first in Live TV > Manage Sources.';
        });
        return;
      }
      source = sources.firstWhere(
        (item) => item.id == widget.initialSourceId,
        orElse: () => sources.first,
      );
      allSourcesSelected =
          widget.initialSourceId == null || widget.initialSourceId!.isEmpty;
      if (widget.initialMediaType == 'series') {
        tab = _MediaTab.series;
      } else if (widget.initialMediaType == 'movie') {
        tab = _MediaTab.movies;
      }
      await _loadCatalog();
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _loadCatalog() async {
    if (sources.isEmpty) {
      return;
    }
    final selected = source ?? sources.first;
    final activeSources = allSourcesSelected
        ? List<LiveTvSource>.from(sources)
        : <LiveTvSource>[selected];
    final generation = ++catalogLoadGeneration;
    setState(() {
      loading = true;
      error = '';
      status = allSourcesSelected
          ? 'Loading movies and series from ${activeSources.length} source(s)...'
          : 'Loading movies and series from ${selected.name}...';
    });
    try {
      final loadedMoviesBySource = await Future.wait(
        activeSources.map((item) => service.loadMovies(item)),
      );
      final loadedSeriesBySource = await Future.wait(
        activeSources.map((item) => service.loadSeries(item)),
      );
      if (!mounted || generation != catalogLoadGeneration) {
        return;
      }
      final mergedMovies = <LiveTvMediaItem>[];
      final mergedSeries = <LiveTvMediaItem>[];
      mediaItemSources.clear();
      for (var i = 0; i < activeSources.length; i++) {
        final sourceItem = activeSources[i];
        for (final item in loadedMoviesBySource[i]) {
          mediaItemSources[item] = sourceItem;
          mergedMovies.add(item);
        }
        for (final item in loadedSeriesBySource[i]) {
          mediaItemSources[item] = sourceItem;
          mergedSeries.add(item);
        }
      }
      setState(() {
        movies = mergedMovies;
        series = mergedSeries;
        loading = false;
        status =
            'Loaded ${mergedMovies.length} movies and ${mergedSeries.length} series';
      });
      unawaited(
        _enrichCatalogMetadataIfConfigured(
          activeSources: activeSources,
          loadedMoviesBySource: loadedMoviesBySource,
          loadedSeriesBySource: loadedSeriesBySource,
          generation: generation,
        ),
      );
      await _tryAutoResume();
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _enrichCatalogMetadataIfConfigured({
    required List<LiveTvSource> activeSources,
    required List<List<LiveTvMediaItem>> loadedMoviesBySource,
    required List<List<LiveTvMediaItem>> loadedSeriesBySource,
    required int generation,
  }) async {
    final tmdbApiKey = await HomePreferences().tmdbApiKey(widget.profileId);
    if (tmdbApiKey.trim().isEmpty) {
      return;
    }
    if (!mounted || generation != catalogLoadGeneration) {
      return;
    }
    setState(() => status = 'Enhancing metadata from TMDB...');
    final mergedMovies = <LiveTvMediaItem>[];
    final mergedSeries = <LiveTvMediaItem>[];
    mediaItemSources.clear();
    for (var i = 0; i < activeSources.length; i++) {
      final sourceItem = activeSources[i];
      var sourceMovies = loadedMoviesBySource[i];
      var sourceSeries = loadedSeriesBySource[i];
      if (sourceItem.isM3u) {
        sourceMovies = await service.enrichM3uMetadata(
          items: sourceMovies,
          series: false,
          tmdbApiKey: tmdbApiKey,
        );
        sourceSeries = await service.enrichM3uMetadata(
          items: sourceSeries,
          series: true,
          tmdbApiKey: tmdbApiKey,
        );
      }
      if (!mounted || generation != catalogLoadGeneration) {
        return;
      }
      for (final item in sourceMovies) {
        mediaItemSources[item] = sourceItem;
        mergedMovies.add(item);
      }
      for (final item in sourceSeries) {
        mediaItemSources[item] = sourceItem;
        mergedSeries.add(item);
      }
    }
    if (!mounted || generation != catalogLoadGeneration) {
      return;
    }
    setState(() {
      movies = mergedMovies;
      series = mergedSeries;
      status =
          'Loaded ${mergedMovies.length} movies and ${mergedSeries.length} series';
    });
  }

  Future<void> _tryAutoResume() async {
    if (!widget.autoResume || resumedInitial) {
      return;
    }
    final targetId = widget.initialMediaId;
    if (targetId == null || targetId.trim().isEmpty) {
      return;
    }
    resumedInitial = true;
    final targetType = widget.initialMediaType?.toLowerCase();
    if (targetType == 'series') {
      final match = series.where((item) => item.id == targetId).toList();
      if (match.isNotEmpty) {
        await _openSeries(match.first);
      }
      return;
    }
    final match = movies.where((item) => item.id == targetId).toList();
    if (match.isNotEmpty) {
      await _openMovie(match.first);
    }
  }

  List<String> get groups {
    final values =
        (tab == _MediaTab.movies ? movies : series)
            .map((item) => item.group?.trim() ?? '')
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ['All', ...values];
  }

  List<LiveTvMediaItem> get visibleItems {
    final input = tab == _MediaTab.movies ? movies : series;
    final query = search.text.trim().toLowerCase();
    return input.where((item) {
      if (groupFilter != 'All' &&
          groups.contains(groupFilter) &&
          (item.group ?? '') != groupFilter) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      return item.title.toLowerCase().contains(query) ||
          (item.group ?? '').toLowerCase().contains(query);
    }).toList();
  }

  String _favoriteKey(String sourceId, String mediaType, String mediaId) =>
      '$sourceId|$mediaType|$mediaId';

  bool _isFavorite(String sourceId, String mediaType, String mediaId) =>
      favorites.any(
        (item) => item.key == _favoriteKey(sourceId, mediaType, mediaId),
      );

  LiveTvLibraryItem? _libraryItemFromMedia(LiveTvMediaItem item) {
    final selected = mediaItemSources[item] ?? source;
    if (selected == null) {
      return null;
    }
    return LiveTvLibraryItem(
      sourceId: selected.id,
      sourceName: selected.name,
      mediaType: item.series ? 'series' : 'movie',
      mediaId: item.id,
      title: item.title,
      subtitle: item.group,
      posterUrl: item.posterUrl,
      streamUrl: item.streamUrl.trim().isEmpty ? null : item.streamUrl,
      seriesId: item.seriesId,
    );
  }

  LiveTvLibraryItem? _libraryItemFromEpisode(
    LiveTvSeriesEpisode episode, {
    required String seriesTitle,
    required String seriesPosterUrl,
  }) {
    final selected = source;
    if (selected == null) {
      return null;
    }
    return LiveTvLibraryItem(
      sourceId: selected.id,
      sourceName: selected.name,
      mediaType: 'episode',
      mediaId: 'episode:${episode.id}',
      title: seriesTitle,
      subtitle: 'S${episode.season}E${episode.episode} · ${episode.title}',
      posterUrl: episode.posterUrl ?? seriesPosterUrl,
      streamUrl: episode.streamUrl,
    );
  }

  Future<void> _toggleFavorite(LiveTvLibraryItem item) async {
    final active = favorites.any((entry) => entry.key == item.key);
    try {
      if (active) {
        await HomePreferences().removeLiveTvFavorite(
          widget.profileId,
          sourceId: item.sourceId,
          mediaType: item.mediaType,
          mediaId: item.mediaId,
        );
      } else {
        await HomePreferences().upsertLiveTvFavorite(widget.profileId, item);
      }
      favorites = await HomePreferences().liveTvFavorites(widget.profileId);
      if (mounted) {
        setState(() {});
      }
      unawaited(_scheduleProfileSync());
    } catch (_) {}
  }

  Future<void> _createPlaylist() async {
    final nameController = TextEditingController();
    try {
      final created = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Create playlist'),
          content: TextField(
            controller: nameController,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Playlist name',
              hintText: 'Weekend Favorites',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = nameController.text.trim();
                Navigator.pop(ctx, value);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      );
      final name = created?.trim() ?? '';
      if (name.isEmpty) {
        return;
      }
      final playlist = LiveTvUserPlaylist(
        id: 'pl-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        items: const [],
        updatedAtUtc: DateTime.now().toUtc(),
      );
      await HomePreferences().upsertLiveTvPlaylist(widget.profileId, playlist);
      playlists = await HomePreferences().liveTvPlaylists(widget.profileId);
      if (mounted) {
        setState(() {});
      }
      unawaited(_scheduleProfileSync());
    } finally {
      nameController.dispose();
    }
  }

  Future<void> _addToPlaylist(LiveTvLibraryItem item) async {
    if (playlists.isEmpty) {
      await _createPlaylist();
      playlists = await HomePreferences().liveTvPlaylists(widget.profileId);
      if (playlists.isEmpty) {
        return;
      }
    }
    if (!mounted) {
      return;
    }
    final selectedPlaylistId = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Add to playlist',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final playlist in playlists)
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text(playlist.name),
                subtitle: Text('${playlist.items.length} items'),
                onTap: () => Navigator.pop(ctx, playlist.id),
              ),
          ],
        ),
      ),
    );
    if (selectedPlaylistId == null) {
      return;
    }
    final playlist = playlists.firstWhere(
      (entry) => entry.id == selectedPlaylistId,
      orElse: () => playlists.first,
    );
    final nextItems = [
      item,
      ...playlist.items.where((entry) => entry.key != item.key),
    ];
    final updated = LiveTvUserPlaylist(
      id: playlist.id,
      name: playlist.name,
      items: nextItems,
      updatedAtUtc: DateTime.now().toUtc(),
    );
    await HomePreferences().upsertLiveTvPlaylist(widget.profileId, updated);
    playlists = await HomePreferences().liveTvPlaylists(widget.profileId);
    if (mounted) {
      setState(() {});
    }
    unawaited(_scheduleProfileSync());
  }

  Future<void> _playLibraryItem(LiveTvLibraryItem item) async {
    if (item.mediaType == 'series') {
      await _openSeriesFromLibrary(item);
      return;
    }
    final stream = item.streamUrl?.trim() ?? '';
    if (stream.isEmpty) {
      return;
    }
    unawaited(_reportMediaPlayback(item, active: true));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MediaPlayerScreen(
          title: item.title,
          subtitle: item.subtitle ?? item.sourceName,
          streamUrl: stream,
          posterUrl: item.posterUrl,
          playbackPerformance: playbackPerformance,
        ),
      ),
    );
  }

  Future<void> _reportMediaPlayback(
    LiveTvLibraryItem item, {
    required bool active,
  }) async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      await liveTvControl.reportPlayback(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: item.sourceId,
        sourceName: item.sourceName,
        mediaType: item.mediaType,
        mediaId: item.mediaId,
        title: item.subtitle == null
            ? item.title
            : '${item.title} ${item.subtitle}',
        active: active,
      );
    } catch (_) {}
  }

  Future<void> _openSeriesFromLibrary(LiveTvLibraryItem item) async {
    final foundSource = sources.where((entry) => entry.id == item.sourceId);
    if (foundSource.isEmpty) {
      return;
    }
    final selectedSource = foundSource.first;
    final switchedSource = source?.id != selectedSource.id;
    if (switchedSource) {
      setState(() => source = selectedSource);
    }
    var candidates = series;
    if (switchedSource || series.isEmpty) {
      candidates = await service.loadSeries(selectedSource);
    }
    final match = candidates
        .where((entry) => entry.id == item.mediaId)
        .toList();
    if (match.isNotEmpty) {
      await _openSeries(match.first);
      return;
    }
    final byTitle = candidates
        .where((entry) => entry.title.toLowerCase() == item.title.toLowerCase())
        .toList();
    if (byTitle.isNotEmpty) {
      await _openSeries(byTitle.first);
    }
  }

  Future<void> _managePlaylists() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PlaylistsScreen(
          playlists: playlists,
          reloadPlaylists: () =>
              HomePreferences().liveTvPlaylists(widget.profileId),
          onCreate: _createPlaylist,
          onPlay: _playLibraryItem,
          onDeletePlaylist: (playlist) async {
            await HomePreferences().removeLiveTvPlaylist(
              widget.profileId,
              playlist.id,
            );
            playlists = await HomePreferences().liveTvPlaylists(
              widget.profileId,
            );
            if (mounted) {
              setState(() {});
            }
            unawaited(_scheduleProfileSync());
          },
          onUpdatePlaylist: (playlist) async {
            await HomePreferences().upsertLiveTvPlaylist(
              widget.profileId,
              playlist,
            );
            playlists = await HomePreferences().liveTvPlaylists(
              widget.profileId,
            );
            if (mounted) {
              setState(() {});
            }
            unawaited(_scheduleProfileSync());
          },
        ),
      ),
    );
    playlists = await HomePreferences().liveTvPlaylists(widget.profileId);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _showMediaDetails(LiveTvMediaItem item) async {
    final libraryItem = _libraryItemFromMedia(item);
    if (libraryItem == null) {
      return;
    }
    final tmdbApiKey = await HomePreferences().tmdbApiKey(widget.profileId);
    final metadata = tmdbApiKey.trim().isEmpty
        ? null
        : await service.loadTmdbMetadataDetails(
            title: item.title,
            series: item.series,
            tmdbApiKey: tmdbApiKey,
          );
    if (!mounted) {
      return;
    }
    final poster = metadata?.posterUrl ?? item.posterUrl;
    final backdrop = metadata?.backdropUrl ?? item.backdropUrl;
    final description = metadata?.overview?.trim().isNotEmpty == true
        ? metadata!.overview!
        : (item.description?.trim().isNotEmpty == true
              ? item.description!
              : 'No synopsis available for this item.');
    final trailerUrl = metadata?.trailerUrl;
    final cast = metadata?.cast ?? const <String>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * .88,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
            children: [
              if (backdrop != null && backdrop.trim().isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    backdrop,
                    height: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: poster == null || poster.trim().isEmpty
                        ? Container(
                            width: 132,
                            height: 186,
                            color: const Color(0xFF1F2B3F),
                            alignment: Alignment.center,
                            child: const Icon(Icons.movie, size: 42),
                          )
                        : Image.network(
                            poster,
                            width: 132,
                            height: 186,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 132,
                              height: 186,
                              color: const Color(0xFF1F2B3F),
                              alignment: Alignment.center,
                              child: const Icon(Icons.movie, size: 42),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (item.group?.trim().isNotEmpty == true)
                          Text(
                            item.group!,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                unawaited(
                                  item.series
                                      ? _openSeries(item)
                                      : _openMovie(item),
                                );
                              },
                              icon: Icon(
                                item.series
                                    ? Icons.list_alt_outlined
                                    : Icons.play_arrow,
                              ),
                              label: Text(
                                item.series ? 'Browse Episodes' : 'Play Now',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                unawaited(_toggleFavorite(libraryItem));
                              },
                              icon: Icon(
                                _isFavorite(
                                      libraryItem.sourceId,
                                      libraryItem.mediaType,
                                      libraryItem.mediaId,
                                    )
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                              ),
                              label: const Text('Favorite'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                unawaited(_addToPlaylist(libraryItem));
                              },
                              icon: const Icon(Icons.playlist_add),
                              label: const Text('Add to Playlist'),
                            ),
                            if (trailerUrl != null && trailerUrl.isNotEmpty)
                              TextButton.icon(
                                onPressed: () => FirefoxBrowser.open(
                                  context,
                                  profileId: widget.profileId,
                                  url: trailerUrl,
                                ),
                                icon: const Icon(Icons.ondemand_video),
                                label: const Text('Watch Trailer'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                description,
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
              if (cast.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text(
                  'Cast',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: cast
                      .map((name) => Chip(label: Text(name)))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showEpisodeDetails(
    LiveTvSeriesEpisode episode, {
    required String seriesTitle,
    required String seriesPoster,
  }) async {
    final item = _libraryItemFromEpisode(
      episode,
      seriesTitle: seriesTitle,
      seriesPosterUrl: seriesPoster,
    );
    if (item == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.subtitle ?? episode.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                episode.description?.trim().isNotEmpty == true
                    ? episode.description!
                    : 'No episode synopsis available from source.',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      unawaited(_playLibraryItem(item));
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play Episode'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      unawaited(_toggleFavorite(item));
                    },
                    icon: Icon(
                      _isFavorite(item.sourceId, item.mediaType, item.mediaId)
                          ? Icons.favorite
                          : Icons.favorite_border,
                    ),
                    label: const Text('Favorite'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      unawaited(_addToPlaylist(item));
                    },
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Add to Playlist'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMovie(LiveTvMediaItem item) async {
    await _saveHistory(item, subtitle: item.group);
    final libraryItem = _libraryItemFromMedia(item);
    if (libraryItem != null) {
      unawaited(_reportMediaPlayback(libraryItem, active: true));
    }
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MediaPlayerScreen(
          title: item.title,
          subtitle: item.group,
          streamUrl: item.streamUrl,
          posterUrl: item.posterUrl,
          playbackPerformance: playbackPerformance,
        ),
      ),
    );
  }

  Future<void> _openSeries(LiveTvMediaItem item) async {
    final selected = mediaItemSources[item] ?? source;
    if (selected == null) {
      return;
    }
    if (source?.id != selected.id && mounted) {
      setState(() => source = selected);
    }
    if (item.seriesId == null || item.seriesId!.trim().isEmpty) {
      await _saveHistory(item, subtitle: item.group);
      final libraryItem = _libraryItemFromMedia(item);
      if (libraryItem != null) {
        unawaited(_reportMediaPlayback(libraryItem, active: true));
      }
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _MediaPlayerScreen(
            title: item.title,
            subtitle: item.group ?? 'Series',
            streamUrl: item.streamUrl,
            posterUrl: item.posterUrl,
            playbackPerformance: playbackPerformance,
          ),
        ),
      );
      return;
    }
    final details = await service.loadSeriesDetails(
      selected,
      item.seriesId!,
      item.title,
    );
    if (!mounted) {
      return;
    }
    final episodes = details?.episodes ?? const <LiveTvSeriesEpisode>[];
    if (episodes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No episodes were returned for this series.'),
          ),
        );
      }
      return;
    }
    final seriesDetails =
        details ??
        LiveTvSeriesDetails(
          seriesId: item.seriesId!,
          title: item.title,
          description: item.description,
          posterUrl: item.posterUrl,
          backdropUrl: item.backdropUrl,
          episodes: episodes,
        );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _SeriesDetailsScreen(
          details: seriesDetails,
          onEpisodeDetails: (episode) => _showEpisodeDetails(
            episode,
            seriesTitle: seriesDetails.title,
            seriesPoster: seriesDetails.posterUrl ?? item.posterUrl ?? '',
          ),
          onPlay: (episode) async {
            await _saveHistory(
              item,
              subtitle:
                  'S${episode.season}E${episode.episode} ${episode.title}',
            );
            final libraryEpisode = _libraryItemFromEpisode(
              episode,
              seriesTitle: seriesDetails.title,
              seriesPosterUrl: seriesDetails.posterUrl ?? item.posterUrl ?? '',
            );
            if (libraryEpisode != null) {
              unawaited(_reportMediaPlayback(libraryEpisode, active: true));
            }
            if (!mounted) {
              return;
            }
            await Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => _MediaPlayerScreen(
                  title: seriesDetails.title,
                  subtitle:
                      'S${episode.season}E${episode.episode} · ${episode.title}',
                  streamUrl: episode.streamUrl,
                  posterUrl: episode.posterUrl ?? seriesDetails.posterUrl,
                  playbackPerformance: playbackPerformance,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _saveHistory(LiveTvMediaItem item, {String? subtitle}) async {
    final selected = mediaItemSources[item] ?? source;
    if (selected == null) {
      return;
    }
    try {
      await HomePreferences().upsertLiveTvRecentMedia(
        widget.profileId,
        LiveTvRecentMedia(
          sourceId: selected.id,
          sourceName: selected.name,
          mediaType: tab == _MediaTab.movies ? 'movie' : 'series',
          mediaId: item.id,
          title: item.title,
          subtitle: subtitle,
          posterUrl: item.posterUrl,
          watchedAtUtc: DateTime.now().toUtc(),
        ),
      );
      history = await HomePreferences().liveTvRecentMedia(widget.profileId);
      if (mounted) {
        setState(() {});
      }
      unawaited(_scheduleProfileSync());
    } catch (_) {}
  }

  Future<void> _resumeRecentMedia(LiveTvRecentMedia recent) async {
    final targetSource = source;
    if (targetSource == null) {
      return;
    }
    if (recent.mediaType == 'movie') {
      final match = movies.where((item) => item.id == recent.mediaId).toList();
      if (match.isNotEmpty) {
        await _openMovie(match.first);
      }
      return;
    }
    final match = series.where((item) => item.id == recent.mediaId).toList();
    if (match.isNotEmpty) {
      await _openSeries(match.first);
    }
  }

  Future<void> _removeRecentMedia(LiveTvRecentMedia recent) async {
    try {
      await HomePreferences().removeLiveTvRecentMedia(
        widget.profileId,
        sourceId: recent.sourceId,
        mediaType: recent.mediaType,
        mediaId: recent.mediaId,
      );
      history = await HomePreferences().liveTvRecentMedia(widget.profileId);
      if (mounted) {
        setState(() {});
      }
      unawaited(_scheduleProfileSync());
    } catch (_) {}
  }

  Widget _historyPanel() {
    final values = history.take(6).toList();
    if (values.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in values)
          InputChip(
            avatar: Icon(
              item.mediaType == 'movie'
                  ? Icons.movie_creation_outlined
                  : Icons.tv,
            ),
            label: Text(
              item.subtitle == null
                  ? item.title
                  : '${item.title} · ${item.subtitle}',
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => unawaited(_resumeRecentMedia(item)),
            onDeleted: () => unawaited(_removeRecentMedia(item)),
            deleteIcon: const Icon(Icons.close, size: 16),
          ),
      ],
    );
  }

  Widget _favoritesPanel() {
    final filtered = favorites
        .where(
          (item) => tab == _MediaTab.movies
              ? item.mediaType == 'movie'
              : item.mediaType == 'series' || item.mediaType == 'episode',
        )
        .take(10)
        .toList();
    if (filtered.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in filtered)
          InputChip(
            avatar: const Icon(
              Icons.favorite,
              size: 16,
              color: Colors.redAccent,
            ),
            label: Text(
              item.subtitle == null
                  ? item.title
                  : '${item.title} · ${item.subtitle}',
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => unawaited(_playLibraryItem(item)),
            onDeleted: () => unawaited(
              HomePreferences()
                  .removeLiveTvFavorite(
                    widget.profileId,
                    sourceId: item.sourceId,
                    mediaType: item.mediaType,
                    mediaId: item.mediaId,
                  )
                  .then(
                    (_) => HomePreferences().liveTvFavorites(widget.profileId),
                  )
                  .then((value) {
                    favorites = value;
                    if (mounted) {
                      setState(() {});
                    }
                  }),
            ),
          ),
      ],
    );
  }

  Widget _continueWatchingCard() {
    final values = history
        .where(
          (item) => tab == _MediaTab.movies
              ? item.mediaType == 'movie'
              : item.mediaType == 'series',
        )
        .toList();
    if (values.isEmpty) {
      return const SizedBox.shrink();
    }
    final recent = values.first;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child:
                  recent.posterUrl == null || recent.posterUrl!.trim().isEmpty
                  ? Container(
                      width: 96,
                      height: 128,
                      color: const Color(0xFF1F2B3F),
                      alignment: Alignment.center,
                      child: const Icon(Icons.movie, size: 34),
                    )
                  : Image.network(
                      recent.posterUrl!,
                      width: 96,
                      height: 128,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 96,
                        height: 128,
                        color: const Color(0xFF1F2B3F),
                        alignment: Alignment.center,
                        child: const Icon(Icons.movie, size: 34),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Continue watching',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove from continue watching',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => unawaited(_removeRecentMedia(recent)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recent.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (recent.subtitle != null)
                    Text(
                      recent.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  Text(
                    recent.sourceName ?? recent.sourceId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: () => unawaited(_resumeRecentMedia(recent)),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Resume'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = visibleItems;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Movies & Series'),
        actions: [
          IconButton(
            tooltip: 'Playlists',
            onPressed: _managePlaylists,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.playlist_play),
                if (playlists.isNotEmpty)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: CircleAvatar(
                      radius: 8,
                      backgroundColor: Colors.blueAccent,
                      child: Text(
                        '${playlists.length}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(onPressed: _loadCatalog, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          if (loading) const LinearProgressIndicator(),
          if (status.isNotEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(status)),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                error,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: allSourcesSelected ? 'all' : source?.id,
                    decoration: const InputDecoration(
                      labelText: 'Source',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: 'all',
                        child: Text('All Sources'),
                      ),
                      ...sources.map(
                        (item) => DropdownMenuItem<String>(
                          value: item.id,
                          child: Text(
                            item.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: loading
                        ? null
                        : (value) async {
                            if (value == 'all') {
                              setState(() => allSourcesSelected = true);
                              await _loadCatalog();
                              return;
                            }
                            final next = sources.firstWhere(
                              (item) => item.id == value,
                              orElse: () => sources.first,
                            );
                            setState(() {
                              source = next;
                              allSourcesSelected = false;
                            });
                            await _loadCatalog();
                          },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: search,
                    decoration: const InputDecoration(
                      labelText: 'Search movies or series',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<_MediaTab>(
                    initialValue: tab,
                    decoration: const InputDecoration(
                      labelText: 'Media Type',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: _MediaTab.movies,
                        child: Text('Movies'),
                      ),
                      DropdownMenuItem(
                        value: _MediaTab.series,
                        child: Text('Series'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        tab = value;
                        groupFilter = 'All';
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('media-group-$groupFilter-${groups.length}'),
                    initialValue: groups.contains(groupFilter)
                        ? groupFilter
                        : groups.first,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      border: OutlineInputBorder(),
                    ),
                    items: groups
                        .map(
                          (group) => DropdownMenuItem<String>(
                            value: group,
                            child: Text(group, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() => groupFilter = value);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _continueWatchingCard(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _historyPanel(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _favoritesPanel(),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text('No items match the current filter.'),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final maxCardWidth = max(190.0, width / 5.2).toDouble();
                      final titleLines = width > 1200 ? 3 : 2;
                      return GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: maxCardWidth,
                          childAspectRatio: .70,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final selected = mediaItemSources[item] ?? source;
                          final favorite = selected == null
                              ? false
                              : _isFavorite(
                                  selected.id,
                                  item.series ? 'series' : 'movie',
                                  item.id,
                                );
                          return InkWell(
                            onTap: () => unawaited(_showMediaDetails(item)),
                            child: Card(
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child:
                                        item.posterUrl == null ||
                                            item.posterUrl!.trim().isEmpty
                                        ? const ColoredBox(
                                            color: Color(0xFF1F2B3F),
                                            child: Center(
                                              child: Icon(
                                                Icons.live_tv,
                                                size: 46,
                                              ),
                                            ),
                                          )
                                        : Image.network(
                                            item.posterUrl!,
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            errorBuilder: (_, __, ___) =>
                                                const ColoredBox(
                                                  color: Color(0xFF1F2B3F),
                                                  child: Center(
                                                    child: Icon(
                                                      Icons.movie_outlined,
                                                      size: 46,
                                                    ),
                                                  ),
                                                ),
                                          ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                item.title,
                                                maxLines: titleLines,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ),
                                            Icon(
                                              favorite
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              size: 16,
                                              color: favorite
                                                  ? Colors.redAccent
                                                  : Colors.white54,
                                            ),
                                          ],
                                        ),
                                        if (item.group != null &&
                                            item.group!.trim().isNotEmpty)
                                          Text(
                                            item.group!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                        if (selected != null)
                                          Text(
                                            selected.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 11,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MediaPlayerScreen extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String streamUrl;
  final String? posterUrl;
  final PlaybackPerformanceSettings playbackPerformance;
  const _MediaPlayerScreen({
    required this.title,
    this.subtitle,
    required this.streamUrl,
    this.posterUrl,
    required this.playbackPerformance,
  });

  @override
  State<_MediaPlayerScreen> createState() => _MediaPlayerScreenState();
}

class _MediaPlayerScreenState extends State<_MediaPlayerScreen> {
  Player? player;
  VideoController? video;
  Track selectedTrack = const Track();
  Tracks tracks = const Tracks();
  final subscriptions = <StreamSubscription<dynamic>>[];
  Duration duration = Duration.zero;
  Duration position = Duration.zero;
  bool playing = false;
  String error = '';
  String playbackEngineStatus = 'GPU decode: checking...';
  Timer? playbackStatusTimer;
  bool fullscreen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    if (fullscreen) {
      unawaited(_setFullscreen(false));
    }
    playbackStatusTimer?.cancel();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    final current = player;
    player = null;
    video = null;
    unawaited(current?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      MediaKit.ensureInitialized();
      final created = Player(
        configuration: playerConfigurationFor(widget.playbackPerformance),
      );
      try {
        await applyNativePlaybackPerformance(
          created,
          widget.playbackPerformance,
        );
      } catch (error) {
        if (mounted) {
          setState(
            () => this.error =
                'Playback tuning is partially unavailable on this device: $error',
          );
        }
      }
      final controller = VideoController(created);
      subscriptions.add(
        created.stream.track.listen((value) {
          if (mounted) {
            setState(() => selectedTrack = value);
          }
        }),
      );
      subscriptions.add(
        created.stream.duration.listen((value) {
          if (mounted) {
            setState(() => duration = value);
          }
        }),
      );
      subscriptions.add(
        created.stream.position.listen((value) {
          if (mounted) {
            setState(() => position = value);
          }
        }),
      );
      subscriptions.add(
        created.stream.playing.listen((value) {
          if (mounted) {
            setState(() => playing = value);
          }
        }),
      );
      subscriptions.add(
        created.stream.tracks.listen((value) {
          if (mounted) {
            setState(() => tracks = value);
          }
        }),
      );
      await created.open(Media(widget.streamUrl), play: true);
      if (!mounted) {
        await created.dispose();
        return;
      }
      await _refreshPlaybackEngineStatus(created);
      playbackStatusTimer?.cancel();
      playbackStatusTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        final current = player;
        if (current == null || !mounted) {
          return;
        }
        unawaited(_refreshPlaybackEngineStatus(current));
      });
      setState(() {
        player = created;
        video = controller;
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _refreshPlaybackEngineStatus(Player current) async {
    final label = await playbackEngineStatusLabel(
      current,
      widget.playbackPerformance,
    );
    if (!mounted) {
      return;
    }
    setState(() => playbackEngineStatus = label);
  }

  Future<void> _setFullscreen(bool value) async {
    try {
      if (value) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(const []);
      }
    } catch (_) {}
    try {
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        await windowManager.setFullScreen(value);
      }
    } catch (_) {}
    if (mounted) {
      setState(() => fullscreen = value);
    } else {
      fullscreen = value;
    }
  }

  Future<void> _toggleFullscreen() async {
    await _setFullscreen(!fullscreen);
  }

  Future<void> _minimizeToPipAndGoHome() async {
    if (fullscreen) {
      await _setFullscreen(false);
    }
    final current = player;
    final controller = video;
    if (current == null || controller == null) {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return;
    }
    playbackStatusTimer?.cancel();
    playbackStatusTimer = null;
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    player = null;
    video = null;
    await PipPlaybackController.instance.minimize(
      PipPlaybackSession(
        player: current,
        video: controller,
        title: widget.title,
        subtitle: widget.subtitle,
        seekable: true,
        onClose: () async {
          try {
            await current.dispose().timeout(const Duration(seconds: 8));
          } catch (_) {}
        },
      ),
    );
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _pickSubtitle() async {
    final current = player;
    if (current == null) {
      return;
    }
    final options = tracks.subtitle;
    if (options.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                'Subtitle Tracks',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final track in options)
              ListTile(
                leading: Icon(
                  selectedTrack.subtitle == track
                      ? Icons.check_circle
                      : Icons.subtitles_outlined,
                ),
                title: Text(track.title ?? '(Unnamed subtitle track)'),
                subtitle: Text('${track.id} • ${track.language ?? 'unknown'}'),
                onTap: () async {
                  await current.setSubtitleTrack(track);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _seekRelative(Duration delta) async {
    final current = player;
    if (current == null || duration <= Duration.zero) {
      return;
    }
    final target = (position + delta).inMilliseconds.clamp(
      0,
      duration.inMilliseconds,
    );
    await current.seek(Duration(milliseconds: target));
  }

  Future<void> _togglePlayPause() async {
    final current = player;
    if (current == null) {
      return;
    }
    if (playing) {
      await current.pause();
    } else {
      await current.play();
    }
  }

  String _clockText(Duration value) {
    final totalSeconds = value.inSeconds.clamp(0, 359999);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _runtimeText(Duration value) {
    final totalMinutes = value.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    return '${minutes}m';
  }

  String _endTimeText(Duration remaining) {
    final end = DateTime.now().add(remaining);
    var hour = end.hour;
    final suffix = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) {
      hour = 12;
    }
    return '$hour:${end.minute.toString().padLeft(2, '0')} $suffix';
  }

  Duration _remainingDuration() {
    final remaining = duration - position;
    if (remaining.isNegative) {
      return Duration.zero;
    }
    return remaining;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (_, __) {
      unawaited(_minimizeToPipAndGoHome());
    },
    child: Scaffold(
      appBar: fullscreen
          ? null
          : AppBar(
              title: Text(widget.title),
              leading: IconButton(
                tooltip: 'Home (PiP)',
                onPressed: () => unawaited(_minimizeToPipAndGoHome()),
                icon: const Icon(Icons.arrow_back),
              ),
              actions: [
                IconButton(
                  tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                  onPressed: () => unawaited(_toggleFullscreen()),
                  icon: Icon(
                    fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  ),
                ),
                IconButton(
                  tooltip: 'Subtitles',
                  onPressed: _pickSubtitle,
                  icon: const Icon(Icons.subtitles),
                ),
              ],
              bottom: widget.subtitle == null
                  ? null
                  : PreferredSize(
                      preferredSize: const Size.fromHeight(30),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          widget.subtitle!,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
            ),
      body: error.isNotEmpty
          ? Center(
              child: Text(
                error,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            )
          : video == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Video(
                        controller: video!,
                        controls: NoVideoControls,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: SafeArea(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton.filledTonal(
                          tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                          onPressed: () => unawaited(_toggleFullscreen()),
                          icon: Icon(
                            fullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: 'Subtitles',
                          onPressed: _pickSubtitle,
                          icon: const Icon(Icons.subtitles),
                        ),
                        const SizedBox(width: 8),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xAA000000),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            child: Text(
                              playbackEngineStatus,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: SafeArea(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xCC000000),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: MediaQuery.sizeOf(context).width < 760
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      IconButton.filledTonal(
                                        onPressed: () => unawaited(
                                          _seekRelative(
                                            const Duration(seconds: -30),
                                          ),
                                        ),
                                        icon: const Icon(Icons.replay_30),
                                        tooltip: 'Rewind 30s',
                                      ),
                                      IconButton.filledTonal(
                                        onPressed: () => unawaited(
                                          _seekRelative(
                                            const Duration(seconds: -10),
                                          ),
                                        ),
                                        icon: const Icon(Icons.replay_10),
                                        tooltip: 'Rewind 10s',
                                      ),
                                      IconButton.filled(
                                        onPressed: () =>
                                            unawaited(_togglePlayPause()),
                                        icon: Icon(
                                          playing
                                              ? Icons.pause
                                              : Icons.play_arrow,
                                        ),
                                        tooltip: playing ? 'Pause' : 'Play',
                                      ),
                                      IconButton.filledTonal(
                                        onPressed: () => unawaited(
                                          _seekRelative(
                                            const Duration(seconds: 10),
                                          ),
                                        ),
                                        icon: const Icon(Icons.forward_10),
                                        tooltip: 'Forward 10s',
                                      ),
                                      IconButton.filledTonal(
                                        onPressed: () => unawaited(
                                          _seekRelative(
                                            const Duration(seconds: 30),
                                          ),
                                        ),
                                        icon: const Icon(Icons.forward_30),
                                        tooltip: 'Forward 30s',
                                      ),
                                    ],
                                  ),
                                  Slider(
                                    value: duration.inMilliseconds <= 0
                                        ? 0
                                        : position.inMilliseconds
                                              .clamp(0, duration.inMilliseconds)
                                              .toDouble(),
                                    min: 0,
                                    max: duration.inMilliseconds <= 0
                                        ? 1
                                        : duration.inMilliseconds.toDouble(),
                                    onChanged: duration.inMilliseconds <= 0
                                        ? null
                                        : (value) => unawaited(
                                            player?.seek(
                                                  Duration(
                                                    milliseconds:
                                                        value.toInt(),
                                                  ),
                                                ) ??
                                                Future<void>.value(),
                                          ),
                                  ),
                                  if (duration.inMilliseconds > 0)
                                    Wrap(
                                      alignment: WrapAlignment.center,
                                      spacing: 12,
                                      runSpacing: 4,
                                      children: [
                                        Text(
                                          _clockText(position),
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        Text(
                                          '-${_clockText(_remainingDuration())}',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        Text(
                                          'Runtime ${_runtimeText(duration)}',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        Text(
                                          'End ${_endTimeText(_remainingDuration())}',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ],
                                    ),
                                ],
                              )
                            : Row(
                                children: [
                                  IconButton(
                                    onPressed: () => unawaited(
                                      _seekRelative(
                                        const Duration(seconds: -30),
                                      ),
                                    ),
                                    icon: const Icon(Icons.replay_30),
                                    tooltip: 'Rewind 30s',
                                  ),
                                  IconButton(
                                    onPressed: () => unawaited(
                                      _seekRelative(
                                        const Duration(seconds: -10),
                                      ),
                                    ),
                                    icon: const Icon(Icons.replay_10),
                                    tooltip: 'Rewind 10s',
                                  ),
                                  IconButton(
                                    onPressed: () => unawaited(
                                      _togglePlayPause(),
                                    ),
                                    icon: Icon(
                                      playing ? Icons.pause : Icons.play_arrow,
                                    ),
                                    tooltip: playing ? 'Pause' : 'Play',
                                  ),
                                  IconButton(
                                    onPressed: () => unawaited(
                                      _seekRelative(
                                        const Duration(seconds: 10),
                                      ),
                                    ),
                                    icon: const Icon(Icons.forward_10),
                                    tooltip: 'Forward 10s',
                                  ),
                                  IconButton(
                                    onPressed: () => unawaited(
                                      _seekRelative(
                                        const Duration(seconds: 30),
                                      ),
                                    ),
                                    icon: const Icon(Icons.forward_30),
                                    tooltip: 'Forward 30s',
                                  ),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Slider(
                                          value: duration.inMilliseconds <= 0
                                              ? 0
                                              : position.inMilliseconds
                                                    .clamp(
                                                      0,
                                                      duration.inMilliseconds,
                                                    )
                                                    .toDouble(),
                                          min: 0,
                                          max: duration.inMilliseconds <= 0
                                              ? 1
                                              : duration.inMilliseconds
                                                    .toDouble(),
                                          onChanged:
                                              duration.inMilliseconds <= 0
                                              ? null
                                              : (value) => unawaited(
                                                  player?.seek(
                                                        Duration(
                                                          milliseconds: value
                                                              .toInt(),
                                                        ),
                                                      ) ??
                                                      Future<void>.value(),
                                                ),
                                        ),
                                        if (duration.inMilliseconds > 0)
                                          Wrap(
                                            spacing: 12,
                                            runSpacing: 4,
                                            children: [
                                              Text(
                                                _clockText(position),
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                ),
                                              ),
                                              Text(
                                                '-${_clockText(_remainingDuration())}',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                ),
                                              ),
                                              Text(
                                                'Runtime ${_runtimeText(duration)}',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                ),
                                              ),
                                              Text(
                                                'End ${_endTimeText(_remainingDuration())}',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}

class _SeriesDetailsScreen extends StatefulWidget {
  final LiveTvSeriesDetails details;
  final Future<void> Function(LiveTvSeriesEpisode episode) onPlay;
  final Future<void> Function(LiveTvSeriesEpisode episode) onEpisodeDetails;
  const _SeriesDetailsScreen({
    required this.details,
    required this.onPlay,
    required this.onEpisodeDetails,
  });

  @override
  State<_SeriesDetailsScreen> createState() => _SeriesDetailsScreenState();
}

class _SeriesDetailsScreenState extends State<_SeriesDetailsScreen> {
  late int season;

  @override
  void initState() {
    super.initState();
    season = widget.details.episodes.first.season;
  }

  List<int> get seasons =>
      widget.details.episodes.map((item) => item.season).toSet().toList()
        ..sort();

  @override
  Widget build(BuildContext context) {
    final visible = widget.details.episodes
        .where((item) => item.season == season)
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.details.title)),
      body: Column(
        children: [
          SizedBox(
            height: 220,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.details.backdropUrl != null &&
                    widget.details.backdropUrl!.trim().isNotEmpty)
                  Image.network(
                    widget.details.backdropUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Color(0xFF0E1829)),
                  )
                else
                  const ColoredBox(color: Color(0xFF0E1829)),
                Container(color: const Color(0xAA000000)),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child:
                            widget.details.posterUrl == null ||
                                widget.details.posterUrl!.trim().isEmpty
                            ? Container(
                                width: 120,
                                height: 172,
                                color: const Color(0xFF1F2B3F),
                                alignment: Alignment.center,
                                child: const Icon(Icons.tv, size: 42),
                              )
                            : Image.network(
                                widget.details.posterUrl!,
                                width: 120,
                                height: 172,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 120,
                                  height: 172,
                                  color: const Color(0xFF1F2B3F),
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.tv, size: 42),
                                ),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.details.title,
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.details.description?.trim().isNotEmpty ==
                                      true
                                  ? widget.details.description!
                                  : 'Series details are not provided by this source.',
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                children: [
                  for (final value in seasons)
                    ChoiceChip(
                      label: Text('Season $value'),
                      selected: season == value,
                      onSelected: (_) => setState(() => season = value),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: visible.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final episode = visible[index];
                return Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => unawaited(widget.onEpisodeDetails(episode)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child:
                                episode.posterUrl == null ||
                                    episode.posterUrl!.trim().isEmpty
                                ? Container(
                                    width: 130,
                                    height: 74,
                                    color: const Color(0xFF1F2B3F),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.ondemand_video_outlined,
                                    ),
                                  )
                                : Image.network(
                                    episode.posterUrl!,
                                    width: 130,
                                    height: 74,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 130,
                                      height: 74,
                                      color: const Color(0xFF1F2B3F),
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.ondemand_video_outlined,
                                      ),
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'E${episode.episode.toString().padLeft(2, '0')} · ${episode.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  episode.description?.trim().isNotEmpty == true
                                      ? episode.description!
                                      : 'No episode synopsis available from source.',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.play_circle_fill),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistsScreen extends StatefulWidget {
  final List<LiveTvUserPlaylist> playlists;
  final Future<List<LiveTvUserPlaylist>> Function() reloadPlaylists;
  final Future<void> Function() onCreate;
  final Future<void> Function(LiveTvLibraryItem item) onPlay;
  final Future<void> Function(LiveTvUserPlaylist playlist) onDeletePlaylist;
  final Future<void> Function(LiveTvUserPlaylist playlist) onUpdatePlaylist;
  const _PlaylistsScreen({
    required this.playlists,
    required this.reloadPlaylists,
    required this.onCreate,
    required this.onPlay,
    required this.onDeletePlaylist,
    required this.onUpdatePlaylist,
  });

  @override
  State<_PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<_PlaylistsScreen> {
  late List<LiveTvUserPlaylist> playlists;

  @override
  void initState() {
    super.initState();
    playlists = [...widget.playlists];
  }

  Future<void> _create() async {
    await widget.onCreate();
    final latest = await widget.reloadPlaylists();
    if (mounted) {
      setState(() => playlists = latest);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Playlists'),
      actions: [
        IconButton(
          tooltip: 'Create playlist',
          onPressed: () => unawaited(_create()),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: playlists.isEmpty
        ? const Center(
            child: Text(
              'No playlists yet. Add movies, series, or episodes to create one.',
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            itemCount: playlists.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              return Card(
                child: ListTile(
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => _PlaylistDetailsScreen(
                        playlist: playlist,
                        onPlay: widget.onPlay,
                        onSave: (updated) async {
                          await widget.onUpdatePlaylist(updated);
                          if (mounted) {
                            setState(() {
                              playlists = [
                                updated,
                                ...playlists.where(
                                  (item) => item.id != updated.id,
                                ),
                              ];
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  leading: const Icon(Icons.playlist_play),
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.items.length} items'),
                  trailing: IconButton(
                    tooltip: 'Delete playlist',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await widget.onDeletePlaylist(playlist);
                      final latest = await widget.reloadPlaylists();
                      if (mounted) {
                        setState(() => playlists = latest);
                      }
                    },
                  ),
                ),
              );
            },
          ),
  );
}

class _PlaylistDetailsScreen extends StatefulWidget {
  final LiveTvUserPlaylist playlist;
  final Future<void> Function(LiveTvLibraryItem item) onPlay;
  final Future<void> Function(LiveTvUserPlaylist updated) onSave;
  const _PlaylistDetailsScreen({
    required this.playlist,
    required this.onPlay,
    required this.onSave,
  });

  @override
  State<_PlaylistDetailsScreen> createState() => _PlaylistDetailsScreenState();
}

class _PlaylistDetailsScreenState extends State<_PlaylistDetailsScreen> {
  late LiveTvUserPlaylist playlist;
  final random = Random();

  @override
  void initState() {
    super.initState();
    playlist = widget.playlist;
  }

  Future<void> _removeItem(LiveTvLibraryItem item) async {
    final updated = LiveTvUserPlaylist(
      id: playlist.id,
      name: playlist.name,
      items: playlist.items.where((entry) => entry.key != item.key).toList(),
      updatedAtUtc: DateTime.now().toUtc(),
    );
    await widget.onSave(updated);
    if (mounted) {
      setState(() => playlist = updated);
    }
  }

  Future<void> _shufflePlay() async {
    if (playlist.items.isEmpty) {
      return;
    }
    final shuffled = [...playlist.items]..shuffle(random);
    await widget.onPlay(shuffled.first);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(playlist.name),
      actions: [
        IconButton(
          tooltip: 'Shuffle play',
          onPressed: () => unawaited(_shufflePlay()),
          icon: const Icon(Icons.shuffle),
        ),
      ],
    ),
    body: playlist.items.isEmpty
        ? const Center(child: Text('Playlist is empty.'))
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            itemCount: playlist.items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = playlist.items[index];
              return Card(
                child: ListTile(
                  onTap: () => unawaited(widget.onPlay(item)),
                  leading: item.posterUrl == null || item.posterUrl!.isEmpty
                      ? const CircleAvatar(child: Icon(Icons.movie))
                      : CircleAvatar(
                          backgroundImage: NetworkImage(item.posterUrl!),
                        ),
                  title: Text(item.title),
                  subtitle: Text(
                    '${item.mediaType.toUpperCase()} · ${item.sourceName}${item.subtitle == null ? '' : '\n${item.subtitle}'}',
                  ),
                  isThreeLine: item.subtitle != null,
                  trailing: IconButton(
                    tooltip: 'Remove from playlist',
                    onPressed: () => unawaited(_removeItem(item)),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
              );
            },
          ),
  );
}
