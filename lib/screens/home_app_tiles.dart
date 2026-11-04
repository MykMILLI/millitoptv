         import 'dart:async';
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
import '../services/native_app_launcher.dart';
import 'live_tv_screen.dart';
import 'live_tv_media_screen.dart';
import 'music_screen.dart';
import 'app_settings_screen.dart';

class HomeAppTiles extends StatefulWidget {
  final int profileId;
  final WebAppCatalog? catalog;
  const HomeAppTiles({super.key, required this.profileId, this.catalog});
  @override
  State<HomeAppTiles> createState() => _HomeAppTilesState();
}

class _HomeAppTilesState extends State<HomeAppTiles>
    with SingleTickerProviderStateMixin {
  late WebAppCatalog catalog;
  final epgService = const LiveTvEpgService();
  final playlistService = const LiveTvPlaylistService();
  final liveTvControl = LiveTvControlService();
  List<WebAppDefinition> apps = builtinWebApps;
  List<LiveTvRecentChannel> recentLiveTv = [];
  List<LiveTvRecentMedia> recentMedia = [];
  LiveTvProgram? recentNowProgram;
  LiveTvProgram? recentNextProgram;
  late final AnimationController livePulseController;
  late final Animation<double> livePulse;
  String error = '';
  List<String> savedOrder = [];
  bool arranging = false, savingOrder = false;
  @override
  void initState() {
    super.initState();
    livePulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: 1,
    );
    livePulse = Tween<double>(begin: 0.35, end: 1).animate(livePulseController);
    catalog = widget.catalog ?? WebAppCatalog.instance;
    catalog.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    unawaited(_load());
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
      final order = await HomePreferences().order(widget.profileId);
      final recents = await HomePreferences().liveTvRecentChannels(
        widget.profileId,
      );
      final mediaRecents = await HomePreferences().liveTvRecentMedia(
        widget.profileId,
      );
      if (mounted) {
        setState(() {
          apps = values;
          savedOrder = order;
          recentLiveTv = recents.take(8).toList();
          recentMedia = mediaRecents.take(8).toList();
          error = '';
        });
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
    livePulseController.dispose();
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
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child:
                    recent.posterUrl == null || recent.posterUrl!.trim().isEmpty
                    ? Container(
                        width: 84,
                        height: 120,
                        color: const Color(0xFF1F2B3F),
                        alignment: Alignment.center,
                        child: Icon(
                          recent.mediaType == 'movie' ? Icons.movie : Icons.tv,
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
                          color: const Color(0xFF1F2B3F),
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
    String title,
    String icon,
    VoidCallback launch, {
    WebAppDefinition? app,
    IconData? iconData,
  }) => SizedBox(
    width: MediaQuery.sizeOf(context).width < 700
        ? ((MediaQuery.sizeOf(context).width - 48) / 2).clamp(150.0, 230.0)
        : 270.0,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (iconData != null)
                  Icon(iconData, size: 46, color: const Color(0xFF8D7BFF))
                else
                  Image.asset(
                    'assets/native/$icon.png',
                    width: 52,
                    height: 52,
                    errorBuilder: (_, e, s) =>
                        const Icon(Icons.language, size: 48),
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
                      app.managed ? Icons.info_outline : Icons.settings,
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
              const Text('Managed', style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 12),
            FilledButton(onPressed: launch, child: const Text('Open')),
          ],
        ),
      ),
    ),
  );
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
        'Live TV',
        'iptvnator',
        () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => LiveTvScreen(profileId: widget.profileId),
          ),
        ),
      ),
      'native:vlc': _tile(
        'VLC player',
        'vlc',
        () =>
            NativeAppLauncher.open(context, appKey: 'vlc', title: 'VLC player'),
      ),
      'native:music': _tile(
        'Music',
        'music',
        () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => MusicScreen(profileId: widget.profileId),
          ),
        ),
        iconData: Icons.graphic_eq_rounded,
      ),
      for (final app in apps)
        'web:${app.id}': _tile(app.title, app.icon, () => _open(app), app: app),
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
        if (recentLiveTv.isNotEmpty) ...[
          const SizedBox(height: 8),
          _continueWatchingPanel(),
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
