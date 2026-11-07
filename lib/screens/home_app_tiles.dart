import 'dart:async';
import 'dart:math' as math;
import '../services/home_preferences.dart';
import 'package:flutter/material.dart';
import '../services/device_connection.dart';
import '../services/live_tv_epg.dart';
import '../services/live_tv_control.dart';
import '../services/live_tv_playlist.dart';
import '../services/live_tv_source.dart';
import '../services/web_app_catalog.dart';
import '../services/web_app_definition.dart';
import '../services/firefox_browser.dart';
import '../services/music_service.dart';
import '../services/podcast_service.dart';
import '../services/podcast_playback.dart';
import '../widgets/animated_media_app_icon.dart';
import '../theme/millitop_visual_theme.dart';
import 'live_tv_screen.dart';
import 'live_tv_media_screen.dart';
import 'music_screen.dart';
import 'podcasts_screen.dart';
import 'youtube_screen.dart';
import 'app_settings_screen.dart';

class _HoverCardLift extends StatefulWidget {
  final Widget child;
  const _HoverCardLift({required this.child});

  @override
  State<_HoverCardLift> createState() => _HoverCardLiftState();
}

class _HoverCardLiftState extends State<_HoverCardLift> {
  bool hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => hovering = true),
      onExit: (_) => setState(() => hovering = false),
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        offset: hovering ? const Offset(0, -0.02) : Offset.zero,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          scale: hovering ? 1.01 : 1,
          child: widget.child,
        ),
      ),
    );
  }
}

class HomeAppTiles extends StatefulWidget {
  final int profileId;
  final WebAppCatalog? catalog;
  final PodcastPlayback? podcastPlayback;
  const HomeAppTiles({
    super.key,
    required this.profileId,
    this.catalog,
    this.podcastPlayback,
  });
  @override
  State<HomeAppTiles> createState() => _HomeAppTilesState();
}

class _HomeAppTilesState extends State<HomeAppTiles>
    with TickerProviderStateMixin {
  late WebAppCatalog catalog;
  final epgService = const LiveTvEpgService();
  final playlistService = const LiveTvPlaylistService();
  final liveTvControl = LiveTvControlService();
  final musicService = MusicService();
  late PodcastPlayback podcastPlayback;
  PodcastLibrary? lastPodcastLibrary;
  List<PodcastResumeEntry> recentPodcasts = [];
  String podcastError = '';
  int podcastGeneration = 0;
  List<WebAppDefinition> apps = builtinWebApps;
  List<LiveTvRecentChannel> recentLiveTv = [];
  List<LiveTvRecentMedia> recentMedia = [];
  MusicTrack? recentMusicTrack;
  String recentMusicQueueContext = '';
  Duration recentMusicPosition = Duration.zero;
  bool recentMusicAvailable = false;
  LiveTvProgram? recentNowProgram;
  LiveTvProgram? recentNextProgram;
  late final AnimationController livePulseController;
  late final Animation<double> livePulse;
  late final AnimationController tileFxController;
  late final Animation<double> tileFx;
  String error = '';
  List<String> savedOrder = [];
  bool arranging = false, savingOrder = false;
  String? hoveredTileId;
  @override
  void initState() {
    super.initState();
    livePulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: 1,
    );
    livePulse = Tween<double>(begin: 0.35, end: 1).animate(livePulseController);
    tileFxController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    tileFx = CurvedAnimation(parent: tileFxController, curve: Curves.easeInOut);
    catalog = widget.catalog ?? WebAppCatalog.instance;
    catalog.addListener(_changed);
    podcastPlayback = widget.podcastPlayback ?? PodcastPlayback.instance;
    podcastPlayback.addListener(_podcastChanged);
    unawaited(_refreshPodcasts());
    unawaited(_load());
  }

  void _changed() {
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant HomeAppTiles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.podcastPlayback != widget.podcastPlayback) {
      podcastPlayback.removeListener(_podcastChanged);
      podcastPlayback = widget.podcastPlayback ?? PodcastPlayback.instance;
      podcastPlayback.addListener(_podcastChanged);
      lastPodcastLibrary = null;
    }
    if (oldWidget.profileId != widget.profileId) {
      recentPodcasts = [];
      podcastError = '';
      lastPodcastLibrary = null;
      unawaited(_refreshPodcasts());
      unawaited(_load());
    }
  }

  void _podcastChanged() {
    if (!mounted ||
        podcastPlayback.profileId != widget.profileId ||
        identical(lastPodcastLibrary, podcastPlayback.library)) {
      return;
    }
    lastPodcastLibrary = podcastPlayback.library;
    podcastGeneration++;
    _applyPodcastLibrary(podcastPlayback.library);
  }

  void _applyPodcastLibrary(PodcastLibrary library) {
    try {
      final entries = library.resumableEpisodes;
      setState(() {
        recentPodcasts = entries.take(3).toList();
        podcastError = '';
      });
    } catch (e) {
      debugPrint('Podcast continue listening could not load: $e');
      setState(
        () => podcastError = 'Podcast continue listening could not load. $e',
      );
    }
  }

  Future<void> _refreshPodcasts() async {
    final profile = widget.profileId;
    final request = ++podcastGeneration;
    try {
      final library = await PodcastStore().load(profile);
      if (!mounted ||
          request != podcastGeneration ||
          widget.profileId != profile)
        return;
      _applyPodcastLibrary(library);
    } catch (e) {
      debugPrint('Podcast continue listening could not load: $e');
      if (mounted &&
          request == podcastGeneration &&
          widget.profileId == profile) {
        setState(
          () => podcastError = 'Podcast continue listening could not load. $e',
        );
      }
    }
  }

  Future<void> _openPodcasts([PodcastEpisode? episode]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PodcastsScreen(
          profileId: widget.profileId,
          initialEpisode: episode,
          playback: podcastPlayback,
        ),
      ),
    );
    if (mounted) await _refreshPodcasts();
  }

  void _syncTileFxActivity() {
    final needsAnimation = hoveredTileId != null || recentMusicAvailable;
    if (needsAnimation) {
      if (!tileFxController.isAnimating) {
        tileFxController.repeat();
      }
      return;
    }
    tileFxController.stop();
    tileFxController.value = 0;
  }

  Future<void> _load() async {
    try {
      final connection = DeviceConnection.instance.connectionKey;
      if (connection.isNotEmpty && DeviceConnection.instance.isConnected) {
        try {
          final remote = await liveTvControl.pullConfig(
            expectedConnection: connection,
            profileId: widget.profileId,
          );
          final sourcesRaw = remote['sources'];
          if (sourcesRaw is List) {
            final remoteSources = <LiveTvSource>[];
            for (final entry in sourcesRaw) {
              if (entry is! Map) {
                continue;
              }
              try {
                remoteSources.add(
                  LiveTvSource.fromJson(Map<String, dynamic>.from(entry)),
                );
              } catch (_) {}
            }
            if (remoteSources.isNotEmpty) {
              await HomePreferences().saveLiveTvSources(
                widget.profileId,
                remoteSources,
              );
            }
          }
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
      final values = await catalog.load(widget.profileId);
      await _refreshPodcasts();
      final order = await HomePreferences().order(widget.profileId);
      final recents = await HomePreferences().liveTvRecentChannels(
        widget.profileId,
      );
      final mediaRecents = await HomePreferences().liveTvRecentMedia(
        widget.profileId,
      );
      final musicSession = await musicService.loadPlaybackSession(
        widget.profileId,
      );
      MusicTrack? sessionTrack;
      var sessionContext = '';
      var sessionPosition = Duration.zero;
      var hasMusicSession = false;
      if (musicSession != null) {
        final queueRaw = musicSession['queue'];
        final index =
            int.tryParse(musicSession['index']?.toString() ?? '') ?? 0;
        if (queueRaw is List &&
            queueRaw.isNotEmpty &&
            index >= 0 &&
            index < queueRaw.length) {
          final current = queueRaw[index];
          if (current is Map) {
            try {
              sessionTrack = MusicTrack.fromJson(
                Map<String, dynamic>.from(current),
              );
              hasMusicSession = true;
            } catch (_) {}
          }
        }
        sessionContext =
            musicSession['queueContextLabel']?.toString().trim() ?? '';
        sessionPosition = Duration(
          milliseconds:
              int.tryParse(musicSession['positionMs']?.toString() ?? '') ?? 0,
        );
      }
      if (mounted) {
        setState(() {
          apps = values;
          savedOrder = order;
          recentLiveTv = recents.take(8).toList();
          recentMedia = mediaRecents.take(8).toList();
          recentMusicTrack = sessionTrack;
          recentMusicQueueContext = sessionContext;
          recentMusicPosition = sessionPosition;
          recentMusicAvailable = hasMusicSession;
          error = '';
        });
        _syncTileFxActivity();
        if (recents.isNotEmpty) {
          if (!livePulseController.isAnimating) {
            livePulseController.repeat(reverse: true);
          }
        } else {
          livePulseController.stop();
          livePulseController.value = 1;
        }
      }
      unawaited(
        _loadRecentProgramPreview(recents.isEmpty ? null : recents.first),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Web-app settings could not be loaded. Open Settings to review them.',
        );
      }
    }
  }

  Future<void> _syncProfileConfig() async {
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
  }

  @override
  void dispose() {
    podcastGeneration++;
    podcastPlayback.removeListener(_podcastChanged);
    livePulseController.dispose();
    tileFxController.dispose();
    catalog.removeListener(_changed);
    super.dispose();
  }

  String _clockText(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  Future<void> _loadRecentProgramPreview(LiveTvRecentChannel? recent) async {
    if (recent == null) {
      if (mounted) {
        setState(() {
          recentNowProgram = null;
          recentNextProgram = null;
        });
      }
      return;
    }
    try {
      final allSources = await HomePreferences().liveTvSources(
        widget.profileId,
      );
      LiveTvSource? source;
      for (final item in allSources) {
        if (item.id == recent.sourceId) {
          source = item;
          break;
        }
      }
      if (source == null ||
          source.epgUrl == null ||
          source.epgUrl!.trim().isEmpty) {
        if (mounted) {
          setState(() {
            recentNowProgram = null;
            recentNextProgram = null;
          });
        }
        return;
      }
      String? tvgId;
      if (recent.channelId.startsWith('tvg:')) {
        tvgId = recent.channelId.substring(4).trim();
      } else if (recent.channelId.startsWith('name:')) {
        final name = recent.channelId.substring(5).trim().toLowerCase();
        final playlist = await playlistService.loadFromSource(source);
        LiveTvChannel? match;
        for (final item in playlist.channels) {
          if (item.title.trim().toLowerCase() == name) {
            match = item;
            break;
          }
        }
        tvgId = match?.tvgId?.trim();
      }
      if (tvgId == null || tvgId.isEmpty) {
        if (mounted) {
          setState(() {
            recentNowProgram = null;
            recentNextProgram = null;
          });
        }
        return;
      }
      final epg = await epgService.loadFromUrl(source.epgUrl!);
      final now = DateTime.now().toUtc();
      final channelId = tvgId;
      if (!mounted) {
        return;
      }
      setState(() {
        recentNowProgram = epg.current(channelId, now);
        recentNextProgram = epg.next(channelId, now);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          recentNowProgram = null;
          recentNextProgram = null;
        });
      }
    }
  }

  Future<void> _openRecentLiveTv() async {
    if (recentLiveTv.isEmpty) {
      return;
    }
    final recent = recentLiveTv.first;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LiveTvScreen(
          profileId: widget.profileId,
          initialSourceId: recent.sourceId,
          initialChannelId: recent.channelId,
        ),
      ),
    );
  }

  Future<void> _removeRecentLiveTv(LiveTvRecentChannel recent) async {
    try {
      await HomePreferences().removeLiveTvRecentChannel(
        widget.profileId,
        sourceId: recent.sourceId,
        channelId: recent.channelId,
      );
      await _load();
    } catch (_) {}
  }

  Widget _continueWatchingPanel() {
    final recent = recentLiveTv.first;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardWidth = screenWidth < 700 ? double.infinity : 554.0;
    return SizedBox(
      width: cardWidth,
      child: _HoverCardLift(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    FadeTransition(
                      opacity: livePulse,
                      child: const Icon(
                        Icons.fiber_manual_record,
                        color: Colors.redAccent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Live · Continue Watching',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Remove from continue watching',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => unawaited(_removeRecentLiveTv(recent)),
                    ),
                    Text(
                      recent.sourceName,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  recent.channelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                if (recentNowProgram != null)
                  Text(
                    'Now · ${_clockText(recentNowProgram!.start)} - ${_clockText(recentNowProgram!.end)} · ${recentNowProgram!.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  )
                else
                  const Text(
                    'EPG loading or unavailable for this channel.',
                    style: TextStyle(color: Colors.white70),
                  ),
                if (recentNextProgram != null)
                  Text(
                    'Next · ${_clockText(recentNextProgram!.start)} - ${_clockText(recentNextProgram!.end)} · ${recentNextProgram!.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60),
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _openRecentLiveTv,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume channel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openRecentMusic() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            MusicScreen(profileId: widget.profileId, resumeSession: true),
      ),
    );
    await _load();
  }

  String _podcastTime(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _continueListeningPodcastsPanel() => SizedBox(
    width: MediaQuery.sizeOf(context).width < 700 ? double.infinity : 554,
    child: _HoverCardLift(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AnimatedBuilder(
            animation: podcastPlayback,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Podcasts · Continue Listening',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                for (final entry in recentPodcasts)
                  Builder(
                    builder: (context) {
                      final active =
                          podcastPlayback.profileId == widget.profileId &&
                          podcastPlayback.active?.key == entry.episode.key;
                      final position = active
                          ? podcastPlayback.position
                          : entry.position;
                      final duration =
                          active && podcastPlayback.duration > Duration.zero
                          ? podcastPlayback.duration
                          : entry.duration;
                      final progress = duration > Duration.zero
                          ? (position.inMilliseconds / duration.inMilliseconds)
                                .clamp(0.0, 1.0)
                          : null;
                      return Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: entry.episode.artwork.isEmpty
                                  ? Icon(
                                      entry.episode.video
                                          ? Icons.videocam
                                          : Icons.headphones,
                                    )
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        entry.episode.artwork,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(Icons.podcasts),
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.episode.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    entry.episode.show.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: context.millitopTheme.mutedColor,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (progress != null) ...[
                                    LinearProgressIndicator(value: progress),
                                    const SizedBox(height: 6),
                                  ],
                                  Text(
                                    duration > Duration.zero
                                        ? '${_podcastTime(position)} / ${_podcastTime(duration)}'
                                        : '${_podcastTime(position)} listened',
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Resume ${entry.episode.title}',
                              icon: const Icon(Icons.play_arrow_rounded),
                              onPressed: () =>
                                  unawaited(_openPodcasts(entry.episode)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _continueListeningMusicPanel() {
    final accent = context.millitopTheme.accentColor;
    final track = recentMusicTrack;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardWidth = screenWidth < 700 ? double.infinity : 554.0;
    if (!recentMusicAvailable || track == null) {
      return const SizedBox.shrink();
    }
    final minutes = recentMusicPosition.inMinutes;
    final seconds = (recentMusicPosition.inSeconds % 60).toString().padLeft(
      2,
      '0',
    );
    final positionLabel = '$minutes:$seconds';
    return SizedBox(
      width: cardWidth,
      child: _HoverCardLift(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Music · Continue Listening',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70),
                          ),
                          Text(
                            track.album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white60),
                          ),
                          if (recentMusicQueueContext.trim().isNotEmpty)
                            Text(
                              'Queue: $recentMusicQueueContext',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    RotationTransition(
                      turns: tileFxController,
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const RadialGradient(
                            colors: [Color(0xFF2C2D34), Color(0xFF050506)],
                          ),
                          border: Border.all(
                            color: const Color(0xFF3A3B43),
                            width: 2,
                          ),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            for (double ring = 42; ring >= 18; ring -= 4)
                              Container(
                                width: ring * 2,
                                height: ring * 2,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withAlpha(22),
                                    width: .8,
                                  ),
                                ),
                              ),
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent.withAlpha(190),
                                border: Border.all(
                                  color: Colors.white.withAlpha(28),
                                ),
                              ),
                              child: const Icon(
                                Icons.music_note_rounded,
                                size: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _openRecentMusic,
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Resume at $positionLabel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openRecentMedia() async {
    if (recentMedia.isEmpty) {
      return;
    }
    final item = recentMedia.first;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LiveTvMediaScreen(
          profileId: widget.profileId,
          initialSourceId: item.sourceId,
          initialMediaType: item.mediaType,
          initialMediaId: item.mediaId,
          autoResume: true,
        ),
      ),
    );
  }

  Future<void> _removeRecentMedia(LiveTvRecentMedia item) async {
    try {
      await HomePreferences().removeLiveTvRecentMedia(
        widget.profileId,
        sourceId: item.sourceId,
        mediaType: item.mediaType,
        mediaId: item.mediaId,
      );
      await _load();
    } catch (_) {}
  }

  Widget _continueWatchingMediaPanel() {
    final recent = recentMedia.first;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardWidth = screenWidth < 700 ? double.infinity : 554.0;
    return SizedBox(
      width: cardWidth,
      child: _HoverCardLift(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child:
                      recent.posterUrl == null ||
                          recent.posterUrl!.trim().isEmpty
                      ? Container(
                          width: 84,
                          height: 120,
                          color: context.millitopTheme.panelColor,
                          alignment: Alignment.center,
                          child: Icon(
                            recent.mediaType == 'movie'
                                ? Icons.movie
                                : Icons.tv,
                            size: 30,
                          ),
                        )
                      : Image.network(
                          recent.posterUrl!,
                          width: 84,
                          height: 120,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 84,
                            height: 120,
                            color: context.millitopTheme.panelColor,
                            alignment: Alignment.center,
                            child: Icon(
                              recent.mediaType == 'movie'
                                  ? Icons.movie
                                  : Icons.tv,
                              size: 30,
                            ),
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
                              recent.mediaType == 'movie'
                                  ? 'Continue Movie'
                                  : 'Continue Series',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove from continue watching',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () =>
                                unawaited(_removeRecentMedia(recent)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        recent.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 24,
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
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _openRecentMedia,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(WebAppDefinition app) async {
    try {
      var current = app;
      if (app.managed) {
        await catalog.sync();
        if (!catalog.lastSyncOk) {
          throw StateError(
            'Cannot confirm this managed app is available. Check the device connection and retry.',
          );
        }
        final matches = (await catalog.load(
          widget.profileId,
        )).where((a) => a.id == app.id).toList();
        if (matches.isEmpty) {
          throw StateError('This app is no longer assigned or enabled.');
        }
        current = matches.first;
      }
      if (mounted) {
        await FirefoxBrowser.open(
          context,
          profileId: widget.profileId,
          url: current.url,
          appFullscreen: true,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    }
  }

  Widget _tile(
    String tileId,
    String title,
    String icon,
    VoidCallback launch, {
    WebAppDefinition? app,
    IconData? iconData,
  }) {
    final isHovered = hoveredTileId == tileId;
    final tilt = isHovered ? -0.008 : 0.0;
    return MouseRegion(
      onEnter: (_) => setState(() {
        hoveredTileId = tileId;
        _syncTileFxActivity();
      }),
      onExit: (_) => setState(() {
        if (hoveredTileId == tileId) {
          hoveredTileId = null;
        }
        _syncTileFxActivity();
      }),
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 190),
        curve: Curves.easeOutCubic,
        offset: isHovered ? const Offset(0, -0.03) : Offset.zero,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
          scale: isHovered ? 1.012 : 1.0,
          child: Transform.rotate(
            angle: tilt,
            child: SizedBox(
              width: MediaQuery.sizeOf(context).width < 700
                  ? ((MediaQuery.sizeOf(context).width - 48) / 2).clamp(
                      150.0,
                      230.0,
                    )
                  : 270.0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: isHovered
                      ? const [
                          BoxShadow(
                            color: Color(0x3348D1CC),
                            blurRadius: 14,
                            spreadRadius: 1,
                            offset: Offset(0, 6),
                          ),
                        ]
                      : null,
                ),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 62,
                              height: 62,
                              child: Center(
                                child: _buildTileIcon(
                                  tileId: tileId,
                                  title: title,
                                  icon: icon,
                                  iconData: iconData,
                                  isHovered: isHovered,
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (app != null)
                              IconButton(
                                onPressed: () => editWebApp(
                                  context,
                                  widget.profileId,
                                  app,
                                  catalog: catalog,
                                ),
                                icon: Icon(
                                  app.managed
                                      ? Icons.info_outline
                                      : Icons.settings,
                                ),
                                tooltip: app.managed
                                    ? 'Managed app details'
                                    : 'App settings',
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 23),
                        ),
                        if (app?.managed == true)
                          const Text(
                            'Managed',
                            style: TextStyle(color: Colors.white60),
                          ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: launch,
                          child: const Text('Open'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTileIcon({
    required String tileId,
    required String title,
    required String icon,
    required bool isHovered,
    IconData? iconData,
  }) {
    if (tileId == 'native:youtube' || tileId == 'native:podcasts') {
      return AnimatedMediaAppIcon(
        kind: tileId == 'native:youtube'
            ? MediaAppIconKind.youtube
            : MediaAppIconKind.podcasts,
      );
    }
    if (tileId == 'native:iptvnator') {
      return AnimatedBuilder(
        animation: tileFxController,
        builder: (context, _) {
          final flicker = (tileFx.value * 2 * 3.14159);
          final snowA = 0.2 + ((math.sin(flicker) + 1) * 0.25);
          final snowB = 0.18 + ((math.sin(flicker + 1.2) + 1) * 0.25);
          return SizedBox(
            width: 62,
            height: 62,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(
                  Icons.live_tv_rounded,
                  size: 54,
                  color: Color(0xFF7FE9E0),
                ),
                Positioned(
                  top: 17,
                  left: 12,
                  right: 12,
                  bottom: 15,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: isHovered ? 1 : 0,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: snowA),
                              Colors.white.withValues(alpha: 0.06),
                              Colors.white.withValues(alpha: snowB),
                            ],
                          ),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    if (tileId == 'native:vlc') {
      return AnimatedRotation(
        duration: const Duration(milliseconds: 220),
        turns: isHovered ? 0.015 : -0.015,
        child: const Icon(
          Icons.traffic_rounded,
          size: 52,
          color: Color(0xFFFFA94A),
        ),
      );
    }
    if (tileId == 'native:music') {
      return AnimatedBuilder(
        animation: tileFxController,
        builder: (context, _) {
          final wobble = 1 + (math.sin(tileFx.value * 2 * 3.14159) * 0.03);
          final scale = isHovered ? 1.08 * wobble : 1.0 * wobble;
          return Transform.scale(
            scale: scale,
            child: Icon(
              Icons.library_music_rounded,
              size: 52,
              color: isHovered
                  ? const Color(0xFF9D9CFF)
                  : const Color(0xFF8D7BFF),
            ),
          );
        },
      );
    }
    if (tileId == 'native:vod') {
      return AnimatedBuilder(
        animation: tileFxController,
        builder: (context, _) {
          final pulse = 1 + (math.sin(tileFx.value * 2 * 3.14159) * 0.025);
          return Transform.scale(
            scale: isHovered ? 1.05 * pulse : pulse,
            child: Icon(
              Icons.movie_filter_rounded,
              size: 48,
              color: isHovered
                  ? const Color(0xFFFF7689)
                  : const Color(0xFFFF5D73),
            ),
          );
        },
      );
    }
    final titleLower = title.toLowerCase();
    if (titleLower.contains('emby') || titleLower.contains('jellyfin')) {
      return AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        offset: isHovered ? const Offset(0.05, -0.04) : Offset.zero,
        child: Image.asset(
          'assets/native/$icon.png',
          width: 52,
          height: 52,
          errorBuilder: (_, __, ___) => const Icon(Icons.language, size: 48),
        ),
      );
    }
    if (iconData != null) {
      return Icon(iconData, size: 46, color: const Color(0xFF8D7BFF));
    }
    return Image.asset(
      'assets/native/$icon.png',
      width: 52,
      height: 52,
      errorBuilder: (_, __, ___) => const Icon(Icons.language, size: 48),
    );
  }

  Future<void> _move(String id, int target, List<String> visible) async {
    if (savingOrder) {
      return;
    }
    final order = List<String>.of(visible);
    final previous = order.indexOf(id);
    if (previous < 0 ||
        target < 0 ||
        target >= order.length ||
        previous == target) {
      return;
    }
    order.removeAt(previous);
    order.insert(target, id);
    setState(() => savingOrder = true);
    try {
      await HomePreferences().saveOrder(widget.profileId, order);
      await _syncProfileConfig();
      if (mounted) {
        setState(() {
          savedOrder = order;
          error = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Could not save app order. Your previous order was kept.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => savingOrder = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact = screenWidth < 700;
    final tileWidth = compact
        ? ((screenWidth - 48) / 2).clamp(150.0, 230.0)
        : 270.0;
    final tiles = <String, Widget>{
      'native:iptvnator': _tile(
        'native:iptvnator',
        'Live TV',
        'iptvnator',
        () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => LiveTvScreen(profileId: widget.profileId),
          ),
        ),
      ),
      'native:vod': _tile(
        'native:vod',
        'Movies & Series',
        'movie',
        () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => LiveTvMediaScreen(profileId: widget.profileId),
          ),
        ),
        iconData: Icons.movie_filter_rounded,
      ),
      'native:music': _tile(
        'native:music',
        'Music',
        'music',
        () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => MusicScreen(profileId: widget.profileId),
          ),
        ),
        iconData: Icons.graphic_eq_rounded,
      ),
      'native:youtube': _tile(
        'native:youtube',
        'YouTube',
        'youtube',
        () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => YouTubeScreen(profileId: widget.profileId),
          ),
        ),
        iconData: Icons.smart_display_rounded,
      ),
      'native:podcasts': _tile(
        'native:podcasts',
        'Podcasts',
        'podcasts',
        () => unawaited(_openPodcasts()),
        iconData: Icons.podcasts_rounded,
      ),
      for (final app in apps)
        'web:${app.id}': _tile(
          'web:${app.id}',
          app.title,
          app.icon,
          () => _open(app),
          app: app,
        ),
    };
    final order = mergeAppOrder(tiles.keys.toList(), savedOrder);
    Widget arrange(String id, int index) => DragTarget<String>(
      onWillAcceptWithDetails: (details) => !savingOrder && details.data != id,
      onAcceptWithDetails: (details) =>
          unawaited(_move(details.data, index, order)),
      builder: (context, candidates, rejected) => Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: candidates.isNotEmpty
                ? const Color(0xFF63DFCB)
                : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Draggable<String>(
              data: id,
              feedback: Material(
                color: Colors.transparent,
                child: Opacity(opacity: .8, child: tiles[id]!),
              ),
              childWhenDragging: Opacity(opacity: .3, child: tiles[id]!),
              child: AbsorbPointer(child: tiles[id]!),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Move left',
                  onPressed: savingOrder || index == 0
                      ? null
                      : () => _move(id, index - 1, order),
                  icon: const Icon(Icons.arrow_back),
                ),
                const Icon(Icons.drag_indicator),
                IconButton(
                  tooltip: 'Move right',
                  onPressed: savingOrder || index == order.length - 1
                      ? null
                      : () => _move(id, index + 1, order),
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: savingOrder
                ? null
                : () => setState(() => arranging = !arranging),
            icon: Icon(arranging ? Icons.check : Icons.swap_horiz),
            label: Text(arranging ? 'Done arranging' : 'Arrange apps'),
          ),
        ),
        if (arranging)
          const Text(
            'Drag tiles into order, or use Move left / Move right. Changes are saved for this profile.',
          ),
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(color: Colors.orangeAccent)),
        if (podcastError.isNotEmpty)
          Text(
            podcastError,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (recentLiveTv.isNotEmpty ||
            recentMusicAvailable ||
            recentPodcasts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (recentLiveTv.isNotEmpty) _continueWatchingPanel(),
              if (recentMusicAvailable) _continueListeningMusicPanel(),
              if (recentPodcasts.isNotEmpty) _continueListeningPodcastsPanel(),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (recentMedia.isNotEmpty) ...[
          _continueWatchingMediaPanel(),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (var i = 0; i < order.length; i++)
              KeyedSubtree(
                key: ValueKey(order[i]),
                child: arranging ? arrange(order[i], i) : tiles[order[i]]!,
              ),
            if (!arranging)
              SizedBox(
                width: tileWidth,
                child: OutlinedButton.icon(
                  onPressed: () => editWebApp(
                    context,
                    widget.profileId,
                    null,
                    catalog: catalog,
                  ),
                  icon: const Icon(Icons.add),
                  label: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Add URL app'),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
