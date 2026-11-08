// ignore_for_file: deprecated_member_use, use_build_context_synchronously, prefer_collection_literals, unnecessary_brace_in_string_interps, unnecessary_string_interpolations

// ignore_for_file: unused_element

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import '../services/playlist_hub.dart';
import '../widgets/mixed_playlist_picker.dart';
import '../services/device_connection.dart';
import '../services/firefox_browser.dart';
import '../services/home_preferences.dart';
import '../services/jellyfin_client.dart';
import '../services/live_tv_control.dart';
import '../services/live_tv_playlist.dart';
import '../services/playback_performance.dart';
import '../services/pip_playback.dart';
import '../services/playlist_playback.dart';
import '../services/sleep_mode.dart';
import '../services/live_tv_source.dart';
import '../services/media_catalog_cache.dart';
import '../services/adult_content.dart';
import '../services/app_log.dart';
import 'jellyfin_connect_screen.dart';
import 'diagnostics_screen.dart';
import 'media_home_view.dart';
import 'playlists_screen.dart';
import 'sleep_mode_panel.dart';
import '../services/subtitle_provider_service.dart';
import '../services/video_playback_memory.dart';
import '../theme/millitop_visual_theme.dart';
import '../widgets/redesign/media_library_shell.dart';
import '../widgets/redesign/media_player_chrome.dart';
import '../widgets/redesign/media_side_panels.dart';

enum _MediaTab { movies, series, adult }

enum _MediaSortMode { relevance, title, source, inTheaters, recentlyAdded }

const String _managedSourcePrefix = 'managed:';

/// A date-gated themed collection (e.g. Halloween, Thanksgiving, Christmas).
/// Matches items either by genre name or by a title/description keyword.
class _SeasonalCollection {
  final String id;
  final String label;
  final IconData icon;
  final int startMonth;
  final int startDay;
  final int endMonth;
  final int endDay;
  final Set<String> genres;
  final List<String> keywords;
  const _SeasonalCollection({
    required this.id,
    required this.label,
    required this.icon,
    required this.startMonth,
    required this.startDay,
    required this.endMonth,
    required this.endDay,
    this.genres = const {},
    this.keywords = const [],
  });

  bool isActiveOn(DateTime date) {
    final start = DateTime(date.year, startMonth, startDay);
    final end = DateTime(date.year, endMonth, endDay, 23, 59, 59);
    final probe = DateTime(date.year, date.month, date.day);
    return !probe.isBefore(start) && !probe.isAfter(end);
  }

  int daysUntilEnd(DateTime date) {
    final end = DateTime(date.year, endMonth, endDay);
    return end.difference(DateTime(date.year, date.month, date.day)).inDays;
  }

  bool matches(LiveTvMediaItem item) {
    if (genres.isNotEmpty &&
        item.genres.any(
          (genre) => genres.any((g) => g.toLowerCase() == genre.toLowerCase()),
        )) {
      return true;
    }
    if (keywords.isEmpty) {
      return false;
    }
    final haystack =
        '${item.title} ${item.description ?? ''} ${item.group ?? ''}'
            .toLowerCase();
    return keywords.any((keyword) => haystack.contains(keyword));
  }
}

const List<_SeasonalCollection> _seasonalCollections = [
  _SeasonalCollection(
    id: 'halloween',
    label: 'Halloween',
    icon: Icons.nightlight_round,
    startMonth: 10,
    startDay: 1,
    endMonth: 11,
    endDay: 15,
    genres: {'Horror'},
    keywords: ['halloween'],
  ),
  _SeasonalCollection(
    id: 'thanksgiving',
    label: 'Thanksgiving',
    icon: Icons.restaurant,
    startMonth: 11,
    startDay: 1,
    endMonth: 11,
    endDay: 30,
    keywords: ['thanksgiving'],
  ),
  _SeasonalCollection(
    id: 'christmas',
    label: 'Christmas',
    icon: Icons.ac_unit,
    startMonth: 11,
    startDay: 15,
    endMonth: 12,
    endDay: 31,
    keywords: ['christmas', 'xmas', 'holiday'],
  ),
  _SeasonalCollection(
    id: 'romance',
    label: 'Romance',
    icon: Icons.favorite,
    startMonth: 2,
    startDay: 1,
    endMonth: 2,
    endDay: 28,
    genres: {'Romance'},
    keywords: ['valentine'],
  ),
];

class _ManagedCatalogLibrary {
  final String id;
  final String name;
  final List<LiveTvMediaItem> movies;
  final List<LiveTvMediaItem> series;
  final Map<String, LiveTvSeriesDetails> seriesDetailsById;
  const _ManagedCatalogLibrary({
    required this.id,
    required this.name,
    required this.movies,
    required this.series,
    required this.seriesDetailsById,
  });
}

class _MediaItemSourceOrigin {
  final String sourceId;
  final String sourceName;
  final LiveTvSource? source;
  const _MediaItemSourceOrigin({
    required this.sourceId,
    required this.sourceName,
    this.source,
  });
}

class _LiveTvMediaPaint {
  static MillitopThemeSpec get _spec =>
      MillitopThemeController.instance.current;
  static ColorScheme get _scheme =>
      MillitopThemeController.instance.materialTheme.colorScheme;
  static Color get accent => _spec.accent;
  static Color get panel => _spec.surfaceVariant;
  static Color get onSurface => _scheme.onSurface;
  static Color get onSurface70 => onSurface.withAlpha(179);
  static Color get onSurface60 => onSurface.withAlpha(153);
  static Color get onSurface54 => onSurface.withAlpha(138);
  static Color get onSurface24 => onSurface.withAlpha(61);
  static Color get warning => _scheme.secondary;
  static Color get error => _scheme.error;
  static Color get overlayMuted => _scheme.surface.withAlpha(170);
  static Color get overlayStrong => _scheme.surface.withAlpha(204);
  static Color get overlayOpaque => _scheme.surface.withAlpha(208);
  static Color get transparent => onSurface.withAlpha(0);
}

class _CatalogLoadingModal extends StatefulWidget {
  final String phase;
  final String? sourceName;
  final int stepsCompleted;
  final int stepsTotal;
  final int moviesLoaded;
  final int seriesLoaded;

  const _CatalogLoadingModal({
    required this.phase,
    required this.sourceName,
    required this.stepsCompleted,
    required this.stepsTotal,
    required this.moviesLoaded,
    required this.seriesLoaded,
  });

  @override
  State<_CatalogLoadingModal> createState() => _CatalogLoadingModalState();
}

class _CatalogLoadingModalState extends State<_CatalogLoadingModal> {
  final elapsed = Stopwatch();
  Timer? ticker;

  @override
  void initState() {
    super.initState();
    elapsed.start();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    ticker?.cancel();
    elapsed.stop();
    super.dispose();
  }

  String _timeText(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final progress = widget.stepsTotal > 0
        ? widget.stepsCompleted / widget.stepsTotal
        : null;
    final remaining = progress != null && progress > 0
        ? Duration(
            milliseconds:
                (elapsed.elapsedMilliseconds * (1 - progress) / progress)
                    .round(),
          )
        : null;
    final theme = Theme.of(context);
    return Stack(
      key: const Key('catalog-loading-modal'),
      children: [
        ModalBarrier(
          dismissible: false,
          color: theme.colorScheme.scrim.withAlpha(166),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final large = constraints.maxWidth >= 1100;
            final bodySize = large ? 20.0 : 16.0;
            return Center(
              child: SingleChildScrollView(
                child: Dialog(
                  insetPadding: const EdgeInsets.all(16),
                  constraints: BoxConstraints(maxWidth: large ? 720 : 560),
                  child: Padding(
                    padding: EdgeInsets.all(large ? 32 : 20),
                    child: DefaultTextStyle(
                      style: theme.textTheme.bodyLarge!.copyWith(
                        fontSize: bodySize,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Loading Movies & Series',
                            style: theme.textTheme.headlineSmall!.copyWith(
                              fontSize: large ? 32 : 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Semantics(
                            liveRegion: true,
                            child: Text(widget.phase),
                          ),
                          if (widget.sourceName != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              widget.sourceName!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: 20),
                          LinearProgressIndicator(value: progress),
                          const SizedBox(height: 16),
                          Text(
                            widget.stepsTotal == 0
                                ? 'Discovering your libraries...'
                                : 'Sources loaded: ${widget.stepsCompleted ~/ 2} / ${widget.stepsTotal ~/ 2}',
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 24,
                            runSpacing: 8,
                            children: [
                              Text('Movies: ${widget.moviesLoaded}'),
                              Text('Series: ${widget.seriesLoaded}'),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text('Elapsed: ${_timeText(elapsed.elapsed)}'),
                          Text(
                            remaining == null
                                ? 'Estimated remaining: calculating...'
                                : 'Estimated remaining: ${_timeText(remaining)}',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class LiveTvMediaScreen extends StatefulWidget {
  final int profileId;
  final String? initialSourceId;
  final String? initialMediaType;
  final String? initialMediaId;
  final bool autoResume;
  final LiveTvLibraryItem? initialLibraryItem;
  final LiveTvPlaylistService? playlistService;
  final Future<List<LiveTvSource>> Function(int profileId)?
  loadConfiguredSources;
  final DateTime Function()? now;
  final MediaCatalogCache? catalogCache;
  final JellyfinAccountStore? jellyfinStore;
  final JellyfinTransport? jellyfinTransport;
  final PlaylistPlaybackSession? mixedSession;
  final String? mixedSessionEntryId;
  final PlaylistSegmentOpener? playlistSegmentOpener;
  const LiveTvMediaScreen({
    super.key,
    required this.profileId,
    this.initialSourceId,
    this.initialMediaType,
    this.initialMediaId,
    this.autoResume = false,
    this.initialLibraryItem,
    this.playlistService,
    this.loadConfiguredSources,
    this.now,
    this.catalogCache,
    this.jellyfinStore,
    this.jellyfinTransport,
    this.mixedSession,
    this.mixedSessionEntryId,
    this.playlistSegmentOpener,
  });

  @override
  State<LiveTvMediaScreen> createState() => _LiveTvMediaScreenState();
}

class _LiveTvMediaScreenState extends State<LiveTvMediaScreen> {
  late final LiveTvPlaylistService service;
  final liveTvControl = LiveTvControlService();
  final playbackMemory = VideoPlaybackMemory();
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final Map<LiveTvMediaItem, _MediaItemSourceOrigin> mediaItemOrigins = {};
  List<LiveTvSource> sources = [];
  final Map<String, _ManagedCatalogLibrary> managedCatalogBySourceId = {};
  late final MediaCatalogCache catalogCache =
      widget.catalogCache ?? MediaCatalogCache();
  bool managedCatalogLoaded = false;
  bool managedCatalogFromCache = false;
  String? managedCatalogVersion;
  bool checkingForCatalogUpdates = false;
  late final JellyfinAccountStore jellyfinStore =
      widget.jellyfinStore ?? JellyfinAccountStore.instance();
  JellyfinAccount? jellyfinAccount;
  JellyfinApi? jellyfinApi;
  bool jellyfinAccountLoaded = false;
  final Map<String, Future<List<JellyfinEntry>>> jellyfinLibraryFetches = {};
  final Map<String, JellyfinUserData> jellyfinUserData = {};
  List<JellyfinEntry> jellyfinResume = const [];
  List<JellyfinEntry> jellyfinNextUp = const [];
  List<JellyfinEntry> jellyfinLatest = const [];
  List<JellyfinEntry> jellyfinSimilar = const [];
  List<JellyfinEntry> jellyfinAdultResume = const [];
  List<JellyfinEntry> jellyfinAdultLatest = const [];
  String? jellyfinSimilarTo;
  String jellyfinHomeError = '';
  LiveTvSource? source;
  List<LiveTvMediaItem> movies = [];
  List<LiveTvMediaItem> series = [];

  /// Adult titles (IPTV "XXX -" / "For Adults", Jellyfin "Adult" library)
  /// never mix with [movies]/[series]; they only appear in their own tab
  /// and Home row when [showAdult] is on.
  List<LiveTvMediaItem> adultMovies = [];
  List<LiveTvMediaItem> adultSeries = [];
  Set<String> adultIds = {};
  bool showAdult = false;
  List<LiveTvRecentMedia> history = [];
  List<LiveTvLibraryItem> favorites = [];
  List<LiveTvUserPlaylist> playlists = [];
  _MediaTab tab = _MediaTab.movies;

  /// Home hub (rows) vs. the poster grid. Home is the default landing page.
  bool homeView = true;
  _MediaSortMode sortMode = _MediaSortMode.relevance;
  String groupFilter = 'All';
  Set<String> selectedGenres = {};
  String? activeCollectionId;
  bool versionAwareOnly = false;
  bool loading = true;
  bool resumedInitial = false;
  bool allSourcesSelected = false;
  int catalogLoadGeneration = 0;
  String status = '';
  String error = '';
  String catalogPhase = 'Syncing your profile and preparing sources...';
  String? catalogSourceName;
  int catalogStepsCompleted = 0;
  int catalogStepsTotal = 0;
  int catalogMoviesLoaded = 0;
  int catalogSeriesLoaded = 0;
  String? focusedMediaId;
  bool filtersOpen = false;
  double posterCardScale = 1.0;
  final ScrollController _catalogScrollController = ScrollController();
  String? _selectedAlphabetLetter;
  final Map<String, int> _alphabetFirstIndex = <String, int>{};
  int _alphabetCrossAxisCount = 1;
  double _alphabetTileStride = 1;
  Timer? profileSyncDebounce;
  PlaybackPerformanceSettings playbackPerformance =
      const PlaybackPerformanceSettings();

  bool get _isTextInputFocused {
    final focused = FocusManager.instance.primaryFocus;
    final context = focused?.context;
    if (context == null) {
      return false;
    }
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  void initState() {
    super.initState();
    service = widget.playlistService ?? const LiveTvPlaylistService();
    unawaited(_loadPosterCardScalePreference());
    _catalogScrollController.addListener(() {
      _updateAlphabetSelectionFromScroll(visibleItems);
    });
    search.addListener(() {
      setState(() {});
      _logSearchSoon();
    });
    unawaited(_initialize());
  }

  Timer? _searchLogDebounce;

  /// Records what people search for (after they stop typing) and whether it
  /// found anything, to improve search and catalog matching later.
  void _logSearchSoon() {
    _searchLogDebounce?.cancel();
    final text = search.text.trim();
    if (text.length < 2) {
      return;
    }
    _searchLogDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || search.text.trim() != text) {
        return;
      }
      AppLog.event(
        'media.search',
        props: {
          'query': text,
          'results': visibleItems.length,
          'tab': homeView ? 'home' : tab.name,
        },
      );
    });
  }

  @override
  void dispose() {
    _searchLogDebounce?.cancel();
    profileSyncDebounce?.cancel();
    _catalogScrollController.dispose();
    searchFocus.dispose();
    search.dispose();
    super.dispose();
  }

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  bool _isManagedSource(LiveTvSource item) =>
      item.id.startsWith(_managedSourcePrefix) || item.type == 'managed';

  Future<List<LiveTvSource>> _configuredSources() =>
      widget.loadConfiguredSources?.call(widget.profileId) ??
      HomePreferences().liveTvSources(widget.profileId);

  bool _isManagedSourceId(String value) =>
      value.startsWith(_managedSourcePrefix);

  String _managedSourceId(String libraryId) =>
      '$_managedSourcePrefix$libraryId';

  // ---- Jellyfin -----------------------------------------------------------

  Future<List<LiveTvSource>> _jellyfinSources({bool reload = false}) async {
    if (!jellyfinAccountLoaded || reload) {
      jellyfinAccount = await jellyfinStore.load(widget.profileId);
      jellyfinApi = jellyfinAccount == null
          ? null
          : JellyfinApi.forAccount(
              jellyfinAccount!,
              transport: widget.jellyfinTransport,
            );
      jellyfinAccountLoaded = true;
    }
    return jellyfinAccount?.sources ?? const [];
  }

  bool _isJellyfinSource(LiveTvSource item) => isJellyfinSourceId(item.id);

  void _rememberJellyfin(Iterable<JellyfinEntry> entries) {
    for (final entry in entries) {
      jellyfinUserData[entry.itemId] = entry.userData;
    }
  }

  /// Downloads one Jellyfin library. Movies and series come from the same
  /// request, so concurrent callers share it.
  Future<List<JellyfinEntry>> _jellyfinLibraryEntries(LiveTvSource source) {
    return jellyfinLibraryFetches.putIfAbsent(source.id, () async {
      final account = jellyfinAccount;
      final api = jellyfinApi;
      if (account == null || api == null) {
        return const <JellyfinEntry>[];
      }
      final libraryId = source.id.substring(jellyfinSourcePrefix.length);
      final library = account.libraries.firstWhere(
        (item) => item.id == libraryId,
        orElse: () => JellyfinLibrary(
          id: libraryId,
          name: source.name,
          collectionType: '',
        ),
      );
      try {
        final entries = await api.libraryItems(account.userId, library);
        _rememberJellyfin(entries);
        return entries;
      } catch (_) {
        jellyfinLibraryFetches.remove(source.id);
        rethrow;
      }
    });
  }

  Future<List<LiveTvMediaItem>> _loadMoviesFor(LiveTvSource source) async {
    if (_isJellyfinSource(source)) {
      final entries = await _jellyfinLibraryEntries(source);
      return [
        for (final entry in entries)
          if (!entry.isSeries) entry.media,
      ];
    }
    return service.loadMovies(source);
  }

  Future<List<LiveTvMediaItem>> _loadSeriesFor(LiveTvSource source) async {
    if (_isJellyfinSource(source)) {
      final entries = await _jellyfinLibraryEntries(source);
      return [
        for (final entry in entries)
          if (entry.isSeries) entry.media,
      ];
    }
    return service.loadSeries(source);
  }

  Future<LiveTvSeriesDetails?> _jellyfinSeriesDetails(
    LiveTvMediaItem item,
  ) async {
    final account = jellyfinAccount;
    final api = jellyfinApi;
    if (account == null || api == null) {
      return null;
    }
    final seriesId = item.seriesId ?? item.id.replaceFirst('jf:', '');
    final entries = await api.episodes(account.userId, seriesId);
    _rememberJellyfin(entries);
    return LiveTvSeriesDetails(
      seriesId: seriesId,
      title: item.title,
      description: item.description,
      posterUrl: item.posterUrl,
      backdropUrl: item.backdropUrl,
      episodes: [
        for (final entry in entries)
          LiveTvSeriesEpisode(
            id: entry.media.id,
            title: entry.media.title,
            streamUrl: entry.media.streamUrl,
            season: entry.season ?? 1,
            episode: entry.episode ?? 0,
            posterUrl: entry.media.backdropUrl ?? entry.media.posterUrl,
            description: entry.media.description,
          ),
      ],
    );
  }

  /// Builds the playback hook for a Jellyfin stream placeholder. Returns
  /// null for every other kind of source.
  JellyfinPlaybackReporter? _jellyfinReporter(String streamUrl) {
    final itemId = jellyfinItemIdFromUrl(streamUrl);
    final account = jellyfinAccount;
    final api = jellyfinApi;
    if (itemId == null || account == null || api == null) {
      return null;
    }
    final userData = jellyfinUserData[itemId];
    return JellyfinPlaybackReporter(
      api: api,
      itemId: itemId,
      resumeMs: userData == null || userData.played
          ? null
          : userData.positionMs,
      enabled: account.syncProgress,
    );
  }

  /// Home rows from Jellyfin: resume, next up, recently added, similar.
  Future<void> _loadJellyfinHome() async {
    final account = jellyfinAccount;
    final api = jellyfinApi;
    if (account == null || api == null) {
      if (mounted) {
        setState(() {
          jellyfinResume = const [];
          jellyfinNextUp = const [];
          jellyfinLatest = const [];
          jellyfinSimilar = const [];
          jellyfinAdultResume = const [];
          jellyfinAdultLatest = const [];
        });
      }
      return;
    }
    try {
      final watch = Stopwatch()..start();
      // Rows are requested per library so adult libraries can be skipped
      // entirely (hidden) or kept in their own row (shown).
      final libraries = account.selectedLibraries
          .where(
            (library) => showAdult || !AdultContent.isAdultLabel(library.name),
          )
          .toList();
      Future<List<JellyfinEntry>> safe(
        String row,
        Future<List<JellyfinEntry>> request,
      ) => request.catchError((Object e, StackTrace st) {
        AppLog.warn(
          LogCategory.jellyfin,
          'Jellyfin $row row failed',
          error: e,
          stackTrace: st,
        );
        return <JellyfinEntry>[];
      });
      final perLibrary = await Future.wait([
        for (final library in libraries)
          Future.wait([
            safe(
              'resume',
              api.resume(
                account.userId,
                parentId: library.id,
                group: library.name,
              ),
            ),
            safe(
              'next up',
              api.nextUp(
                account.userId,
                parentId: library.id,
                group: library.name,
              ),
            ),
            safe(
              'latest',
              api.latest(
                account.userId,
                parentId: library.id,
                limit: 12,
                group: library.name,
              ),
            ),
          ]),
      ]);
      final resume = <JellyfinEntry>[];
      final nextUp = <JellyfinEntry>[];
      final latest = <JellyfinEntry>[];
      final adultResume = <JellyfinEntry>[];
      final adultLatest = <JellyfinEntry>[];
      for (var i = 0; i < libraries.length; i++) {
        final adultLibrary = AdultContent.isAdultLabel(libraries[i].name);
        final lists = perLibrary[i];
        for (final entry in lists[0]) {
          (adultLibrary || _isAdultJellyfin(entry) ? adultResume : resume).add(
            entry,
          );
        }
        for (final entry in lists[1]) {
          if (!adultLibrary && !_isAdultJellyfin(entry)) {
            nextUp.add(entry);
          }
        }
        for (final entry in lists[2]) {
          (adultLibrary || _isAdultJellyfin(entry) ? adultLatest : latest).add(
            entry,
          );
        }
      }
      int byLastPlayed(JellyfinEntry a, JellyfinEntry b) =>
          (b.userData.lastPlayed ?? DateTime(1970)).compareTo(
            a.userData.lastPlayed ?? DateTime(1970),
          );
      int byAdded(JellyfinEntry a, JellyfinEntry b) =>
          (b.media.addedAt ?? DateTime(1970)).compareTo(
            a.media.addedAt ?? DateTime(1970),
          );
      resume.sort(byLastPlayed);
      nextUp.sort(byLastPlayed);
      adultResume.sort(byLastPlayed);
      latest.sort(byAdded);
      adultLatest.sort(byAdded);
      _rememberJellyfin([
        ...resume,
        ...nextUp,
        ...latest,
        ...adultResume,
        ...adultLatest,
      ]);
      var similar = const <JellyfinEntry>[];
      String? similarTo;
      final seed = resume.isNotEmpty ? resume.first : null;
      if (seed != null) {
        final seedId = seed.isEpisode
            ? (seed.seriesId ?? seed.itemId)
            : seed.itemId;
        similarTo = seed.isEpisode
            ? (seed.seriesName ?? seed.media.title)
            : seed.media.title;
        similar = (await safe(
          'similar',
          api.similar(account.userId, seedId),
        )).where((entry) => !_isAdultJellyfin(entry)).toList();
      }
      AppLog.info(
        LogCategory.jellyfin,
        'Jellyfin Home rows loaded',
        details: {
          'libraries': libraries.length,
          'resume': resume.length,
          'nextUp': nextUp.length,
          'latest': latest.length,
          'ms': watch.elapsedMilliseconds,
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        jellyfinResume = account.showContinueWatching ? resume : const [];
        jellyfinNextUp = nextUp.take(20).toList();
        jellyfinLatest = latest.take(24).toList();
        jellyfinSimilar = similar;
        jellyfinSimilarTo = similarTo;
        jellyfinAdultResume = showAdult && account.showContinueWatching
            ? adultResume
            : const [];
        jellyfinAdultLatest = showAdult
            ? adultLatest.take(24).toList()
            : const [];
        jellyfinHomeError = '';
      });
    } catch (e, st) {
      AppLog.error(
        LogCategory.jellyfin,
        'Jellyfin Home failed to load',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        setState(() => jellyfinHomeError = e.toString());
      }
    }
  }

  String _managedPathToStreamUrl(String value) {
    final path = value.trim();
    if (path.isEmpty) {
      return path;
    }
    if (path.startsWith(r'\\')) {
      return Uri.file(path, windows: true).toString();
    }
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme.toLowerCase() == 'smb' &&
          Platform.isWindows &&
          uri.host.trim().isNotEmpty) {
        final sharePath = uri.pathSegments
            .where((item) => item.trim().isNotEmpty)
            .map((item) => Uri.decodeComponent(item).trim())
            .join(r'\');
        if (sharePath.isNotEmpty) {
          final uncPath = r'\\' + uri.host + r'\' + sharePath;
          return Uri.file(uncPath, windows: true).toString();
        }
      }
      return uri.toString();
    }
    return Uri.file(path, windows: true).toString();
  }

  List<String> _playbackUrlCandidates(String rawUrl) {
    final candidates = <String>[];
    final input = rawUrl.trim();
    if (input.isEmpty) {
      return candidates;
    }
    void addCandidate(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || candidates.contains(normalized)) {
        return;
      }
      candidates.add(normalized);
    }

    addCandidate(input);
    final parsed = Uri.tryParse(input);
    if (parsed != null && parsed.scheme.toLowerCase() == 'file') {
      final localPath = parsed.toFilePath(windows: Platform.isWindows);
      addCandidate(localPath);
      if (Platform.isWindows) {
        addCandidate(Uri.file(localPath, windows: true).toString());
      }
    } else if (parsed != null &&
        parsed.scheme.toLowerCase() == 'smb' &&
        Platform.isWindows &&
        parsed.host.trim().isNotEmpty) {
      final sharePath = parsed.pathSegments
          .where((item) => item.trim().isNotEmpty)
          .map((item) => Uri.decodeComponent(item).trim())
          .join(r'\');
      if (sharePath.isNotEmpty) {
        final uncPath = r'\\' + parsed.host + r'\' + sharePath;
        addCandidate(uncPath);
        addCandidate(Uri.file(uncPath, windows: true).toString());
      }
    }

    return candidates;
  }

  String _seriesSlug(String value) {
    final normalized = value.toLowerCase().trim();
    if (normalized.isEmpty) {
      return 'series';
    }
    return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  }

  LiveTvSeriesDetails? _managedSeriesDetails({
    required String sourceId,
    required String seriesId,
  }) {
    return managedCatalogBySourceId[sourceId]?.seriesDetailsById[seriesId];
  }

  List<LiveTvSource> _managedSourceList() => managedCatalogBySourceId.values
      .map(
        (library) => LiveTvSource(
          id: library.id,
          name: '${library.name} (SMB)',
          type: 'managed',
        ),
      )
      .toList();

  /// Dashboard (SMB) libraries. Opens from the cached catalog when one exists;
  /// [_refreshManagedCatalog] checks the server for changes afterwards.
  Future<List<LiveTvSource>> _managedSources(
    int profileId, {
    bool preferCache = true,
  }) async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty ||
        !DeviceConnection.instance.isEnrolled ||
        DeviceConnection.instance.isSuspended) {
      managedCatalogBySourceId.clear();
      managedCatalogLoaded = false;
      return const [];
    }
    if (preferCache) {
      if (managedCatalogLoaded) {
        return _managedSourceList();
      }
      final entry = await catalogCache.managedCatalog(profileId, connection);
      if (entry != null) {
        _parseManagedCatalog(entry.response);
        managedCatalogVersion = entry.version;
        managedCatalogLoaded = true;
        managedCatalogFromCache = true;
        return _managedSourceList();
      }
    }
    await _refreshManagedCatalog(profileId);
    return _managedSourceList();
  }

  /// Asks the server for the dashboard catalog, sending the version we already
  /// have so an unchanged library costs almost nothing. Returns true when the
  /// catalog changed.
  Future<bool> _refreshManagedCatalog(int profileId) async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty) {
      return false;
    }
    try {
      final response = await liveTvControl.mediaLibraryCatalog(
        expectedConnection: connection,
        profileId: profileId,
        catalogVersion: managedCatalogLoaded ? managedCatalogVersion : null,
      );
      managedCatalogFromCache = false;
      if (response['unchanged'] == true && managedCatalogLoaded) {
        return false;
      }
      final version = response['catalogVersion']?.toString();
      _parseManagedCatalog(response);
      managedCatalogVersion = version;
      managedCatalogLoaded = true;
      unawaited(
        catalogCache.saveManagedCatalog(
          profileId,
          connection,
          response,
          version: version,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void _parseManagedCatalog(Map<String, dynamic> response) {
    final libraries = response['libraries'];
    if (libraries is! List) {
      managedCatalogBySourceId.clear();
      return;
    }
    final parsedCatalogs = <String, _ManagedCatalogLibrary>{};
    for (final entry in libraries) {
      if (entry is! Map) {
        continue;
      }
      final value = Map<String, dynamic>.from(entry);
      final libraryId = value['id']?.toString().trim() ?? '';
      final libraryName = value['name']?.toString().trim() ?? '';
      if (libraryId.isEmpty || libraryName.isEmpty) {
        continue;
      }
      final sourceId = _managedSourceId(libraryId);
      final movies = <LiveTvMediaItem>[];
      final series = <LiveTvMediaItem>[];
      final seriesDetailsById = <String, LiveTvSeriesDetails>{};
      final rawItems = value['items'];
      if (rawItems is List) {
        for (final rawItem in rawItems) {
          if (rawItem is! Map) {
            continue;
          }
          final item = Map<String, dynamic>.from(rawItem);
          final mediaKind = item['mediaKind']?.toString().trim().toLowerCase();
          if (mediaKind == 'series') {
            continue;
          }
          final itemId = item['id']?.toString().trim() ?? '';
          final title = item['title']?.toString().trim() ?? '';
          final path = item['path']?.toString().trim() ?? '';
          if (itemId.isEmpty || title.isEmpty || path.isEmpty) {
            continue;
          }
          movies.add(
            LiveTvMediaItem(
              id: '$sourceId:movie:$itemId',
              title: title,
              streamUrl: _managedPathToStreamUrl(path),
              posterUrl: item['posterUrl']?.toString(),
              description: item['overview']?.toString(),
              backdropUrl: item['backdropUrl']?.toString(),
              group: libraryName,
              series: false,
            ),
          );
        }
      }
      final rawSeries = value['series'];
      if (rawSeries is List) {
        for (final rawSeriesItem in rawSeries) {
          if (rawSeriesItem is! Map) {
            continue;
          }
          final seriesItem = Map<String, dynamic>.from(rawSeriesItem);
          final seriesTitle = seriesItem['title']?.toString().trim() ?? '';
          if (seriesTitle.isEmpty) {
            continue;
          }
          final seriesId = '$sourceId:series:${_seriesSlug(seriesTitle)}';
          final episodes = <LiveTvSeriesEpisode>[];
          final seasons = seriesItem['seasons'];
          if (seasons is List) {
            for (final rawSeason in seasons) {
              if (rawSeason is! Map) {
                continue;
              }
              final seasonMap = Map<String, dynamic>.from(rawSeason);
              final seasonNumber =
                  int.tryParse(seasonMap['season']?.toString() ?? '') ?? 0;
              final episodesRaw = seasonMap['episodes'];
              if (episodesRaw is! List) {
                continue;
              }
              for (final rawEpisode in episodesRaw) {
                if (rawEpisode is! Map) {
                  continue;
                }
                final episodeMap = Map<String, dynamic>.from(rawEpisode);
                final episodeId = episodeMap['id']?.toString().trim() ?? '';
                final episodeTitle =
                    episodeMap['title']?.toString().trim() ?? '';
                final path = episodeMap['path']?.toString().trim() ?? '';
                if (episodeId.isEmpty || episodeTitle.isEmpty || path.isEmpty) {
                  continue;
                }
                episodes.add(
                  LiveTvSeriesEpisode(
                    id: '$seriesId:$episodeId',
                    title: episodeTitle,
                    streamUrl: _managedPathToStreamUrl(path),
                    season: seasonNumber,
                    episode:
                        int.tryParse(episodeMap['episode']?.toString() ?? '') ??
                        0,
                    posterUrl: episodeMap['posterUrl']?.toString(),
                    description: episodeMap['overview']?.toString(),
                  ),
                );
              }
            }
          }
          if (episodes.isEmpty) {
            continue;
          }
          episodes.sort((a, b) {
            final bySeason = a.season.compareTo(b.season);
            if (bySeason != 0) {
              return bySeason;
            }
            final byEpisode = a.episode.compareTo(b.episode);
            if (byEpisode != 0) {
              return byEpisode;
            }
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
          final details = LiveTvSeriesDetails(
            seriesId: seriesId,
            title: seriesTitle,
            description: null,
            posterUrl: episodes.first.posterUrl,
            backdropUrl: null,
            episodes: episodes,
          );
          seriesDetailsById[seriesId] = details;
          series.add(
            LiveTvMediaItem(
              id: seriesId,
              title: seriesTitle,
              streamUrl: episodes.first.streamUrl,
              posterUrl: details.posterUrl,
              description: details.description,
              backdropUrl: details.backdropUrl,
              group: libraryName,
              series: true,
              seriesId: seriesId,
            ),
          );
        }
      }
      parsedCatalogs[sourceId] = _ManagedCatalogLibrary(
        id: sourceId,
        name: libraryName,
        movies: movies,
        series: series,
        seriesDetailsById: seriesDetailsById,
      );
    }
    managedCatalogBySourceId
      ..clear()
      ..addAll(parsedCatalogs);
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
    } catch (error, stack) {
      AppLog.warn(
        LogCategory.sync,
        'Profile sync pull failed; using local copy',
        error: error,
        stackTrace: stack,
      );
    }
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
      } catch (error, stack) {
        AppLog.warn(
          LogCategory.sync,
          'Profile sync push failed',
          error: error,
          stackTrace: stack,
        );
      }
    });
  }

  Future<void> _initialize() async {
    try {
      // Profile sync (history, favorites, playlists, TMDB key) runs alongside
      // the catalog instead of blocking it.
      final profileSync = _pullRemoteProfileSnapshot().then((_) async {
        final nextHistory = await HomePreferences().liveTvRecentMedia(
          widget.profileId,
        );
        final nextFavorites = await HomePreferences().liveTvFavorites(
          widget.profileId,
        );
        final nextPlaylists = await HomePreferences().liveTvPlaylists(
          widget.profileId,
        );
        if (mounted) {
          setState(() {
            history = nextHistory;
            favorites = nextFavorites;
            playlists = nextPlaylists;
          });
        }
      });
      playbackPerformance = await HomePreferences().playbackPerformance(
        widget.profileId,
      );
      showAdult = await HomePreferences().showAdultContent(widget.profileId);
      AppLog.event(
        'screen.view',
        props: {'screen': 'movies_series', 'adultVisible': showAdult},
      );
      final configuredSources = await _configuredSources();
      final managedSources = await _managedSources(widget.profileId);
      final jellyfinSources = await _jellyfinSources();
      sources = [...configuredSources, ...managedSources, ...jellyfinSources];
      unawaited(_loadJellyfinHome());
      history = await HomePreferences().liveTvRecentMedia(widget.profileId);
      favorites = await HomePreferences().liveTvFavorites(widget.profileId);
      playlists = await HomePreferences().liveTvPlaylists(widget.profileId);
      if (!mounted) {
        return;
      }
      if (sources.isEmpty) {
        // With no cached dashboard catalog, wait for the profile sync before
        // concluding that nothing is configured.
        await profileSync;
        if (!mounted) {
          return;
        }
        setState(() {
          loading = false;
          error =
              'Add a source in Live TV > Manage Sources or enable SMB libraries in the dashboard.';
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
        homeView = false;
      } else if (widget.initialMediaType == 'movie') {
        tab = _MediaTab.movies;
        homeView = false;
      }
      await _loadCatalog();
    } catch (e, st) {
      AppLog.error(
        LogCategory.catalog,
        'Movies & Series failed to start',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  void _applyCatalog(
    List<LiveTvSource> activeSources,
    List<List<LiveTvMediaItem>> moviesBySource,
    List<List<LiveTvMediaItem>> seriesBySource,
  ) {
    final mergedMovies = <LiveTvMediaItem>[];
    final mergedSeries = <LiveTvMediaItem>[];
    final nextAdultMovies = <LiveTvMediaItem>[];
    final nextAdultSeries = <LiveTvMediaItem>[];
    mediaItemOrigins.clear();
    for (var i = 0; i < activeSources.length; i++) {
      final sourceItem = activeSources[i];
      final origin = _MediaItemSourceOrigin(
        sourceId: sourceItem.id,
        sourceName: sourceItem.name,
        source: _isManagedSource(sourceItem) ? null : sourceItem,
      );
      final adultSource = _isAdultSource(sourceItem);
      for (final item in moviesBySource[i]) {
        mediaItemOrigins[item] = origin;
        if (adultSource || AdultContent.isAdult(item)) {
          nextAdultMovies.add(item);
        } else {
          mergedMovies.add(item);
        }
      }
      for (final item in seriesBySource[i]) {
        mediaItemOrigins[item] = origin;
        if (adultSource || AdultContent.isAdult(item)) {
          nextAdultSeries.add(item);
        } else {
          mergedSeries.add(item);
        }
      }
    }
    movies = mergedMovies;
    series = mergedSeries;
    adultIds = {
      ...adultIds,
      for (final item in nextAdultMovies) item.id,
      for (final item in nextAdultSeries) item.id,
    };
    // Hidden adult titles are dropped from memory entirely.
    adultMovies = showAdult ? nextAdultMovies : const [];
    adultSeries = showAdult ? nextAdultSeries : const [];
    if (!showAdult && tab == _MediaTab.adult) {
      tab = _MediaTab.movies;
    }
  }

  bool _isAdultSource(LiveTvSource item) =>
      AdultContent.isAdultLabel(item.name);

  /// Sources the user can see: adult-only sources/libraries are hidden
  /// unless adult content is turned on.
  List<LiveTvSource> get _visibleSources => showAdult
      ? sources
      : sources.where((item) => !_isAdultSource(item)).toList();

  /// True for any history/favorite/Jellyfin row that belongs in the Adult
  /// section rather than the regular rows.
  bool _isAdultRef({String? id, String title = '', String? sourceName}) =>
      (id != null && adultIds.contains(id)) ||
      AdultContent.isAdultEntry(title: title, sourceName: sourceName);

  bool _isAdultJellyfin(JellyfinEntry entry) =>
      adultIds.contains(entry.media.id) ||
      adultIds.contains(entry.itemId) ||
      AdultContent.isAdult(entry.media);

  List<LiveTvMediaItem>? _adultCombined;
  List<LiveTvMediaItem>? _adultCombinedMovies;
  List<LiveTvMediaItem>? _adultCombinedSeries;

  List<LiveTvMediaItem> get adultItems {
    if (_adultCombined == null ||
        !identical(_adultCombinedMovies, adultMovies) ||
        !identical(_adultCombinedSeries, adultSeries)) {
      _adultCombinedMovies = adultMovies;
      _adultCombinedSeries = adultSeries;
      _adultCombined = [...adultMovies, ...adultSeries];
    }
    return _adultCombined!;
  }

  /// Items for the current grid tab.
  List<LiveTvMediaItem> get _tabItems => switch (tab) {
    _MediaTab.movies => movies,
    _MediaTab.series => series,
    _MediaTab.adult => showAdult ? adultItems : const [],
  };

  Future<void> _setShowAdult(bool value) async {
    if (value == showAdult) {
      return;
    }
    await HomePreferences().setShowAdultContent(widget.profileId, value);
    AppLog.audit(
      'Adult content ${value ? 'shown' : 'hidden'}',
      details: {'profileId': widget.profileId},
    );
    if (!mounted) {
      return;
    }
    setState(() {
      showAdult = value;
      if (!value) {
        adultMovies = const [];
        adultSeries = const [];
        if (tab == _MediaTab.adult) {
          tab = _MediaTab.movies;
        }
        if (source != null && _isAdultSource(source!)) {
          allSourcesSelected = true;
        }
      }
    });
    unawaited(_scheduleProfileSync());
    await _loadCatalog();
    unawaited(_loadJellyfinHome());
  }

  /// Opens the catalog from the local cache when possible, so the screen is
  /// usable immediately. Only sources that have never been loaded (or a
  /// manual reload via [forceRefresh]) block on the network; everything else
  /// is checked for changes in the background by [_checkCatalogForChanges].
  Future<void> _loadCatalog({bool forceRefresh = false}) async {
    if (!mounted) {
      return;
    }
    final generation = ++catalogLoadGeneration;
    setState(() {
      error = '';
      checkingForCatalogUpdates = false;
      catalogPhase = 'Checking configured and dashboard sources...';
      catalogSourceName = null;
      catalogStepsCompleted = 0;
      catalogStepsTotal = 0;
      catalogMoviesLoaded = 0;
      catalogSeriesLoaded = 0;
      if (forceRefresh) {
        loading = true;
      }
    });
    try {
      final configuredSources = await _configuredSources();
      final managedSources = await _managedSources(
        widget.profileId,
        preferCache: !forceRefresh,
      );
      if (!mounted || generation != catalogLoadGeneration) {
        return;
      }
      final jellyfinSources = await _jellyfinSources();
      if (forceRefresh) {
        jellyfinLibraryFetches.clear();
        unawaited(_loadJellyfinHome());
      }
      if (!mounted || generation != catalogLoadGeneration) {
        return;
      }
      final previousSourceId = source?.id;
      sources = [...configuredSources, ...managedSources, ...jellyfinSources];
      unawaited(
        catalogCache.retainSources(
          widget.profileId,
          sources.map((item) => item.id),
        ),
      );
      if (sources.isEmpty) {
        if (mounted) {
          setState(() {
            loading = false;
            movies = const [];
            series = const [];
            error =
                'No VOD sources are available. Add Live TV sources or enable SMB libraries in the dashboard.';
          });
        }
        return;
      }
      final selected = previousSourceId == null
          ? (source ?? sources.first)
          : sources.firstWhere(
              (item) => item.id == previousSourceId,
              orElse: () => sources.first,
            );
      source = selected;
      final visible = _visibleSources;
      final activeSources = allSourcesSelected || !visible.contains(selected)
          ? List<LiveTvSource>.from(visible)
          : <LiveTvSource>[selected];
      final cachedEntries = await Future.wait([
        for (final activeSource in activeSources)
          catalogCache.source(widget.profileId, activeSource),
      ]);
      final cached = <String, MediaCatalogCacheEntry?>{
        for (var i = 0; i < activeSources.length; i++)
          activeSources[i].id: cachedEntries[i],
      };
      final needsFetch = activeSources
          .where(
            (item) =>
                !_isManagedSource(item) &&
                (forceRefresh || cached[item.id] == null),
          )
          .toList();
      setState(() {
        if (needsFetch.isNotEmpty) {
          loading = true;
        }
        catalogStepsTotal = needsFetch.length * 2;
        catalogPhase = needsFetch.length > 1
            ? 'Loading ${needsFetch.length} sources in parallel...'
            : 'Loading movies and series...';
        status = allSourcesSelected
            ? 'Loading movies and series from ${activeSources.length} source(s)...'
            : 'Loading movies and series from ${selected.name}...';
      });
      final loadWatch = Stopwatch()..start();
      final moviesBySource = List<List<LiveTvMediaItem>>.filled(
        activeSources.length,
        const [],
      );
      final seriesBySource = List<List<LiveTvMediaItem>>.filled(
        activeSources.length,
        const [],
      );
      // Index -> ids that already went through metadata enrichment. A null
      // value means "enrich everything" (first load of that source).
      final enrichQueue = <int, Set<String>?>{};
      final unsaved = <int>{};
      final failures = <String>[];
      Object? firstFailure;
      StackTrace? firstFailureStack;
      Future<void> loadOne(int i) async {
        final activeSource = activeSources[i];
        final entry = cached[activeSource.id];
        if (_isManagedSource(activeSource)) {
          final managed = managedCatalogBySourceId[activeSource.id];
          moviesBySource[i] = MediaCatalogCache.mergeKeepingMetadata(
            managed?.movies ?? const [],
            entry?.movies ?? const [],
          );
          seriesBySource[i] = MediaCatalogCache.mergeKeepingMetadata(
            managed?.series ?? const [],
            entry?.series ?? const [],
          );
          enrichQueue[i] = entry == null ? null : _idsOf(entry);
          return;
        }
        if (entry != null && !forceRefresh) {
          moviesBySource[i] = entry.movies;
          seriesBySource[i] = entry.series;
          return;
        }
        final watch = Stopwatch()..start();
        void progress(int movieCount, int seriesCount) {
          if (!mounted || generation != catalogLoadGeneration) {
            return;
          }
          setState(() {
            catalogSourceName = activeSource.name;
            catalogMoviesLoaded += movieCount;
            catalogSeriesLoaded += seriesCount;
            catalogStepsCompleted++;
          });
        }

        // Movies and series are requested together; the playlist service
        // shares one download when both come from the same M3U.
        final results =
            await Future.wait([
              _loadMoviesFor(activeSource).then((value) {
                progress(value.length, 0);
                return value;
              }),
              _loadSeriesFor(activeSource).then((value) {
                progress(0, value.length);
                return value;
              }),
            ]).catchError((Object e, StackTrace st) {
              AppLog.error(
                LogCategory.catalog,
                'Failed to load source "${activeSource.name}"',
                error: e,
                stackTrace: st,
                details: {
                  'sourceId': activeSource.id,
                  'type': activeSource.type,
                },
              );
              failures.add(activeSource.name);
              firstFailure ??= e;
              firstFailureStack ??= st;
              // Fall back to whatever was cached so one bad source does not
              // block the rest of the catalog.
              return <List<LiveTvMediaItem>>[
                entry?.movies ?? const [],
                entry?.series ?? const [],
              ];
            });
        AppLog.info(
          LogCategory.catalog,
          'Loaded source "${activeSource.name}"',
          details: {
            'sourceId': activeSource.id,
            'movies': results[0].length,
            'series': results[1].length,
            'ms': watch.elapsedMilliseconds,
          },
        );
        moviesBySource[i] = MediaCatalogCache.mergeKeepingMetadata(
          results[0],
          entry?.movies ?? const [],
        );
        seriesBySource[i] = MediaCatalogCache.mergeKeepingMetadata(
          results[1],
          entry?.series ?? const [],
        );
        enrichQueue[i] = entry == null ? null : _idsOf(entry);
        if (!failures.contains(activeSource.name)) {
          unsaved.add(i);
        }
      }

      await Future.wait([
        for (var i = 0; i < activeSources.length; i++) loadOne(i),
      ]);
      if (needsFetch.isNotEmpty) {
        AppLog.info(
          LogCategory.catalog,
          'Catalog network load finished',
          details: {
            'sources': needsFetch.length,
            'failed': failures.length,
            'ms': loadWatch.elapsedMilliseconds,
          },
        );
      }
      if (!mounted || generation != catalogLoadGeneration) {
        return;
      }
      // Nothing loaded and nothing cached: show the error instead of an
      // empty library.
      if (firstFailure != null &&
          moviesBySource.every((list) => list.isEmpty) &&
          seriesBySource.every((list) => list.isEmpty)) {
        Error.throwWithStackTrace(firstFailure!, firstFailureStack!);
      }
      setState(() {
        _applyCatalog(activeSources, moviesBySource, seriesBySource);
        loading = false;
        status = failures.isEmpty
            ? 'Loaded ${movies.length} movies and ${series.length} series'
            : 'Loaded ${movies.length} movies and ${series.length} series. '
                  'Could not refresh: ${failures.join(', ')} (see Diagnostics).';
      });
      // Save freshly downloaded lists right away so the next visit is instant
      // even if metadata enrichment is interrupted.
      for (final i in unsaved) {
        unawaited(
          catalogCache.saveSource(
            widget.profileId,
            activeSources[i],
            movies: moviesBySource[i],
            series: seriesBySource[i],
          ),
        );
      }
      unawaited(
        _checkCatalogForChanges(
          generation: generation,
          activeSources: activeSources,
          moviesBySource: moviesBySource,
          seriesBySource: seriesBySource,
          cached: cached,
          enrichQueue: enrichQueue,
          refreshedSourceIds: {for (final i in unsaved) activeSources[i].id},
        ),
      );
      await _tryAutoResume();
    } catch (e, st) {
      AppLog.error(
        LogCategory.catalog,
        'Movies & Series catalog failed to load',
        error: e,
        stackTrace: st,
      );
      if (mounted && generation == catalogLoadGeneration) {
        setState(() {
          loading = false;
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  static Set<String> _idsOf(MediaCatalogCacheEntry entry) => {
    for (final item in entry.movies) item.id,
    for (final item in entry.series) item.id,
  };

  /// Background pass after the catalog is on screen:
  /// 1. asks the dashboard whether its SMB catalog changed (version check),
  /// 2. re-downloads provider lists whose cache is older than
  ///    [MediaCatalogCache.freshFor],
  /// 3. looks up TMDB metadata only for titles that are new,
  /// and updates the grid in place only if something actually changed.
  Future<void> _checkCatalogForChanges({
    required int generation,
    required List<LiveTvSource> activeSources,
    required List<List<LiveTvMediaItem>> moviesBySource,
    required List<List<LiveTvMediaItem>> seriesBySource,
    required Map<String, MediaCatalogCacheEntry?> cached,
    required Map<int, Set<String>?> enrichQueue,
    required Set<String> refreshedSourceIds,
  }) async {
    bool stale() => !mounted || generation != catalogLoadGeneration;
    final movieLists = [...moviesBySource];
    final seriesLists = [...seriesBySource];
    final changed = <int>{};
    final before = MediaCatalogCache.signature(movies, series);
    if (stale()) {
      return;
    }
    setState(() => checkingForCatalogUpdates = true);
    try {
      final hasManaged = activeSources.any(_isManagedSource);
      if (hasManaged && managedCatalogFromCache) {
        final managedChanged = await _refreshManagedCatalog(widget.profileId);
        if (stale()) {
          return;
        }
        if (managedChanged) {
          for (var i = 0; i < activeSources.length; i++) {
            if (!_isManagedSource(activeSources[i])) {
              continue;
            }
            final managed = managedCatalogBySourceId[activeSources[i].id];
            final known = {
              for (final item in movieLists[i]) item.id,
              for (final item in seriesLists[i]) item.id,
            };
            movieLists[i] = MediaCatalogCache.mergeKeepingMetadata(
              managed?.movies ?? const [],
              movieLists[i],
            );
            seriesLists[i] = MediaCatalogCache.mergeKeepingMetadata(
              managed?.series ?? const [],
              seriesLists[i],
            );
            enrichQueue[i] = known;
            changed.add(i);
          }
        }
      }
      final now = _now();
      for (var i = 0; i < activeSources.length; i++) {
        final activeSource = activeSources[i];
        final entry = cached[activeSource.id];
        if (_isManagedSource(activeSource) ||
            refreshedSourceIds.contains(activeSource.id) ||
            entry == null ||
            entry.age(now) < MediaCatalogCache.freshFor) {
          continue;
        }
        try {
          jellyfinLibraryFetches.remove(activeSource.id);
          final freshMovies = await _loadMoviesFor(activeSource);
          final freshSeries = await _loadSeriesFor(activeSource);
          if (stale()) {
            return;
          }
          movieLists[i] = MediaCatalogCache.mergeKeepingMetadata(
            freshMovies,
            entry.movies,
          );
          seriesLists[i] = MediaCatalogCache.mergeKeepingMetadata(
            freshSeries,
            entry.series,
          );
          enrichQueue[i] = _idsOf(entry);
          changed.add(i);
        } catch (_) {
          // Offline or provider hiccup: keep showing the cached list.
        }
      }
      final tmdbApiKey = await HomePreferences().tmdbApiKey(widget.profileId);
      if (tmdbApiKey.trim().isNotEmpty) {
        for (final i in enrichQueue.keys) {
          final sourceItem = activeSources[i];
          if (!(sourceItem.isM3u || _isManagedSource(sourceItem))) {
            continue;
          }
          final known = enrichQueue[i];
          final maxItems = _isManagedSource(sourceItem) ? 1400 : 320;
          final enrichedMovies = await _enrichNewItems(
            movieLists[i],
            known,
            series: false,
            tmdbApiKey: tmdbApiKey,
            maxItems: maxItems,
          );
          final enrichedSeries = await _enrichNewItems(
            seriesLists[i],
            known,
            series: true,
            tmdbApiKey: tmdbApiKey,
            maxItems: maxItems,
          );
          if (stale()) {
            return;
          }
          if (!identical(enrichedMovies, movieLists[i]) ||
              !identical(enrichedSeries, seriesLists[i])) {
            movieLists[i] = enrichedMovies;
            seriesLists[i] = enrichedSeries;
            changed.add(i);
          }
          // Managed sources were never saved in the foreground pass.
          if (_isManagedSource(sourceItem) && known == null) {
            changed.add(i);
          }
        }
      } else {
        for (final i in enrichQueue.keys) {
          if (_isManagedSource(activeSources[i]) && enrichQueue[i] == null) {
            changed.add(i);
          }
        }
      }
      if (stale()) {
        return;
      }
      for (final i in changed) {
        await catalogCache.saveSource(
          widget.profileId,
          activeSources[i],
          movies: movieLists[i],
          series: seriesLists[i],
        );
      }
      if (changed.isEmpty || stale()) {
        return;
      }
      final previousCount = movies.length + series.length;
      setState(() {
        _applyCatalog(activeSources, movieLists, seriesLists);
        final added = movies.length + series.length - previousCount;
        if (MediaCatalogCache.signature(movies, series) != before) {
          status = added > 0
              ? 'Updated: $added new title${added == 1 ? '' : 's'}. ${movies.length} movies and ${series.length} series'
              : 'Loaded ${movies.length} movies and ${series.length} series';
        }
      });
    } finally {
      if (mounted && generation == catalogLoadGeneration) {
        setState(() => checkingForCatalogUpdates = false);
      }
    }
  }

  Future<List<LiveTvMediaItem>> _enrichNewItems(
    List<LiveTvMediaItem> items,
    Set<String>? known, {
    required bool series,
    required String tmdbApiKey,
    required int maxItems,
  }) async {
    if (known == null) {
      final result = await service.enrichM3uMetadata(
        items: items,
        series: series,
        tmdbApiKey: tmdbApiKey,
        maxItems: maxItems,
      );
      return result;
    }
    final newIndexes = [
      for (var i = 0; i < items.length; i++)
        if (!known.contains(items[i].id)) i,
    ];
    if (newIndexes.isEmpty) {
      return items;
    }
    final enriched = await service.enrichM3uMetadata(
      items: [for (final i in newIndexes) items[i]],
      series: series,
      tmdbApiKey: tmdbApiKey,
      maxItems: maxItems,
    );
    final updated = [...items];
    for (var j = 0; j < newIndexes.length; j++) {
      updated[newIndexes[j]] = enriched[j];
    }
    return updated;
  }

  Future<void> _tryAutoResume() async {
    final saved = widget.initialLibraryItem;
    if (saved != null && !resumedInitial) {
      resumedInitial = true;
      if (!sources.any((s) => s.id == saved.sourceId)) {
        throw StateError(
          'The source for "${saved.title}" is unavailable. Reconnect it in TV settings.',
        );
      }
      if (saved.mediaType == 'episode') {
        if (saved.streamUrl?.trim().isNotEmpty != true) {
          throw StateError(
            'This saved episode has no playback address. Open its series and save it again.',
          );
        }
        await _playLibraryItem(saved);
        return;
      }
      final catalog = saved.mediaType == 'series' ? series : movies;
      final matches = catalog.where((v) => v.id == saved.mediaId);
      if (matches.isEmpty) {
        throw StateError(
          '"${saved.title}" is no longer available from ${saved.sourceName}.',
        );
      }
      if (saved.mediaType == 'series') {
        await _openSeries(matches.first);
      } else {
        await _openMovie(matches.first);
      }
      return;
    }
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
      final match = [
        ...series,
        ...adultSeries,
      ].where((item) => item.id == targetId).toList();
      if (match.isNotEmpty) {
        await _openSeries(match.first);
      }
      return;
    }
    final match = [
      ...movies,
      ...adultMovies,
    ].where((item) => item.id == targetId).toList();
    if (match.isNotEmpty) {
      await _openMovie(match.first);
    }
  }

  List<String>? _groupsCache;
  List<LiveTvMediaItem>? _groupsFor;

  List<String> get groups {
    final input = _tabItems;
    if (_groupsCache != null && identical(_groupsFor, input)) {
      return _groupsCache!;
    }
    final values =
        input
            .map((item) => item.group?.trim() ?? '')
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _groupsFor = input;
    return _groupsCache = ['All', ...values];
  }

  /// Distinct genres available for the current media tab, derived from
  /// whatever TMDB metadata has been enriched so far.
  List<String>? _genresCache;
  List<LiveTvMediaItem>? _genresFor;

  List<String> get availableGenres {
    final input = _tabItems;
    if (_genresCache != null && identical(_genresFor, input)) {
      return _genresCache!;
    }
    final values =
        input
            .expand((item) => item.genres)
            .map((genre) => genre.trim())
            .where((genre) => genre.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _genresFor = input;
    return _genresCache = values;
  }

  /// Seasonal/themed collections that are currently in their active date
  /// window, soonest-ending first, so the most time-sensitive one is
  /// suggested first.
  List<_SeasonalCollection> get activeSeasonalCollections {
    final now = _now();
    final active =
        _seasonalCollections
            .where((collection) => collection.isActiveOn(now))
            .toList()
          ..sort((a, b) => a.daysUntilEnd(now).compareTo(b.daysUntilEnd(now)));
    return active;
  }

  final Map<List<LiveTvMediaItem>, Map<String, int>> _versionCountCache =
      Map.identity();

  /// Title -> number of copies, computed once per list (was O(n) per card).
  Map<String, int> _versionCountsOf(List<LiveTvMediaItem> input) {
    final cached = _versionCountCache[input];
    if (cached != null) {
      return cached;
    }
    if (_versionCountCache.length > 6) {
      _versionCountCache.clear();
    }
    final buckets = <String, int>{};
    for (final item in input) {
      final key = _versionTitleKey(item);
      buckets.update(key, (value) => value + 1, ifAbsent: () => 1);
    }
    return _versionCountCache[input] = buckets;
  }

  Map<String, int> get _versionCounts => _versionCountsOf(_tabItems);

  List<LiveTvMediaItem>? _visibleCache;
  List<Object?>? _visibleKey;

  List<LiveTvMediaItem> get visibleItems {
    final input = _tabItems;
    final key = <Object?>[
      input,
      search.text.trim().toLowerCase(),
      groupFilter,
      selectedGenres,
      activeCollectionId,
      versionAwareOnly,
      sortMode,
      mediaItemOrigins.length,
    ];
    final previous = _visibleKey;
    if (_visibleCache != null &&
        previous != null &&
        identical(previous[0], key[0]) &&
        identical(previous[3], key[3]) &&
        _listEquals(previous.skip(1), key.skip(1), skip: {2})) {
      return _visibleCache!;
    }
    final result = _computeVisibleItems(input);
    _visibleKey = key;
    return _visibleCache = result;
  }

  static bool _listEquals(
    Iterable<Object?> a,
    Iterable<Object?> b, {
    Set<int> skip = const {},
  }) {
    final left = a.toList();
    final right = b.toList();
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (skip.contains(i)) {
        continue;
      }
      if (left[i] != right[i]) {
        return false;
      }
    }
    return true;
  }

  List<LiveTvMediaItem> _computeVisibleItems(List<LiveTvMediaItem> input) {
    final query = search.text.trim().toLowerCase();
    final currentGroups = groups;
    final effectiveGroupFilter = currentGroups.contains(groupFilter)
        ? groupFilter
        : 'All';
    final versionCounts = versionAwareOnly ? _versionCounts : null;
    final collection = activeCollectionId == null
        ? null
        : _seasonalCollections
              .where((item) => item.id == activeCollectionId)
              .firstOrNull;
    final filtered = input.where((item) {
      if (effectiveGroupFilter != 'All' &&
          (item.group ?? '') != effectiveGroupFilter) {
        return false;
      }
      if (versionCounts != null &&
          (versionCounts[_versionTitleKey(item)] ?? 0) < 2) {
        return false;
      }
      if (selectedGenres.isNotEmpty &&
          !item.genres.any(
            (genre) => selectedGenres.any(
              (selected) => selected.toLowerCase() == genre.toLowerCase(),
            ),
          )) {
        return false;
      }
      if (collection != null && !collection.matches(item)) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      return item.title.toLowerCase().contains(query) ||
          (item.group ?? '').toLowerCase().contains(query);
    }).toList();
    if (sortMode == _MediaSortMode.title) {
      filtered.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    } else if (sortMode == _MediaSortMode.source) {
      filtered.sort((a, b) {
        final sourceA = (mediaItemOrigins[a]?.sourceName ?? source?.name ?? '')
            .toLowerCase();
        final sourceB = (mediaItemOrigins[b]?.sourceName ?? source?.name ?? '')
            .toLowerCase();
        final bySource = sourceA.compareTo(sourceB);
        if (bySource != 0) {
          return bySource;
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    } else if (sortMode == _MediaSortMode.inTheaters) {
      final now = _now();
      filtered.sort((a, b) {
        final daysA = a.releaseDate == null
            ? 999999
            : now.difference(a.releaseDate!).inDays.abs();
        final daysB = b.releaseDate == null
            ? 999999
            : now.difference(b.releaseDate!).inDays.abs();
        final byRecency = daysA.compareTo(daysB);
        if (byRecency != 0) {
          return byRecency;
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    } else if (sortMode == _MediaSortMode.recentlyAdded) {
      filtered.sort((a, b) {
        if (a.addedAt != null && b.addedAt != null) {
          return b.addedAt!.compareTo(a.addedAt!);
        }
        if (a.addedAt != null) {
          return -1;
        }
        if (b.addedAt != null) {
          return 1;
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    }
    return filtered;
  }

  Future<void> _shuffleWithinFilters() async {
    final candidates = visibleItems;
    if (candidates.isEmpty) {
      return;
    }
    final movieCandidates = candidates
        .where((item) => !item.series)
        .where((item) => _libraryItemFromMedia(item) != null)
        .toList();
    if (movieCandidates.isNotEmpty) {
      final collectionLabel = activeCollectionId == null
          ? null
          : _seasonalCollections
                .where((item) => item.id == activeCollectionId)
                .firstOrNull
                ?.label;
      final scopeLabel =
          collectionLabel ??
          (selectedGenres.length == 1
              ? selectedGenres.first
              : selectedGenres.isNotEmpty
              ? '${selectedGenres.length} genres'
              : groupFilter != 'All'
              ? groupFilter
              : 'Movies');
      final message =
          'Shuffling $scopeLabel · '
          '${movieCandidates.length} eligible titles.';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      await PlaylistPlayback(
        profileId: widget.profileId,
        open: widget.playlistSegmentOpener ?? openPlaylistSegment,
      ).play(
        context,
        playlistId: 'filtered-${DateTime.now().microsecondsSinceEpoch}',
        name: scopeLabel,
        items: [
          for (final item in movieCandidates)
            vodHubItem(_libraryItemFromMedia(item)!),
        ],
        shuffle: true,
      );
      return;
    }
    final pick = candidates[Random().nextInt(candidates.length)];
    setState(() => focusedMediaId = pick.id);
    if (pick.series) {
      await _openSeries(pick);
    } else {
      await _openMovie(pick);
    }
  }

  void _toggleCollection(String id) {
    setState(() {
      if (activeCollectionId == id) {
        activeCollectionId = null;
      } else {
        activeCollectionId = id;
      }
    });
  }

  void _toggleGenre(String genre) {
    setState(() {
      if (selectedGenres.contains(genre)) {
        selectedGenres = {...selectedGenres}..remove(genre);
      } else {
        selectedGenres = {...selectedGenres, genre};
      }
    });
  }

  Future<void> _showCategoryPicker(List<String> groups) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final mediaQuery = MediaQuery.of(dialogContext);
        final maxHeight = (mediaQuery.size.height * 0.7).clamp(320.0, 560.0);
        return _CategoryPickerDialog(groups: groups, maxHeight: maxHeight);
      },
    );
    if (selected != null && mounted) {
      setState(() => groupFilter = selected);
    }
  }

  String _versionTitleKey(LiveTvMediaItem item) {
    final cleaned = item.title.toLowerCase().trim();
    return cleaned.replaceAll(RegExp(r'\s+'), ' ');
  }

  int _versionCountFor(LiveTvMediaItem item) {
    final input = adultIds.contains(item.id)
        ? adultItems
        : item.series
        ? series
        : movies;
    return _versionCountsOf(input)[_versionTitleKey(item)] ?? 0;
  }

  int get _multiVersionCount =>
      _versionCounts.values.where((value) => value > 1).length;

  int? _yearFromTitle(String title) {
    final match = RegExp(r'(19|20)\d{2}').firstMatch(title);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(0)!);
  }

  String _normalizeEditionKey(String title) {
    var value = title.toLowerCase();
    value = value.replaceAll(RegExp(r'\((19|20)\d{2}\)'), ' ');
    value = value.replaceAll(
      RegExp(
        r'\b(4k|2160p|1080p|720p|remux|extended|director.?s cut|hdr|uhd|hevc|x26[45]|dubbed|multi)\b',
      ),
      ' ',
    );
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value;
  }

  List<LiveTvMediaItem> _editionsFor(LiveTvMediaItem item) {
    final key = _normalizeEditionKey(item.title);
    final pool = item.series ? series : movies;
    return pool
        .where((entry) => _normalizeEditionKey(entry.title) == key)
        .toList();
  }

  List<LiveTvMediaItem> _relatedLocalTitlesFor(LiveTvMediaItem item) {
    final pool = item.series ? series : movies;
    final group = (item.group ?? '').trim();
    if (group.isEmpty) {
      return const [];
    }
    return pool
        .where(
          (entry) => entry.id != item.id && (entry.group ?? '').trim() == group,
        )
        .take(8)
        .toList();
  }

  String _qualityHint(LiveTvMediaItem item) {
    final source = '${item.title} ${item.group ?? ''}'.toLowerCase();
    if (source.contains('2160') ||
        source.contains('4k') ||
        source.contains('uhd')) {
      return '4K / UHD';
    }
    if (source.contains('1080')) {
      return '1080p';
    }
    if (source.contains('720')) {
      return '720p';
    }
    return 'Adaptive / source-defined';
  }

  String _audioHint(LiveTvMediaItem item) {
    final source = '${item.title} ${item.group ?? ''}'.toLowerCase();
    if (source.contains('dual') || source.contains('multi-audio')) {
      return 'Multiple audio tracks likely';
    }
    if (source.contains('commentary')) {
      return 'Commentary track likely';
    }
    return 'Audio track picker available in player';
  }

  String _subtitleHint(LiveTvMediaItem item) {
    final source = '${item.title} ${item.group ?? ''}'.toLowerCase();
    if (source.contains('sub') ||
        source.contains('cc') ||
        source.contains('sdh')) {
      return 'Subtitles likely included';
    }
    return 'Subtitle picker and search available in player';
  }

  String _favoriteKey(String sourceId, String mediaType, String mediaId) =>
      '$sourceId|$mediaType|$mediaId';

  bool _isFavorite(String sourceId, String mediaType, String mediaId) =>
      favorites.any(
        (item) => item.key == _favoriteKey(sourceId, mediaType, mediaId),
      );

  LiveTvLibraryItem? _libraryItemFromMedia(LiveTvMediaItem item) {
    final origin = mediaItemOrigins[item];
    if (origin == null) {
      return null;
    }
    return LiveTvLibraryItem(
      sourceId: origin.sourceId,
      sourceName: origin.sourceName,
      mediaType: item.series ? 'series' : 'movie',
      mediaId: item.id,
      title: item.title,
      subtitle: item.group,
      posterUrl: item.posterUrl,
      streamUrl: item.streamUrl.trim().isEmpty ? null : item.streamUrl,
      seriesId: item.seriesId,
    );
  }

  LiveTvLibraryItem _libraryItemFromEpisode(
    LiveTvSeriesEpisode episode, {
    required String seriesTitle,
    required String seriesPosterUrl,
    required String sourceId,
    required String sourceName,
  }) {
    return LiveTvLibraryItem(
      sourceId: sourceId,
      sourceName: sourceName,
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
    if (!mounted) {
      return;
    }
    await addToMixedPlaylist(
      context,
      profileId: widget.profileId,
      item: vodHubItem(item),
    );
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
    try {
      await Navigator.of(context).push<Object?>(
        MaterialPageRoute<Object?>(
          builder: (_) => _MediaPlayerScreen(
            profileKey: 'profile-${widget.profileId}',
            title: item.title,
            subtitle: item.subtitle ?? item.sourceName,
            streamUrl: stream,
            jellyfin: _jellyfinReporter(stream),
            jellyfinFor: _jellyfinReporter,
            streamUrlCandidates: _playbackUrlCandidates(stream),
            posterUrl: item.posterUrl,
            playbackPerformance: playbackPerformance,
          ),
        ),
      );
    } finally {
      unawaited(_reportMediaPlayback(item, active: false));
    }
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
      if (_isManagedSource(selectedSource)) {
        final managed = managedCatalogBySourceId[selectedSource.id];
        candidates = managed == null
            ? const <LiveTvMediaItem>[]
            : List<LiveTvMediaItem>.from(managed.series);
      } else {
        candidates = await _loadSeriesFor(selectedSource);
      }
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
      MaterialPageRoute<Object?>(
        builder: (_) => PlaylistsScreen(profileId: widget.profileId),
      ),
    );
  }

  Future<void> _openSleepTimer() async {
    await showSleepModeSheet(context, profileId: widget.profileId);
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
    final crew = metadata?.crew ?? const <String>[];
    final genres = metadata?.genres ?? const <String>[];
    final advisories = metadata?.advisories ?? const <String>[];
    final relatedTmdb = metadata?.relatedTitles ?? const <String>[];
    final extras = metadata?.extras ?? const <LiveTvMediaExtraLink>[];
    final year = metadata?.year ?? _yearFromTitle(item.title);
    final runtime = metadata?.runtimeMinutes;
    final watchedState = await playbackMemory.loadProgress(item.streamUrl);
    final jellyfinItemId = jellyfinItemIdFromUrl(item.streamUrl);
    final remoteState = jellyfinItemId == null
        ? null
        : jellyfinUserData[jellyfinItemId];
    // Jellyfin's state includes other devices, so it wins when present.
    final watched = remoteState?.played ?? watchedState['complete'] == true;
    final resumeMs = (remoteState?.positionMs ?? 0) > 0
        ? remoteState!.positionMs
        : int.tryParse(watchedState['positionMs']?.toString() ?? '') ?? 0;
    final editions = _editionsFor(item);
    final relatedLocal = _relatedLocalTitlesFor(item);
    final quality = _qualityHint(item);
    final audioHint = _audioHint(item);
    final subtitleHint = _subtitleHint(item);
    final watchlisted = _isFavorite(
      libraryItem.sourceId,
      libraryItem.mediaType,
      libraryItem.mediaId,
    );
    Widget section(String title, List<Widget> children) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.millitopTheme.panelColor.withAlpha(130),
        borderRadius: BorderRadius.circular(context.millitopTheme.cardRadius),
        border: Border.all(color: context.millitopTheme.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * .9,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                children: [
                  if (backdrop != null && backdrop.trim().isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        backdrop,
                        height: 260,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: poster == null || poster.trim().isEmpty
                            ? Container(
                                width: 170,
                                height: 240,
                                color: context.millitopTheme.panelColor,
                                alignment: Alignment.center,
                                child: const Icon(Icons.movie, size: 52),
                              )
                            : Image.network(
                                poster,
                                width: 170,
                                height: 240,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 170,
                                  height: 240,
                                  color: context.millitopTheme.panelColor,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.movie, size: 52),
                                ),
                              ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              year == null
                                  ? item.title
                                  : '${item.title} ($year)',
                              style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (item.group?.trim().isNotEmpty == true)
                              Text(
                                item.group!,
                                style: TextStyle(
                                  color: _LiveTvMediaPaint.onSurface70,
                                  fontSize: 16,
                                ),
                              ),
                            const SizedBox(height: 14),
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
                                    item.series
                                        ? 'Browse Episodes'
                                        : 'Play Now',
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    unawaited(_toggleFavorite(libraryItem));
                                  },
                                  icon: Icon(
                                    watchlisted
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                  ),
                                  label: Text(
                                    watchlisted ? 'In Watchlist' : 'Watchlist',
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    unawaited(_addToPlaylist(libraryItem));
                                  },
                                  icon: const Icon(Icons.playlist_add),
                                  label: const Text('Add to Playlist'),
                                ),
                                if (!item.series && resumeMs > 15000)
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      if (jellyfinItemId != null) {
                                        jellyfinUserData[jellyfinItemId] =
                                            const JellyfinUserData();
                                      }
                                      unawaited(
                                        playbackMemory
                                            .saveProgress(
                                              item.streamUrl,
                                              positionMs: 0,
                                              durationMs: 0,
                                              complete: false,
                                            )
                                            .then((_) => _openMovie(item)),
                                      );
                                    },
                                    icon: const Icon(Icons.replay),
                                    label: const Text('Restart'),
                                  ),
                                if (!item.series && resumeMs > 15000)
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      unawaited(_openMovie(item));
                                    },
                                    icon: const Icon(Icons.play_arrow),
                                    label: const Text('Resume'),
                                  ),
                                if (!item.series)
                                  OutlinedButton.icon(
                                    key: const ValueKey('media-mark-watched'),
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      unawaited(
                                        _setWatched(item, played: !watched),
                                      );
                                    },
                                    icon: Icon(
                                      watched
                                          ? Icons.remove_done
                                          : Icons.done_all,
                                    ),
                                    label: Text(
                                      watched
                                          ? 'Mark unwatched'
                                          : 'Mark watched',
                                    ),
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
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (runtime != null)
                                  Chip(label: Text('Runtime ${runtime}m')),
                                Chip(
                                  label: Text(
                                    watched ? 'Watched' : 'Not watched',
                                  ),
                                ),
                                Chip(label: Text('Quality $quality')),
                                if (metadata?.contentRating != null)
                                  Chip(
                                    label: Text(
                                      '${metadata!.ratingSystem ?? 'Rating'} ${metadata.contentRating}',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  section('Synopsis', [
                    Text(
                      description,
                      style: TextStyle(
                        color: _LiveTvMediaPaint.onSurface70,
                        height: 1.45,
                        fontSize: 16,
                      ),
                    ),
                  ]),
                  section('Playback capabilities', [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Chip(label: Text('Audio: $audioHint')),
                        Chip(label: Text('Subtitles: $subtitleHint')),
                      ],
                    ),
                  ]),
                  if (genres.isNotEmpty) ...[
                    section('Genres', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: genres
                            .map((value) => Chip(label: Text(value)))
                            .toList(),
                      ),
                    ]),
                  ],
                  if (advisories.isNotEmpty) ...[
                    section(
                      'Content advisories',
                      advisories
                          .map(
                            (value) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '• $value',
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                  if (cast.isNotEmpty) ...[
                    section('Cast', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: cast
                            .map((name) => Chip(label: Text(name)))
                            .toList(),
                      ),
                    ]),
                  ],
                  if (crew.isNotEmpty) ...[
                    section('Crew', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: crew
                            .map((name) => Chip(label: Text(name)))
                            .toList(),
                      ),
                    ]),
                  ],
                  if (editions.length > 1) ...[
                    section('Play from', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: editions.map((entry) {
                          final origin = mediaItemOrigins[entry];
                          final badge = origin == null
                              ? null
                              : _sourceBadge(origin.sourceId);
                          return ActionChip(
                            key: ValueKey('media-play-from-${entry.id}'),
                            avatar: CircleAvatar(
                              backgroundColor:
                                  badge?.color ?? _LiveTvMediaPaint.accent,
                              radius: 8,
                            ),
                            label: Text(
                              [
                                entry.title,
                                ?origin?.sourceName,
                                if (identical(entry, item)) 'this copy',
                              ].join(' · '),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              unawaited(_openMovie(entry));
                            },
                          );
                        }).toList(),
                      ),
                    ]),
                  ],
                  if (extras.isNotEmpty) ...[
                    section('Extras', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: extras
                            .map(
                              (entry) => ActionChip(
                                label: Text(entry.label),
                                onPressed: () => FirefoxBrowser.open(
                                  context,
                                  profileId: widget.profileId,
                                  url: entry.url,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ]),
                  ],
                  if (relatedTmdb.isNotEmpty || relatedLocal.isNotEmpty) ...[
                    section('Related titles', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ...relatedLocal.map(
                            (entry) => ActionChip(
                              label: Text(entry.title),
                              onPressed: () {
                                Navigator.pop(ctx);
                                unawaited(_showMediaDetails(entry));
                              },
                            ),
                          ),
                          ...relatedTmdb
                              .where(
                                (title) => !relatedLocal
                                    .map((entry) => entry.title.toLowerCase())
                                    .contains(title.toLowerCase()),
                              )
                              .map((title) => Chip(label: Text(title))),
                        ],
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showEpisodeDetails(
    LiveTvSeriesEpisode episode, {
    required String seriesTitle,
    required String seriesPoster,
    required String sourceId,
    required String sourceName,
  }) async {
    final item = _libraryItemFromEpisode(
      episode,
      seriesTitle: seriesTitle,
      seriesPosterUrl: seriesPoster,
      sourceId: sourceId,
      sourceName: sourceName,
    );
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
                style: TextStyle(color: _LiveTvMediaPaint.onSurface70),
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

  /// Marks a movie watched/unwatched locally and, for Jellyfin titles, on
  /// the server so other Jellyfin apps agree.
  Future<void> _setWatched(LiveTvMediaItem item, {required bool played}) async {
    await playbackMemory.saveProgress(
      item.streamUrl,
      positionMs: 0,
      durationMs: 0,
      complete: played,
    );
    final itemId = jellyfinItemIdFromUrl(item.streamUrl);
    final account = jellyfinAccount;
    final api = jellyfinApi;
    if (itemId == null || account == null || api == null) {
      return;
    }
    jellyfinUserData[itemId] = JellyfinUserData(played: played);
    try {
      await api.setPlayed(account.userId, itemId, played);
      unawaited(_loadJellyfinHome());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Jellyfin did not save that: $e')),
        );
      }
    }
  }

  Future<void> _openMovie(
    LiveTvMediaItem item, {
    List<LiveTvMediaItem>? queue,
    int queueIndex = 0,
  }) async {
    await _saveHistory(item, subtitle: item.group);
    final libraryItem = _libraryItemFromMedia(item);
    if (libraryItem != null) {
      unawaited(_reportMediaPlayback(libraryItem, active: true));
    }
    if (!mounted) {
      return;
    }
    try {
      final movieQueue = queue == null
          ? const <_MovieQueueEntry>[]
          : queue
                .where((entry) => !entry.series)
                .map(
                  (entry) => _MovieQueueEntry(
                    id: '${mediaItemOrigins[entry]?.sourceId ?? 'source'}:${entry.id}',
                    title: entry.title,
                    subtitle: entry.group,
                    streamUrl: entry.streamUrl,
                    streamUrlCandidates: _playbackUrlCandidates(
                      entry.streamUrl,
                    ),
                    posterUrl: entry.posterUrl,
                    description: entry.description,
                    year: entry.year,
                    genres: entry.genres,
                    releaseDate: entry.releaseDate,
                    addedAt: entry.addedAt,
                  ),
                )
                .toList();
      final normalizedQueueIndex = movieQueue.isEmpty
          ? 0
          : queueIndex.clamp(0, movieQueue.length - 1).toInt();
      final result = await Navigator.of(context).push<Object?>(
        MaterialPageRoute<Object?>(
          builder: (_) => _MediaPlayerScreen(
            profileKey: 'profile-${widget.profileId}',
            title: item.title,
            subtitle: item.group,
            streamUrl: item.streamUrl,
            jellyfin: _jellyfinReporter(item.streamUrl),
            jellyfinFor: _jellyfinReporter,
            streamUrlCandidates: _playbackUrlCandidates(item.streamUrl),
            posterUrl: item.posterUrl,
            description: item.description,
            playbackPerformance: playbackPerformance,
            movieQueue: movieQueue,
            movieQueueIndex: normalizedQueueIndex,
            mixedSession: widget.mixedSession,
            mixedSessionEntryId: widget.mixedSessionEntryId,
          ),
        ),
      );
      if (widget.mixedSession != null &&
          result is PlaylistPlaybackExit &&
          mounted) {
        Navigator.of(context).pop<Object?>(result);
      }
    } finally {
      if (libraryItem != null) {
        unawaited(_reportMediaPlayback(libraryItem, active: false));
      }
      if (jellyfinItemIdFromUrl(item.streamUrl) != null) {
        unawaited(_loadJellyfinHome());
      }
    }
  }

  Future<void> _openSeries(LiveTvMediaItem item) async {
    final origin = mediaItemOrigins[item];
    if (origin == null) {
      return;
    }
    final selected = origin.source;
    if (selected != null && source?.id != selected.id && mounted) {
      setState(() => source = selected);
    }
    if (widget.mixedSession != null) {
      await _saveHistory(item, subtitle: item.group ?? 'Series');
      if (!mounted) {
        return;
      }
      final result = await Navigator.of(context).push<Object?>(
        MaterialPageRoute<Object?>(
          builder: (_) => _MediaPlayerScreen(
            profileKey: 'profile-${widget.profileId}',
            title: item.title,
            subtitle: item.group ?? 'Series',
            streamUrl: item.streamUrl,
            jellyfin: _jellyfinReporter(item.streamUrl),
            jellyfinFor: _jellyfinReporter,
            streamUrlCandidates: _playbackUrlCandidates(item.streamUrl),
            posterUrl: item.posterUrl,
            description: item.description,
            playbackPerformance: playbackPerformance,
            mixedSession: widget.mixedSession,
            mixedSessionEntryId: widget.mixedSessionEntryId,
          ),
        ),
      );
      if (result is PlaylistPlaybackExit && mounted) {
        Navigator.of(context).pop<Object?>(result);
      }
      return;
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
      try {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => _MediaPlayerScreen(
              profileKey: 'profile-${widget.profileId}',
              title: item.title,
              subtitle: item.group ?? 'Series',
              streamUrl: item.streamUrl,
              jellyfin: _jellyfinReporter(item.streamUrl),
              jellyfinFor: _jellyfinReporter,
              streamUrlCandidates: _playbackUrlCandidates(item.streamUrl),
              posterUrl: item.posterUrl,
              description: item.description,
              playbackPerformance: playbackPerformance,
              seriesEpisodePlayback: true,
              seriesEpisodes: [
                _SeriesEpisodeEntry(
                  id: item.id,
                  title: item.title,
                  streamUrl: item.streamUrl,
                  season: 1,
                  episode: 1,
                  posterUrl: item.posterUrl,
                  description: item.description,
                ),
              ],
              seriesEpisodeIndex: 0,
            ),
          ),
        );
      } finally {
        if (libraryItem != null) {
          unawaited(_reportMediaPlayback(libraryItem, active: false));
        }
      }
      return;
    }
    final details = _isManagedSourceId(origin.sourceId)
        ? _managedSeriesDetails(
            sourceId: origin.sourceId,
            seriesId: item.seriesId!,
          )
        : isJellyfinSourceId(origin.sourceId)
        ? await _jellyfinSeriesDetails(item)
        : await service.loadSeriesDetails(
            selected!,
            item.seriesId!,
            item.title,
          );
    final tmdbApiKey = await HomePreferences().tmdbApiKey(widget.profileId);
    final metadata = tmdbApiKey.trim().isEmpty
        ? null
        : await service.loadTmdbMetadataDetails(
            title: item.title,
            series: true,
            tmdbApiKey: tmdbApiKey,
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
    final followed = _isFavorite(origin.sourceId, 'series', item.id);
    final recent = history
        .where(
          (entry) => entry.mediaType == 'series' && entry.mediaId == item.id,
        )
        .toList();
    final nextUpLabel = () {
      if (recent.isEmpty) {
        return null;
      }
      final text = recent.first.subtitle ?? '';
      final match = RegExp(r'S(\d+)E(\d+)').firstMatch(text.toUpperCase());
      if (match == null) {
        return null;
      }
      final season = int.tryParse(match.group(1) ?? '');
      final episode = int.tryParse(match.group(2) ?? '');
      if (season == null || episode == null) {
        return null;
      }
      final ordered = [...seriesDetails.episodes]
        ..sort((a, b) {
          final bySeason = a.season.compareTo(b.season);
          if (bySeason != 0) {
            return bySeason;
          }
          return a.episode.compareTo(b.episode);
        });
      final index = ordered.indexWhere(
        (entry) => entry.season == season && entry.episode == episode,
      );
      if (index < 0 || index + 1 >= ordered.length) {
        return null;
      }
      final next = ordered[index + 1];
      return 'S${next.season}E${next.episode} · ${next.title}';
    }();
    final progress = () {
      if (seriesDetails.episodes.isEmpty || recent.isEmpty) {
        return 0.0;
      }
      final text = recent.first.subtitle ?? '';
      final match = RegExp(r'S(\d+)E(\d+)').firstMatch(text.toUpperCase());
      if (match == null) {
        return 0.0;
      }
      final season = int.tryParse(match.group(1) ?? '');
      final episode = int.tryParse(match.group(2) ?? '');
      if (season == null || episode == null) {
        return 0.0;
      }
      final ordered = [...seriesDetails.episodes]
        ..sort((a, b) {
          final bySeason = a.season.compareTo(b.season);
          if (bySeason != 0) {
            return bySeason;
          }
          return a.episode.compareTo(b.episode);
        });
      final index = ordered.indexWhere(
        (entry) => entry.season == season && entry.episode == episode,
      );
      if (index < 0) {
        return 0.0;
      }
      return ((index + 1) / ordered.length).clamp(0.0, 1.0);
    }();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _SeriesDetailsScreen(
          details: seriesDetails,
          status: metadata?.status,
          contentRating: metadata?.contentRating,
          genres: metadata?.genres ?? const [],
          followed: followed,
          nextUpLabel: nextUpLabel,
          seriesProgress: progress,
          hasNewEpisode: nextUpLabel != null,
          onEpisodeDetails: (episode) => _showEpisodeDetails(
            episode,
            seriesTitle: seriesDetails.title,
            seriesPoster: seriesDetails.posterUrl ?? item.posterUrl ?? '',
            sourceId: origin.sourceId,
            sourceName: origin.sourceName,
          ),
          onToggleFollow: () async {
            final seriesLibrary = _libraryItemFromMedia(item);
            if (seriesLibrary == null) {
              return;
            }
            await _toggleFavorite(seriesLibrary);
          },
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
              sourceId: origin.sourceId,
              sourceName: origin.sourceName,
            );
            unawaited(_reportMediaPlayback(libraryEpisode, active: true));
            if (!mounted) {
              return;
            }
            try {
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => _MediaPlayerScreen(
                    profileKey: 'profile-${widget.profileId}',
                    title: seriesDetails.title,
                    subtitle:
                        'S${episode.season}E${episode.episode} · ${episode.title}',
                    streamUrl: episode.streamUrl,
                    jellyfin: _jellyfinReporter(episode.streamUrl),
                    jellyfinFor: _jellyfinReporter,
                    streamUrlCandidates: _playbackUrlCandidates(
                      episode.streamUrl,
                    ),
                    posterUrl: episode.posterUrl ?? seriesDetails.posterUrl,
                    description: episode.description,
                    playbackPerformance: playbackPerformance,
                    seriesEpisodePlayback: true,
                    seriesEpisodes: () {
                      final episodes = [...seriesDetails.episodes]
                        ..sort((a, b) {
                          final bySeason = a.season.compareTo(b.season);
                          if (bySeason != 0) {
                            return bySeason;
                          }
                          return a.episode.compareTo(b.episode);
                        });
                      return [
                        for (final item in episodes)
                          _SeriesEpisodeEntry(
                            id: item.id,
                            title: item.title,
                            streamUrl: item.streamUrl,
                            season: item.season,
                            episode: item.episode,
                            posterUrl: item.posterUrl,
                            description: item.description,
                          ),
                      ];
                    }(),
                    seriesEpisodeIndex: () {
                      final episodes = [...seriesDetails.episodes]
                        ..sort((a, b) {
                          final bySeason = a.season.compareTo(b.season);
                          if (bySeason != 0) {
                            return bySeason;
                          }
                          return a.episode.compareTo(b.episode);
                        });
                      final index = episodes.indexWhere(
                        (item) =>
                            item.streamUrl == episode.streamUrl &&
                            item.season == episode.season &&
                            item.episode == episode.episode,
                      );
                      return index < 0 ? 0 : index;
                    }(),
                    nextEpisodeStreamUrl: () {
                      final episodes = [...seriesDetails.episodes]
                        ..sort((a, b) {
                          final bySeason = a.season.compareTo(b.season);
                          if (bySeason != 0) {
                            return bySeason;
                          }
                          return a.episode.compareTo(b.episode);
                        });
                      final index = episodes.indexWhere(
                        (item) =>
                            item.streamUrl == episode.streamUrl &&
                            item.season == episode.season &&
                            item.episode == episode.episode,
                      );
                      if (index < 0 || index + 1 >= episodes.length) {
                        return null;
                      }
                      return episodes[index + 1].streamUrl;
                    }(),
                    nextEpisodeTitle: () {
                      final episodes = [...seriesDetails.episodes]
                        ..sort((a, b) {
                          final bySeason = a.season.compareTo(b.season);
                          if (bySeason != 0) {
                            return bySeason;
                          }
                          return a.episode.compareTo(b.episode);
                        });
                      final index = episodes.indexWhere(
                        (item) =>
                            item.streamUrl == episode.streamUrl &&
                            item.season == episode.season &&
                            item.episode == episode.episode,
                      );
                      if (index < 0 || index + 1 >= episodes.length) {
                        return null;
                      }
                      final next = episodes[index + 1];
                      return 'S${next.season}E${next.episode} · ${next.title}';
                    }(),
                  ),
                ),
              );
            } finally {
              unawaited(_reportMediaPlayback(libraryEpisode, active: false));
            }
          },
        ),
      ),
    );
  }

  Future<void> _saveHistory(LiveTvMediaItem item, {String? subtitle}) async {
    final origin = mediaItemOrigins[item];
    if (origin == null) {
      return;
    }
    try {
      await HomePreferences().upsertLiveTvRecentMedia(
        widget.profileId,
        LiveTvRecentMedia(
          sourceId: origin.sourceId,
          sourceName: origin.sourceName,
          mediaType: item.series ? 'series' : 'movie',
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
    if (sources.where((item) => item.id == recent.sourceId).isEmpty) {
      return;
    }
    if (recent.mediaType == 'movie') {
      final match = [
        ...movies,
        ...adultMovies,
      ].where((item) => item.id == recent.mediaId).toList();
      if (match.isNotEmpty) {
        await _openMovie(match.first);
      }
      return;
    }
    final match = [
      ...series,
      ...adultSeries,
    ].where((item) => item.id == recent.mediaId).toList();
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

  bool _isSeriesRecent(LiveTvRecentMedia item) =>
      item.mediaType == 'series' || item.mediaType == 'episode';

  bool _isCurrentRecentContext(LiveTvRecentMedia item) {
    if (homeView) {
      return !_isAdultRef(
        id: item.mediaId,
        title: item.title,
        sourceName: item.sourceName,
      );
    }
    final matchesAdultScope =
        _isAdultRef(
          id: item.mediaId,
          title: item.title,
          sourceName: item.sourceName,
        ) ==
        (tab == _MediaTab.adult);
    if (!matchesAdultScope) {
      return false;
    }
    return switch (tab) {
      _MediaTab.adult => showAdult,
      _MediaTab.movies => item.mediaType == 'movie',
      _MediaTab.series => _isSeriesRecent(item),
    };
  }

  String get _searchHintText {
    if (homeView) {
      return 'Search movies or series';
    }
    return switch (tab) {
      _MediaTab.movies => 'Search movies',
      _MediaTab.series => 'Search series',
      _MediaTab.adult => 'Search adult titles',
    };
  }

  String get _continueWatchingTitle {
    if (homeView) {
      return 'Continue watching';
    }
    return switch (tab) {
      _MediaTab.movies => 'Continue watching movies',
      _MediaTab.series => 'Continue watching series',
      _MediaTab.adult => 'Continue watching',
    };
  }

  String get _browseContextTitle => switch (tab) {
    _MediaTab.movies => 'Movies library',
    _MediaTab.series => 'Series library',
    _MediaTab.adult => 'Adult library',
  };

  String get _browseContextSubtitle {
    final sourceLabel = allSourcesSelected
        ? 'All libraries'
        : (source?.name ?? 'Selected library');
    final total = visibleItems.length;
    final titleLabel = total == 1 ? 'title' : 'titles';
    return '$sourceLabel · $total $titleLabel';
  }

  Widget _sectionLabel(String label, {required IconData icon}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: _LiveTvMediaPaint.onSurface60),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: _LiveTvMediaPaint.onSurface70,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }

  Widget _historyPanel() {
    final values = history.where(_isCurrentRecentContext).take(6).toList();
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
          (item) =>
              _isAdultRef(
                id: item.mediaId,
                title: item.title,
                sourceName: item.sourceName,
              ) ==
              (tab == _MediaTab.adult),
        )
        .where(
          (item) => switch (tab) {
            _MediaTab.adult => showAdult,
            _MediaTab.movies => item.mediaType == 'movie',
            _MediaTab.series =>
              item.mediaType == 'series' || item.mediaType == 'episode',
          },
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
            avatar: Icon(
              Icons.favorite,
              size: 16,
              color: _LiveTvMediaPaint.error,
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
    final values = history.where(_isCurrentRecentContext).toList();
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
                      color: _LiveTvMediaPaint.panel,
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
                        color: _LiveTvMediaPaint.panel,
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
                          _continueWatchingTitle,
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
                      style: TextStyle(color: _LiveTvMediaPaint.onSurface70),
                    ),
                  Text(
                    recent.sourceName ?? recent.sourceId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _LiveTvMediaPaint.onSurface60,
                      fontSize: 12,
                    ),
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

  Future<void> _openSearchKeyboard() async {
    final controller = TextEditingController(text: search.text);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Media search'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(labelText: _searchHintText),
          onSubmitted: (text) => Navigator.pop(ctx, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) {
      return;
    }
    search.text = value;
  }

  Future<void> _openVoiceSearch() async {
    final controller = TextEditingController(text: search.text);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Voice search'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Use your platform keyboard microphone button to dictate where supported.',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(labelText: 'Voice query'),
              onSubmitted: (text) => Navigator.pop(ctx, text),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Search'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) {
      return;
    }
    search.text = value;
  }

  // ---- Home hub -------------------------------------------------------------

  List<Widget> _tabChips() => [
    ChoiceChip(
      key: const ValueKey('media-tab-home'),
      label: const Text('Home'),
      selected: homeView,
      onSelected: (selected) {
        if (!selected) {
          return;
        }
        _showHome();
      },
    ),
    ChoiceChip(
      key: const ValueKey('media-tab-movies'),
      label: const Text('Movies'),
      selected: !homeView && tab == _MediaTab.movies,
      onSelected: (selected) {
        if (!selected) {
          return;
        }
        setState(() {
          homeView = false;
          tab = _MediaTab.movies;
          groupFilter = 'All';
        });
      },
    ),
    ChoiceChip(
      key: const ValueKey('media-tab-series'),
      label: const Text('Series'),
      selected: !homeView && tab == _MediaTab.series,
      onSelected: (selected) {
        if (!selected) {
          return;
        }
        setState(() {
          homeView = false;
          tab = _MediaTab.series;
          groupFilter = 'All';
        });
      },
    ),
    if (showAdult)
      ChoiceChip(
        key: const ValueKey('media-tab-adult'),
        label: const Text('Adult'),
        selected: !homeView && tab == _MediaTab.adult,
        onSelected: (selected) {
          if (!selected) {
            return;
          }
          setState(() {
            homeView = false;
            tab = _MediaTab.adult;
            groupFilter = 'All';
          });
          AppLog.event('media.tab', props: {'tab': 'adult'});
        },
      ),
  ];

  /// Home always shows every source, so switch back to "All Sources".
  void _showHome() {
    final reload = !allSourcesSelected;
    setState(() {
      homeView = true;
      allSourcesSelected = true;
    });
    if (reload) {
      unawaited(_loadCatalog());
    }
  }

  void _openLibrary(LiveTvSource library) {
    final hasMovies = movies.any(
      (item) => mediaItemOrigins[item]?.sourceId == library.id,
    );
    setState(() {
      source = library;
      allSourcesSelected = false;
      homeView = false;
      tab = hasMovies ? _MediaTab.movies : _MediaTab.series;
      groupFilter = 'All';
    });
    unawaited(_loadCatalog());
  }

  Future<void> _openJellyfinConnect() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => JellyfinConnectScreen(
          profileId: widget.profileId,
          store: jellyfinStore,
          transport: widget.jellyfinTransport,
        ),
      ),
    );
    if (changed != true || !mounted) {
      return;
    }
    jellyfinLibraryFetches.clear();
    jellyfinUserData.clear();
    await _jellyfinSources(reload: true);
    unawaited(_loadJellyfinHome());
    setState(() => allSourcesSelected = true);
    await _loadCatalog();
  }

  ({String label, Color color}) _sourceBadge(String sourceId) {
    if (isJellyfinSourceId(sourceId)) {
      return (label: 'JELLYFIN', color: MediaSourceColors.jellyfin);
    }
    if (_isManagedSourceId(sourceId)) {
      return (label: 'NAS', color: MediaSourceColors.nas);
    }
    return (label: 'IPTV', color: MediaSourceColors.iptv);
  }

  MediaHomeCard _cardForItem(LiveTvMediaItem item, {bool landscape = false}) {
    final origin = mediaItemOrigins[item];
    final badge = origin == null ? null : _sourceBadge(origin.sourceId);
    final copies = _versionCountFor(item);
    final yearText = item.year?.toString();
    return MediaHomeCard(
      id: 'item-${item.id}',
      title: item.title,
      subtitle: [
        ?yearText,
        if (item.series) 'Series',
        if (copies > 1) '$copies sources',
      ].join(' · '),
      imageUrl: landscape
          ? (item.backdropUrl ?? item.posterUrl)
          : (item.posterUrl ?? item.backdropUrl),
      badge: badge?.label,
      badgeColor: badge?.color,
      icon: item.series ? Icons.tv : Icons.movie_outlined,
      onTap: () =>
          unawaited(item.series ? _openSeries(item) : _showMediaDetails(item)),
    );
  }

  MediaHomeCard _cardForJellyfin(
    JellyfinEntry entry, {
    bool landscape = false,
    bool play = false,
  }) {
    final episodeLabel = entry.isEpisode
        ? 'S${entry.season ?? 0}E${entry.episode ?? 0} · ${entry.media.title}'
        : null;
    return MediaHomeCard(
      id: 'jf-${entry.itemId}',
      title: entry.isEpisode
          ? (entry.seriesName ?? entry.media.title)
          : entry.media.title,
      subtitle:
          episodeLabel ??
          [
            if (entry.media.year != null) '${entry.media.year}',
            if (entry.isSeries) 'Series',
          ].join(' · '),
      imageUrl: landscape
          ? (entry.media.backdropUrl ?? entry.media.posterUrl)
          : (entry.media.posterUrl ?? entry.media.backdropUrl),
      progress: entry.progress > 0 ? entry.progress : null,
      badge: 'JELLYFIN',
      badgeColor: MediaSourceColors.jellyfin,
      icon: entry.isSeries || entry.isEpisode ? Icons.tv : Icons.movie_outlined,
      onTap: () => unawaited(_openJellyfinEntry(entry, play: play)),
    );
  }

  /// Opens a Jellyfin title from a Home row. Episodes play straight away
  /// (like Jellyfin's Next Up); movies open details unless [play].
  Future<void> _openJellyfinEntry(
    JellyfinEntry entry, {
    bool play = false,
  }) async {
    if (entry.isEpisode) {
      await _playJellyfinEpisode(entry);
      return;
    }
    final list = entry.isSeries ? series : movies;
    final item = list.firstWhere(
      (candidate) => candidate.id == entry.media.id,
      orElse: () => entry.media,
    );
    if (!mediaItemOrigins.containsKey(item)) {
      final jellyfinSources = jellyfinAccount?.sources ?? const [];
      if (jellyfinSources.isEmpty) {
        return;
      }
      final first = jellyfinSources.first;
      mediaItemOrigins[item] = _MediaItemSourceOrigin(
        sourceId: first.id,
        sourceName: first.name,
        source: first,
      );
    }
    if (entry.isSeries) {
      await _openSeries(item);
    } else if (play) {
      await _openMovie(item);
    } else {
      await _showMediaDetails(item);
    }
  }

  Future<void> _playJellyfinEpisode(JellyfinEntry entry) async {
    if (!mounted) {
      return;
    }
    final details = (entry.isEpisode && entry.seriesId != null)
        ? await _jellyfinSeriesDetails(
            LiveTvMediaItem(
              id: 'jf:${entry.seriesId}',
              title: entry.seriesName ?? entry.media.title,
              streamUrl: entry.media.streamUrl,
              posterUrl: entry.media.posterUrl,
              description: entry.media.description,
              backdropUrl: entry.media.backdropUrl,
              series: true,
              seriesId: entry.seriesId,
            ),
          )
        : null;
    final episodeEntries = details == null
        ? const <_SeriesEpisodeEntry>[]
        : [
            for (final item
                in [...details.episodes]..sort((a, b) {
                  final bySeason = a.season.compareTo(b.season);
                  if (bySeason != 0) {
                    return bySeason;
                  }
                  return a.episode.compareTo(b.episode);
                }))
              _SeriesEpisodeEntry(
                id: item.id,
                title: item.title,
                streamUrl: item.streamUrl,
                season: item.season,
                episode: item.episode,
                posterUrl: item.posterUrl,
                description: item.description,
              ),
          ];
    final currentEpisodeIndex = episodeEntries.indexWhere(
      (item) =>
          item.streamUrl == entry.media.streamUrl ||
          (entry.episode != null &&
              entry.season != null &&
              item.season == entry.season &&
              item.episode == entry.episode),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MediaPlayerScreen(
          profileKey: 'profile-${widget.profileId}',
          title: details?.title ?? (entry.seriesName ?? entry.media.title),
          subtitle:
              'S${entry.season ?? 0}E${entry.episode ?? 0} · ${entry.media.title}',
          streamUrl: entry.media.streamUrl,
          posterUrl: entry.media.posterUrl,
          description: entry.media.description,
          playbackPerformance: playbackPerformance,
          jellyfin: _jellyfinReporter(entry.media.streamUrl),
          jellyfinFor: _jellyfinReporter,
          seriesEpisodePlayback: episodeEntries.isNotEmpty,
          seriesEpisodes: episodeEntries,
          seriesEpisodeIndex: currentEpisodeIndex < 0 ? 0 : currentEpisodeIndex,
        ),
      ),
    );
    unawaited(_loadJellyfinHome());
  }

  Widget _homeHeader({required bool compact, required Size viewport}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ..._tabChips(),
          SizedBox(
            width: compact ? viewport.width - 24 : 360,
            child: TextField(
              controller: search,
              focusNode: searchFocus,
              decoration: InputDecoration(
                hintText: _searchHintText,
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (error.isNotEmpty)
            Text(error, style: TextStyle(color: _LiveTvMediaPaint.warning)),
        ],
      ),
    );
  }

  List<LiveTvMediaItem>? _datedCache;
  List<LiveTvMediaItem>? _datedMovies;
  List<LiveTvMediaItem>? _datedSeries;

  /// Newest-first non-adult titles with an added date, sorted once per
  /// catalog instead of on every Home rebuild.
  List<LiveTvMediaItem> _recentlyAddedSorted() {
    if (_datedCache != null &&
        identical(_datedMovies, movies) &&
        identical(_datedSeries, series)) {
      return _datedCache!;
    }
    _datedMovies = movies;
    _datedSeries = series;
    return _datedCache =
        [...movies, ...series].where((item) => item.addedAt != null).toList()
          ..sort((a, b) => b.addedAt!.compareTo(a.addedAt!));
  }

  Widget _buildHome() {
    final rows = <MediaHomeRow>[];
    final resume = jellyfinResume;

    // Continue watching: Jellyfin resume points first, then local history
    // from IPTV / NAS sources (Jellyfin titles are already covered above).
    final visibleSourceIds = {for (final item in _visibleSources) item.id};
    bool adultRecent(LiveTvRecentMedia entry) => _isAdultRef(
      id: entry.mediaId,
      title: entry.title,
      sourceName: entry.sourceName,
    );
    final localHistory = history
        .where(
          (entry) =>
              !isJellyfinSourceId(entry.sourceId) &&
              visibleSourceIds.contains(entry.sourceId),
        )
        .toList();
    final localRecent = localHistory.where((entry) => !adultRecent(entry));
    final localMovieRecent = localRecent
        .where((entry) => entry.mediaType == 'movie')
        .take(20)
        .toList();
    final localSeriesRecent = localRecent
        .where(_isSeriesRecent)
        .take(20)
        .toList();
    final jellyfinMovieResume = resume
        .where((entry) => !entry.isEpisode && !entry.isSeries)
        .toList();
    final jellyfinSeriesResume = resume
        .where((entry) => entry.isEpisode || entry.isSeries)
        .toList();
    MediaHomeCard recentCard(LiveTvRecentMedia entry) => MediaHomeCard(
      id: 'recent-${entry.sourceId}-${entry.mediaId}',
      title: entry.title,
      subtitle: entry.subtitle ?? entry.sourceName,
      imageUrl: entry.posterUrl,
      badge: _sourceBadge(entry.sourceId).label,
      badgeColor: _sourceBadge(entry.sourceId).color,
      icon: _isSeriesRecent(entry) ? Icons.tv : Icons.movie_outlined,
      onTap: () => unawaited(_resumeRecentMedia(entry)),
    );
    final continueMovieCards = <MediaHomeCard>[
      for (final entry in jellyfinMovieResume)
        _cardForJellyfin(entry, landscape: true, play: true),
      for (final entry in localMovieRecent) recentCard(entry),
    ];
    if (continueMovieCards.isNotEmpty) {
      rows.add(
        MediaHomeRow(
          title: 'Continue Watching Movies',
          shape: MediaHomeCardShape.landscape,
          cards: continueMovieCards,
        ),
      );
    }
    final continueSeriesCards = <MediaHomeCard>[
      for (final entry in jellyfinSeriesResume)
        _cardForJellyfin(entry, landscape: true, play: true),
      for (final entry in localSeriesRecent) recentCard(entry),
    ];
    if (continueSeriesCards.isNotEmpty) {
      rows.add(
        MediaHomeRow(
          title: 'Continue Watching Series',
          shape: MediaHomeCardShape.landscape,
          cards: continueSeriesCards,
        ),
      );
    }
    rows.add(
      MediaHomeRow(
        title: 'Next Up',
        shape: MediaHomeCardShape.landscape,
        cards: [
          for (final entry in jellyfinNextUp)
            _cardForJellyfin(entry, landscape: true, play: true),
        ],
      ),
    );

    final counts = <String, int>{};
    for (final entry in mediaItemOrigins.entries) {
      counts[entry.value.sourceId] = (counts[entry.value.sourceId] ?? 0) + 1;
    }
    rows.add(
      MediaHomeRow(
        title: 'Your Libraries',
        shape: MediaHomeCardShape.tile,
        cards: [
          for (final library in _visibleSources)
            MediaHomeCard(
              id: 'library-${library.id}',
              title: library.name,
              subtitle: [
                _sourceBadge(library.id).label,
                if (counts[library.id] != null) '${counts[library.id]} titles',
              ].join(' · '),
              badgeColor: _sourceBadge(library.id).color,
              icon: isJellyfinSourceId(library.id)
                  ? Icons.dns
                  : (_isManagedSourceId(library.id)
                        ? Icons.storage
                        : Icons.live_tv),
              onTap: () => _openLibrary(library),
            ),
          if (jellyfinAccount == null)
            MediaHomeCard(
              id: 'library-connect-jellyfin',
              title: 'Connect Jellyfin',
              subtitle: 'Add your Jellyfin libraries',
              badgeColor: MediaSourceColors.jellyfin,
              icon: Icons.add_link,
              onTap: () => unawaited(_openJellyfinConnect()),
            ),
        ],
      ),
    );

    // Recently added: Jellyfin's own list, then newest catalog titles.
    final seen = <String>{};
    final recentCards = <MediaHomeCard>[];
    for (final entry in jellyfinLatest) {
      if (seen.add(entry.media.id)) {
        recentCards.add(_cardForJellyfin(entry));
      }
    }
    final dated = _recentlyAddedSorted();
    for (final item in dated) {
      if (recentCards.length >= 24) {
        break;
      }
      if (seen.add(item.id)) {
        recentCards.add(_cardForItem(item));
      }
    }
    rows.add(MediaHomeRow(title: 'Recently Added', cards: recentCards));

    // Because you watched: Jellyfin's similar items, else a genre match
    // against the most recent local title.
    if (jellyfinSimilar.isNotEmpty && jellyfinSimilarTo != null) {
      rows.add(
        MediaHomeRow(
          title: 'Because you watched $jellyfinSimilarTo',
          cards: [for (final entry in jellyfinSimilar) _cardForJellyfin(entry)],
        ),
      );
    } else if (localRecent.isNotEmpty) {
      final last = localRecent.first;
      final pool = last.mediaType == 'series' ? series : movies;
      final seed = pool.where((item) => item.id == last.mediaId).toList();
      if (seed.isNotEmpty && seed.first.genres.isNotEmpty) {
        final genres = seed.first.genres.map((g) => g.toLowerCase()).toSet();
        final matches = pool
            .where(
              (item) =>
                  item.id != seed.first.id &&
                  item.genres.any((g) => genres.contains(g.toLowerCase())),
            )
            .take(16)
            .toList();
        rows.add(
          MediaHomeRow(
            title: 'Because you watched ${seed.first.title}',
            cards: [for (final item in matches) _cardForItem(item)],
          ),
        );
      }
    }

    void seeAll(_MediaTab next) => setState(() {
      homeView = false;
      tab = next;
      groupFilter = 'All';
    });
    rows.add(
      MediaHomeRow(
        title: 'Movies',
        actionLabel: 'See all',
        onAction: () => seeAll(_MediaTab.movies),
        cards: [for (final item in movies.take(24)) _cardForItem(item)],
      ),
    );
    rows.add(
      MediaHomeRow(
        title: 'Series',
        actionLabel: 'See all',
        onAction: () => seeAll(_MediaTab.series),
        cards: [for (final item in series.take(24)) _cardForItem(item)],
      ),
    );
    // Adult titles only ever appear here (and in the Adult tab), never in
    // the rows above, and only when the profile turned them on.
    if (showAdult) {
      final adultRecentLocal = localHistory.where(adultRecent).take(12);
      rows.add(
        MediaHomeRow(
          title: 'Adult',
          actionLabel: 'See all',
          onAction: () => seeAll(_MediaTab.adult),
          cards: [
            for (final entry in jellyfinAdultResume)
              _cardForJellyfin(entry, play: true),
            for (final entry in adultRecentLocal) recentCard(entry),
            for (final entry in jellyfinAdultLatest) _cardForJellyfin(entry),
            for (final item in adultItems.take(24)) _cardForItem(item),
          ],
        ),
      );
    }
    rows.add(
      MediaHomeRow(
        title: 'My List',
        cards: [
          for (final item
              in favorites
                  .where(
                    (item) => !_isAdultRef(
                      id: item.mediaId,
                      title: item.title,
                      sourceName: item.sourceName,
                    ),
                  )
                  .take(24))
            MediaHomeCard(
              id: 'fav-${item.sourceId}-${item.mediaId}',
              title: item.title,
              subtitle: item.subtitle ?? item.sourceName,
              imageUrl: item.posterUrl,
              badge: _sourceBadge(item.sourceId).label,
              badgeColor: _sourceBadge(item.sourceId).color,
              icon: item.mediaType == 'series'
                  ? Icons.tv
                  : Icons.movie_outlined,
              onTap: () => unawaited(_playLibraryItem(item)),
            ),
        ],
      ),
    );
    rows.add(
      MediaHomeRow(
        title: 'Playlists',
        shape: MediaHomeCardShape.tile,
        actionLabel: 'Manage',
        onAction: () => unawaited(_managePlaylists()),
        cards: [
          for (final playlist in playlists)
            MediaHomeCard(
              id: 'playlist-${playlist.id}',
              title: playlist.name,
              subtitle: '${playlist.items.length} items',
              icon: Icons.playlist_play,
              onTap: () => unawaited(_managePlaylists()),
            ),
        ],
      ),
    );

    // Hero: the title you were last watching on Jellyfin, else the newest
    // title that has artwork.
    MediaHomeHero? hero;
    if (resume.isNotEmpty) {
      final entry = resume.first;
      hero = MediaHomeHero(
        title: entry.isEpisode
            ? (entry.seriesName ?? entry.media.title)
            : entry.media.title,
        meta: entry.isEpisode
            ? 'S${entry.season ?? 0}E${entry.episode ?? 0} · ${entry.media.title}'
            : entry.media.year?.toString(),
        overview: entry.media.description,
        backdropUrl: entry.media.backdropUrl ?? entry.media.posterUrl,
        badge: 'CONTINUE · JELLYFIN',
        badgeColor: MediaSourceColors.jellyfin,
        playLabel: 'Resume',
        progress: entry.progress,
        onPlay: () => unawaited(_openJellyfinEntry(entry, play: true)),
        onDetails: () => unawaited(_openJellyfinEntry(entry)),
      );
    } else {
      final featured = dated.where((item) => item.backdropUrl != null).toList();
      final pick = featured.isNotEmpty
          ? featured.first
          : [
              ...movies,
              ...series,
            ].where((item) => item.backdropUrl != null).firstOrNull;
      if (pick != null) {
        final badge = mediaItemOrigins[pick] == null
            ? null
            : _sourceBadge(mediaItemOrigins[pick]!.sourceId);
        hero = MediaHomeHero(
          title: pick.title,
          meta: [
            if (pick.year != null) '${pick.year}',
            if (pick.genres.isNotEmpty) pick.genres.take(3).join(', '),
          ].join(' · '),
          overview: pick.description,
          backdropUrl: pick.backdropUrl,
          badge: badge == null ? 'FEATURED' : 'FEATURED · ${badge.label}',
          badgeColor: badge?.color,
          onPlay: () =>
              unawaited(pick.series ? _openSeries(pick) : _openMovie(pick)),
          onDetails: () => unawaited(
            pick.series ? _openSeries(pick) : _showMediaDetails(pick),
          ),
        );
      }
    }
    return RefreshIndicator(
      onRefresh: () async {
        await _loadJellyfinHome();
      },
      child: MediaHomeView(
        hero: hero,
        rows: rows,
        emptyState: loading
            ? const SizedBox.shrink()
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Nothing here yet.'),
                    const SizedBox(height: 12),
                    if (jellyfinAccount == null)
                      FilledButton.icon(
                        onPressed: () => unawaited(_openJellyfinConnect()),
                        icon: const Icon(Icons.add_link),
                        label: const Text('Connect Jellyfin'),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  /// At the Movies & Series Home with nothing to back out of.
  bool get _atMediaHome =>
      homeView && allSourcesSelected && search.text.trim().isEmpty;

  /// One Back step inside Movies & Series: clear search, else return from a
  /// library/grid to the Movies & Series Home.
  void _stepBackWithinMedia() {
    if (search.text.trim().isNotEmpty) {
      search.clear();
      return;
    }
    AppLog.debug(LogCategory.nav, 'Back to Movies & Series Home');
    _showHome();
  }

  String get _posterScalePreferenceKey =>
      'media.posterScale.v1.${widget.profileId}';

  Future<void> _loadPosterCardScalePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_posterScalePreferenceKey);
    if (value == null || !mounted) {
      return;
    }
    final clamped = value.clamp(0.75, 1.4).toDouble();
    setState(() => posterCardScale = clamped);
  }

  Future<void> _savePosterCardScalePreference(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_posterScalePreferenceKey, value);
  }

  Future<void> _requestExitToHome() async {
    if (!mounted) {
      return;
    }
    if (!_atMediaHome) {
      _stepBackWithinMedia();
      return;
    }
    await Navigator.of(context).maybePop();
  }

  LibrarySection get _librarySection => homeView
      ? LibrarySection.home
      : (tab == _MediaTab.series
            ? LibrarySection.series
            : LibrarySection.movies);

  String get _sortLabel => switch (sortMode) {
    _MediaSortMode.relevance => 'Relevance',
    _MediaSortMode.title => 'Title A-Z',
    _MediaSortMode.source => 'Source',
    _MediaSortMode.inTheaters => 'In theaters proximity',
    _MediaSortMode.recentlyAdded => 'Recently Added',
  };

  String get _genreLabel => selectedGenres.isEmpty
      ? 'All genres'
      : '${selectedGenres.length} selected';

  String get _libraryScopeLabel => allSourcesSelected
      ? 'All libraries'
      : (source?.name ?? 'Selected library');

  String get _librarySummary {
    if (loading) {
      return 'Loading your movies and series libraries...';
    }
    return '$_libraryScopeLabel · ${visibleItems.length} titles in view';
  }

  bool get _showAlphabetRail =>
      !homeView &&
      tab != _MediaTab.adult &&
      sortMode == _MediaSortMode.title &&
      visibleItems.isNotEmpty;

  void _refreshAlphabetMap(List<LiveTvMediaItem> items) {
    _alphabetFirstIndex.clear();
    for (var i = 0; i < items.length; i++) {
      final letter = mediaLetter(mediaSortKey(items[i].title));
      _alphabetFirstIndex.putIfAbsent(letter, () => i);
    }
    if (_alphabetFirstIndex.isEmpty) {
      _selectedAlphabetLetter = null;
      return;
    }
    if (_selectedAlphabetLetter == null ||
        !_alphabetFirstIndex.containsKey(_selectedAlphabetLetter)) {
      _selectedAlphabetLetter = _alphabetFirstIndex.keys.first;
    }
  }

  void _updateAlphabetSelectionFromScroll(List<LiveTvMediaItem> items) {
    if (!_showAlphabetRail ||
        !_catalogScrollController.hasClients ||
        items.isEmpty) {
      return;
    }
    final offset = _catalogScrollController.offset.clamp(
      0.0,
      _catalogScrollController.position.maxScrollExtent,
    );
    final row = (offset / max(1.0, _alphabetTileStride)).floor();
    final index = (row * _alphabetCrossAxisCount).clamp(0, items.length - 1);
    final letter = mediaLetter(mediaSortKey(items[index].title));
    if (letter != _selectedAlphabetLetter && mounted) {
      setState(() => _selectedAlphabetLetter = letter);
    }
  }

  Future<void> _jumpToAlphabetLetter(
    String letter,
    List<LiveTvMediaItem> items,
  ) async {
    if (!_showAlphabetRail || !_catalogScrollController.hasClients) {
      return;
    }
    final first = _alphabetFirstIndex[letter];
    if (first == null) {
      return;
    }
    final row = first ~/ _alphabetCrossAxisCount;
    final target = row * _alphabetTileStride;
    setState(() => _selectedAlphabetLetter = letter);
    await _catalogScrollController.animateTo(
      target.clamp(0.0, _catalogScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _chooseSort() async {
    final selected = await showModalBottomSheet<_MediaSortMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Sort titles',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final option in <(_MediaSortMode, String)>[
              (_MediaSortMode.relevance, 'Relevance'),
              (_MediaSortMode.title, 'Title A-Z'),
              (_MediaSortMode.source, 'Source'),
              (_MediaSortMode.inTheaters, 'In theaters proximity'),
              (_MediaSortMode.recentlyAdded, 'Recently Added'),
            ])
              ListTile(
                leading: Icon(
                  option.$1 == sortMode
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                ),
                title: Text(option.$2),
                onTap: () => Navigator.pop(ctx, option.$1),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected == sortMode) {
      return;
    }
    setState(() {
      sortMode = selected;
      _selectedAlphabetLetter = null;
    });
  }

  Future<void> _chooseGenre() async {
    final picks = Set<String>.from(selectedGenres);
    final applied = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Genres'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final genre in availableGenres)
                    FilterChip(
                      label: Text(genre),
                      selected: picks.contains(genre),
                      onSelected: (on) {
                        setDialog(() {
                          if (on) {
                            picks.add(genre);
                          } else {
                            picks.remove(genre);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, <String>{}),
              child: const Text('Clear'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, picks),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (applied == null) {
      return;
    }
    setState(() {
      selectedGenres = applied;
      _selectedAlphabetLetter = null;
    });
  }

  Future<void> _chooseLibraryScope() async {
    final selected = await showModalBottomSheet<Object?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('All libraries'),
              selected: allSourcesSelected,
              onTap: () => Navigator.pop(ctx, 'all-libraries'),
            ),
            for (final item in _visibleSources)
              ListTile(
                title: Text(item.name),
                selected: !allSourcesSelected && source?.id == item.id,
                onTap: () => Navigator.pop(ctx, item),
              ),
          ],
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    if (selected == null) {
      return;
    }
    if (selected == 'all-libraries') {
      if (!allSourcesSelected) {
        setState(() {
          allSourcesSelected = true;
          _selectedAlphabetLetter = null;
        });
        await _loadCatalog();
      }
      return;
    }
    if (selected is! LiveTvSource) {
      return;
    }
    if (!allSourcesSelected && source?.id == selected.id) {
      return;
    }
    setState(() {
      source = selected;
      allSourcesSelected = false;
      _selectedAlphabetLetter = null;
    });
    await _loadCatalog();
  }

  @override
  Widget build(BuildContext context) {
    final items = visibleItems;
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 720;
    final showingHome = homeView && search.text.trim().isEmpty;
    final groups = <String>{'All', ...items.map((item) => item.group).nonNulls}
      ..removeWhere((value) => value.trim().isEmpty);
    final groupOptions = groups.toList()..sort();
    _refreshAlphabetMap(items);
    final collectionChips = <Widget>[
      if (showAdult)
        ChoiceChip(
          key: const ValueKey('media-tab-adult'),
          label: const Text('Adult'),
          selected: !homeView && tab == _MediaTab.adult,
          onSelected: (selected) {
            if (!selected) {
              return;
            }
            setState(() {
              homeView = false;
              tab = _MediaTab.adult;
              groupFilter = 'All';
            });
            AppLog.event('media.tab', props: {'tab': 'adult'});
          },
        ),
      ...activeSeasonalCollections.map((collection) {
        return FilterChip(
          avatar: Icon(collection.icon, size: 16),
          label: Text(collection.label),
          selected: activeCollectionId == collection.id,
          onSelected: (_) => _toggleCollection(collection.id),
        );
      }),
    ];

    Widget buildFilters() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _showCategoryPicker(groupOptions),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Category',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.filter_alt_outlined),
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              child: Text(
                groupOptions.contains(groupFilter)
                    ? groupFilter
                    : groupOptions.first,
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const ValueKey('media-shuffle-filters'),
            onPressed: () => unawaited(_shuffleWithinFilters()),
            icon: const Icon(Icons.shuffle),
            label: Text(
              selectedGenres.isEmpty
                  ? 'Shuffle all movies'
                  : 'Shuffle selected genres',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show multi-version titles only'),
            value: versionAwareOnly,
            onChanged: (value) => setState(() => versionAwareOnly = value),
          ),
          const SizedBox(height: 12),
          Text('Poster size', style: Theme.of(context).textTheme.labelLarge),
          Slider(
            value: posterCardScale,
            min: 0.75,
            max: 1.4,
            divisions: 13,
            label: '${(posterCardScale * 100).round()}%',
            onChanged: (value) {
              setState(() => posterCardScale = value);
              unawaited(_savePosterCardScalePreference(value));
            },
          ),
          const Text(
            'Smaller posters show more titles on screen.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      );
    }

    Widget buildCatalogGrid() {
      return LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth;
          final scaledWidth = width / posterCardScale.clamp(0.75, 1.4);
          final crossAxisCount = scaledWidth >= 1480
              ? 6
              : scaledWidth >= 1180
              ? 5
              : scaledWidth >= 900
              ? 4
              : scaledWidth >= 620
              ? 3
              : 2;
          _alphabetCrossAxisCount = crossAxisCount;
          const horizontalPadding = 16.0 * 2;
          const crossSpacing = 12.0;
          const mainSpacing = 12.0;
          const cardAspectRatio = 10 / 16;
          final gridWidth =
              width - horizontalPadding - ((crossAxisCount - 1) * crossSpacing);
          final tileWidth = max(1.0, gridWidth / crossAxisCount);
          final tileHeight = tileWidth / cardAspectRatio;
          _alphabetTileStride = tileHeight + mainSpacing;
          if (items.isEmpty) {
            return const Center(
              child: Text('No titles match the current filters.'),
            );
          }
          return GridView.builder(
            key: const ValueKey('media-grid'),
            controller: _catalogScrollController,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: items.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 10 / 16,
            ),
            itemBuilder: (context, index) {
              final item = items[index];
              final selected = focusedMediaId == item.id;
              final posterUrl = item.posterUrl?.trim();
              return Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: selected
                      ? BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2,
                        )
                      : BorderSide.none,
                ),
                child: InkWell(
                  onTap: () => unawaited(_showMediaDetails(item)),
                  onFocusChange: (value) {
                    if (value) {
                      setState(() => focusedMediaId = item.id);
                    }
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: posterUrl == null || posterUrl.isEmpty
                            ? const ColoredBox(
                                color: Colors.black26,
                                child: Icon(Icons.ondemand_video, size: 42),
                              )
                            : Image.network(
                                posterUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const ColoredBox(
                                  color: Colors.black26,
                                  child: Icon(Icons.ondemand_video, size: 42),
                                ),
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.group?.trim().isNotEmpty == true
                                  ? item.group!
                                  : (mediaItemOrigins[item]?.sourceName ??
                                        'Library title'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
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
      );
    }

    Future<void> onSectionChanged(LibrarySection section) async {
      if (section == LibrarySection.home) {
        _showHome();
        return;
      }
      setState(() {
        homeView = false;
        tab = section == LibrarySection.series
            ? _MediaTab.series
            : _MediaTab.movies;
        groupFilter = 'All';
        _selectedAlphabetLetter = null;
      });
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          unawaited(_requestExitToHome());
        },
        const SingleActivator(LogicalKeyboardKey.goBack): () {
          unawaited(_requestExitToHome());
        },
        const SingleActivator(LogicalKeyboardKey.f5): () {
          if (_isTextInputFocused) {
            return;
          }
          unawaited(_loadCatalog(forceRefresh: true));
        },
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (_isTextInputFocused) {
            return;
          }
          final focused = focusedMediaId;
          if (focused == null) {
            return;
          }
          final match = items.where((item) => item.id == focused).toList();
          if (match.isNotEmpty) {
            unawaited(_showMediaDetails(match.first));
          }
        },
        const SingleActivator(LogicalKeyboardKey.select): () {
          if (_isTextInputFocused) {
            return;
          }
          final focused = focusedMediaId;
          if (focused == null) {
            return;
          }
          final match = items.where((item) => item.id == focused).toList();
          if (match.isNotEmpty) {
            unawaited(_showMediaDetails(match.first));
          }
        },
        const SingleActivator(LogicalKeyboardKey.slash): () {
          if (_isTextInputFocused) {
            return;
          }
          unawaited(_openSearchKeyboard());
        },
        const SingleActivator(LogicalKeyboardKey.keyV): () {
          if (_isTextInputFocused) {
            return;
          }
          unawaited(_openVoiceSearch());
        },
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          if (_isTextInputFocused) {
            return;
          }
          searchFocus.requestFocus();
        },
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: _atMediaHome,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _stepBackWithinMedia();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Movies & Series'),
              actions: [
                IconButton(
                  key: const ValueKey('media-jellyfin-settings'),
                  tooltip: jellyfinAccount == null
                      ? 'Connect Jellyfin'
                      : 'Jellyfin settings',
                  onPressed: () => unawaited(_openJellyfinConnect()),
                  icon: Icon(
                    jellyfinAccount == null ? Icons.add_link : Icons.dns,
                    color: jellyfinAccount == null
                        ? null
                        : MediaSourceColors.jellyfin,
                  ),
                ),
                IconButton(
                  tooltip: 'Sleep timer',
                  onPressed: () => unawaited(_openSleepTimer()),
                  icon: ListenableBuilder(
                    listenable: SleepMode.instance,
                    builder: (context, _) {
                      final running = SleepMode.instance.deadline != null;
                      return Icon(
                        running
                            ? Icons.timer_outlined
                            : Icons.nightlight_round_outlined,
                      );
                    },
                  ),
                ),
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
                            backgroundColor: _LiveTvMediaPaint.accent,
                            child: Text(
                              '${playlists.length}',
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: checkingForCatalogUpdates
                      ? 'Checking for new titles...'
                      : 'Reload library',
                  onPressed: loading || checkingForCatalogUpdates
                      ? null
                      : () => unawaited(_loadCatalog(forceRefresh: true)),
                  icon: checkingForCatalogUpdates
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
                PopupMenuButton<String>(
                  key: const ValueKey('media-more-menu'),
                  tooltip: 'More',
                  onSelected: (value) {
                    if (value == 'adult') {
                      unawaited(_setShowAdult(!showAdult));
                    } else if (value == 'diagnostics') {
                      unawaited(
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            settings: const RouteSettings(name: 'diagnostics'),
                            builder: (_) => const DiagnosticsScreen(),
                          ),
                        ),
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem<String>(
                      key: const ValueKey('media-adult-toggle'),
                      value: 'adult',
                      checked: showAdult,
                      child: const Text('Show adult content'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'diagnostics',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.bug_report_outlined),
                        title: Text('Diagnostics & logs'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            body: SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ExcludeFocus(
                    excluding: loading,
                    child: showingHome
                        ? Column(
                            children: [
                              _homeHeader(compact: compact, viewport: viewport),
                              Expanded(child: _buildHome()),
                            ],
                          )
                        : MediaLibraryShell(
                            section: _librarySection,
                            onSectionChanged: (section) {
                              unawaited(onSectionChanged(section));
                            },
                            searchController: search,
                            searchFocusNode: searchFocus,
                            onSearchChanged: (_) => setState(() {}),
                            libraryName: _libraryScopeLabel,
                            onChooseLibrary: () =>
                                unawaited(_chooseLibraryScope()),
                            summary: _librarySummary,
                            genreLabel: _genreLabel,
                            onChooseGenre: () => unawaited(_chooseGenre()),
                            sortLabel: _sortLabel,
                            onChooseSort: () => unawaited(_chooseSort()),
                            filtersOpen: filtersOpen,
                            onToggleFilters: () {
                              setState(() => filtersOpen = !filtersOpen);
                            },
                            onCloseFilters: () {
                              setState(() => filtersOpen = false);
                            },
                            filters: buildFilters(),
                            collections: collectionChips,
                            onVoiceSearch: () => unawaited(_openVoiceSearch()),
                            embedInScaffold: false,
                            alphabetRail: _showAlphabetRail
                                ? AlphabetRail(
                                    selected: _selectedAlphabetLetter,
                                    available: _alphabetFirstIndex.keys.toSet(),
                                    onJump: (letter) => unawaited(
                                      _jumpToAlphabetLetter(letter, items),
                                    ),
                                  )
                                : null,
                            content: Column(
                              children: [
                                _continueWatchingCard(),
                                Expanded(child: buildCatalogGrid()),
                              ],
                            ),
                          ),
                  ),
                  if (loading)
                    Positioned.fill(
                      child: _CatalogLoadingModal(
                        phase: catalogPhase,
                        sourceName: catalogSourceName,
                        stepsCompleted: catalogStepsCompleted,
                        stepsTotal: catalogStepsTotal,
                        moviesLoaded: catalogMoviesLoaded,
                        seriesLoaded: catalogSeriesLoaded,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryPickerDialog extends StatefulWidget {
  const _CategoryPickerDialog({required this.groups, required this.maxHeight});

  final List<String> groups;
  final double maxHeight;

  @override
  State<_CategoryPickerDialog> createState() => _CategoryPickerDialogState();
}

class _CategoryPickerDialogState extends State<_CategoryPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? widget.groups
        : widget.groups
              .where((group) => group.toLowerCase().contains(_query))
              .toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: widget.maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Category', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('category-picker-search'),
                controller: _search,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Filter categories',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: Text('No matching categories')),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final group = filtered[index];
                          return ListTile(
                            dense: true,
                            title: Text(group, overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.of(context).pop(group),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plays a cloud DVR recording from the paired Millitop server using the
/// same player as on-demand media (seek, subtitles, resume, full screen).
class DvrRecordingPlayerScreen extends StatelessWidget {
  final int profileId;
  final String title;
  final String? subtitle;
  final String streamUrl;
  const DvrRecordingPlayerScreen({
    super.key,
    required this.profileId,
    required this.title,
    required this.streamUrl,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PlaybackPerformanceSettings>(
      future: HomePreferences()
          .playbackPerformance(profileId)
          .catchError((_) => const PlaybackPerformanceSettings()),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return _MediaPlayerScreen(
          profileKey: 'profile-$profileId',
          title: title,
          subtitle: subtitle,
          streamUrl: streamUrl,
          playbackPerformance: snapshot.data!,
        );
      },
    );
  }
}

class _MovieQueueEntry {
  final String id;
  final String title;
  final String? subtitle;
  final String streamUrl;
  final List<String> streamUrlCandidates;
  final String? posterUrl;
  final String? description;
  final int? year;
  final List<String> genres;
  final DateTime? releaseDate;
  final DateTime? addedAt;

  const _MovieQueueEntry({
    required this.id,
    required this.title,
    this.subtitle,
    required this.streamUrl,
    this.streamUrlCandidates = const <String>[],
    this.posterUrl,
    this.description,
    this.year,
    this.genres = const [],
    this.releaseDate,
    this.addedAt,
  });
}

class _SeriesEpisodeEntry {
  final String id;
  final String title;
  final String streamUrl;
  final int season;
  final int episode;
  final String? posterUrl;
  final String? description;

  const _SeriesEpisodeEntry({
    required this.id,
    required this.title,
    required this.streamUrl,
    required this.season,
    required this.episode,
    this.posterUrl,
    this.description,
  });
}

class _ActivePlaybackMedia {
  final String id;
  final String title;
  final String? subtitle;
  final String streamUrl;
  final List<String> streamUrlCandidates;
  final String? posterUrl;
  final String? description;
  const _ActivePlaybackMedia({
    required this.id,
    required this.title,
    this.subtitle,
    required this.streamUrl,
    this.streamUrlCandidates = const <String>[],
    this.posterUrl,
    this.description,
  });
}

class _MediaPlayerScreen extends StatefulWidget {
  final String profileKey;
  final String title;
  final String? subtitle;
  final String streamUrl;
  final List<String> streamUrlCandidates;
  final String? posterUrl;
  final String? description;
  final PlaybackPerformanceSettings playbackPerformance;
  final String? nextEpisodeStreamUrl;
  final String? nextEpisodeTitle;
  final bool seriesEpisodePlayback;
  final List<_MovieQueueEntry> movieQueue;
  final int movieQueueIndex;
  final List<_SeriesEpisodeEntry> seriesEpisodes;
  final int seriesEpisodeIndex;
  final PlaylistPlaybackSession? mixedSession;
  final String? mixedSessionEntryId;

  /// Set for Jellyfin titles: supplies the real stream URL and reports
  /// progress back to the server. [jellyfinFor] builds one for the next
  /// episode when autoplay advances.
  final JellyfinPlaybackReporter? jellyfin;
  final JellyfinPlaybackReporter? Function(String streamUrl)? jellyfinFor;
  const _MediaPlayerScreen({
    required this.profileKey,
    required this.title,
    this.subtitle,
    required this.streamUrl,
    this.streamUrlCandidates = const <String>[],
    this.posterUrl,
    this.description,
    required this.playbackPerformance,
    this.nextEpisodeStreamUrl,
    this.nextEpisodeTitle,
    this.seriesEpisodePlayback = false,
    this.movieQueue = const <_MovieQueueEntry>[],
    this.movieQueueIndex = 0,
    this.seriesEpisodes = const <_SeriesEpisodeEntry>[],
    this.seriesEpisodeIndex = 0,
    this.jellyfin,
    this.jellyfinFor,
    this.mixedSession,
    this.mixedSessionEntryId,
  });

  @override
  State<_MediaPlayerScreen> createState() => _MediaPlayerScreenState();
}

class _MediaPlayerScreenState extends State<_MediaPlayerScreen>
    with WidgetsBindingObserver {
  final memory = VideoPlaybackMemory();
  final subtitleProviders = const SubtitleProviderService();
  late JellyfinPlaybackReporter? jellyfin = widget.jellyfin;
  Player? player;
  VideoController? video;
  Track selectedTrack = const Track();
  Tracks tracks = const Tracks();
  final subscriptions = <StreamSubscription<dynamic>>[];
  final Stopwatch _sessionWatch = Stopwatch()..start();
  Duration duration = Duration.zero;
  Duration position = Duration.zero;
  bool playing = false;
  bool buffering = false;
  String error = '';
  String statusMessage = '';
  String playbackEngineStatus = 'GPU decode: checking...';
  Timer? playbackStatusTimer;
  Timer? controlsHideTimer;
  bool fullscreen = false;
  bool controlsVisible = true;
  bool autoplayNext = true;
  bool muted = false;
  double volume = 100;
  double preMuteVolume = 100;
  double playbackSpeed = 1.0;
  String subtitleFontFamily = 'Default';
  int seekIncrementSeconds = 10;
  String aspectMode = 'contain';
  String audioOutputProfile = 'auto';
  List<int> bookmarksMs = const <int>[];
  bool pauseHistory = false;
  bool qualityAdaptive = true;
  bool attemptedRecovery = false;
  int? resumePositionMs;
  bool showingResumePrompt = false;
  bool creditsVisible = false;
  bool playNextPromptVisible = false;
  bool playNextPromptDismissed = false;
  int nextMoviePromptRemainingMs = const Duration(minutes: 5).inMilliseconds;
  bool nextEpisodePrompted = false;
  double? scrubPreviewMs;
  int recoveryAttempts = 0;
  bool forceCompatiblePlayback = false;
  bool attemptedCompatibleFallback = false;
  int maxBandwidthKbpsRemote = 4500;
  int maxBandwidthKbpsLocal = 18000;
  String playbackRoute = 'unknown';
  String qualityRoute = 'original';
  String transcodeReason = 'None';
  String outputEnvironment = 'Unknown';
  bool compatibilityProfileApplied = false;
  bool didAutoSelectTracks = false;
  String preferredAudioLanguage = 'en';
  String preferredSubtitleLanguage = 'en';
  bool preferSdh = false;
  bool preferForcedSubtitles = true;
  bool preferAudioDescription = false;
  bool subtitlesEnabled = true;
  bool highContrastInterface = false;
  bool reducedMotion = false;
  double subtitleFontSize = 46;
  double subtitleOpacity = 1.0;
  double subtitlePosition = 92;
  double subtitleDelaySeconds = 0.0;
  double playerTextScale = 1.0;
  Color subtitleForeground = _LiveTvMediaPaint.onSurface;
  Color subtitleBackground = _LiveTvMediaPaint.overlayStrong;
  Color subtitleOutline = _LiveTvMediaPaint.overlayStrong;
  bool spoilerSafeEpisodes = false;
  bool screenReaderHints = true;
  DateTime lastProgressWrite = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? bufferingStartedAtUtc;
  int bufferingEpisodes = 0;
  int bufferingSessionMs = 0;
  late List<_MovieQueueEntry> _movieQueue = List<_MovieQueueEntry>.from(
    widget.movieQueue,
  );
  late int _movieQueueIndex = widget.movieQueueIndex;
  late final List<_SeriesEpisodeEntry> _seriesEpisodes =
      List<_SeriesEpisodeEntry>.from(widget.seriesEpisodes);
  late int _seriesEpisodeIndex = widget.seriesEpisodeIndex;
  int? _episodeBrowseSeason;
  Future<void> _episodeTransitionChain = Future<void>.value();
  bool _episodeTransitionInProgress = false;
  int _playbackSessionId = 0;
  bool _backActionInProgress = false;
  bool _routeExitTriggered = false;
  bool _mixedExitSent = false;
  bool _globalShortcutsSuppressed = false;
  final FocusScopeNode _panelFocusNode = FocusScopeNode();
  late _ActivePlaybackMedia _activeMedia = _initialActiveMedia();
  bool showMovieQueuePanel = false;
  bool showSeriesEpisodesPanel = false;
  bool get _hasMixedSession =>
      widget.mixedSession != null && widget.mixedSessionEntryId != null;
  bool get _hasMovieQueue => _movieQueue.isNotEmpty;
  bool get _hasPreviousMovieQueueItem => _hasMovieQueue && _movieQueueIndex > 0;
  bool get _hasNextMovieQueueItem =>
      _hasMovieQueue && _movieQueueIndex < _movieQueue.length - 1;
  bool get _hasSeriesEpisodes => _seriesEpisodes.isNotEmpty;
  bool get _hasPreviousSeriesEpisode =>
      _hasSeriesEpisodes && _seriesEpisodeIndex > 0;
  bool get _hasNextSeriesEpisode =>
      _hasSeriesEpisodes && _seriesEpisodeIndex < _seriesEpisodes.length - 1;
  bool get _seriesSkipControlsEnabled => widget.seriesEpisodePlayback;
  String? get _nextMovieTitle =>
      _hasNextMovieQueueItem ? _movieQueue[_movieQueueIndex + 1].title : null;
  String? get _nextSeriesEpisodeLabel => _hasNextSeriesEpisode
      ? 'S${_seriesEpisodes[_seriesEpisodeIndex + 1].season}'
            'E${_seriesEpisodes[_seriesEpisodeIndex + 1].episode}'
            ' · ${_seriesEpisodes[_seriesEpisodeIndex + 1].title}'
      : null;
  bool get _showPlayNextOverlay =>
      (((widget.nextEpisodeStreamUrl?.trim().isNotEmpty == true) ||
              (widget.seriesEpisodePlayback && _hasNextSeriesEpisode)) &&
          creditsVisible) ||
      (_hasNextMovieQueueItem && playNextPromptVisible);

  void _exitMixed(PlaylistPlaybackExit exit) {
    if (!mounted || _mixedExitSent) {
      return;
    }
    _mixedExitSent = true;
    Navigator.of(context).pop<Object?>(exit);
  }

  _ActivePlaybackMedia _initialActiveMedia() {
    if (widget.seriesEpisodePlayback && _seriesEpisodes.isNotEmpty) {
      final entry = _seriesEpisodes[_seriesEpisodeIndex];
      return _ActivePlaybackMedia(
        id: entry.id,
        title: widget.title,
        subtitle: 'S${entry.season}E${entry.episode} · ${entry.title}',
        streamUrl: entry.streamUrl,
        streamUrlCandidates: <String>[entry.streamUrl],
        posterUrl: entry.posterUrl ?? widget.posterUrl,
        description: entry.description ?? widget.description,
      );
    }
    if (_movieQueue.isNotEmpty) {
      final entry = _movieQueue[_movieQueueIndex];
      return _ActivePlaybackMedia(
        id: entry.id,
        title: entry.title,
        subtitle: entry.subtitle,
        streamUrl: entry.streamUrl,
        streamUrlCandidates: entry.streamUrlCandidates,
        posterUrl: entry.posterUrl ?? widget.posterUrl,
        description: entry.description ?? widget.description,
      );
    }
    return _ActivePlaybackMedia(
      id: widget.streamUrl,
      title: widget.title,
      subtitle: widget.subtitle,
      streamUrl: widget.streamUrl,
      streamUrlCandidates: widget.streamUrlCandidates,
      posterUrl: widget.posterUrl,
      description: widget.description,
    );
  }

  void _syncActiveMediaFromState() {
    _activeMedia = _initialActiveMedia();
    jellyfin =
        widget.jellyfinFor?.call(_activeMedia.streamUrl) ?? widget.jellyfin;
    _episodeBrowseSeason ??= _hasSeriesEpisodes
        ? _seriesEpisodes[_seriesEpisodeIndex].season
        : null;
  }

  @override
  void initState() {
    super.initState();
    if (_movieQueue.isNotEmpty) {
      _movieQueueIndex = _movieQueueIndex.clamp(0, _movieQueue.length - 1);
    } else {
      _movieQueueIndex = 0;
    }
    if (_seriesEpisodes.isNotEmpty) {
      _seriesEpisodeIndex = _seriesEpisodeIndex.clamp(
        0,
        _seriesEpisodes.length - 1,
      );
    } else {
      _seriesEpisodeIndex = 0;
    }
    _syncActiveMediaFromState();
    FocusManager.instance.addListener(_handleGlobalFocusChanged);
    _handleGlobalFocusChanged();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _finishBufferingTelemetry(aborted: true);
    AppLog.event(
      'media.play',
      props: {
        'title': _activeMedia.title,
        'seconds': _sessionWatch.elapsed.inSeconds,
        'jellyfin': jellyfin != null,
        'route': qualityRoute,
        'hadError': error.isNotEmpty,
        'bufferEpisodes': bufferingEpisodes,
        'bufferMs': bufferingSessionMs,
      },
    );
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_handleGlobalFocusChanged);
    _panelFocusNode.dispose();
    if (fullscreen) {
      unawaited(_setFullscreen(false));
    }
    unawaited(_saveFinalProgress());
    playbackStatusTimer?.cancel();
    controlsHideTimer?.cancel();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    final current = player;
    player = null;
    video = null;
    unawaited(WakelockPlus.disable());
    unawaited(current?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  bool get _isLikelyLiveTvStream {
    final lowerTitle = _activeMedia.title.toLowerCase();
    final lowerUrl = _activeMedia.streamUrl.toLowerCase();
    return lowerUrl.contains('/live/') ||
        lowerUrl.contains('.m3u8') ||
        lowerTitle.contains('live') ||
        lowerTitle.contains('channel');
  }

  Future<void> _emitBufferingStartTelemetry() async {
    if (bufferingStartedAtUtc != null) {
      return;
    }
    bufferingStartedAtUtc = DateTime.now().toUtc();
    bufferingEpisodes += 1;
    AppLog.event(
      'live_tv.buffer.start',
      props: {
        'title': _activeMedia.title,
        'positionMs': position.inMilliseconds,
        'liveTv': _isLikelyLiveTvStream,
        'route': qualityRoute,
        'playbackRoute': playbackRoute,
        'attempts': recoveryAttempts,
        'output': outputEnvironment,
      },
    );
  }

  void _finishBufferingTelemetry({bool aborted = false}) {
    final started = bufferingStartedAtUtc;
    if (started == null) {
      return;
    }
    bufferingStartedAtUtc = null;
    final bufferedMs = DateTime.now()
        .toUtc()
        .difference(started)
        .inMilliseconds;
    if (bufferedMs > 0) {
      bufferingSessionMs += bufferedMs;
    }
    AppLog.event(
      'live_tv.buffer.end',
      props: {
        'title': _activeMedia.title,
        'positionMs': position.inMilliseconds,
        'bufferedMs': bufferedMs,
        'aborted': aborted,
        'liveTv': _isLikelyLiveTvStream,
        'route': qualityRoute,
        'playbackRoute': playbackRoute,
        'attempts': recoveryAttempts,
        'output': outputEnvironment,
      },
    );
    if (_isLikelyLiveTvStream && bufferedMs >= 4000) {
      AppLog.warn(
        LogCategory.playback,
        'Live TV buffering spike',
        details: {
          'title': _activeMedia.title,
          'bufferedMs': bufferedMs,
          'route': qualityRoute,
          'playbackRoute': playbackRoute,
          'output': outputEnvironment,
          'positionMs': position.inMilliseconds,
        },
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final current = player;
      if (current != null && playing) {
        unawaited(current.pause());
      }
      unawaited(_saveProgressSnapshot());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(WakelockPlus.enable());
      if (error.isNotEmpty) {
        unawaited(_attemptStreamRecovery());
      }
      return;
    }
    if (state == AppLifecycleState.detached) {
      unawaited(_saveFinalProgress());
    }
  }

  Future<void> _openWithPolicy(
    Player created, {
    required bool compatibleMode,
    _ActivePlaybackMedia? media,
    JellyfinPlaybackReporter? reporter,
  }) async {
    final targetMedia = media ?? _activeMedia;
    final targetReporter = reporter ?? jellyfin;
    final candidates = targetReporter != null
        ? <String>[targetReporter.playUrl]
        : <String>[...targetMedia.streamUrlCandidates, targetMedia.streamUrl];
    Object? lastError;
    StackTrace? lastStack;
    final watch = Stopwatch()..start();
    var attempt = 0;
    for (final candidate in candidates) {
      attempt++;
      try {
        await created.open(Media(candidate), play: true);
        lastError = null;
        AppLog.info(
          LogCategory.playback,
          'Playback opened "${targetMedia.title}"',
          details: {
            'attempt': attempt,
            'candidates': candidates.length,
            'compatible': compatibleMode,
            'jellyfin': targetReporter != null,
            'ms': watch.elapsedMilliseconds,
          },
        );
        break;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        AppLog.warn(
          LogCategory.playback,
          'Stream candidate $attempt/${candidates.length} failed for '
          '"${targetMedia.title}"',
          error: error,
          details: {'url': candidate},
        );
      }
    }
    if (lastError != null) {
      AppLog.error(
        LogCategory.playback,
        'Could not open "${targetMedia.title}"',
        error: lastError,
        stackTrace: lastStack,
        details: {
          'candidates': candidates.length,
          'compatible': compatibleMode,
        },
      );
      throw lastError;
    }
    if (qualityAdaptive) {
      try {
        await created.setVideoTrack(VideoTrack.auto());
      } catch (_) {}
    }
    if (compatibleMode) {
      try {
        final platform = created.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('hwdec', 'no');
        }
      } catch (_) {}
      await created.setRate(1.0);
    } else {
      await created.setRate(playbackSpeed);
    }
    await created.setVolume(muted ? 0 : volume.clamp(0, 100));
  }

  Future<void> _tryCompatiblePlayback() async {
    final current = player;
    if (current == null) {
      return;
    }
    setState(() {
      statusMessage = 'Trying compatible playback profile...';
      error = '';
    });
    try {
      await _openWithPolicy(current, compatibleMode: true);
      forceCompatiblePlayback = true;
      compatibilityProfileApplied = true;
      await _rememberProvenLimitation('Manual compatible playback recovery');
      await _savePlayerPreferences();
      if (mounted) {
        setState(() {
          playbackSpeed = 1.0;
          qualityRoute = 'compatibility-constrained';
          transcodeReason = 'Compatible playback profile requested manually.';
          statusMessage = 'Compatible playback active.';
        });
      }
      await _applyBandwidthPolicy();
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              'Compatible playback could not start: ${e.toString().replaceFirst('Bad state: ', '')}',
        );
      }
    }
  }

  Future<void> _initialize() async {
    try {
      await _loadPlayerPreferences();
      final prior = await memory.loadProgress(_activeMedia.streamUrl);
      final priorPosition = int.tryParse(prior['positionMs']?.toString() ?? '');
      if (priorPosition != null && priorPosition > 0) {
        resumePositionMs = priorPosition;
      }
      // Jellyfin's resume point wins: it includes progress from other devices.
      final remoteResume = jellyfin?.resumeMs ?? 0;
      if (remoteResume > 0) {
        resumePositionMs = remoteResume;
      }
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
      outputEnvironment = _detectOutputEnvironment();
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
            setState(() {
              position = value;
              final totalMs = duration.inMilliseconds;
              if (totalMs > 0) {
                if (_hasNextMovieQueueItem) {
                  final remainingMs = max(0, totalMs - value.inMilliseconds);
                  if (playNextPromptDismissed) {
                    playNextPromptVisible = false;
                  } else {
                    playNextPromptVisible =
                        remainingMs <= nextMoviePromptRemainingMs;
                  }
                  creditsVisible = false;
                } else {
                  final creditsThreshold = max(
                    0,
                    totalMs - const Duration(seconds: 45).inMilliseconds,
                  );
                  creditsVisible = value.inMilliseconds >= creditsThreshold;
                  playNextPromptVisible = false;
                }
              } else {
                creditsVisible = false;
                playNextPromptVisible = false;
              }
            });
          }
          final now = DateTime.now().toUtc();
          if (now.difference(lastProgressWrite) >= const Duration(seconds: 5)) {
            lastProgressWrite = now;
            unawaited(_saveProgressSnapshot());
          }
        }),
      );
      subscriptions.add(
        created.stream.playing.listen((value) {
          if (mounted) {
            setState(() => playing = value);
            _scheduleControlsAutoHide();
          }
        }),
      );
      subscriptions.add(
        created.stream.buffering.listen((value) {
          if (value) {
            unawaited(_emitBufferingStartTelemetry());
          } else {
            _finishBufferingTelemetry();
          }
          if (mounted) {
            setState(() => buffering = value);
            _scheduleControlsAutoHide();
          }
        }),
      );
      subscriptions.add(
        created.stream.volume.listen((value) {
          if (mounted) {
            setState(() {
              volume = value;
              muted = value <= 0.0001;
            });
          } else {
            volume = value;
            muted = value <= 0.0001;
          }
        }),
      );
      subscriptions.add(
        created.stream.tracks.listen((value) {
          if (mounted) {
            setState(() => tracks = value);
            if (!compatibilityProfileApplied) {
              compatibilityProfileApplied = true;
              unawaited(_applyBandwidthPolicy());
            }
            unawaited(_autoSelectCompatibleTracks());
          }
        }),
      );
      subscriptions.add(
        created.stream.error.listen((message) {
          AppLog.error(
            LogCategory.playback,
            'Player error during "${_activeMedia.title}"',
            error: message,
            details: {'route': qualityRoute},
          );
          if (mounted) {
            setState(
              () => error =
                  'Playback encountered an error. Attempting recovery with current profile...',
            );
          }
          unawaited(_attemptStreamRecovery());
        }),
      );
      subscriptions.add(
        created.stream.completed.listen((done) {
          if (!done) {
            return;
          }
          unawaited(_handlePlaybackCompleted());
        }),
      );
      await _openWithPolicy(created, compatibleMode: forceCompatiblePlayback);
      compatibilityProfileApplied = forceCompatiblePlayback;
      if (forceCompatiblePlayback) {
        qualityRoute = 'compatibility-constrained';
        transcodeReason = 'Proven device limitation for this stream host.';
      } else {
        qualityRoute = 'original';
      }
      await WakelockPlus.enable();
      await _applySubtitleRenderingPreferences();
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
      _scheduleControlsAutoHide();
      unawaited(_offerResumeIfAvailable());
    } catch (e) {
      if (!attemptedCompatibleFallback) {
        attemptedCompatibleFallback = true;
        forceCompatiblePlayback = true;
        await _rememberProvenLimitation('Automatic compatible fallback');
        await _initialize();
        return;
      }
      if (mounted) {
        final detail = e.toString().replaceFirst('Bad state: ', '');
        setState(
          () => error =
              'Playback could not start. $detail\n'
              'Reason: unsupported codec/container, network denial, or provider restrictions.\n'
              'Use "Try compatible playback" to force safe decode.',
        );
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

  bool _isLocalAddress(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower == '127.0.0.1' || lower == '::1') {
      return true;
    }
    if (lower.startsWith('10.') || lower.startsWith('192.168.')) {
      return true;
    }
    final octets = lower.split('.');
    final secondOctet = octets.length > 1 ? int.tryParse(octets[1]) : null;
    if (lower.startsWith('172.') &&
        secondOctet != null &&
        secondOctet >= 16 &&
        secondOctet <= 31) {
      return true;
    }
    return false;
  }

  String get _effectiveStreamUrl => jellyfin?.playUrl ?? _activeMedia.streamUrl;

  String _streamHost() {
    final uri = Uri.tryParse(_effectiveStreamUrl);
    return uri?.host.toLowerCase() ?? '';
  }

  int _maxBandwidthKbpsForCurrentRoute() {
    final uri = Uri.tryParse(_effectiveStreamUrl);
    final host = uri?.host ?? '';
    final local = host.isNotEmpty && _isLocalAddress(host);
    playbackRoute = local ? 'local-network' : 'remote-streaming';
    return local ? maxBandwidthKbpsLocal : maxBandwidthKbpsRemote;
  }

  String _detectOutputEnvironment() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return fullscreen
          ? 'Android fullscreen output'
          : 'Android embedded output';
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'iOS output';
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return fullscreen
          ? 'Windows fullscreen output'
          : 'Windows windowed output';
    }
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return fullscreen ? 'Linux fullscreen output' : 'Linux windowed output';
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return fullscreen ? 'macOS fullscreen output' : 'macOS windowed output';
    }
    return 'Generic output';
  }

  String _promisedSubtitleFormats() {
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return 'SRT, ASS/SSA, WebVTT (backend/decoder dependent)';
    }
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return 'SRT, WebVTT (ASS/SSA depends on decoder build)';
    }
    return 'SRT, WebVTT';
  }

  Future<void> _rememberProvenLimitation(String reason) async {
    final prefs = await memory.loadPrefs(widget.profileKey);
    final host = _streamHost();
    if (host.isEmpty) {
      return;
    }
    final prior = prefs['provenCompatibleHosts'];
    final values = <String>{
      if (prior is List)
        ...prior
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty),
      host,
    };
    prefs['provenCompatibleHosts'] = values.toList();
    prefs['lastCompatibilityReason'] = reason;
    await memory.savePrefs(widget.profileKey, prefs);
  }

  String _langLabel(String? value) {
    final code = (value ?? '').trim().toLowerCase();
    if (code.isEmpty || code == 'und' || code == 'unknown') {
      return 'Unknown';
    }

    switch (code) {
      case 'en':
      case 'eng':
        return 'English';
      case 'es':
      case 'spa':
        return 'Spanish';
      case 'fr':
      case 'fra':
        return 'French';
      case 'de':
      case 'ger':
      case 'deu':
        return 'German';
      default:
        return code.toUpperCase();
    }
  }

  String _subtitleTrackTitle(SubtitleTrack track, int index) {
    final title = (track.title ?? '').trim();
    final lower = title.toLowerCase();
    if (title.isNotEmpty &&
        !lower.contains('unnamed subtitle') &&
        lower != 'subtitle' &&
        lower != 'track') {
      return title;
    }
    final language = _langLabel(track.language);
    final kind = _trackKindLabel(title);
    if (kind == 'Standard') {
      return '$language subtitle ${index + 1}';
    }
    return '$language $kind ${index + 1}';
  }

  String _movieQueueMetadata(_MovieQueueEntry entry) {
    final parts = <String>[];
    if (entry.year != null) {
      parts.add('${entry.year}');
    } else if (entry.releaseDate != null) {
      parts.add('${entry.releaseDate!.year}');
    }
    if (entry.genres.isNotEmpty) {
      parts.add(entry.genres.take(2).join(' · '));
    }
    if (entry.subtitle != null && entry.subtitle!.trim().isNotEmpty) {
      parts.add(entry.subtitle!.trim());
    }
    if (parts.isEmpty) {
      return 'Metadata not available';
    }
    return parts.join(' • ');
  }

  String _currentTopMetaLine() {
    if (widget.seriesEpisodePlayback && _hasSeriesEpisodes) {
      final entry = _seriesEpisodes[_seriesEpisodeIndex];
      return 'S${entry.season}E${entry.episode} · ${entry.title}';
    }
    if (_movieQueue.isNotEmpty) {
      return _movieQueueMetadata(_movieQueue[_movieQueueIndex]);
    }
    return _activeMedia.subtitle?.trim().isNotEmpty == true
        ? _activeMedia.subtitle!.trim()
        : 'Now playing';
  }

  String? _currentTopDescription() {
    if (widget.seriesEpisodePlayback && _hasSeriesEpisodes) {
      return _seriesEpisodes[_seriesEpisodeIndex].description;
    }
    if (_movieQueue.isNotEmpty) {
      return _movieQueue[_movieQueueIndex].description;
    }
    return _activeMedia.description;
  }

  String? _currentTopPosterUrl() {
    if (widget.seriesEpisodePlayback && _hasSeriesEpisodes) {
      return _seriesEpisodes[_seriesEpisodeIndex].posterUrl;
    }
    if (_movieQueue.isNotEmpty) {
      return _movieQueue[_movieQueueIndex].posterUrl;
    }
    return _activeMedia.posterUrl;
  }

  String _trackKindLabel(String title) {
    final lower = title.toLowerCase();
    final flags = <String>[];
    if (lower.contains('forced')) {
      flags.add('Forced');
    }
    if (lower.contains('sdh') ||
        lower.contains('cc') ||
        lower.contains('closed caption')) {
      flags.add('SDH/CC');
    }
    if (lower.contains('commentary')) {
      flags.add('Commentary');
    }
    if (lower.contains('descriptive') || lower.contains('audio description')) {
      flags.add('Audio description');
    }
    if (flags.isEmpty) {
      return 'Standard';
    }
    return flags.join(' · ');
  }

  String _toMpvHex(Color color, {double opacity = 1.0}) {
    final a = (opacity.clamp(0.0, 1.0) * 255).round().clamp(0, 255);
    final r = color.red;
    final g = color.green;
    final b = color.blue;
    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    return '#${hex(r)}${hex(g)}${hex(b)}${hex(a)}';
  }

  Future<void> _applySubtitleRenderingPreferences() async {
    final current = player;
    if (current == null) {
      return;
    }
    final platform = current.platform;
    if (platform is! NativePlayer) {
      return;
    }
    try {
      await platform.setProperty(
        'sub-font-size',
        subtitleFontSize.toStringAsFixed(0),
      );
      await platform.setProperty(
        'sub-font',
        subtitleFontFamily == 'Default' ? '' : subtitleFontFamily,
      );
      await platform.setProperty(
        'sub-color',
        _toMpvHex(subtitleForeground, opacity: subtitleOpacity),
      );
      await platform.setProperty(
        'sub-back-color',
        _toMpvHex(subtitleBackground, opacity: subtitleOpacity),
      );
      await platform.setProperty(
        'sub-border-color',
        _toMpvHex(subtitleOutline, opacity: subtitleOpacity),
      );
      await platform.setProperty(
        'sub-pos',
        subtitlePosition.toStringAsFixed(0),
      );
      await platform.setProperty(
        'sub-delay',
        subtitleDelaySeconds.toStringAsFixed(2),
      );
      await platform.setProperty(
        'sub-shadow-offset',
        reducedMotion ? '0' : '1',
      );
      await platform.setProperty('sub-ass-override', 'force');
    } catch (_) {}
  }

  Future<void> _toggleSubtitles(bool value) async {
    final current = player;
    if (current == null) {
      return;
    }
    try {
      if (!value) {
        await current.setSubtitleTrack(SubtitleTrack.no());
      } else if (tracks.subtitle.isNotEmpty) {
        await _selectSubtitleByPolicy();
      }
      if (mounted) {
        setState(() => subtitlesEnabled = value);
      } else {
        subtitlesEnabled = value;
      }
      await _savePlayerPreferences();
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'Subtitles could not be changed for this stream.';
        });
      }
    }
  }

  Future<void> _applyBandwidthPolicy() async {
    final current = player;
    if (current == null || tracks.video.isEmpty) {
      return;
    }
    final limitKbps = _maxBandwidthKbpsForCurrentRoute();
    if (!qualityAdaptive) {
      qualityRoute = 'manual';
      return;
    }
    VideoTrack? best;
    var bestScore = -1;
    final widthPattern = RegExp(r'(\d{3,4})p', caseSensitive: false);
    final kbpsPattern = RegExp(r'(\d{3,6})\s?kbps', caseSensitive: false);
    for (final track in tracks.video) {
      final label = '${track.title ?? ''} ${track.language ?? ''}'
          .toLowerCase();
      final width = int.tryParse(
        widthPattern.firstMatch(label)?.group(1) ?? '',
      );
      final kbps = int.tryParse(kbpsPattern.firstMatch(label)?.group(1) ?? '');
      final score = kbps ?? ((width ?? 0) * 8);
      if (score <= limitKbps && score > bestScore) {
        bestScore = score;
        best = track;
      }
    }
    if (best != null) {
      await current.setVideoTrack(best);
      qualityRoute = best == selectedTrack.video
          ? 'original'
          : 'compatibility-constrained';
      if (qualityRoute == 'compatibility-constrained') {
        transcodeReason =
            'Bandwidth policy ($playbackRoute <= ${limitKbps}kbps) selected a lower compatible quality.';
      }
    } else {
      qualityRoute = 'original';
      transcodeReason = 'No constrained profile matched; original stream used.';
    }
  }

  Future<void> _autoSelectCompatibleTracks() async {
    if (didAutoSelectTracks) {
      return;
    }
    didAutoSelectTracks = true;
    await _selectAudioByPolicy();
    if (subtitlesEnabled) {
      await _selectSubtitleByPolicy();
    }
  }

  Future<void> _selectAudioByPolicy() async {
    final current = player;
    if (current == null || tracks.audio.isEmpty) {
      return;
    }
    final byLanguage = tracks.audio.where((track) {
      final lang = (track.language ?? '').toLowerCase();
      return lang.contains(preferredAudioLanguage.toLowerCase());
    }).toList();
    AudioTrack chosen = byLanguage.isNotEmpty
        ? byLanguage.first
        : tracks.audio.first;
    if (preferAudioDescription) {
      for (final track in byLanguage.isNotEmpty ? byLanguage : tracks.audio) {
        if (_trackKindLabel(
          track.title ?? '',
        ).toLowerCase().contains('audio description')) {
          chosen = track;
          break;
        }
      }
    }
    await current.setAudioTrack(chosen);
    if (mounted) {
      setState(
        () => statusMessage =
            'Audio selected: ${_langLabel(chosen.language)} · ${_trackKindLabel(chosen.title ?? '')}',
      );
    }
  }

  Future<void> _selectSubtitleByPolicy() async {
    final current = player;
    if (current == null || tracks.subtitle.isEmpty) {
      return;
    }
    SubtitleTrack? forced;
    SubtitleTrack? sdh;
    SubtitleTrack? language;
    for (final track in tracks.subtitle) {
      final title = track.title ?? '';
      final lower = title.toLowerCase();
      final lang = (track.language ?? '').toLowerCase();
      if (forced == null && lower.contains('forced')) {
        forced = track;
      }
      if (sdh == null &&
          (lower.contains('sdh') ||
              lower.contains('cc') ||
              lower.contains('closed caption'))) {
        sdh = track;
      }
      if (language == null &&
          lang.contains(preferredSubtitleLanguage.toLowerCase())) {
        language = track;
      }
    }
    SubtitleTrack? chosen;
    if (preferForcedSubtitles) {
      chosen = forced;
    }
    if (chosen == null && preferSdh) {
      chosen = sdh;
    }
    chosen ??= language;
    if (chosen == null) {
      chosen = tracks.subtitle.first;
      if (mounted) {
        setState(
          () => statusMessage =
              'No subtitle matched your policy; safe default selected.',
        );
      }
    }
    final chosenTrack = chosen;
    await current.setSubtitleTrack(chosenTrack);
    if (mounted) {
      setState(
        () => statusMessage =
            'Subtitle selected: ${_langLabel(chosenTrack.language)} · ${_trackKindLabel(chosenTrack.title ?? '')}',
      );
    }
  }

  Future<void> _loadPlayerPreferences() async {
    final prefs = await memory.loadPrefs(widget.profileKey);
    final profileId = int.tryParse(
      widget.profileKey.replaceFirst('profile-', ''),
    );
    Map<String, dynamic> defaults = const {};
    if (profileId != null) {
      try {
        defaults = await HomePreferences().liveTvPlayerDefaults(profileId);
      } catch (_) {}
    }
    seekIncrementSeconds =
        int.tryParse(prefs['seekIncrementSeconds']?.toString() ?? '') ?? 10;
    if (seekIncrementSeconds < 5) {
      seekIncrementSeconds = 5;
    }
    if (seekIncrementSeconds > 60) {
      seekIncrementSeconds = 60;
    }
    autoplayNext = prefs['autoplayNext'] != false;
    qualityAdaptive = prefs['qualityAdaptive'] != false;
    pauseHistory = prefs['pauseHistory'] == true;
    aspectMode = prefs['aspectMode']?.toString() ?? 'contain';
    audioOutputProfile = prefs['audioOutputProfile']?.toString() ?? 'auto';
    preferredAudioLanguage =
        prefs['preferredAudioLanguage']?.toString() ?? 'en';
    preferredSubtitleLanguage =
        prefs['preferredSubtitleLanguage']?.toString() ?? 'en';
    preferSdh = prefs['preferSdh'] == true;
    preferForcedSubtitles = prefs['preferForcedSubtitles'] != false;
    preferAudioDescription = prefs['preferAudioDescription'] == true;
    subtitlesEnabled = prefs['subtitlesEnabled'] != false;
    highContrastInterface = prefs['highContrastInterface'] == true;
    reducedMotion = prefs['reducedMotion'] == true;
    spoilerSafeEpisodes = prefs['spoilerSafeEpisodes'] == true;
    screenReaderHints = prefs['screenReaderHints'] != false;
    subtitleFontSize =
        double.tryParse(prefs['subtitleFontSize']?.toString() ?? '') ?? 46;
    subtitleOpacity =
        double.tryParse(prefs['subtitleOpacity']?.toString() ?? '') ?? 1.0;
    subtitlePosition =
        double.tryParse(prefs['subtitlePosition']?.toString() ?? '') ?? 92;
    subtitleDelaySeconds =
        double.tryParse(prefs['subtitleDelaySeconds']?.toString() ?? '') ?? 0.0;
    subtitleFontFamily =
        prefs['subtitleFontFamily']?.toString().trim().isNotEmpty == true
        ? prefs['subtitleFontFamily'].toString().trim()
        : 'Default';
    playerTextScale =
        double.tryParse(prefs['playerTextScale']?.toString() ?? '') ?? 1.0;
    subtitleForeground = Color(
      int.tryParse(prefs['subtitleForeground']?.toString() ?? '') ??
          _LiveTvMediaPaint.onSurface.value,
    );
    subtitleBackground = Color(
      int.tryParse(prefs['subtitleBackground']?.toString() ?? '') ??
          _LiveTvMediaPaint.overlayStrong.value,
    );
    subtitleOutline = Color(
      int.tryParse(prefs['subtitleOutline']?.toString() ?? '') ??
          _LiveTvMediaPaint.overlayStrong.value,
    );
    maxBandwidthKbpsRemote =
        int.tryParse(prefs['maxBandwidthKbpsRemote']?.toString() ?? '') ?? 4500;
    maxBandwidthKbpsLocal =
        int.tryParse(prefs['maxBandwidthKbpsLocal']?.toString() ?? '') ?? 18000;
    final defaultRemote = int.tryParse(
      defaults['maxBandwidthKbpsRemote']?.toString() ?? '',
    );
    final defaultLocal = int.tryParse(
      defaults['maxBandwidthKbpsLocal']?.toString() ?? '',
    );
    if (defaultRemote != null && defaultRemote >= 1200) {
      maxBandwidthKbpsRemote = defaultRemote;
    }
    if (defaultLocal != null && defaultLocal >= maxBandwidthKbpsRemote) {
      maxBandwidthKbpsLocal = defaultLocal;
    }
    final defaultFont = defaults['subtitleFontFamily']?.toString().trim() ?? '';
    if (defaultFont.isNotEmpty) {
      subtitleFontFamily = defaultFont;
    }
    final defaultFontSize = double.tryParse(
      defaults['subtitleFontSize']?.toString() ?? '',
    );
    if (defaultFontSize != null &&
        defaultFontSize >= 26 &&
        defaultFontSize <= 82) {
      subtitleFontSize = defaultFontSize;
    }
    final defaultOffset = double.tryParse(
      defaults['subtitleDelaySeconds']?.toString() ?? '',
    );
    if (defaultOffset != null && defaultOffset >= -10 && defaultOffset <= 10) {
      subtitleDelaySeconds = defaultOffset;
    }
    final defaultOpacity = double.tryParse(
      defaults['subtitleOpacity']?.toString() ?? '',
    );
    if (defaultOpacity != null &&
        defaultOpacity >= 0.2 &&
        defaultOpacity <= 1.0) {
      subtitleOpacity = defaultOpacity;
    }
    final defaultPosition = double.tryParse(
      defaults['subtitlePosition']?.toString() ?? '',
    );
    if (defaultPosition != null &&
        defaultPosition >= 10 &&
        defaultPosition <= 100) {
      subtitlePosition = defaultPosition;
    }
    final defaultForeground = int.tryParse(
      defaults['subtitleForeground']?.toString() ?? '',
    );
    if (defaultForeground != null) {
      subtitleForeground = Color(defaultForeground);
    }
    final defaultBackground = int.tryParse(
      defaults['subtitleBackground']?.toString() ?? '',
    );
    if (defaultBackground != null) {
      subtitleBackground = Color(defaultBackground);
    }
    final defaultOutline = int.tryParse(
      defaults['subtitleOutline']?.toString() ?? '',
    );
    if (defaultOutline != null) {
      subtitleOutline = Color(defaultOutline);
    }
    if (maxBandwidthKbpsRemote < 1200) {
      maxBandwidthKbpsRemote = 1200;
    }
    if (maxBandwidthKbpsLocal < maxBandwidthKbpsRemote) {
      maxBandwidthKbpsLocal = maxBandwidthKbpsRemote;
    }
    final provenHosts = prefs['provenCompatibleHosts'];
    final host = _streamHost();
    forceCompatiblePlayback =
        provenHosts is List &&
        host.isNotEmpty &&
        provenHosts.map((item) => item.toString().toLowerCase()).contains(host);
    final speed = double.tryParse(prefs['playbackSpeed']?.toString() ?? '');
    if (speed != null && speed >= 0.5 && speed <= 2.0) {
      playbackSpeed = speed;
    }
    bookmarksMs = await memory.loadBookmarks(_activeMedia.streamUrl);
  }

  Future<void> _savePlayerPreferences() async {
    await memory.savePrefs(widget.profileKey, {
      'seekIncrementSeconds': seekIncrementSeconds,
      'autoplayNext': autoplayNext,
      'qualityAdaptive': qualityAdaptive,
      'pauseHistory': pauseHistory,
      'aspectMode': aspectMode,
      'audioOutputProfile': audioOutputProfile,
      'preferredAudioLanguage': preferredAudioLanguage,
      'preferredSubtitleLanguage': preferredSubtitleLanguage,
      'preferSdh': preferSdh,
      'preferForcedSubtitles': preferForcedSubtitles,
      'preferAudioDescription': preferAudioDescription,
      'subtitlesEnabled': subtitlesEnabled,
      'highContrastInterface': highContrastInterface,
      'reducedMotion': reducedMotion,
      'spoilerSafeEpisodes': spoilerSafeEpisodes,
      'screenReaderHints': screenReaderHints,
      'subtitleFontSize': subtitleFontSize,
      'subtitleOpacity': subtitleOpacity,
      'subtitlePosition': subtitlePosition,
      'subtitleDelaySeconds': subtitleDelaySeconds,
      'subtitleFontFamily': subtitleFontFamily,
      'playerTextScale': playerTextScale,
      'subtitleForeground': subtitleForeground.value,
      'subtitleBackground': subtitleBackground.value,
      'subtitleOutline': subtitleOutline.value,
      'maxBandwidthKbpsRemote': maxBandwidthKbpsRemote,
      'maxBandwidthKbpsLocal': maxBandwidthKbpsLocal,
      'playbackSpeed': playbackSpeed,
    });
  }

  Future<void> _saveProgressSnapshot({
    _ActivePlaybackMedia? media,
    JellyfinPlaybackReporter? reporter,
    int? sessionId,
    bool allowDuringTransition = false,
  }) async {
    if (_episodeTransitionInProgress &&
        !allowDuringTransition &&
        media == null) {
      return;
    }
    final targetMedia = media ?? _activeMedia;
    final targetReporter = reporter ?? jellyfin;
    final targetSessionId = sessionId ?? _playbackSessionId;
    if (pauseHistory) {
      return;
    }
    if (targetSessionId != _playbackSessionId && media == null) {
      return;
    }
    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;
    final complete =
        durationMs > 0 &&
        positionMs >= (durationMs - const Duration(seconds: 8).inMilliseconds);
    if (positionMs > 0) {
      targetReporter?.progress(positionMs, paused: !playing);
    }
    await memory.saveProgress(
      targetMedia.streamUrl,
      positionMs: positionMs,
      durationMs: durationMs,
      complete: complete,
    );
    await memory.appendStatsEvent(
      widget.profileKey,
      type: 'progress',
      payload: {
        'streamUrl': targetMedia.streamUrl,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'buffering': buffering,
        'sessionId': targetSessionId,
      },
    );
  }

  Future<void> _saveFinalProgress({
    _ActivePlaybackMedia? media,
    JellyfinPlaybackReporter? reporter,
    int? sessionId,
    bool allowDuringTransition = false,
  }) async {
    final targetMedia = media ?? _activeMedia;
    final targetReporter = reporter ?? jellyfin;
    final targetSessionId = sessionId ?? _playbackSessionId;
    try {
      await _saveProgressSnapshot(
        media: targetMedia,
        reporter: targetReporter,
        sessionId: targetSessionId,
        allowDuringTransition: allowDuringTransition,
      );
      await targetReporter?.stopped(position.inMilliseconds);
      await memory.appendStatsEvent(
        widget.profileKey,
        type: 'final_progress',
        payload: {
          'streamUrl': targetMedia.streamUrl,
          'positionMs': position.inMilliseconds,
          'durationMs': duration.inMilliseconds,
          'title': targetMedia.title,
          'sessionId': targetSessionId,
        },
      );
    } catch (_) {}
  }

  Future<void> _offerResumeIfAvailable() async {
    if (showingResumePrompt) {
      return;
    }
    final current = player;
    if (!mounted || current == null) {
      return;
    }
    final resumeMs = resumePositionMs;
    if (resumeMs == null || resumeMs <= 15000) {
      return;
    }
    if (duration.inMilliseconds > 0 &&
        resumeMs >=
            duration.inMilliseconds -
                const Duration(seconds: 12).inMilliseconds) {
      return;
    }
    showingResumePrompt = true;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resume playback'),
        content: Text(
          'Resume from ${_clockText(Duration(milliseconds: resumeMs))} or restart from beginning?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'restart'),
            child: const Text('Restart'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'resume'),
            child: const Text('Resume'),
          ),
        ],
      ),
    );
    showingResumePrompt = false;
    if (!mounted || action == null) {
      return;
    }
    if (action == 'resume') {
      await current.seek(Duration(milliseconds: resumeMs));
    } else {
      await current.seek(Duration.zero);
    }
  }

  Future<void> _attemptStreamRecovery() async {
    if (attemptedRecovery) {
      return;
    }
    final current = player;
    if (current == null) {
      return;
    }
    attemptedRecovery = true;
    recoveryAttempts += 1;
    if (recoveryAttempts > 3) {
      attemptedRecovery = false;
      if (mounted) {
        setState(
          () => error =
              'Automatic recovery stopped to avoid restart loops. Use "Try compatible playback" or Retry.',
        );
      }
      await _rememberProvenLimitation('Recovery loop guard engaged');
      return;
    }
    final resumeMs = position.inMilliseconds;
    try {
      await _openWithPolicy(current, compatibleMode: forceCompatiblePlayback);
      if (resumeMs > 0) {
        await current.seek(Duration(milliseconds: resumeMs));
      }
      recoveryAttempts = 0;
      if (mounted) {
        setState(() => error = '');
      } else {
        error = '';
      }
    } catch (_) {
      if (recoveryAttempts < 3) {
        Future<void>.delayed(const Duration(seconds: 2), () async {
          if (!mounted || player == null) {
            return;
          }
          await _attemptStreamRecovery();
        });
      }
      if (mounted) {
        setState(
          () =>
              error = 'Playback could not recover automatically. Please retry.',
        );
      } else {
        error = 'Playback could not recover automatically. Please retry.';
      }
    } finally {
      attemptedRecovery = false;
    }
  }

  Future<void> _handlePlaybackCompleted({bool force = false}) async {
    await _saveFinalProgress();
    if (_hasMixedSession) {
      final session = widget.mixedSession!;
      final current = session.current;
      if (current == null || current.entryId != widget.mixedSessionEntryId) {
        return;
      }
      if (!session.autoplay && !force) {
        return;
      }
      if (!mounted) {
        return;
      }
      _exitMixed(const PlaylistPlaybackExit.completed());
      return;
    }
    if (!autoplayNext && !force) {
      return;
    }
    if (widget.seriesEpisodePlayback && _hasNextSeriesEpisode) {
      await _openSeriesEpisodeAt(
        _seriesEpisodeIndex + 1,
        status: _nextSeriesEpisodeLabel == null
            ? 'Starting next episode...'
            : 'Starting $_nextSeriesEpisodeLabel...',
        autoplayed: true,
      );
      return;
    }
    final nextStream = widget.nextEpisodeStreamUrl?.trim();
    if (nextStream == null || nextStream.isEmpty) {
      if (_hasNextMovieQueueItem) {
        await _openMovieQueueItem(
          _movieQueueIndex + 1,
          status: _nextMovieTitle == null
              ? 'Starting next movie...'
              : 'Starting $_nextMovieTitle...',
        );
      }
      return;
    }
    if (nextEpisodePrompted) {
      return;
    }
    nextEpisodePrompted = true;
    if (mounted) {
      setState(() {
        statusMessage = widget.nextEpisodeTitle == null
            ? 'Starting next episode...'
            : 'Starting ${widget.nextEpisodeTitle}...';
      });
    }
    final current = player;
    if (current == null) {
      nextEpisodePrompted = false;
      return;
    }
    jellyfin = widget.jellyfinFor?.call(nextStream);
    await current.open(Media(jellyfin?.playUrl ?? nextStream), play: true);
    resumePositionMs = 0;
    nextEpisodePrompted = false;
    if (mounted) {
      setState(() {
        error = '';
        creditsVisible = false;
      });
    }
    await memory.saveProgress(
      nextStream,
      positionMs: 0,
      durationMs: 0,
      complete: false,
    );
  }

  Future<void> _openMovieQueueItem(int index, {String? status}) async {
    if (!_hasMovieQueue || index < 0 || index >= _movieQueue.length) {
      return;
    }
    final entry = _movieQueue[index];
    await _saveFinalProgress();
    if (!mounted) {
      return;
    }
    if (status != null && status.trim().isNotEmpty) {
      setState(() => statusMessage = status);
    }
    await Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(
        builder: (_) => _MediaPlayerScreen(
          profileKey: widget.profileKey,
          title: entry.title,
          subtitle: entry.subtitle,
          streamUrl: entry.streamUrl,
          streamUrlCandidates: entry.streamUrlCandidates,
          posterUrl: entry.posterUrl,
          description: entry.description,
          playbackPerformance: widget.playbackPerformance,
          seriesEpisodePlayback: false,
          movieQueue: _movieQueue,
          movieQueueIndex: index,
          jellyfin: widget.jellyfinFor?.call(entry.streamUrl),
          jellyfinFor: widget.jellyfinFor,
        ),
      ),
    );
  }

  Future<void> _openMovieQueue() async {
    Future<void> showDetails(_MovieQueueEntry entry, int index) async {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (detailsCtx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    style: Theme.of(detailsCtx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _movieQueueMetadata(entry),
                    style: Theme.of(detailsCtx).textTheme.bodySmall,
                  ),
                  if (entry.releaseDate != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Released ${entry.releaseDate!.toLocal().toString().split(' ').first}',
                      style: Theme.of(detailsCtx).textTheme.bodySmall,
                    ),
                  ],
                  if (entry.addedAt != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Added ${entry.addedAt!.toLocal().toString().split(' ').first}',
                      style: Theme.of(detailsCtx).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (entry.description?.trim().isNotEmpty == true)
                    Text(entry.description!.trim())
                  else
                    const Text('No description available for this movie.'),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          Navigator.pop(detailsCtx);
                          await _openMovieQueueItem(index);
                        },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play now'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          _queueMovieForPlayNext(index);
                          Navigator.pop(detailsCtx);
                        },
                        icon: const Icon(Icons.playlist_play),
                        label: const Text('Play next'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            ListTile(
              title: Text(
                'Movie queue (${_movieQueue.length})',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('Shuffled order • premium metadata'),
            ),
            for (var i = 0; i < _movieQueue.length; i++)
              ListTile(
                leading: _movieQueue[i].posterUrl?.trim().isNotEmpty == true
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(
                          _movieQueue[i].posterUrl!,
                          width: 42,
                          height: 62,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(
                            i == _movieQueueIndex
                                ? Icons.play_arrow
                                : Icons.movie_outlined,
                          ),
                        ),
                      )
                    : Icon(
                        i == _movieQueueIndex
                            ? Icons.play_arrow
                            : Icons.movie_outlined,
                      ),
                title: Text(_movieQueue[i].title),
                subtitle: Text(
                  _movieQueueMetadata(_movieQueue[i]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: i == _movieQueueIndex,
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Play next',
                      onPressed: i == _movieQueueIndex
                          ? null
                          : () => _queueMovieForPlayNext(i),
                      icon: const Icon(Icons.playlist_play),
                    ),
                    IconButton(
                      tooltip: 'Details',
                      onPressed: () =>
                          unawaited(showDetails(_movieQueue[i], i)),
                      icon: const Icon(Icons.info_outline),
                    ),
                  ],
                ),
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected == _movieQueueIndex) {
      return;
    }
    await _openMovieQueueItem(selected);
  }

  void _queueMovieForPlayNext(int index) {
    if (!_hasMovieQueue ||
        index < 0 ||
        index >= _movieQueue.length ||
        index == _movieQueueIndex) {
      return;
    }
    final target = _movieQueue[index];
    final reordered = List<_MovieQueueEntry>.from(_movieQueue)
      ..removeAt(index)
      ..insert(_movieQueueIndex + 1, target);
    setState(() {
      _movieQueue = reordered;
      statusMessage = 'Queued "${target.title}" to play next.';
    });
  }

  Future<void> _openSeriesEpisodeAt(
    int index, {
    String? status,
    bool autoplayed = false,
  }) async {
    _episodeTransitionChain = _episodeTransitionChain
        .then((_) async {
          if (!_hasSeriesEpisodes ||
              index < 0 ||
              index >= _seriesEpisodes.length ||
              player == null) {
            return;
          }
          if (_episodeTransitionInProgress) {
            return;
          }
          _episodeTransitionInProgress = true;
          final outgoingMedia = _activeMedia;
          final outgoingReporter = jellyfin;
          final outgoingSession = _playbackSessionId;
          final entry = _seriesEpisodes[index];
          await _saveFinalProgress(
            media: outgoingMedia,
            reporter: outgoingReporter,
            sessionId: outgoingSession,
            allowDuringTransition: true,
          );
          if (mounted && status != null && status.trim().isNotEmpty) {
            setState(() => statusMessage = status);
          }
          final incomingMedia = _ActivePlaybackMedia(
            id: entry.id,
            title: widget.title,
            subtitle: 'S${entry.season}E${entry.episode} · ${entry.title}',
            streamUrl: entry.streamUrl,
            streamUrlCandidates: <String>[entry.streamUrl],
            posterUrl: entry.posterUrl ?? widget.posterUrl,
            description: entry.description ?? widget.description,
          );
          final incomingReporter = widget.jellyfinFor?.call(entry.streamUrl);
          var incomingResumeMs = incomingReporter?.resumeMs;
          if (incomingResumeMs == null || incomingResumeMs <= 0) {
            final prior = await memory.loadProgress(incomingMedia.streamUrl);
            incomingResumeMs = int.tryParse(
              prior['positionMs']?.toString() ?? '',
            );
          }
          await _openWithPolicy(
            player!,
            compatibleMode: forceCompatiblePlayback,
            media: incomingMedia,
            reporter: incomingReporter,
          );
          if (incomingResumeMs != null && incomingResumeMs > 0) {
            await player!.seek(Duration(milliseconds: incomingResumeMs));
          }
          if (!mounted) {
            _activeMedia = incomingMedia;
            jellyfin = incomingReporter;
            _seriesEpisodeIndex = index;
            _episodeBrowseSeason = entry.season;
            _playbackSessionId += 1;
          } else {
            setState(() {
              _activeMedia = incomingMedia;
              jellyfin = incomingReporter;
              _seriesEpisodeIndex = index;
              _episodeBrowseSeason = entry.season;
              _playbackSessionId += 1;
              if (autoplayed) {
                showSeriesEpisodesPanel = false;
              }
              error = '';
              creditsVisible = false;
            });
          }
        })
        .catchError((_) {
          if (mounted) {
            setState(() {
              error = 'Could not switch episode. Please try again.';
            });
          }
        })
        .whenComplete(() {
          _episodeTransitionInProgress = false;
        });
    await _episodeTransitionChain;
  }

  void _toggleContextPanel() {
    if (widget.seriesEpisodePlayback && _hasSeriesEpisodes) {
      setState(() {
        showSeriesEpisodesPanel = !showSeriesEpisodesPanel;
        if (showSeriesEpisodesPanel) {
          showMovieQueuePanel = false;
        }
      });
      return;
    }
    if (MediaQuery.sizeOf(context).width < 960) {
      unawaited(_openMovieQueue());
      return;
    }
    setState(() {
      showMovieQueuePanel = !showMovieQueuePanel;
      if (showMovieQueuePanel) {
        showSeriesEpisodesPanel = false;
      }
    });
  }

  Future<void> _showCurrentDescription() async {
    final description = _currentTopDescription();
    if (description == null || description.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Description is unavailable for this title.'),
          ),
        );
      }
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Description'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: Text(description.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildMovieQueueSidePanel() {
    if (_hasMixedSession) {
      return _buildMixedQueueSidePanel();
    }
    bool canMoveUp(int index) => index > _movieQueueIndex + 1;
    bool canMoveDown(int index) =>
        index > _movieQueueIndex && index < _movieQueue.length - 1;
    bool canRemove(int index) => index > _movieQueueIndex;
    return MovieQueuePanel(
      items: [
        for (var i = 0; i < _movieQueue.length; i++)
          MediaQueueRow(
            id: _movieQueue[i].id,
            title: _movieQueue[i].title,
            subtitle: i == _movieQueueIndex
                ? '${_movieQueueMetadata(_movieQueue[i])} • Now playing'
                : (i == _movieQueueIndex + 1
                      ? '${_movieQueueMetadata(_movieQueue[i])} • Up next'
                      : _movieQueueMetadata(_movieQueue[i])),
            nowPlaying: i == _movieQueueIndex,
            canMoveUp: canMoveUp(i),
            canMoveDown: canMoveDown(i),
            canRemove: canRemove(i),
            poster: _movieQueue[i].posterUrl?.trim().isNotEmpty == true
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      _movieQueue[i].posterUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.movie_outlined),
                    ),
                  )
                : null,
          ),
      ],
      autoplay: autoplayNext,
      onAutoplayChanged: (value) {
        setState(() => autoplayNext = value);
        unawaited(_savePlayerPreferences());
      },
      onPlay: (id) {
        final index = _movieQueue.indexWhere((entry) => entry.id == id);
        if (index < 0) {
          return;
        }
        unawaited(_openMovieQueueItem(index));
      },
      onMoveUp: (id) {
        final index = _movieQueue.indexWhere((entry) => entry.id == id);
        if (index < 0 || !canMoveUp(index)) {
          return;
        }
        _moveQueueItem(index, index - 1);
      },
      onMoveDown: (id) {
        final index = _movieQueue.indexWhere((entry) => entry.id == id);
        if (index < 0 || !canMoveDown(index)) {
          return;
        }
        _moveQueueItem(index, index + 1);
      },
      onRemove: (id) {
        final index = _movieQueue.indexWhere((entry) => entry.id == id);
        if (index < 0 || index >= _movieQueue.length || !canRemove(index)) {
          return;
        }
        final current = _movieQueueIndex;
        final updated = List<_MovieQueueEntry>.from(_movieQueue)
          ..removeAt(index);
        setState(() {
          _movieQueue = updated;
          if (_movieQueue.isEmpty) {
            _movieQueueIndex = 0;
            showMovieQueuePanel = false;
          } else if (index < current) {
            _movieQueueIndex = current - 1;
          } else if (index == current) {
            _movieQueueIndex = _movieQueueIndex.clamp(
              0,
              _movieQueue.length - 1,
            );
          }
        });
      },
      onReorder: (oldIndex, newIndex) {
        if (oldIndex <= _movieQueueIndex || newIndex <= _movieQueueIndex) {
          return;
        }
        if (oldIndex == newIndex ||
            oldIndex < 0 ||
            newIndex < 0 ||
            oldIndex >= _movieQueue.length ||
            newIndex >= _movieQueue.length) {
          return;
        }
        _moveQueueItem(oldIndex, newIndex);
      },
    );
  }

  Widget _buildMixedQueueSidePanel() {
    final session = widget.mixedSession!;
    bool canMoveUp(int index) => index > session.currentIndex + 1;
    bool canMoveDown(int index) =>
        index > session.currentIndex && index < session.entries.length - 1;
    bool canRemove(int index) => index > session.currentIndex;
    return AnimatedBuilder(
      animation: session,
      builder: (_, __) => Column(
        children: [
          ListTile(
            title: Text(session.playlistName),
            subtitle: Text(
              session.shuffled
                  ? 'Mixed playlist queue · shuffled'
                  : 'Mixed playlist queue',
            ),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Previous item',
                  onPressed: session.hasPrevious
                      ? () => unawaited(_switchToMixedPrevious())
                      : null,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton(
                  tooltip: 'Next item',
                  onPressed: session.hasNext
                      ? () => unawaited(_switchToMixedNext())
                      : null,
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ),
          Expanded(
            child: MovieQueuePanel(
              items: [
                for (var i = 0; i < session.entries.length; i++)
                  MediaQueueRow(
                    id: session.entries[i].entryId,
                    title: session.entries[i].item.title,
                    subtitle: session.entries[i].item.subtitle.trim().isEmpty
                        ? session.entries[i].item.sourceName
                        : '${session.entries[i].item.sourceName} · ${session.entries[i].item.subtitle}',
                    nowPlaying: i == session.currentIndex,
                    canMoveUp: canMoveUp(i),
                    canMoveDown: canMoveDown(i),
                    canRemove: canRemove(i),
                    poster: session.entries[i].item.artwork.trim().isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              session.entries[i].item.artwork,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.movie_outlined),
                            ),
                          )
                        : null,
                  ),
              ],
              autoplay: session.autoplay,
              onAutoplayChanged: session.setAutoplay,
              onPlay: (entryId) {
                unawaited(_switchToMixedEntry(entryId));
              },
              onMoveUp: (entryId) {
                final oldIndex = session.entries.indexWhere(
                  (entry) => entry.entryId == entryId,
                );
                if (oldIndex > 0) {
                  session.reorderPending(oldIndex, oldIndex - 1);
                }
              },
              onMoveDown: (entryId) {
                final oldIndex = session.entries.indexWhere(
                  (entry) => entry.entryId == entryId,
                );
                if (oldIndex >= 0) {
                  session.reorderPending(oldIndex, oldIndex + 1);
                }
              },
              onRemove: session.removePending,
              onReorder: session.reorderPending,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _switchToMixedEntry(String entryId) async {
    final session = widget.mixedSession;
    if (session == null ||
        session.entryById(entryId) == null ||
        session.current?.entryId == entryId) {
      return;
    }
    await _saveFinalProgress(allowDuringTransition: true);
    _exitMixed(PlaylistPlaybackExit.switched(entryId));
  }

  Future<void> _switchToMixedPrevious() async {
    final session = widget.mixedSession;
    final target = session?.previousEntry;
    if (target == null) {
      return;
    }
    await _saveFinalProgress(allowDuringTransition: true);
    _exitMixed(PlaylistPlaybackExit.switched(target.entryId));
  }

  Future<void> _switchToMixedNext() async {
    final session = widget.mixedSession;
    final target = session?.nextEntry;
    if (target == null) {
      return;
    }
    await _saveFinalProgress(allowDuringTransition: true);
    _exitMixed(PlaylistPlaybackExit.switched(target.entryId));
  }

  void _moveQueueItem(int oldIndex, int newIndex) {
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _movieQueue.length ||
        newIndex >= _movieQueue.length ||
        oldIndex <= _movieQueueIndex ||
        newIndex <= _movieQueueIndex) {
      return;
    }
    final moved = _movieQueue[oldIndex];
    final reordered = List<_MovieQueueEntry>.from(_movieQueue)
      ..removeAt(oldIndex)
      ..insert(newIndex, moved);
    setState(() {
      _movieQueue = reordered;
      statusMessage = 'Queue order updated.';
    });
  }

  Widget _buildSeriesEpisodesSidePanel() {
    final seasons =
        _seriesEpisodes.map((entry) => entry.season).toSet().toList()..sort();
    final selectedSeason =
        _episodeBrowseSeason ??
        (_hasSeriesEpisodes
            ? _seriesEpisodes[_seriesEpisodeIndex].season
            : (seasons.isNotEmpty ? seasons.first : null));
    return SeriesEpisodesPanel(
      seasons: seasons,
      selectedSeason: selectedSeason,
      onSeasonChanged: (season) {
        setState(() => _episodeBrowseSeason = season);
      },
      episodes: [
        for (var i = 0; i < _seriesEpisodes.length; i++)
          EpisodeRow(
            id: '$i',
            season: _seriesEpisodes[i].season,
            number: _seriesEpisodes[i].episode,
            title: _seriesEpisodes[i].title,
            subtitle: _seriesEpisodes[i].description?.trim().isNotEmpty == true
                ? _seriesEpisodes[i].description!
                : 'Season ${_seriesEpisodes[i].season}',
            nowPlaying: i == _seriesEpisodeIndex,
            thumbnail: _seriesEpisodes[i].posterUrl?.trim().isNotEmpty == true
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      _seriesEpisodes[i].posterUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.tv),
                    ),
                  )
                : null,
          ),
      ],
      onPlay: (id) {
        final index = int.tryParse(id);
        if (index == null) {
          return;
        }
        unawaited(_openSeriesEpisodeAt(index, status: 'Starting episode...'));
      },
      autoplay: autoplayNext,
      onAutoplayChanged: (value) {
        setState(() => autoplayNext = value);
        unawaited(_savePlayerPreferences());
      },
    );
  }

  void _snoozePlayNextPrompt() {
    final totalMs = duration.inMilliseconds;
    if (!_hasNextMovieQueueItem || totalMs <= 0) {
      return;
    }
    final remainingMs = max(0, totalMs - position.inMilliseconds);
    final snoozedTarget = max(
      0,
      remainingMs - const Duration(minutes: 2).inMilliseconds,
    );
    setState(() {
      playNextPromptVisible = false;
      nextMoviePromptRemainingMs = snoozedTarget;
    });
  }

  void _dismissPlayNextPrompt() {
    if (!_hasNextMovieQueueItem) {
      return;
    }
    setState(() {
      playNextPromptVisible = false;
      playNextPromptDismissed = true;
    });
  }

  bool _computeShortcutSuppression() {
    final focused = FocusManager.instance.primaryFocus;
    final context = focused?.context;
    if (context == null) {
      return _panelFocusNode.hasFocus;
    }
    if (context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null) {
      return true;
    }
    if (context.widget is Slider ||
        context.findAncestorWidgetOfExactType<Slider>() != null) {
      return true;
    }
    if (context.widget is DropdownButton ||
        context.findAncestorWidgetOfExactType<DropdownButton>() != null) {
      return true;
    }
    if (_panelFocusNode.hasFocus) {
      return true;
    }
    return false;
  }

  void _handleGlobalFocusChanged() {
    final next = _computeShortcutSuppression();
    if (next == _globalShortcutsSuppressed || !mounted) {
      return;
    }
    setState(() => _globalShortcutsSuppressed = next);
  }

  bool get _canSystemPop =>
      !_backActionInProgress &&
      !showMovieQueuePanel &&
      !showSeriesEpisodesPanel &&
      !fullscreen;

  Future<void> _handleBackIntent({bool didPop = false}) async {
    if (didPop) {
      _routeExitTriggered = true;
      return;
    }
    if (_backActionInProgress) {
      return;
    }
    _backActionInProgress = true;
    if (showMovieQueuePanel || showSeriesEpisodesPanel) {
      setState(() {
        showMovieQueuePanel = false;
        showSeriesEpisodesPanel = false;
      });
      _backActionInProgress = false;
      return;
    }
    if (fullscreen) {
      await _setFullscreen(false);
      _backActionInProgress = false;
      return;
    }
    if (mounted && !_routeExitTriggered) {
      _routeExitTriggered = true;
      if (_hasMixedSession) {
        widget.mixedSession?.stop();
        _exitMixed(const PlaylistPlaybackExit.explicitBack());
      } else {
        Navigator.of(context).pop();
      }
    }
    if (!_routeExitTriggered) {
      _backActionInProgress = false;
    }
  }

  Future<void> _pickAudioTrack() async {
    final current = player;
    if (current == null) {
      return;
    }
    final options = tracks.audio;
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
                'Audio Tracks',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final track in options)
              ListTile(
                leading: Icon(
                  selectedTrack.audio == track
                      ? Icons.check_circle
                      : Icons.audiotrack_outlined,
                ),
                title: Text(track.title ?? '(Unnamed audio track)'),
                subtitle: Text(
                  '${_langLabel(track.language)} • ${_trackKindLabel(track.title ?? '')}',
                ),
                onTap: () async {
                  await current.setAudioTrack(track);
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

  Future<void> _pickVideoTrackQuality() async {
    final current = player;
    if (current == null) {
      return;
    }
    final options = tracks.video;
    if (options.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            SwitchListTile(
              value: qualityAdaptive,
              title: const Text('Adaptive quality'),
              onChanged: (value) async {
                if (mounted) {
                  setState(() {
                    qualityAdaptive = value;
                    statusMessage = value
                        ? 'Adaptive quality enabled.'
                        : 'Manual quality mode enabled.';
                  });
                } else {
                  qualityAdaptive = value;
                }
                await _savePlayerPreferences();
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              },
            ),
            const ListTile(
              title: Text(
                'Manual quality',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final track in options)
              ListTile(
                leading: Icon(
                  selectedTrack.video == track
                      ? Icons.check_circle
                      : Icons.high_quality_outlined,
                ),
                title: Text(track.title ?? '(Quality ${track.id})'),
                subtitle: Text(track.language ?? 'unknown'),
                onTap: () async {
                  await current.setVideoTrack(track);
                  if (mounted) {
                    setState(() => qualityAdaptive = false);
                  } else {
                    qualityAdaptive = false;
                  }
                  await _savePlayerPreferences();
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

  Future<void> _setPlaybackSpeed(double speed) async {
    final current = player;
    if (current == null) {
      return;
    }
    await current.setRate(speed);
    if (mounted) {
      setState(() => playbackSpeed = speed);
    } else {
      playbackSpeed = speed;
    }
    await _savePlayerPreferences();
  }

  Future<void> _toggleMute() async {
    final current = player;
    if (current == null) {
      return;
    }
    if (muted || volume <= 0.0001) {
      final target = preMuteVolume <= 0.0001 ? 100.0 : preMuteVolume;
      await current.setVolume(target.clamp(0, 100));
      if (mounted) {
        setState(() {
          muted = false;
          volume = target;
        });
      }
      return;
    }
    preMuteVolume = volume;
    await current.setVolume(0);
    if (mounted) {
      setState(() => muted = true);
    }
  }

  Future<void> _setVolume(double value) async {
    final current = player;
    if (current == null) {
      return;
    }
    await current.setVolume(value);
    if (!mounted) {
      return;
    }
    setState(() {
      volume = value;
      if (value > 0) {
        muted = false;
      } else {
        muted = true;
      }
    });
  }

  Future<void> _addBookmark() async {
    final value = position.inMilliseconds.clamp(
      0,
      max(0, duration.inMilliseconds),
    );
    final next = [...bookmarksMs, value.toInt()].toSet().toList()..sort();
    bookmarksMs = next;
    await memory.saveBookmarks(_activeMedia.streamUrl, bookmarksMs);
    if (mounted) {
      setState(
        () => statusMessage =
            'Bookmark added at ${_clockText(Duration(milliseconds: value.toInt()))}.',
      );
    }
  }

  Future<void> _openBookmarks() async {
    if (bookmarksMs.isEmpty) {
      return;
    }
    final target = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                'Bookmarks',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final mark in bookmarksMs)
              ListTile(
                title: Text(_clockText(Duration(milliseconds: mark))),
                onTap: () => Navigator.pop(ctx, mark),
              ),
          ],
        ),
      ),
    );
    if (target != null) {
      await player?.seek(Duration(milliseconds: target));
    }
  }

  List<int> _chapters() {
    final total = duration.inMilliseconds;
    if (total <= 0) {
      return const <int>[];
    }
    final result = <int>[];
    for (var i = 1; i < 10; i++) {
      result.add((total * (i / 10)).round());
    }
    return result;
  }

  Future<void> _openChapters() async {
    final chapters = _chapters();
    if (chapters.isEmpty) {
      return;
    }
    final target = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                'Chapters',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (var i = 0; i < chapters.length; i++)
              ListTile(
                title: Text('Chapter ${i + 1}'),
                subtitle: Text(_clockText(Duration(milliseconds: chapters[i]))),
                onTap: () => Navigator.pop(ctx, chapters[i]),
              ),
          ],
        ),
      ),
    );
    if (target != null) {
      await player?.seek(Duration(milliseconds: target));
    }
  }

  Future<void> _createSessionHandoff() async {
    final code = await memory.createSessionHandoff(
      title: _activeMedia.title,
      streamUrl: _activeMedia.streamUrl,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
    );
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session handoff'),
        content: SelectableText('Use this code on another device: $code'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _consumeSessionHandoff() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Continue from handoff'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Handoff code'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) {
      return;
    }
    final payload = await memory.consumeSessionHandoff(code);
    if (payload == null) {
      if (mounted) {
        setState(() => error = 'Handoff code not found or expired.');
      }
      return;
    }
    final stream = payload['streamUrl']?.toString().trim() ?? '';
    final seekMs = int.tryParse(payload['positionMs']?.toString() ?? '') ?? 0;
    if (stream.isEmpty || player == null) {
      return;
    }
    await player!.open(Media(stream), play: true);
    if (seekMs > 0) {
      await player!.seek(Duration(milliseconds: seekMs));
    }
  }

  Future<void> _openExternalPlayer() async {
    await Clipboard.setData(ClipboardData(text: _activeMedia.streamUrl));
    if (mounted) {
      setState(() => statusMessage = 'Stream URL copied for external player.');
    }
  }

  Future<void> _stepFrame(int direction) async {
    if (playing) {
      return;
    }
    await _seekRelative(Duration(milliseconds: 33 * direction));
  }

  Future<void> _restartPlayback() async {
    await player?.seek(Duration.zero);
    if (mounted) {
      setState(() => statusMessage = 'Restarted from the beginning.');
    }
  }

  Future<void> _resumeSavedPosition() async {
    final saved = resumePositionMs ?? 0;
    if (saved <= 0) {
      return;
    }
    await player?.seek(Duration(milliseconds: saved));
    if (mounted) {
      setState(() => statusMessage = 'Resumed from saved progress.');
    }
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
        if (!value) {
          await windowManager.show();
          await windowManager.focus();
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        fullscreen = value;
        controlsVisible = true;
        outputEnvironment = _detectOutputEnvironment();
      });
    } else {
      fullscreen = value;
      controlsVisible = true;
      outputEnvironment = _detectOutputEnvironment();
    }
    _scheduleControlsAutoHide();
  }

  void _registerControlsInteraction() {
    if (!mounted) {
      return;
    }
    if (fullscreen && !controlsVisible) {
      setState(() => controlsVisible = true);
    }
    _scheduleControlsAutoHide();
  }

  void _scheduleControlsAutoHide() {
    controlsHideTimer?.cancel();
    final shouldAutoHide =
        fullscreen &&
        playing &&
        !buffering &&
        error.isEmpty &&
        statusMessage.isEmpty &&
        !creditsVisible &&
        !showMovieQueuePanel &&
        !showSeriesEpisodesPanel;
    if (!shouldAutoHide) {
      if (mounted && !controlsVisible) {
        setState(() => controlsVisible = true);
      } else {
        controlsVisible = true;
      }
      return;
    }
    controlsHideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !fullscreen || !playing || buffering) {
        return;
      }
      setState(() => controlsVisible = false);
    });
  }

  BoxFit _aspectFit() {
    switch (aspectMode) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      default:
        return BoxFit.contain;
    }
  }

  Future<void> _setAspectMode(String value) async {
    aspectMode = value;
    if (mounted) {
      setState(() => statusMessage = 'Aspect mode: $value');
    }
    await _savePlayerPreferences();
  }

  Future<void> _setAudioOutputProfile(String value) async {
    audioOutputProfile = value;
    final current = player;
    if (current != null) {
      if (value == 'night') {
        await current.setVolume(min(volume, 70));
      } else if (value == 'theater') {
        await current.setVolume(max(volume, 80));
      }
    }
    if (mounted) {
      setState(() => statusMessage = 'Output profile: $value');
    }
    await _savePlayerPreferences();
  }

  Future<void> _showPlaybackStats() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playback statistics'),
        content: SelectableText(
          'Position: ${_clockText(position)}\n'
          'Duration: ${_runtimeText(duration)}\n'
          'Buffering: ${buffering ? 'yes' : 'no'}\n'
          'Engine: $playbackEngineStatus\n'
          'Output env: $outputEnvironment\n'
          'Route: $playbackRoute\n'
          'Quality route: $qualityRoute\n'
          'Reason: $transcodeReason\n'
          'Volume: ${volume.toStringAsFixed(0)}%\n'
          'Speed: ${playbackSpeed.toStringAsFixed(2)}x\n'
          'Aspect: $aspectMode\n'
          'Output: $audioOutputProfile',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCapabilitiesReport() async {
    final sourceScheme =
        Uri.tryParse(_activeMedia.streamUrl)?.scheme.toLowerCase() ?? 'unknown';
    final canSelectAudio = tracks.audio.isNotEmpty;
    final canSelectSubtitle = tracks.subtitle.isNotEmpty;
    final canSelectQuality = tracks.video.isNotEmpty;
    final canUseFallback = player != null;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Client capability report'),
        content: SelectableText(
          'Scheme: $sourceScheme\n'
          'Output environment: $outputEnvironment\n'
          'Route policy: $playbackRoute\n'
          'Audio track selection: ${canSelectAudio ? 'supported' : 'not exposed by source'}\n'
          'Subtitle selection: ${canSelectSubtitle ? 'supported' : 'not exposed by source'}\n'
          'Quality selection: ${canSelectQuality ? 'supported' : 'not exposed by source'}\n'
          'Promised subtitle formats: ${_promisedSubtitleFormats()}\n'
          'Bandwidth policy: local <= ${maxBandwidthKbpsLocal} kbps, remote <= ${maxBandwidthKbpsRemote} kbps\n'
          'Fallback profile: ${canUseFallback ? 'available (compatible playback)' : 'unavailable'}\n'
          'Avoid restart loops: automatic recovery capped at 3 attempts\n'
          '\nTrack policy:\n'
          'Preferred audio language -> Preferred subtitle language -> Forced-subtitle rules -> SDH preference -> Remembered host/device limitation -> Safe default',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSubtitleAccessibilitySettings() async {
    final audioLang = TextEditingController(text: preferredAudioLanguage);
    final subLang = TextEditingController(text: preferredSubtitleLanguage);
    final colorOptions = <MapEntry<String, Color>>[
      MapEntry('Primary', _LiveTvMediaPaint.onSurface),
      MapEntry('Accent', _LiveTvMediaPaint.accent),
      MapEntry('Muted', _LiveTvMediaPaint.onSurface70),
      MapEntry('Panel', _LiveTvMediaPaint.panel),
      MapEntry('Backdrop', _LiveTvMediaPaint.overlayStrong),
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setLocalState) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Subtitle & accessibility (premium)',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: subtitlesEnabled,
                  title: const Text('Subtitles on/off'),
                  onChanged: (value) async {
                    setLocalState(() => subtitlesEnabled = value);
                    await _toggleSubtitles(value);
                  },
                ),
                SwitchListTile(
                  value: preferForcedSubtitles,
                  title: const Text('Prefer forced subtitles'),
                  onChanged: (value) =>
                      setLocalState(() => preferForcedSubtitles = value),
                ),
                SwitchListTile(
                  value: preferSdh,
                  title: const Text('Prefer SDH/closed captions'),
                  onChanged: (value) => setLocalState(() => preferSdh = value),
                ),
                SwitchListTile(
                  value: preferAudioDescription,
                  title: const Text('Prefer audio description'),
                  onChanged: (value) =>
                      setLocalState(() => preferAudioDescription = value),
                ),
                SwitchListTile(
                  value: highContrastInterface,
                  title: const Text('High-contrast interface'),
                  onChanged: (value) =>
                      setLocalState(() => highContrastInterface = value),
                ),
                SwitchListTile(
                  value: reducedMotion,
                  title: const Text('Reduced motion'),
                  onChanged: (value) =>
                      setLocalState(() => reducedMotion = value),
                ),
                SwitchListTile(
                  value: screenReaderHints,
                  title: const Text('Screen-reader hints'),
                  onChanged: (value) =>
                      setLocalState(() => screenReaderHints = value),
                ),
                ListTile(
                  title: const Text('Preferred audio language'),
                  subtitle: TextField(
                    controller: audioLang,
                    decoration: const InputDecoration(hintText: 'en'),
                  ),
                ),
                ListTile(
                  title: const Text('Preferred subtitle language'),
                  subtitle: TextField(
                    controller: subLang,
                    decoration: const InputDecoration(hintText: 'en'),
                  ),
                ),
                ListTile(
                  title: const Text('Subtitle foreground color'),
                  subtitle: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in colorOptions)
                        ChoiceChip(
                          label: Text(option.key),
                          selected:
                              subtitleForeground.value == option.value.value,
                          onSelected: (_) => setLocalState(
                            () => subtitleForeground = option.value,
                          ),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  title: const Text('Subtitle background color'),
                  subtitle: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in colorOptions)
                        ChoiceChip(
                          label: Text(option.key),
                          selected:
                              subtitleBackground.value == option.value.value,
                          onSelected: (_) => setLocalState(
                            () => subtitleBackground = option.value,
                          ),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  title: const Text('Subtitle outline/shadow color'),
                  subtitle: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in colorOptions)
                        ChoiceChip(
                          label: Text(option.key),
                          selected: subtitleOutline.value == option.value.value,
                          onSelected: (_) => setLocalState(
                            () => subtitleOutline = option.value,
                          ),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  title: const Text('Subtitle font family'),
                  subtitle: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final family in const [
                        'Default',
                        'Arial',
                        'Roboto',
                        'Noto Sans',
                        'Open Sans',
                        'Verdana',
                      ])
                        ChoiceChip(
                          label: Text(family),
                          selected: subtitleFontFamily == family,
                          onSelected: (_) =>
                              setLocalState(() => subtitleFontFamily = family),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  title: Text(
                    'Subtitle font size: ${subtitleFontSize.toStringAsFixed(0)}',
                  ),
                  subtitle: Slider(
                    value: subtitleFontSize.clamp(26, 82),
                    min: 26,
                    max: 82,
                    onChanged: (value) =>
                        setLocalState(() => subtitleFontSize = value),
                  ),
                ),
                ListTile(
                  title: Text(
                    'Subtitle opacity: ${(subtitleOpacity * 100).round()}%',
                  ),
                  subtitle: Slider(
                    value: subtitleOpacity.clamp(0.2, 1.0),
                    min: 0.2,
                    max: 1.0,
                    onChanged: (value) =>
                        setLocalState(() => subtitleOpacity = value),
                  ),
                ),
                ListTile(
                  title: Text(
                    'Subtitle position: ${subtitlePosition.toStringAsFixed(0)}',
                  ),
                  subtitle: Slider(
                    value: subtitlePosition.clamp(10, 100),
                    min: 10,
                    max: 100,
                    onChanged: (value) =>
                        setLocalState(() => subtitlePosition = value),
                  ),
                ),
                ListTile(
                  title: Text(
                    'Subtitle timing offset: ${subtitleDelaySeconds.toStringAsFixed(2)}s',
                  ),
                  subtitle: Slider(
                    value: subtitleDelaySeconds.clamp(-10, 10),
                    min: -10,
                    max: 10,
                    onChanged: (value) =>
                        setLocalState(() => subtitleDelaySeconds = value),
                  ),
                ),
                ListTile(
                  title: Text(
                    'Text scaling: ${playerTextScale.toStringAsFixed(2)}x',
                  ),
                  subtitle: Slider(
                    value: playerTextScale.clamp(0.8, 1.8),
                    min: 0.8,
                    max: 1.8,
                    onChanged: (value) =>
                        setLocalState(() => playerTextScale = value),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () async {
                      preferredAudioLanguage = audioLang.text.trim().isEmpty
                          ? 'en'
                          : audioLang.text.trim().toLowerCase();
                      preferredSubtitleLanguage = subLang.text.trim().isEmpty
                          ? 'en'
                          : subLang.text.trim().toLowerCase();
                      await _savePlayerPreferences();
                      await _applySubtitleRenderingPreferences();
                      await _selectAudioByPolicy();
                      if (subtitlesEnabled) {
                        await _selectSubtitleByPolicy();
                      }
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                    },
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _importSubtitleFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Subtitle files',
          extensions: ['srt', 'ass', 'ssa', 'vtt', 'sub'],
        ),
      ],
    );
    if (file == null) {
      return;
    }
    final current = player;
    if (current == null) {
      return;
    }
    final platform = current.platform;
    if (platform is! NativePlayer) {
      if (mounted) {
        setState(() {
          error =
              'User-provided subtitle files are not supported on this platform.';
        });
      }
      return;
    }
    try {
      await platform.setProperty('sub-files-append', file.path);
      if (mounted) {
        setState(() => statusMessage = 'Subtitle file loaded: ${file.name}');
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not load subtitle file.');
      }
    }
  }

  Future<void> _subtitleQualityReport() async {
    final items = tracks.subtitle;
    final summary = <String>[];
    if (items.isEmpty) {
      summary.add('No subtitle tracks were exposed by this source.');
    } else {
      for (final track in items) {
        final title = track.title ?? '(untitled)';
        final kind = _trackKindLabel(title);
        final lang = _langLabel(track.language);
        summary.add('$lang · $kind · $title');
      }
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Subtitle quality report'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(child: Text(summary.join('\n'))),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _loadSubtitleProviderPrefs() async {
    final legacy = await memory.loadPrefs(widget.profileKey);
    final profileId = int.tryParse(widget.profileKey);
    if (profileId == null) {
      return legacy;
    }
    final home = await HomePreferences().subtitleProviderSettings(profileId);
    final merged = <String, dynamic>{...legacy, ...home};
    return merged;
  }

  Future<void> _saveSubtitleProviderPrefs(Map<String, dynamic> next) async {
    final profileId = int.tryParse(widget.profileKey);
    if (profileId != null) {
      await HomePreferences().saveSubtitleProviderSettings(profileId, next);
    }
    final merged = await memory.loadPrefs(widget.profileKey);
    merged.addAll(next);
    await memory.savePrefs(widget.profileKey, merged);
  }

  Future<void> _subtitleSearchAuthorizedWorkflow() async {
    final prefs = await _loadSubtitleProviderPrefs();
    final query = TextEditingController(text: _activeMedia.title);
    final openApiKey = TextEditingController(
      text: prefs['openSubtitlesApiKey']?.toString() ?? '',
    );
    final openUser = TextEditingController(
      text: prefs['openSubtitlesUsername']?.toString() ?? '',
    );
    final openPass = TextEditingController(
      text: prefs['openSubtitlesPassword']?.toString() ?? '',
    );
    final subdlKey = TextEditingController(
      text: prefs['subdlApiKey']?.toString() ?? '',
    );
    var busy = false;
    var localError = '';
    var results = <SubtitleSearchResult>[];

    String providerName(SubtitleProvider provider) {
      switch (provider) {
        case SubtitleProvider.openSubtitles:
          return 'OpenSubtitles';
        case SubtitleProvider.subdl:
          return 'SubDL';
      }
    }

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text('Subtitle search providers'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: query,
                    decoration: const InputDecoration(
                      labelText: 'Search query',
                      hintText: 'Movie or episode title',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: openApiKey,
                    decoration: const InputDecoration(
                      labelText: 'OpenSubtitles API key',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: openUser,
                    decoration: const InputDecoration(
                      labelText: 'OpenSubtitles username',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: openPass,
                    decoration: const InputDecoration(
                      labelText: 'OpenSubtitles password',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: subdlKey,
                    decoration: const InputDecoration(
                      labelText: 'SubDL API key (optional second provider)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                setLocalState(() {
                                  busy = true;
                                  localError = '';
                                });
                                final config = {
                                  'openSubtitlesApiKey': openApiKey.text.trim(),
                                  'openSubtitlesUsername': openUser.text.trim(),
                                  'openSubtitlesPassword': openPass.text.trim(),
                                  'subdlApiKey': subdlKey.text.trim(),
                                };
                                try {
                                  results = await subtitleProviders.search(
                                    query: query.text.trim(),
                                    language: preferredSubtitleLanguage,
                                    providerConfig: config,
                                  );
                                  await _saveSubtitleProviderPrefs(config);
                                } catch (e) {
                                  localError = e.toString().replaceFirst(
                                    'Bad state: ',
                                    '',
                                  );
                                } finally {
                                  setLocalState(() => busy = false);
                                }
                              },
                        icon: const Icon(Icons.search),
                        label: const Text('Search providers'),
                      ),
                      const SizedBox(width: 10),
                      if (busy) const CircularProgressIndicator(strokeWidth: 2),
                    ],
                  ),
                  if (localError.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        localError,
                        style: TextStyle(color: _LiveTvMediaPaint.warning),
                      ),
                    ),
                  const SizedBox(height: 10),
                  if (results.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: results.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = results[index];
                          return ListTile(
                            title: Text(item.title),
                            subtitle: Text(
                              '${providerName(item.provider)} · ${item.language}'
                              '${item.release == null ? '' : ' · ${item.release}'}'
                              '${item.forced ? ' · Forced' : ''}'
                              '${item.hearingImpaired == null ? '' : ' · SDH ${item.hearingImpaired}'}',
                            ),
                            trailing: FilledButton(
                              onPressed: () async {
                                final current = player;
                                if (current == null) {
                                  return;
                                }
                                final platform = current.platform;
                                if (platform is! NativePlayer) {
                                  if (mounted) {
                                    setState(
                                      () => error =
                                          'Subtitle injection is unavailable on this platform.',
                                    );
                                  }
                                  return;
                                }
                                try {
                                  final path = await subtitleProviders
                                      .downloadSubtitleToTemp(
                                        item,
                                        baseName: _activeMedia.title,
                                      );
                                  await platform.setProperty(
                                    'sub-files-append',
                                    path,
                                  );
                                  if (mounted) {
                                    setState(
                                      () => statusMessage =
                                          'Loaded subtitle from ${providerName(item.provider)}.',
                                    );
                                  }
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                  }
                                } catch (e) {
                                  setLocalState(
                                    () => localError = e
                                        .toString()
                                        .replaceFirst('Bad state: ', ''),
                                  );
                                }
                              },
                              child: const Text('Use'),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _translationAuthorizedWorkflow() async {
    final prefs = await _loadSubtitleProviderPrefs();
    final textInput = TextEditingController();
    final source = TextEditingController(text: preferredSubtitleLanguage);
    final target = TextEditingController(text: preferredAudioLanguage);
    final endpoint = TextEditingController(
      text:
          prefs['translateEndpoint']?.toString() ??
          'https://libretranslate.com/translate',
    );
    final apiKey = TextEditingController(
      text: prefs['translateApiKey']?.toString() ?? '',
    );
    var translated = '';
    var localError = '';
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text('Subtitle translation'),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: textInput,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Text to translate',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: source,
                          decoration: const InputDecoration(
                            labelText: 'From (lang code)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: target,
                          decoration: const InputDecoration(
                            labelText: 'To (lang code)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: endpoint,
                    decoration: const InputDecoration(
                      labelText: 'LibreTranslate endpoint',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: apiKey,
                    decoration: const InputDecoration(
                      labelText: 'LibreTranslate API key (optional)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                setLocalState(() {
                                  busy = true;
                                  localError = '';
                                  translated = '';
                                });
                                try {
                                  translated = await subtitleProviders
                                      .translateText(
                                        text: textInput.text,
                                        fromLanguage: source.text.trim().isEmpty
                                            ? 'auto'
                                            : source.text.trim(),
                                        toLanguage: target.text.trim().isEmpty
                                            ? 'en'
                                            : target.text.trim(),
                                        providerConfig: {
                                          'translateEndpoint': endpoint.text
                                              .trim(),
                                          'translateApiKey': apiKey.text.trim(),
                                        },
                                      );
                                  await _saveSubtitleProviderPrefs({
                                    'translateEndpoint': endpoint.text.trim(),
                                    'translateApiKey': apiKey.text.trim(),
                                  });
                                } catch (e) {
                                  localError = e.toString().replaceFirst(
                                    'Bad state: ',
                                    '',
                                  );
                                } finally {
                                  setLocalState(() => busy = false);
                                }
                              },
                        icon: const Icon(Icons.translate),
                        label: const Text('Translate'),
                      ),
                      const SizedBox(width: 10),
                      if (busy) const CircularProgressIndicator(strokeWidth: 2),
                    ],
                  ),
                  if (localError.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        localError,
                        style: TextStyle(color: _LiveTvMediaPaint.warning),
                      ),
                    ),
                  if (translated.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: SelectableText(translated),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSecondarySubtitleTrack() async {
    final current = player;
    if (current == null || tracks.subtitle.isEmpty) {
      return;
    }
    final platform = current.platform;
    if (platform is! NativePlayer) {
      return;
    }
    final pick = await showModalBottomSheet<SubtitleTrack>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                'Secondary subtitle track',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (var i = 0; i < tracks.subtitle.length; i++)
              ListTile(
                title: Text(_subtitleTrackTitle(tracks.subtitle[i], i)),
                subtitle: Text(_langLabel(tracks.subtitle[i].language)),
                onTap: () => Navigator.pop(ctx, tracks.subtitle[i]),
              ),
          ],
        ),
      ),
    );
    if (pick == null) {
      return;
    }
    try {
      await platform.setProperty('secondary-sid', '${pick.id}');
      if (mounted) {
        setState(() => statusMessage = 'Secondary subtitle enabled.');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          error =
              'Multiple simultaneous subtitles are not supported by this platform/stream.';
        });
      }
    }
  }

  Future<void> _seekToPreview(double value) async {
    final current = player;
    if (current == null) {
      return;
    }
    await current.seek(Duration(milliseconds: value.round()));
    if (mounted) {
      setState(() => scrubPreviewMs = null);
    } else {
      scrubPreviewMs = null;
    }
  }

  Widget _seekThumbnailPreview() {
    final previewMs = scrubPreviewMs;
    if (previewMs == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: 170,
      height: 96,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withAlpha(210),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _LiveTvMediaPaint.onSurface24),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _currentTopPosterUrl()?.trim().isNotEmpty == true
                  ? Image.network(
                      _currentTopPosterUrl()!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          ColoredBox(color: context.millitopTheme.panelColor),
                    )
                  : ColoredBox(color: context.millitopTheme.panelColor),
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withAlpha(192),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  _clockText(Duration(milliseconds: previewMs.round())),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
    await _saveProgressSnapshot();
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
        title: _activeMedia.title,
        subtitle: _activeMedia.subtitle,
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
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Import subtitle file'),
              subtitle: const Text('Load SRT, ASS, SSA, VTT, or SUB file'),
              onTap: () async {
                Navigator.pop(ctx);
                await _importSubtitleFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Subtitle appearance & timing'),
              subtitle: const Text(
                'Font, size, colors, and subtitle delay/offset',
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await _openSubtitleAccessibilitySettings();
              },
            ),
            if (options.isEmpty)
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('No embedded subtitle tracks'),
                subtitle: Text('Import a subtitle file to continue.'),
              ),
            for (var i = 0; i < options.length; i++)
              Builder(
                builder: (context) {
                  final track = options[i];
                  return ListTile(
                    leading: Icon(
                      selectedTrack.subtitle == track
                          ? Icons.check_circle
                          : Icons.subtitles_outlined,
                    ),
                    title: Text(_subtitleTrackTitle(track, i)),
                    subtitle: Text(
                      '${_langLabel(track.language)} • ${_trackKindLabel(track.title ?? '')}',
                    ),
                    onTap: () async {
                      try {
                        await current.setSubtitleTrack(track);
                        final subtitleLabel =
                            '${track.title ?? ''} ${track.language ?? ''}'
                                .toLowerCase();
                        final likelyImageSubtitle =
                            subtitleLabel.contains('pgs') ||
                            subtitleLabel.contains('dvd') ||
                            subtitleLabel.contains('vobsub');
                        if (mounted) {
                          setState(() {
                            if (likelyImageSubtitle) {
                              transcodeReason =
                                  'Selected subtitle may require provider-side burn-in on some servers.';
                              qualityRoute = 'compatibility-constrained';
                            } else {
                              transcodeReason =
                                  'Subtitle track switched without forced transcoding.';
                            }
                          });
                        }
                      } catch (_) {
                        if (mounted) {
                          setState(() {
                            error =
                                'This subtitle format could not be rendered on this platform. Try another track or compatible playback.';
                          });
                        }
                      }
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                    },
                  );
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

  Future<void> _seekByConfigured(
    int direction, {
    bool accelerated = false,
  }) async {
    final step = seekIncrementSeconds * (accelerated ? 3 : 1);
    await _seekRelative(Duration(seconds: step * direction));
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

  Future<void> _showRemoteControlHelp() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remote & keyboard controls'),
        content: const SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Text(
              'Space/Enter: Play or pause\n'
              'Left/Right: Seek by configured step\n'
              'Up/Down: Volume +/- 10%\n'
              'M: Mute or unmute\n'
              'F: Toggle fullscreen\n'
              'C: Subtitle tracks\n'
              'A: Audio tracks\n'
              'Q: Quality tracks\n'
              'P: Back to home with PiP\n'
              'Esc / Back: Close panel, then exit fullscreen, then go back\n'
              'H: Show this help\n\n'
              'When buffering/transcoding, open Playback stats and choose Try compatible playback.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSpeedPicker() async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Playback speed',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final speed in const [0.5, 1.0, 1.25, 1.5, 2.0])
              ListTile(
                leading: Icon(
                  (playbackSpeed - speed).abs() < 0.001
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                ),
                title: Text(
                  '${speed.toStringAsFixed(speed == 1.25 || speed == 1.5 ? 2 : 1)}×',
                ),
                onTap: () => Navigator.pop(ctx, speed),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await _setPlaybackSpeed(selected);
    }
  }

  Future<void> _openPlaybackSettings() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Playback settings',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: const Text('Audio track'),
              subtitle: const Text('Select audio language and mix'),
              onTap: () => Navigator.pop(ctx, 'audio'),
            ),
            ListTile(
              leading: const Icon(Icons.high_quality_outlined),
              title: const Text('Video quality'),
              subtitle: const Text('Choose a quality profile'),
              onTap: () => Navigator.pop(ctx, 'quality'),
            ),
            ListTile(
              leading: const Icon(Icons.keyboard),
              title: const Text('Remote shortcuts'),
              subtitle: const Text('View keyboard and remote controls'),
              onTap: () => Navigator.pop(ctx, 'shortcuts'),
            ),
          ],
        ),
      ),
    );
    if (selected == 'audio') {
      await _pickAudioTrack();
    } else if (selected == 'quality') {
      await _pickVideoTrackQuality();
    } else if (selected == 'shortcuts') {
      await _showRemoteControlHelp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final activePlayer = player;
    final activeVideo = video;
    final playerPanel =
        showSeriesEpisodesPanel &&
            widget.seriesEpisodePlayback &&
            _hasSeriesEpisodes
        ? PlayerSidePanel.episodes
        : (showMovieQueuePanel ? PlayerSidePanel.queue : PlayerSidePanel.none);

    Future<void> onPanelChanged(PlayerSidePanel panel) async {
      setState(() {
        showMovieQueuePanel = panel == PlayerSidePanel.queue;
        showSeriesEpisodesPanel = panel == PlayerSidePanel.episodes;
      });
    }

    final shortcutBindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): () {
        unawaited(_handleBackIntent());
      },
      const SingleActivator(LogicalKeyboardKey.goBack): () {
        unawaited(_handleBackIntent());
      },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.keyP): () {
          unawaited(_minimizeToPipAndGoHome());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.enter): () {
          unawaited(_togglePlayPause());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.space): () {
          unawaited(_togglePlayPause());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          unawaited(_seekByConfigured(-1));
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.arrowRight): () {
          unawaited(_seekByConfigured(1));
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.arrowUp): () {
          unawaited(_setVolume((volume + 10).clamp(0, 100).toDouble()));
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.arrowDown): () {
          unawaited(_setVolume((volume - 10).clamp(0, 100).toDouble()));
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.keyM): () {
          unawaited(_toggleMute());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.keyF): () {
          unawaited(_toggleFullscreen());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.keyC): () {
          unawaited(_pickSubtitle());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.keyA): () {
          unawaited(_pickAudioTrack());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.keyQ): () {
          unawaited(_pickVideoTrackQuality());
        },
      if (!_globalShortcutsSuppressed)
        const SingleActivator(LogicalKeyboardKey.keyH): () {
          unawaited(_showRemoteControlHelp());
        },
    };

    return PopScope(
      canPop: _canSystemPop,
      onPopInvokedWithResult: (didPop, __) {
        unawaited(_handleBackIntent(didPop: didPop));
      },
      child: CallbackShortcuts(
        bindings: shortcutBindings,
        child: Focus(
          autofocus: true,
          child: MouseRegion(
            onHover: (_) => _registerControlsInteraction(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _registerControlsInteraction,
              onPanStart: (_) => _registerControlsInteraction(),
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(
                    playerTextScale.clamp(0.8, 1.8),
                  ),
                ),
                child: Scaffold(
                  backgroundColor: Colors.black,
                  body: activePlayer == null || activeVideo == null
                      ? const Center(child: CircularProgressIndicator())
                      : MediaPlayerChrome(
                          video: Video(
                            controller: activeVideo,
                            controls: NoVideoControls,
                          ),
                          title: _activeMedia.title,
                          metadata: _currentTopMetaLine(),
                          description: _currentTopDescription(),
                          poster:
                              _currentTopPosterUrl()?.trim().isNotEmpty == true
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    _currentTopPosterUrl()!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.movie_outlined),
                                  ),
                                )
                              : null,
                          playing: playing,
                          position: position,
                          duration: duration,
                          volume: volume,
                          muted: muted,
                          speed: playbackSpeed,
                          onPlayPause: () => unawaited(_togglePlayPause()),
                          onSeek: (target) => unawaited(
                            _seekToPreview(target.inMilliseconds.toDouble()),
                          ),
                          onSeekBack: () => unawaited(_seekByConfigured(-1)),
                          onSeekForward: () => unawaited(_seekByConfigured(1)),
                          seekIntervalSeconds: seekIncrementSeconds,
                          onToggleMute: () => unawaited(_toggleMute()),
                          onVolumeChanged: (value) =>
                              unawaited(_setVolume(value)),
                          onDescription: () =>
                              unawaited(_showCurrentDescription()),
                          onSubtitles: _pickSubtitle,
                          onSpeed: () => unawaited(_openSpeedPicker()),
                          onSettings: () => unawaited(_openPlaybackSettings()),
                          onFullscreen: () => unawaited(_toggleFullscreen()),
                          onBack: () => unawaited(_handleBackIntent()),
                          onPipHome: () => unawaited(_minimizeToPipAndGoHome()),
                          panel: playerPanel,
                          onPanelChanged: (panel) {
                            unawaited(onPanelChanged(panel));
                          },
                          queuePanel: FocusScope(
                            node: _panelFocusNode,
                            child: _buildMovieQueueSidePanel(),
                          ),
                          episodesPanel:
                              widget.seriesEpisodePlayback && _hasSeriesEpisodes
                              ? FocusScope(
                                  node: _panelFocusNode,
                                  child: _buildSeriesEpisodesSidePanel(),
                                )
                              : null,
                          onPreviousEpisode:
                              widget.seriesEpisodePlayback &&
                                  _hasPreviousSeriesEpisode
                              ? () => unawaited(
                                  _openSeriesEpisodeAt(
                                    _seriesEpisodeIndex - 1,
                                    status: 'Starting previous episode...',
                                  ),
                                )
                              : null,
                          onNextEpisode:
                              widget.seriesEpisodePlayback &&
                                  _hasNextSeriesEpisode
                              ? () => unawaited(
                                  _openSeriesEpisodeAt(
                                    _seriesEpisodeIndex + 1,
                                    status: _nextSeriesEpisodeLabel == null
                                        ? 'Starting next episode...'
                                        : 'Starting $_nextSeriesEpisodeLabel...',
                                  ),
                                )
                              : null,
                          fullscreen: fullscreen,
                          visible: !fullscreen || controlsVisible,
                          onReveal: fullscreen && !controlsVisible
                              ? () {
                                  _registerControlsInteraction();
                                  setState(() => controlsVisible = true);
                                }
                              : null,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SeriesDetailsScreen extends StatefulWidget {
  final LiveTvSeriesDetails details;
  final String? status;
  final String? contentRating;
  final List<String> genres;
  final bool followed;
  final String? nextUpLabel;
  final bool hasNewEpisode;
  final double seriesProgress;
  final Future<void> Function(LiveTvSeriesEpisode episode) onPlay;
  final Future<void> Function(LiveTvSeriesEpisode episode) onEpisodeDetails;
  final Future<void> Function() onToggleFollow;
  const _SeriesDetailsScreen({
    required this.details,
    this.status,
    this.contentRating,
    this.genres = const [],
    required this.followed,
    this.nextUpLabel,
    required this.hasNewEpisode,
    required this.seriesProgress,
    required this.onPlay,
    required this.onEpisodeDetails,
    required this.onToggleFollow,
  });

  @override
  State<_SeriesDetailsScreen> createState() => _SeriesDetailsScreenState();
}

class _SeriesDetailsScreenState extends State<_SeriesDetailsScreen> {
  late int season;
  bool spoilerSafe = false;
  late bool followed;

  @override
  void initState() {
    super.initState();
    season = widget.details.episodes.first.season;
    followed = widget.followed;
  }

  List<int> get seasons =>
      widget.details.episodes.map((item) => item.season).toSet().toList()
        ..sort();

  @override
  Widget build(BuildContext context) {
    final visible = widget.details.episodes
        .where((item) => item.season == season)
        .toList();
    final sectionCardDecoration = BoxDecoration(
      color: context.millitopTheme.panelColor.withAlpha(130),
      borderRadius: BorderRadius.circular(context.millitopTheme.cardRadius),
      border: Border.all(color: context.millitopTheme.panelBorder),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.details.title),
        actions: [
          IconButton(
            tooltip: followed ? 'Unfollow series' : 'Follow series',
            onPressed: () async {
              await widget.onToggleFollow();
              if (mounted) {
                setState(() => followed = !followed);
              }
            },
            icon: Icon(
              followed ? Icons.notifications_active : Icons.notifications_none,
            ),
          ),
          IconButton(
            tooltip: spoilerSafe
                ? 'Disable spoiler-safe mode'
                : 'Enable spoiler-safe mode',
            onPressed: () => setState(() => spoilerSafe = !spoilerSafe),
            icon: Icon(spoilerSafe ? Icons.visibility_off : Icons.visibility),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 270,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.details.backdropUrl != null &&
                      widget.details.backdropUrl!.trim().isNotEmpty)
                    Image.network(
                      widget.details.backdropUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          ColoredBox(color: context.millitopTheme.panelColor),
                    )
                  else
                    ColoredBox(color: context.millitopTheme.panelColor),
                  Container(
                    color: Theme.of(context).colorScheme.surface.withAlpha(170),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child:
                              widget.details.posterUrl == null ||
                                  widget.details.posterUrl!.trim().isEmpty
                              ? Container(
                                  width: 160,
                                  height: 220,
                                  color: context.millitopTheme.panelColor,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.tv, size: 52),
                                )
                              : Image.network(
                                  widget.details.posterUrl!,
                                  width: 160,
                                  height: 220,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 160,
                                    height: 220,
                                    color: context.millitopTheme.panelColor,
                                    alignment: Alignment.center,
                                    child: const Icon(Icons.tv, size: 52),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.details.title,
                                style: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (widget.status?.trim().isNotEmpty == true)
                                    Chip(
                                      label: Text('Status: ${widget.status!}'),
                                    ),
                                  if (widget.contentRating?.trim().isNotEmpty ==
                                      true)
                                    Chip(
                                      label: Text(
                                        'Rating: ${widget.contentRating!}',
                                      ),
                                    ),
                                  Chip(
                                    label: Text(
                                      widget.hasNewEpisode
                                          ? 'New episodes available'
                                          : 'Up to date',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              LinearProgressIndicator(
                                value: widget.seriesProgress.clamp(0.0, 1.0),
                                minHeight: 6,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Series progress ${(widget.seriesProgress * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  color: _LiveTvMediaPaint.onSurface70,
                                  fontSize: 12,
                                ),
                              ),
                              if (widget.nextUpLabel != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Next Up: ${widget.nextUpLabel}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _LiveTvMediaPaint.onSurface70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              if (widget.genres.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: widget.genres
                                      .map((genre) => Chip(label: Text(genre)))
                                      .toList(),
                                ),
                              ],
                              const SizedBox(height: 10),
                              Text(
                                widget.details.description?.trim().isNotEmpty ==
                                        true
                                    ? widget.details.description!
                                    : 'Series details are not provided by this source.',
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _LiveTvMediaPaint.onSurface70,
                                  fontSize: 15,
                                  height: 1.35,
                                ),
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
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: sectionCardDecoration,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
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
                    elevation: 1,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => unawaited(widget.onEpisodeDetails(episode)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child:
                                  spoilerSafe ||
                                      episode.posterUrl == null ||
                                      episode.posterUrl!.trim().isEmpty
                                  ? Container(
                                      width: 130,
                                      height: 74,
                                      color: _LiveTvMediaPaint.panel,
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
                                        color: _LiveTvMediaPaint.panel,
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
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    spoilerSafe
                                        ? 'Spoiler-safe mode is on.'
                                        : episode.description
                                                  ?.trim()
                                                  .isNotEmpty ==
                                              true
                                        ? episode.description!
                                        : 'No episode synopsis available from source.',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: _LiveTvMediaPaint.onSurface70,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.play_circle_fill, size: 28),
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
