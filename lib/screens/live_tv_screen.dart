import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/device_connection.dart';
import '../services/home_preferences.dart';
import '../services/live_tv_epg.dart';
import '../services/live_tv_playlist.dart';
import '../services/live_tv_source.dart';
import '../services/live_tv_sync.dart';
import '../services/live_tv_control.dart';
import '../services/playback_performance.dart';
import '../services/pip_playback.dart';
import '../services/viewing_sessions.dart';
import 'live_tv_media_screen.dart';

enum _ChannelFilterMode { all, favorites, recent }

class LiveTvScreen extends StatefulWidget {
  final int profileId;
  final String? initialSourceId;
  final String? initialChannelId;
  final bool openGuideOnStart;
  const LiveTvScreen({
    super.key,
    required this.profileId,
    this.initialSourceId,
    this.initialChannelId,
    this.openGuideOnStart = false,
  });

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {
  final service = const LiveTvPlaylistService();
  final epgService = const LiveTvEpgService();
  final syncService = LiveTvSyncService();
  final controlService = LiveTvControlService();
  final subscriptions = <StreamSubscription<dynamic>>[];
  final sessionKey = 'live-tv';
  final timerSessionKey = 'native-live-tv';
  final secondaryTimerSessionKey = 'native-live-tv-secondary';
  final search = TextEditingController();
  final FocusNode fullScreenFocusNode = FocusNode();
  Player? player;
  VideoController? video;
  Player? secondaryPlayer;
  VideoController? secondaryVideo;
  Player? tertiaryPlayer;
  VideoController? tertiaryVideo;
  Player? quaternaryPlayer;
  VideoController? quaternaryVideo;
  List<LiveTvSource> sources = [];
  List<LiveTvChannel> channels = [];
  List<String> groupOptions = const ['All'];
  List<LiveTvChannel> visibleChannels = const [];
  Set<String> duplicateChannelTitles = const {};
  final Map<String, List<String>> categoryRecencyBySource = {};
  final Map<String, String> selectedGroupByScope = {};
  LiveTvSource? source;
  bool allSourcesSelected = true;
  LiveTvChannel? selected;
  LiveTvChannel? selectedSecondary;
  LiveTvChannel? selectedTertiary;
  LiveTvChannel? selectedQuaternary;
  String selectedGroup = 'All';
  _ChannelFilterMode filterMode = _ChannelFilterMode.all;
  bool loading = true;
  bool opening = false;
  bool openingSecondary = false;
  bool openingTertiary = false;
  bool openingQuaternary = false;
  bool reconnecting = false;
  bool syncing = false;
  bool recording = false;
  bool osdVisible = false;
  bool mediaActive = false;
  int screenCount = 1;
  bool fullScreenVideo = false;
  bool fullScreenControlsVisible = true;
  int focusedPane = 0;
  String status = '';
  String error = '';
  String syncStatus = '';
  Timer? watchdog;
  Timer? reconnectMessageClear;
  Timer? osdHide;
  Timer? fullScreenControlsHide;
  DateTime? lastProgressAt;
  DateTime? lastReconnectAt;
  DateTime? becameNotPlayingAt;
  Duration lastPosition = Duration.zero;
  Duration lastDuration = Duration.zero;
  bool isPlaying = false;
  int reconnectAttempts = 0;
  Set<String> favorites = {};
  List<String> history = [];
  LiveTvEpg? epg;
  final Map<String, LiveTvEpg> epgBySource = {};
  final Map<String, List<LiveTvProgram>> xtreamEpgFallback = {};
  final Set<String> xtreamEpgRequests = {};
  final Set<String> epgLoadingSourceIds = {};
  final Set<String> scopedSourceIds = {};
  final Map<String, Set<String>> scopedGroupsBySource = {};
  Timer? profileSyncDebounce;
  Timer? playbackStatusTimer;
  final Map<int, String> playbackEngineStatusByPane = {};
  PlaybackPerformanceSettings playbackPerformance =
      const PlaybackPerformanceSettings();
  bool playbackTuningWarningShown = false;

  void _recomputeChannelViews() {
    final availableGroups = channels
        .map((channel) => channel.group?.trim() ?? '')
        .where((group) => group.isNotEmpty)
        .toSet();
    final sourceRecency = categoryRecencyBySource[_sourceId()] ?? const [];
    final recencyRank = <String, int>{};
    for (var i = 0; i < sourceRecency.length; i++) {
      recencyRank[sourceRecency[i]] = i;
    }
    final sortedGroups = availableGroups.toList()
      ..sort((a, b) {
        final ar = recencyRank[a];
        final br = recencyRank[b];
        if (ar != null && br != null) {
          return ar.compareTo(br);
        }
        if (ar != null) {
          return -1;
        }
        if (br != null) {
          return 1;
        }
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    final nextGroups = ['All', ...sortedGroups];
    final effectiveGroup = nextGroups.contains(selectedGroup)
        ? selectedGroup
        : 'All';
    final query = search.text.trim().toLowerCase();
    final recentKeys = history.toSet();
    final rankedHistory = <String, int>{};
    for (var i = 0; i < history.length; i++) {
      rankedHistory[history[i]] = i;
    }
    final filtered = channels.where((channel) {
      final key = _channelKey(channel);
      if (filterMode == _ChannelFilterMode.favorites && !_favorite(channel)) {
        return false;
      }
      if (filterMode == _ChannelFilterMode.recent &&
          !recentKeys.contains(key)) {
        return false;
      }
      if (effectiveGroup != 'All' && (channel.group ?? '') != effectiveGroup) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      final title = channel.title.toLowerCase();
      final group = (channel.group ?? '').toLowerCase();
      if (title.contains(query) || group.contains(query)) {
        return true;
      }
      final programText = _programsForChannel(
        channel,
      ).take(6).map((item) => item.title.toLowerCase()).join(' ');
      return programText.contains(query);
    }).toList();
    if (filterMode == _ChannelFilterMode.recent) {
      filtered.sort((a, b) {
        final ar = rankedHistory[_channelKey(a)] ?? 100000;
        final br = rankedHistory[_channelKey(b)] ?? 100000;
        return ar.compareTo(br);
      });
    }
    final titleCounts = <String, int>{};
    for (final channel in channels) {
      final normalized = channel.title.trim().toLowerCase();
      if (normalized.isEmpty) {
        continue;
      }
      titleCounts[normalized] = (titleCounts[normalized] ?? 0) + 1;
    }
    final duplicates = titleCounts.entries
        .where((entry) => entry.value > 1)
        .map((entry) => entry.key)
        .toSet();
    _setState(() {
      selectedGroup = effectiveGroup;
      groupOptions = nextGroups;
      visibleChannels = filtered;
      duplicateChannelTitles = duplicates;
    });
  }

  void _pinCategorySelection(String group) {
    if (group == 'All') {
      return;
    }
    final key = _sourceId();
    final current = categoryRecencyBySource[key] ?? const [];
    categoryRecencyBySource[key] = [
      group,
      ...current.where((item) => item != group),
    ].take(40).toList();
  }

  String _channelToken(LiveTvChannel channel) =>
      channel.tvgId?.trim().isNotEmpty == true
      ? 'tvg:${channel.tvgId!.trim()}'
      : 'name:${channel.title.toLowerCase()}';

  String _channelKey(LiveTvChannel channel) {
    final sourceId = channel.sourceId ?? source?.id ?? 'unknown';
    return '$sourceId|${_channelToken(channel)}';
  }

  String _sourceId() {
    if (allSourcesSelected) {
      return 'all';
    }
    return source?.id ?? 'default';
  }

  bool get splitScreen => screenCount > 1;

  Player? _playerForPane(int pane) {
    switch (pane) {
      case 1:
        return secondaryPlayer;
      case 2:
        return tertiaryPlayer;
      case 3:
        return quaternaryPlayer;
      default:
        return player;
    }
  }

  VideoController? _videoForPane(int pane) {
    switch (pane) {
      case 1:
        return secondaryVideo;
      case 2:
        return tertiaryVideo;
      case 3:
        return quaternaryVideo;
      default:
        return video;
    }
  }

  LiveTvChannel? _channelForPane(int pane) {
    switch (pane) {
      case 1:
        return selectedSecondary;
      case 2:
        return selectedTertiary;
      case 3:
        return selectedQuaternary;
      default:
        return selected;
    }
  }

  bool _openingForPane(int pane) {
    switch (pane) {
      case 1:
        return openingSecondary;
      case 2:
        return openingTertiary;
      case 3:
        return openingQuaternary;
      default:
        return opening;
    }
  }

  String _sourceTag(LiveTvChannel? channel) =>
      channel?.sourceName?.trim().isNotEmpty == true
      ? channel!.sourceName!.trim()
      : 'Unknown Source';

  String _paneLabel(int pane) {
    switch (pane) {
      case 1:
        return 'Top Right';
      case 2:
        return 'Bottom Left';
      case 3:
        return 'Bottom Right';
      default:
        return 'Top Left';
    }
  }

  LiveTvChannel? _channelByKey(String key) {
    final normalized = key.trim();
    for (final channel in channels) {
      if (_channelKey(channel) == normalized ||
          _channelToken(channel) == normalized ||
          _channelKey(channel).endsWith('|$normalized')) {
        return channel;
      }
    }
    return null;
  }

  bool _favorite(LiveTvChannel channel) =>
      favorites.contains(_channelKey(channel));

  String _displayTitle(LiveTvChannel channel) {
    if (!duplicateChannelTitles.contains(channel.title.trim().toLowerCase())) {
      return channel.title;
    }
    final group = channel.group?.trim();
    if (group != null && group.isNotEmpty) {
      return '${channel.title} ($group)';
    }
    if (channel.tvgId?.trim().isNotEmpty == true) {
      return '${channel.title} (${channel.tvgId!.trim()})';
    }
    return channel.title;
  }

  LiveTvProgram? _currentProgram(LiveTvChannel channel) {
    final values = _programsForChannel(channel);
    if (values.isEmpty) {
      return null;
    }
    final now = DateTime.now().toUtc();
    for (final item in values) {
      if (item.contains(now)) {
        return item;
      }
    }
    return null;
  }

  LiveTvProgram? _nextProgram(LiveTvChannel channel) {
    final values = _programsForChannel(channel);
    if (values.isEmpty) {
      return null;
    }
    final now = DateTime.now().toUtc();
    LiveTvProgram? current;
    for (final item in values) {
      if (item.contains(now)) {
        current = item;
        break;
      }
    }
    if (current != null) {
      final index = values.indexOf(current);
      if (index >= 0 && index + 1 < values.length) {
        return values[index + 1];
      }
    }
    for (final item in values) {
      if (!item.start.isBefore(now)) {
        return item;
      }
    }
    return null;
  }

  List<LiveTvProgram> _programsForChannel(LiveTvChannel channel) {
    final sourceId = channel.sourceId ?? source?.id;
    final selectedEpg = sourceId == null ? epg : epgBySource[sourceId] ?? epg;
    if (selectedEpg != null) {
      final id = selectedEpg.resolveChannelId(
        tvgId: channel.tvgId,
        channelTitle: channel.title,
      );
      if (id != null && id.isNotEmpty) {
        final values = selectedEpg.byChannelId[id];
        if (values != null && values.isNotEmpty) {
          return values;
        }
      }
    }
    return xtreamEpgFallback[_channelKey(channel)] ?? const [];
  }

  Future<void> _loadXtreamFallbackEpg(LiveTvChannel channel) async {
    final selectedSource = sources.firstWhere(
      (item) => item.id == channel.sourceId,
      orElse: () => source ?? sources.first,
    );
    if (!selectedSource.isXtream) {
      return;
    }
    final streamId = channel.streamId?.trim() ?? '';
    if (streamId.isEmpty) {
      return;
    }
    final key = '${selectedSource.id}|$streamId';
    if (xtreamEpgRequests.contains(key)) {
      return;
    }
    xtreamEpgRequests.add(key);
    try {
      final values = await service.loadXtreamShortEpg(selectedSource, streamId);
      if (!mounted || selectedSource.id != source?.id) {
        return;
      }
      if (values.isNotEmpty) {
        _setState(() => xtreamEpgFallback[_channelKey(channel)] = values);
      }
    } catch (_) {
    } finally {
      xtreamEpgRequests.remove(key);
    }
  }

  @override
  void initState() {
    super.initState();
    search.addListener(_recomputeChannelViews);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    watchdog?.cancel();
    reconnectMessageClear?.cancel();
    osdHide?.cancel();
    fullScreenControlsHide?.cancel();
    profileSyncDebounce?.cancel();
    playbackStatusTimer?.cancel();
    fullScreenFocusNode.dispose();
    search.dispose();
    ViewingSessions.instance.remove(timerSessionKey);
    ViewingSessions.instance.remove(secondaryTimerSessionKey);
    ViewingSessions.instance.remove('native-live-tv-tertiary');
    ViewingSessions.instance.remove('native-live-tv-quaternary');
    unawaited(_disposePlayer());
    unawaited(_disposeSecondaryPlayer());
    unawaited(_disposeTertiaryPlayer());
    unawaited(_disposeQuaternaryPlayer());
    super.dispose();
  }

  void _setState(VoidCallback update) {
    if (mounted) {
      setState(update);
    }
  }

  Future<Player> _createConfiguredPlayer() async {
    final created = Player(
      configuration: playerConfigurationFor(playbackPerformance),
    );
    try {
      await applyNativePlaybackPerformance(created, playbackPerformance);
    } catch (error) {
      if (!playbackTuningWarningShown) {
        playbackTuningWarningShown = true;
        _setState(
          () =>
              status =
                  'Playback tuning is partially unavailable on this device: $error',
        );
      }
    }
    return created;
  }

  void _ensurePlaybackStatusPolling() {
    playbackStatusTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_refreshPlaybackEngineStatuses());
    });
    unawaited(_refreshPlaybackEngineStatuses());
  }

  Future<void> _refreshPlaybackEngineStatuses() async {
    final entries = <MapEntry<int, Player>>[];
    for (var pane = 0; pane < 4; pane++) {
      final current = _playerForPane(pane);
      if (current != null) {
        entries.add(MapEntry(pane, current));
      }
    }
    if (entries.isEmpty) {
      if (playbackEngineStatusByPane.isNotEmpty && mounted) {
        _setState(() => playbackEngineStatusByPane.clear());
      }
      return;
    }
    final labels = await Future.wait(
      entries.map(
        (entry) => playbackEngineStatusLabel(entry.value, playbackPerformance),
      ),
    );
    if (!mounted) {
      return;
    }
    _setState(() {
      for (var index = 0; index < entries.length; index++) {
        playbackEngineStatusByPane[entries[index].key] = labels[index];
      }
      playbackEngineStatusByPane.removeWhere(
        (pane, _) => entries.every((entry) => entry.key != pane),
      );
    });
  }

  Future<void> _initialize() async {
    await _pullRemoteProfileSnapshot();
    playbackPerformance = await HomePreferences().playbackPerformance(
      widget.profileId,
    );
    await _loadLocalRecent();
    await _loadUiState();
    await _loadSources();
    if (source != null) {
      await _loadChannels();
      if (widget.openGuideOnStart && mounted && selected != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showEpgGuide();
          }
        });
      }
    } else {
      _setState(() {
        loading = false;
        status = '';
        error =
            'Add a Live TV source (M3U or Xtream API) to begin. Select Manage Sources.';
      });
    }
  }

  Future<void> _minimizeToPipAndGoHome() async {
    final current = player;
    final currentVideo = video;
    final channel = selected;
    if (current == null || currentVideo == null || channel == null) {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return;
    }
    watchdog?.cancel();
    watchdog = null;
    reconnectMessageClear?.cancel();
    reconnectMessageClear = null;
    osdHide?.cancel();
    osdHide = null;
    fullScreenControlsHide?.cancel();
    fullScreenControlsHide = null;
    playbackStatusTimer?.cancel();
    playbackStatusTimer = null;
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    player = null;
    video = null;
    reconnecting = false;
    reconnectAttempts = 0;
    lastReconnectAt = null;
    becameNotPlayingAt = null;
    lastProgressAt = null;
    lastPosition = Duration.zero;
    lastDuration = Duration.zero;
    isPlaying = false;
    await _disposeSecondaryPlayer();
    await _disposeTertiaryPlayer();
    await _disposeQuaternaryPlayer();
    await PipPlaybackController.instance.minimize(
      PipPlaybackSession(
        player: current,
        video: currentVideo,
        title: channel.title,
        subtitle: channel.sourceName,
        seekable: false,
        onClose: () async {
          try {
            await current.dispose().timeout(const Duration(seconds: 8));
          } catch (_) {}
          if (mediaActive) {
            DeviceConnection.instance.setMediaActive(sessionKey, false);
            mediaActive = false;
          }
          ViewingSessions.instance.remove(timerSessionKey);
          ViewingSessions.instance.remove(secondaryTimerSessionKey);
          ViewingSessions.instance.remove('native-live-tv-tertiary');
          ViewingSessions.instance.remove('native-live-tv-quaternary');
          await _reportPlaybackState(channel, active: false);
        },
      ),
    );
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  List<String> _readStringList(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Map<String, Set<String>> _readStringSetMap(dynamic raw) {
    if (raw is! Map) {
      return const {};
    }
    final values = <String, Set<String>>{};
    for (final entry in raw.entries) {
      final key = entry.key.toString().trim();
      if (key.isEmpty) {
        continue;
      }
      final items = _readStringList(entry.value).toSet();
      if (items.isNotEmpty) {
        values[key] = items;
      }
    }
    return values;
  }

  Future<void> _loadUiState() async {
    try {
      final uiState = await HomePreferences().liveTvUiState(widget.profileId);
      if (!mounted || uiState.isEmpty) {
        return;
      }
      final scopedSources = _readStringList(uiState['scopedSourceIds']);
      final selectedGroupsByScope = <String, String>{};
      final selectedRaw = uiState['selectedGroupByScope'];
      if (selectedRaw is Map) {
        for (final entry in selectedRaw.entries) {
          final key = entry.key.toString().trim();
          final value = entry.value.toString().trim();
          if (key.isNotEmpty && value.isNotEmpty) {
            selectedGroupsByScope[key] = value;
          }
        }
      }
      final recencyRaw = uiState['categoryRecencyBySource'];
      final recency = <String, List<String>>{};
      if (recencyRaw is Map) {
        for (final entry in recencyRaw.entries) {
          final key = entry.key.toString().trim();
          final values = _readStringList(entry.value);
          if (key.isNotEmpty && values.isNotEmpty) {
            recency[key] = values;
          }
        }
      }
      final scopedGroups = _readStringSetMap(uiState['scopedGroupsBySource']);
      _setState(() {
        scopedSourceIds
          ..clear()
          ..addAll(scopedSources);
        scopedGroupsBySource
          ..clear()
          ..addAll(scopedGroups);
        categoryRecencyBySource
          ..clear()
          ..addAll(recency);
        selectedGroupByScope
          ..clear()
          ..addAll(selectedGroupsByScope);
      });
    } catch (_) {}
  }

  Future<void> _saveUiState() async {
    final uiState = {
      'scopedSourceIds': scopedSourceIds.toList(),
      'scopedGroupsBySource': {
        for (final entry in scopedGroupsBySource.entries)
          entry.key: entry.value.toList(),
      },
      'categoryRecencyBySource': categoryRecencyBySource,
      'selectedGroupByScope': selectedGroupByScope,
    };
    try {
      await HomePreferences().saveLiveTvUiState(widget.profileId, uiState);
    } catch (_) {}
  }

  Future<void> _pullRemoteProfileSnapshot() async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      final remote = await controlService.pullConfig(
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

  Future<void> _loadLocalRecent() async {
    try {
      final recents = await HomePreferences().liveTvRecentChannels(
        widget.profileId,
      );
      if (!mounted) {
        return;
      }
      _setState(() {
        history = recents
            .map((item) => '${item.sourceId}|${item.channelId}')
            .toList();
      });
      _recomputeChannelViews();
    } catch (_) {}
  }

  Future<void> _loadSources() async {
    final next = await HomePreferences().liveTvSources(widget.profileId);
    final sourceIds = next.map((item) => item.id).toSet();
    scopedSourceIds.removeWhere((id) => !sourceIds.contains(id));
    final obsoleteGroupKeys = scopedGroupsBySource.keys
        .where((id) => !sourceIds.contains(id))
        .toList();
    for (final key in obsoleteGroupKeys) {
      scopedGroupsBySource.remove(key);
    }
    if (!mounted) {
      return;
    }
    _setState(() {
      sources = next;
      if (sources.isEmpty) {
        source = null;
        allSourcesSelected = false;
      } else {
        final requested = widget.initialSourceId;
        source = next.firstWhere(
          (item) => item.id == requested || item.id == source?.id,
          orElse: () => next.first,
        );
        allSourcesSelected = requested == null || requested.trim().isEmpty;
      }
      selectedGroup = selectedGroupByScope[_sourceId()] ?? 'All';
    });
  }

  Future<void> _saveSources(List<LiveTvSource> values) async {
    await HomePreferences().saveLiveTvSources(widget.profileId, values);
    await _loadSources();
    await _pushRemoteConfig();
  }

  Future<void> _pushRemoteConfig() async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      await controlService.pushConfig(
        expectedConnection: connection,
        profileId: widget.profileId,
        sources: sources,
        tmdbApiKey: await HomePreferences().tmdbApiKey(widget.profileId),
        profileState: await HomePreferences().liveTvProfileSyncState(
          widget.profileId,
        ),
      );
    } catch (_) {}
  }

  Future<void> _scheduleProfileSync() async {
    await _saveUiState();
    profileSyncDebounce?.cancel();
    profileSyncDebounce = Timer(const Duration(milliseconds: 900), () {
      unawaited(_pushRemoteConfig());
    });
  }

  LiveTvSource? _sourceForChannel(LiveTvChannel channel) {
    if (sources.isEmpty) {
      return null;
    }
    return sources.firstWhere(
      (item) => item.id == channel.sourceId,
      orElse: () => source ?? sources.first,
    );
  }

  Future<void> _reportPlaybackState(
    LiveTvChannel channel, {
    required bool active,
  }) async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    final selectedSource = _sourceForChannel(channel);
    if (selectedSource == null) {
      return;
    }
    try {
      await controlService.reportPlayback(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: selectedSource.id,
        sourceName: selectedSource.name,
        mediaType: 'channel',
        mediaId: _channelToken(channel),
        title: channel.title,
        active: active,
      );
    } catch (_) {}
  }

  Future<void> _loadChannels() async {
    if (sources.isEmpty) {
      return;
    }
    final selectedSource = source ?? sources.first;
    final activeSources = allSourcesSelected
        ? List<LiveTvSource>.from(
            scopedSourceIds.isEmpty
                ? sources
                : sources.where((item) => scopedSourceIds.contains(item.id)),
          )
        : <LiveTvSource>[selectedSource];
    if (activeSources.isEmpty) {
      _setState(() {
        channels = [];
        visibleChannels = const [];
        groupOptions = const ['All'];
        loading = false;
        status = 'No sources selected in Channel Scope.';
        error = '';
      });
      return;
    }
    _setState(() {
      loading = true;
      error = '';
      status = allSourcesSelected
          ? 'Loading ${activeSources.length} source(s): ${activeSources.take(3).map((item) => item.name).join(', ')}${activeSources.length > 3 ? '…' : ''}'
          : 'Loading channels from ${selectedSource.name}...';
      channels = [];
      visibleChannels = const [];
      groupOptions = const ['All'];
      duplicateChannelTitles = const {};
      xtreamEpgFallback.clear();
      xtreamEpgRequests.clear();
      final validSourceIds = sources.map((item) => item.id).toSet();
      final staleIds = epgBySource.keys
          .where((id) => !validSourceIds.contains(id))
          .toList();
      for (final id in staleIds) {
        epgBySource.remove(id);
      }
      epg = source == null ? null : epgBySource[source!.id];
      selectedGroup = selectedGroupByScope[_sourceId()] ?? 'All';
    });
    try {
      var completed = 0;
      var mergedCount = 0;
      final total = activeSources.length;
      final results = activeSources.map((activeSource) async {
        try {
          final loaded = await service
              .loadFromSource(activeSource)
              .timeout(const Duration(seconds: 25));
          final allowedGroups = scopedGroupsBySource[activeSource.id];
          final filteredChannels = loaded.channels.where((channel) {
            if (allowedGroups == null || allowedGroups.isEmpty) {
              return true;
            }
            final group = channel.group?.trim() ?? '';
            return group.isNotEmpty && allowedGroups.contains(group);
          }).toList();
          final mapped = filteredChannels
              .map(
                (channel) => LiveTvChannel(
                  title: channel.title,
                  streamUrl: channel.streamUrl,
                  group: channel.group,
                  logo: channel.logo,
                  tvgId: channel.tvgId,
                  streamId: channel.streamId,
                  sourceId: activeSource.id,
                  sourceName: activeSource.name,
                ),
              )
              .toList();
          completed++;
          mergedCount += mapped.length;
          if (mounted) {
            _setState(() {
              status =
                  'Loaded $completed/$total sources · $mergedCount channels so far';
            });
          }
          return mapped;
        } catch (_) {
          completed++;
          if (mounted) {
            _setState(() {
              status =
                  'Loaded $completed/$total sources · $mergedCount channels so far';
            });
          }
          return <LiveTvChannel>[];
        }
      }).toList();
      final loadedBySource = await Future.wait(results);
      final merged = <LiveTvChannel>[
        for (final list in loadedBySource) ...list,
      ];
      if (!mounted) {
        return;
      }
      _setState(() {
        channels = merged;
        loading = false;
        status = 'Loaded ${merged.length} channels';
      });
      _recomputeChannelViews();
      unawaited(_loadEpg());
      unawaited(_loadSyncState());
      LiveTvChannel? toOpen;
      final requested = widget.initialChannelId;
      if (requested != null && requested.trim().isNotEmpty) {
        toOpen = _channelByKey(requested.trim());
      }
      toOpen ??= history.isNotEmpty ? _channelByKey(history.first) : null;
      toOpen ??= visibleChannels.isNotEmpty ? visibleChannels.first : null;
      if (toOpen != null && selected == null && !splitScreen) {
        await _open(toOpen);
      }
    } catch (e) {
      _setState(() {
        loading = false;
        epg = null;
        epgBySource.clear();
        error = e
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('FormatException: ', '');
      });
    }
  }

  Future<void> _loadEpg() async {
    final selectedSource =
        source ?? (sources.isNotEmpty ? sources.first : null);
    if (selectedSource == null || sources.isEmpty) {
      _setState(() => epg = null);
      return;
    }
    final activeSources = <LiveTvSource>[selectedSource];
    final loadedBySource = <String, LiveTvEpg>{};
    for (final item in activeSources) {
      final loaded = await _ensureEpgForSource(item.id);
      if (loaded != null) {
        loadedBySource[item.id] = loaded;
      }
    }
    if (!mounted) {
      return;
    }
    _setState(() {
      epgBySource
        ..clear()
        ..addAll(loadedBySource);
      epg = epgBySource[selectedSource.id];
    });
  }

  String? _epgUrlForSource(LiveTvSource item) {
    String? epgUrl = item.epgUrl?.trim();
    if ((epgUrl == null || epgUrl.isEmpty) && item.isXtream) {
      final server = item.serverUrl?.trim() ?? '';
      final username = item.username?.trim() ?? '';
      final password = item.password?.trim() ?? '';
      if (server.isNotEmpty && username.isNotEmpty && password.isNotEmpty) {
        final parsed = Uri.tryParse(server);
        if (parsed != null && parsed.isAbsolute) {
          epgUrl = parsed
              .replace(
                path: '/xmltv.php',
                queryParameters: {'username': username, 'password': password},
              )
              .toString();
        }
      }
    }
    return epgUrl == null || epgUrl.isEmpty ? null : epgUrl;
  }

  Future<LiveTvEpg?> _ensureEpgForSource(String sourceId) async {
    final cached = epgBySource[sourceId];
    if (cached != null) {
      return cached;
    }
    if (epgLoadingSourceIds.contains(sourceId)) {
      return null;
    }
    final sourceItem = sources.where((item) => item.id == sourceId).toList();
    if (sourceItem.isEmpty) {
      return null;
    }
    final epgUrl = _epgUrlForSource(sourceItem.first);
    if (epgUrl == null) {
      return null;
    }
    epgLoadingSourceIds.add(sourceId);
    try {
      final loaded = await epgService
          .loadFromUrl(epgUrl)
          .timeout(const Duration(seconds: 18));
      epgBySource[sourceId] = loaded;
      if (mounted && source?.id == sourceId) {
        _setState(() => epg = loaded);
      }
      return loaded;
    } catch (_) {
      return null;
    } finally {
      epgLoadingSourceIds.remove(sourceId);
    }
  }

  Future<void> _loadSyncState() async {
    if (allSourcesSelected) {
      return;
    }
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty ||
        !DeviceConnection.instance.isConnected ||
        source == null) {
      return;
    }
    syncing = true;
    _setState(() => syncStatus = 'Syncing favorites...');
    try {
      final snapshot = await syncService.load(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: _sourceId(),
      );
      if (!mounted || source == null) {
        return;
      }
      _setState(() {
        favorites = snapshot.favorites;
        history = [
          ...snapshot.history,
          ...history.where((value) => !snapshot.history.contains(value)),
        ].take(50).toList();
        syncStatus = '';
      });
      _recomputeChannelViews();
    } catch (_) {
      if (mounted) {
        _setState(() => syncStatus = 'Favorites sync unavailable (offline).');
      }
    } finally {
      syncing = false;
    }
  }

  Future<void> _ensurePlayer() async {
    if (player != null && video != null) {
      return;
    }
    MediaKit.ensureInitialized();
    final created = await _createConfiguredPlayer();
    _ensurePlaybackStatusPolling();
    final controller = VideoController(created);
    subscriptions.add(
      created.stream.duration.listen((value) {
        lastDuration = value;
      }),
    );
    subscriptions.add(
      created.stream.position.listen((value) {
        if (value != lastPosition) {
          lastPosition = value;
          lastProgressAt = DateTime.now();
        }
      }),
    );
    subscriptions.add(
      created.stream.playing.listen((value) {
        isPlaying = value;
        if (value) {
          becameNotPlayingAt = null;
          lastProgressAt = DateTime.now();
        } else {
          becameNotPlayingAt ??= DateTime.now();
        }
      }),
    );
    subscriptions.add(
      created.stream.error.listen((_) {
        _setState(() {
          status = 'Stream interrupted. Recovering...';
          error = '';
        });
        unawaited(_reconnect('The stream reported an error.'));
      }),
    );
    player = created;
    video = controller;
    if (!mediaActive) {
      DeviceConnection.instance.setMediaActive(sessionKey, true);
      mediaActive = true;
    }
    ViewingSessions.instance.register(timerSessionKey, () async {
      await _disposePlayer();
    });
    watchdog ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_verifyPlaybackHealth());
    });
  }

  Future<void> _disposePlayer() async {
    watchdog?.cancel();
    watchdog = null;
    reconnectMessageClear?.cancel();
    reconnectMessageClear = null;
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    subscriptions.clear();
    final current = player;
    player = null;
    video = null;
    reconnecting = false;
    reconnectAttempts = 0;
    lastReconnectAt = null;
    becameNotPlayingAt = null;
    lastProgressAt = null;
    lastPosition = Duration.zero;
    lastDuration = Duration.zero;
    isPlaying = false;
    if (current != null) {
      try {
        await current.dispose().timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (mediaActive) {
      DeviceConnection.instance.setMediaActive(sessionKey, false);
      mediaActive = false;
    }
  }

  Future<void> _ensureSecondaryPlayer() async {
    if (secondaryPlayer != null && secondaryVideo != null) {
      return;
    }
    MediaKit.ensureInitialized();
    final created = await _createConfiguredPlayer();
    _ensurePlaybackStatusPolling();
    final controller = VideoController(created);
    secondaryPlayer = created;
    secondaryVideo = controller;
    try {
      await created.setVolume(0);
    } catch (_) {}
    ViewingSessions.instance.register(secondaryTimerSessionKey, () async {
      await _disposeSecondaryPlayer();
    });
  }

  Future<void> _ensureTertiaryPlayer() async {
    if (tertiaryPlayer != null && tertiaryVideo != null) {
      return;
    }
    MediaKit.ensureInitialized();
    final created = await _createConfiguredPlayer();
    _ensurePlaybackStatusPolling();
    final controller = VideoController(created);
    tertiaryPlayer = created;
    tertiaryVideo = controller;
    try {
      await created.setVolume(0);
    } catch (_) {}
    ViewingSessions.instance.register('native-live-tv-tertiary', () async {
      await _disposeTertiaryPlayer();
    });
  }

  Future<void> _ensureQuaternaryPlayer() async {
    if (quaternaryPlayer != null && quaternaryVideo != null) {
      return;
    }
    MediaKit.ensureInitialized();
    final created = await _createConfiguredPlayer();
    _ensurePlaybackStatusPolling();
    final controller = VideoController(created);
    quaternaryPlayer = created;
    quaternaryVideo = controller;
    try {
      await created.setVolume(0);
    } catch (_) {}
    ViewingSessions.instance.register('native-live-tv-quaternary', () async {
      await _disposeQuaternaryPlayer();
    });
  }

  Future<void> _disposeSecondaryPlayer() async {
    final current = secondaryPlayer;
    secondaryPlayer = null;
    secondaryVideo = null;
    selectedSecondary = null;
    openingSecondary = false;
    if (current != null) {
      try {
        await current.dispose().timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
  }

  Future<void> _disposeTertiaryPlayer() async {
    final current = tertiaryPlayer;
    tertiaryPlayer = null;
    tertiaryVideo = null;
    selectedTertiary = null;
    openingTertiary = false;
    if (current != null) {
      try {
        await current.dispose().timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
  }

  Future<void> _disposeQuaternaryPlayer() async {
    final current = quaternaryPlayer;
    quaternaryPlayer = null;
    quaternaryVideo = null;
    selectedQuaternary = null;
    openingQuaternary = false;
    if (current != null) {
      try {
        await current.dispose().timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
  }

  Future<void> _setFocusedPane(int pane) async {
    focusedPane = pane.clamp(0, screenCount - 1);
    try {
      await player?.setVolume(focusedPane == 0 ? 100 : 0);
    } catch (_) {}
    try {
      await secondaryPlayer?.setVolume(focusedPane == 1 ? 100 : 0);
    } catch (_) {}
    try {
      await tertiaryPlayer?.setVolume(focusedPane == 2 ? 100 : 0);
    } catch (_) {}
    try {
      await quaternaryPlayer?.setVolume(focusedPane == 3 ? 100 : 0);
    } catch (_) {}
    final focusedChannel = _channelForPane(focusedPane);
    if (focusedChannel != null) {
      status =
          'Focused ${_paneLabel(focusedPane)} · ${focusedChannel.title} · ${_sourceTag(focusedChannel)}';
    }
    _setState(() {});
  }

  Future<void> _open(LiveTvChannel channel) async {
    await _openOnPane(0, channel);
  }

  Future<void> _openOnPane(int pane, LiveTvChannel channel) async {
    if (_openingForPane(pane)) {
      return;
    }
    final paneName = _paneLabel(pane);
    _setState(() {
      if (pane == 0) {
        opening = true;
        selected = channel;
      } else if (pane == 1) {
        openingSecondary = true;
        selectedSecondary = channel;
      } else if (pane == 2) {
        openingTertiary = true;
        selectedTertiary = channel;
      } else {
        openingQuaternary = true;
        selectedQuaternary = channel;
      }
      error = '';
      status = 'Opening ${channel.title} on $paneName...';
    });
    try {
      if (pane == 0) {
        await _ensurePlayer();
      } else if (pane == 1) {
        await _ensureSecondaryPlayer();
      } else if (pane == 2) {
        await _ensureTertiaryPlayer();
      } else {
        await _ensureQuaternaryPlayer();
      }
      final current = _playerForPane(pane);
      if (current == null) {
        throw StateError('Live TV pane player is unavailable.');
      }
      await current
          .open(Media(channel.streamUrl), play: true)
          .timeout(const Duration(seconds: 20));
      if (pane == 0) {
        lastProgressAt = DateTime.now();
        becameNotPlayingAt = null;
        lastPosition = Duration.zero;
        reconnectAttempts = 0;
      }
      await _setFocusedPane(pane);
      _setState(
        () => status =
            'Now playing ${channel.title} · ${_sourceTag(channel)} on $paneName',
      );
      if (channel.sourceId != null) {
        unawaited(_ensureEpgForSource(channel.sourceId!));
      }
      unawaited(_loadXtreamFallbackEpg(channel));
      _showOsd();
      unawaited(_appendHistory(channel));
      unawaited(_reportPlaybackState(channel, active: true));
    } catch (e) {
      _setState(() {
        error =
            'Could not open ${channel.title} on $paneName. ${e.toString().replaceFirst('Bad state: ', '')}';
      });
    } finally {
      _setState(() {
        if (pane == 0) {
          opening = false;
        } else if (pane == 1) {
          openingSecondary = false;
        } else if (pane == 2) {
          openingTertiary = false;
        } else {
          openingQuaternary = false;
        }
      });
    }
  }

  Future<void> _openFocusedPane(LiveTvChannel channel) async {
    await _openOnPane(splitScreen ? focusedPane : 0, channel);
  }

  Future<void> _zapChannel(int direction, {bool secondary = false}) async {
    if (visibleChannels.isEmpty) {
      return;
    }
    final current = secondary ? _channelForPane(focusedPane) : selected;
    var index = visibleChannels.indexOf(current ?? visibleChannels.first);
    if (index < 0) {
      index = 0;
    }
    final nextIndex = (index + direction).clamp(0, visibleChannels.length - 1);
    if (nextIndex == index) {
      return;
    }
    if (secondary) {
      await _openOnPane(focusedPane, visibleChannels[nextIndex]);
    } else {
      await _open(visibleChannels[nextIndex]);
    }
  }

  Future<void> _appendHistory(LiveTvChannel channel) async {
    final key = _channelKey(channel);
    final selectedSource = sources.firstWhere(
      (item) => item.id == channel.sourceId,
      orElse: () => source ?? sources.first,
    );
    history = [
      key,
      ...history.where((value) => value != key),
    ].take(50).toList();
    _recomputeChannelViews();
    try {
      await HomePreferences().upsertLiveTvRecentChannel(
        widget.profileId,
        LiveTvRecentChannel(
          sourceId: selectedSource.id,
          sourceName: selectedSource.name,
          channelId: _channelToken(channel),
          channelName: channel.title,
          watchedAtUtc: DateTime.now().toUtc(),
        ),
      );
    } catch (_) {}
    unawaited(_scheduleProfileSync());
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty ||
        !DeviceConnection.instance.isConnected ||
        allSourcesSelected) {
      return;
    }
    try {
      await syncService.appendHistory(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: selectedSource.id,
        channelId: _channelToken(channel),
        channelName: channel.title,
      );
    } catch (_) {}
  }

  Future<void> _toggleFavorite(LiveTvChannel channel) async {
    final key = _channelKey(channel);
    final next = Set<String>.from(favorites);
    if (!next.remove(key)) {
      next.add(key);
    }
    favorites = next;
    _recomputeChannelViews();
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty ||
        !DeviceConnection.instance.isConnected ||
        allSourcesSelected) {
      return;
    }
    final selectedSource = sources.firstWhere(
      (item) => item.id == channel.sourceId,
      orElse: () => source ?? sources.first,
    );
    try {
      await syncService.syncFavorites(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: selectedSource.id,
        favorites: next,
      );
      if (mounted) {
        _setState(() => syncStatus = '');
      }
    } catch (_) {
      if (mounted) {
        _setState(() => syncStatus = 'Favorites will sync when connected.');
      }
    }
  }

  Future<void> _reconnect(String reason) async {
    final channel = selected;
    if (channel == null || opening || reconnecting || !mounted) {
      return;
    }
    reconnecting = true;
    reconnectAttempts++;
    lastReconnectAt = DateTime.now();
    _setState(() {
      status = 'Reconnecting ${channel.title} ($reconnectAttempts)... $reason';
      error = '';
    });
    try {
      final current = player;
      if (current == null) {
        return;
      }
      await current
          .open(Media(channel.streamUrl), play: true)
          .timeout(const Duration(seconds: 20));
      lastProgressAt = DateTime.now();
      becameNotPlayingAt = null;
      lastPosition = Duration.zero;
      isPlaying = true;
      _setState(() {
        status = 'Live stream recovered';
      });
      reconnectMessageClear?.cancel();
      reconnectMessageClear = Timer(const Duration(seconds: 2), () {
        if (!mounted || reconnecting) {
          return;
        }
        _setState(() {
          if (status == 'Live stream recovered') {
            status = 'Now playing ${channel.title}';
          }
        });
      });
      _showOsd();
    } catch (e) {
      _setState(() {
        error =
            'Reconnect failed for ${channel.title}. ${e.toString().replaceFirst('Bad state: ', '')}';
      });
    } finally {
      reconnecting = false;
    }
  }

  void _showOsd() {
    osdHide?.cancel();
    _setState(() => osdVisible = true);
    osdHide = Timer(const Duration(seconds: 4), () {
      if (!mounted) {
        return;
      }
      _setState(() => osdVisible = false);
    });
  }

  Future<void> _togglePlayPause() async {
    final current = _playerForPane(splitScreen ? focusedPane : 0);
    if (current == null) {
      return;
    }
    try {
      if (isPlaying) {
        await current.pause().timeout(const Duration(seconds: 4));
      } else {
        await current.play().timeout(const Duration(seconds: 4));
      }
      _showOsd();
    } catch (_) {}
  }

  Future<void> _seekRelative(Duration offset, {bool secondary = false}) async {
    final targetPane = secondary ? focusedPane : 0;
    final current = _playerForPane(targetPane);
    if (current == null) {
      return;
    }
    if (lastDuration <= Duration.zero) {
      await _zapChannel(offset.isNegative ? -1 : 1, secondary: secondary);
      return;
    }
    final target = (lastPosition + offset).inMilliseconds.clamp(
      0,
      lastDuration.inMilliseconds,
    );
    try {
      await current
          .seek(Duration(milliseconds: target))
          .timeout(const Duration(seconds: 4));
      _showOsd();
    } catch (_) {}
  }

  Future<void> _toggleDvr() async {
    final channel = _channelForPane(splitScreen ? focusedPane : 0);
    final selectedSource = channel == null
        ? null
        : sources.firstWhere(
            (item) => item.id == channel.sourceId,
            orElse: () => source ?? sources.first,
          );
    if (channel == null || selectedSource == null) {
      return;
    }
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      _setState(() => syncStatus = 'Connect device to control DVR recording.');
      return;
    }
    final start = !recording;
    try {
      await syncService.dvr(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: selectedSource.id,
        channelId: _channelKey(channel),
        channelName: channel.title,
        start: start,
      );
      if (mounted) {
        _setState(() {
          recording = start;
          syncStatus = start
              ? 'DVR recording started.'
              : 'DVR recording stopped.';
        });
      }
      _showOsd();
    } catch (_) {
      if (mounted) {
        _setState(
          () => syncStatus = 'DVR action failed. Verify backend route.',
        );
      }
    }
  }

  Future<void> _scheduleDvrFromGuide() async {
    final channel = _channelForPane(splitScreen ? focusedPane : 0);
    final selectedSource = channel == null ? null : _sourceForChannel(channel);
    if (channel == null || selectedSource == null) {
      return;
    }
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      _setState(() => syncStatus = 'Connect device to schedule DVR.');
      return;
    }
    final programs = _programsForChannel(channel)
        .where((item) => item.end.isAfter(DateTime.now().toUtc()))
        .take(6)
        .toList();
    if (programs.isEmpty) {
      _setState(() => syncStatus = 'No upcoming EPG program available.');
      return;
    }
    final selectedProgram = await showModalBottomSheet<LiveTvProgram>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            ListTile(
              title: Text(
                'Schedule recording · ${channel.title}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final program in programs)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(program.title),
                subtitle: Text(
                  '${_clockText(program.start)} - ${_clockText(program.end)}',
                ),
                onTap: () => Navigator.pop(ctx, program),
              ),
          ],
        ),
      ),
    );
    if (selectedProgram == null) {
      return;
    }
    try {
      await controlService.scheduleDvr(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: selectedSource.id,
        channelId: _channelToken(channel),
        channelName: channel.title,
        startUtc: selectedProgram.start,
        endUtc: selectedProgram.end,
        title: selectedProgram.title,
      );
      if (mounted) {
        _setState(() => syncStatus = 'DVR schedule saved.');
      }
    } catch (_) {
      if (mounted) {
        _setState(() => syncStatus = 'DVR scheduling failed.');
      }
    }
  }

  Future<void> _verifyPlaybackHealth() async {
    if (!mounted || opening || reconnecting) {
      return;
    }
    final current = player;
    final channel = selected;
    if (current == null || channel == null) {
      return;
    }
    final now = DateTime.now();
    if (lastReconnectAt != null &&
        now.difference(lastReconnectAt!) < const Duration(seconds: 45)) {
      return;
    }
    final progressAge = lastProgressAt == null
        ? const Duration(days: 1)
        : now.difference(lastProgressAt!);
    final isLikelyLiveStream = lastDuration <= Duration.zero;
    final stalled =
        !isLikelyLiveStream && progressAge > const Duration(seconds: 50);
    final notPlaying =
        !isPlaying &&
        becameNotPlayingAt != null &&
        now.difference(becameNotPlayingAt!) > const Duration(seconds: 12);
    if (stalled || notPlaying) {
      await _reconnect(
        stalled
            ? 'Playback stalled for ${progressAge.inSeconds}s.'
            : 'Playback did not resume automatically.',
      );
    }
  }

  Future<void> _manageSources() async {
    final result = await showDialog<List<LiveTvSource>>(
      context: context,
      builder: (ctx) => _LiveTvSourcesDialog(sources: sources),
    );
    if (result == null) {
      return;
    }
    await _saveSources(result);
    if (source == null && sources.isNotEmpty) {
      _setState(() => source = sources.first);
    }
    if (source != null) {
      await _loadChannels();
    }
  }

  Future<void> _manageChannelScope() async {
    final sourceList = List<LiveTvSource>.from(sources);
    final sourceCategories = <String, List<String>>{};
    for (final item in sourceList) {
      final groups =
          channels
              .where((channel) => channel.sourceId == item.id)
              .map((channel) => channel.group?.trim() ?? '')
              .where((group) => group.isNotEmpty)
              .toSet()
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      sourceCategories[item.id] = groups;
    }
    final selectedSources = scopedSourceIds.isEmpty
        ? sourceList.map((item) => item.id).toSet()
        : Set<String>.from(scopedSourceIds);
    final selectedGroups = <String, Set<String>>{
      for (final entry in scopedGroupsBySource.entries)
        entry.key: Set<String>.from(entry.value),
    };
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Channel Scope'),
          content: SizedBox(
            width: 700,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text(
                  'Select which sources and categories should be loaded in All Sources mode.',
                ),
                const SizedBox(height: 10),
                for (final src in sourceList)
                  Card(
                    child: ExpansionTile(
                      title: Row(
                        children: [
                          Checkbox(
                            value: selectedSources.contains(src.id),
                            onChanged: (checked) {
                              setLocal(() {
                                if (checked == true) {
                                  selectedSources.add(src.id);
                                } else {
                                  selectedSources.remove(src.id);
                                }
                              });
                            },
                          ),
                          Expanded(
                            child: Text(
                              src.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        sourceCategories[src.id]!.isEmpty
                            ? 'Load all categories (no category map yet)'
                            : selectedGroups[src.id]?.isNotEmpty == true
                            ? '${selectedGroups[src.id]!.length} categories selected'
                            : 'All categories selected',
                      ),
                      children: [
                        if (sourceCategories[src.id]!.isEmpty)
                          const ListTile(
                            title: Text(
                              'Categories appear here after first channel load.',
                            ),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('All Categories'),
                                selected:
                                    !(selectedGroups[src.id]?.isNotEmpty ??
                                        false),
                                onSelected: (_) => setLocal(
                                  () => selectedGroups.remove(src.id),
                                ),
                              ),
                              for (final group in sourceCategories[src.id]!)
                                FilterChip(
                                  label: Text(group),
                                  selected:
                                      selectedGroups[src.id]?.contains(group) ??
                                      false,
                                  onSelected: (enabled) {
                                    setLocal(() {
                                      final set =
                                          selectedGroups[src.id] ?? <String>{};
                                      if (enabled) {
                                        set.add(group);
                                      } else {
                                        set.remove(group);
                                      }
                                      if (set.isEmpty) {
                                        selectedGroups.remove(src.id);
                                      } else {
                                        selectedGroups[src.id] = set;
                                      }
                                    });
                                  },
                                ),
                            ],
                          ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (apply != true) {
      return;
    }
    _setState(() {
      scopedSourceIds
        ..clear()
        ..addAll(selectedSources);
      scopedGroupsBySource
        ..clear()
        ..addAll({
          for (final entry in selectedGroups.entries)
            entry.key: Set<String>.from(entry.value),
        });
    });
    await _scheduleProfileSync();
    if (allSourcesSelected) {
      await _loadChannels();
    } else {
      _recomputeChannelViews();
    }
  }

  Future<void> _toggleSplitScreen() async {
    final nextCount = screenCount == 1
        ? 2
        : screenCount == 2
        ? 3
        : screenCount == 3
        ? 4
        : 1;
    if (nextCount >= 2) {
      await _ensureSecondaryPlayer();
    }
    if (nextCount == 3) {
      await _ensureTertiaryPlayer();
    } else if (nextCount == 4) {
      await _ensureTertiaryPlayer();
      await _ensureQuaternaryPlayer();
    }
    if (screenCount == 4 && nextCount < 4) {
      await _disposeTertiaryPlayer();
      await _disposeQuaternaryPlayer();
    } else if (screenCount == 3 && nextCount < 3) {
      await _disposeTertiaryPlayer();
    }
    if (nextCount == 1) {
      await _disposeSecondaryPlayer();
      focusedPane = 0;
    } else if (focusedPane >= nextCount) {
      focusedPane = 0;
    }
    _setState(() => screenCount = nextCount);
    await _setFocusedPane(focusedPane);
  }

  void _toggleFullScreenVideo() {
    final next = !fullScreenVideo;
    _setState(() {
      fullScreenVideo = next;
      fullScreenControlsVisible = true;
    });
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        fullScreenFocusNode.requestFocus();
        _showFullScreenControlsTemporarily();
      });
    } else {
      fullScreenControlsHide?.cancel();
      fullScreenControlsHide = null;
    }
  }

  void _showFullScreenControlsTemporarily() {
    if (!fullScreenVideo) {
      return;
    }
    fullScreenControlsHide?.cancel();
    _setState(() => fullScreenControlsVisible = true);
    fullScreenControlsHide = Timer(const Duration(seconds: 3), () {
      if (!mounted || !fullScreenVideo) {
        return;
      }
      _setState(() => fullScreenControlsVisible = false);
    });
  }

  void _onFullScreenKey(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _showFullScreenControlsTemporarily();
    }
  }

  Future<void> _stopPaneStream(int pane) async {
    final current = _playerForPane(pane);
    if (current == null) {
      return;
    }
    final channel = _channelForPane(pane);
    try {
      await current.stop().timeout(const Duration(seconds: 4));
    } catch (_) {}
    _setState(() {
      if (pane == 0) {
        selected = null;
      } else if (pane == 1) {
        selectedSecondary = null;
      } else if (pane == 2) {
        selectedTertiary = null;
      } else if (pane == 3) {
        selectedQuaternary = null;
      }
    });
    if (channel != null) {
      unawaited(_reportPlaybackState(channel, active: false));
    }
  }

  Future<void> _stopCurrentChannel() async {
    await _stopPaneStream(splitScreen ? focusedPane : 0);
    _showOsd();
  }

  double? _epgProgress(LiveTvProgram? now) {
    if (now == null) {
      return null;
    }
    final total = now.end.difference(now.start).inSeconds;
    if (total <= 0) {
      return null;
    }
    final elapsed = DateTime.now().toUtc().difference(now.start).inSeconds;
    final clamped = elapsed.clamp(0, total);
    return clamped / total;
  }

  Widget _buildPaneContent(int pane) {
    final controller = _videoForPane(pane);
    final focused = focusedPane == pane;
    final channel = _channelForPane(pane);
    final nowProgram = channel == null ? null : _currentProgram(channel);
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            unawaited(_setFocusedPane(pane));
            _showOsd();
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(
                color: focused ? Colors.lightBlueAccent : Colors.transparent,
                width: 2,
              ),
            ),
            child: controller == null
                ? Center(child: Text(_paneLabel(pane)))
                : Video(controller: controller, controls: NoVideoControls),
          ),
        ),
        Positioned(
          top: 8,
          left: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xAA000000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                channel == null
                    ? '${_paneLabel(pane)} · No channel'
                    : '${_paneLabel(pane)} · ${channel.title}\n${_sourceTag(channel)}${nowProgram == null ? '' : ' · ${nowProgram.title}'}',
                style: const TextStyle(fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 56,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xAA000000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                playbackEngineStatusByPane[pane] ?? 'GPU decode: checking...',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton.filledTonal(
            tooltip: 'Stop stream',
            onPressed: () => unawaited(_stopPaneStream(pane)),
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    );
  }

  Widget _buildSplitLayout() {
    if (screenCount == 2) {
      return Stack(
        children: [
          Row(
            children: [
              Expanded(child: _buildPaneContent(0)),
              const VerticalDivider(width: 1),
              Expanded(child: _buildPaneContent(1)),
            ],
          ),
          if (fullScreenVideo)
            Positioned(
              top: 12,
              right: 12,
              child: AnimatedOpacity(
                opacity: fullScreenControlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !fullScreenControlsVisible,
                  child: IconButton.filledTonal(
                    tooltip: 'Exit full screen',
                    onPressed: _toggleFullScreenVideo,
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    if (screenCount == 3) {
      return Stack(
        children: [
          Row(
            children: [
              Expanded(child: _buildPaneContent(0)),
              const VerticalDivider(width: 1),
              Expanded(child: _buildPaneContent(1)),
              const VerticalDivider(width: 1),
              Expanded(child: _buildPaneContent(2)),
            ],
          ),
          if (fullScreenVideo)
            Positioned(
              top: 12,
              right: 12,
              child: AnimatedOpacity(
                opacity: fullScreenControlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !fullScreenControlsVisible,
                  child: IconButton.filledTonal(
                    tooltip: 'Exit full screen',
                    onPressed: _toggleFullScreenVideo,
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _buildPaneContent(0)),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildPaneContent(1)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _buildPaneContent(2)),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildPaneContent(3)),
                ],
              ),
            ),
          ],
        ),
        if (fullScreenVideo)
          Positioned(
            top: 12,
            right: 12,
            child: AnimatedOpacity(
              opacity: fullScreenControlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !fullScreenControlsVisible,
                child: IconButton.filledTonal(
                  tooltip: 'Exit full screen',
                  onPressed: _toggleFullScreenVideo,
                  icon: const Icon(Icons.fullscreen_exit),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showEpgGuide() {
    final channel = _channelForPane(splitScreen ? focusedPane : 0);
    if (channel == null) {
      return;
    }
    unawaited(_loadXtreamFallbackEpg(channel));
    showDialog<void>(
      context: context,
      builder: (ctx) => _LiveTvGuideDialog(
        channels: visibleChannels,
        selected: channel,
        programsForChannel: _programsForChannel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, __) {
        unawaited(_minimizeToPipAndGoHome());
      },
      child: Scaffold(
      appBar: fullScreenVideo
          ? null
          : AppBar(
              title: const Text('Live TV'),
              leading: IconButton(
                tooltip: 'Home (PiP)',
                onPressed: () => unawaited(_minimizeToPipAndGoHome()),
                icon: const Icon(Icons.arrow_back),
              ),
              actions: [
                IconButton(
                  tooltip: screenCount == 1
                      ? 'Enable split screen'
                      : screenCount == 2
                      ? 'Enable 3-screen'
                      : screenCount == 3
                      ? 'Enable 4-screen'
                      : 'Return to single screen',
                  onPressed: loading || opening
                      ? null
                      : () => unawaited(_toggleSplitScreen()),
                  icon: Icon(
                    screenCount == 1 ? Icons.view_week : Icons.grid_view,
                  ),
                ),
                IconButton(
                  tooltip: fullScreenVideo ? 'Exit full screen' : 'Full screen',
                  onPressed: _toggleFullScreenVideo,
                  icon: Icon(
                    fullScreenVideo ? Icons.fullscreen_exit : Icons.fullscreen,
                  ),
                ),
                IconButton(
                  tooltip: 'Guide',
                  onPressed:
                      _channelForPane(splitScreen ? focusedPane : 0) == null
                      ? null
                      : _showEpgGuide,
                  icon: const Icon(Icons.view_agenda_outlined),
                ),
                TextButton(
                  onPressed: opening || loading
                      ? null
                      : () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => LiveTvMediaScreen(
                              profileId: widget.profileId,
                              initialSourceId: source?.id,
                            ),
                          ),
                        ),
                  child: const Text('Movies & Series'),
                ),
                TextButton(
                  onPressed: opening ? null : _manageSources,
                  child: const Text('Manage Sources'),
                ),
                TextButton(
                  onPressed: loading || opening || source == null
                      ? null
                      : _loadChannels,
                  child: const Text('Reload'),
                ),
              ],
            ),
      body: Column(
        children: [
          if (!fullScreenVideo && (loading || opening))
            const LinearProgressIndicator(),
          if (!fullScreenVideo && status.isNotEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(status)),
          if (!fullScreenVideo && syncStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                syncStatus,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          if (!fullScreenVideo && error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                error,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (!fullScreenVideo)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(
                        allSourcesSelected
                            ? 'source-all'
                            : (source?.id ?? 'no-source'),
                      ),
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
                              '${item.name} (${item.isXtream ? 'Xtream' : 'M3U'})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: loading || opening
                          ? null
                          : (value) async {
                              if (value == 'all') {
                                _setState(() {
                                  allSourcesSelected = true;
                                  selectedGroup =
                                      selectedGroupByScope[_sourceId()] ??
                                      'All';
                                });
                                await _scheduleProfileSync();
                                await _loadChannels();
                                return;
                              }
                              final next = sources.firstWhere(
                                (item) => item.id == value,
                                orElse: () => sources.first,
                              );
                              _setState(() {
                                source = next;
                                allSourcesSelected = false;
                                selectedGroup =
                                    selectedGroupByScope[_sourceId()] ?? 'All';
                              });
                              await _scheduleProfileSync();
                              await _loadChannels();
                            },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: search,
                      decoration: const InputDecoration(
                        labelText: 'Search channels',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    tooltip: 'Channel Scope',
                    onPressed: loading || opening ? null : _manageChannelScope,
                    icon: const Icon(Icons.tune),
                  ),
                ],
              ),
            ),
          if (!fullScreenVideo)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<_ChannelFilterMode>(
                      initialValue: filterMode,
                      decoration: const InputDecoration(
                        labelText: 'Channel Filter',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: _ChannelFilterMode.all,
                          child: Text('All Channels'),
                        ),
                        DropdownMenuItem(
                          value: _ChannelFilterMode.favorites,
                          child: Text('Favorites'),
                        ),
                        DropdownMenuItem(
                          value: _ChannelFilterMode.recent,
                          child: Text('Continue Watching'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        _setState(() => filterMode = value);
                        _recomputeChannelViews();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(
                        'group-$selectedGroup-${groupOptions.length}',
                      ),
                      initialValue: groupOptions.contains(selectedGroup)
                          ? selectedGroup
                          : groupOptions.first,
                      decoration: const InputDecoration(
                        labelText: 'Category',
                        border: OutlineInputBorder(),
                      ),
                      items: groupOptions
                          .map(
                            (group) => DropdownMenuItem<String>(
                              value: group,
                              child: Text(
                                group,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        _setState(() {
                          selectedGroup = value;
                          selectedGroupByScope[_sourceId()] = value;
                        });
                        _pinCategorySelection(value);
                        _recomputeChannelViews();
                        unawaited(_scheduleProfileSync());
                      },
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Row(
              children: [
                if (!fullScreenVideo)
                  SizedBox(
                    width: 460,
                    child: visibleChannels.isEmpty
                        ? const Center(
                            child: Text(
                              'No channels match the current filter.',
                            ),
                          )
                        : ListView.builder(
                            itemExtent: 74,
                            itemCount: visibleChannels.length,
                            itemBuilder: (context, index) {
                              final channel = visibleChannels[index];
                              final active =
                                  selected == channel ||
                                  selectedSecondary == channel ||
                                  selectedTertiary == channel ||
                                  selectedQuaternary == channel;
                              final nowProgram = _currentProgram(channel);
                              return ListTile(
                                selected: active,
                                leading: SizedBox(
                                  width: 62,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('${index + 1}'),
                                      if (_favorite(channel))
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(
                                            Icons.star,
                                            size: 14,
                                            color: Colors.amber,
                                          ),
                                        ),
                                      if (selectedSecondary == channel ||
                                          selectedTertiary == channel ||
                                          selectedQuaternary == channel)
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(
                                            Icons.splitscreen,
                                            size: 14,
                                            color: Colors.lightBlueAccent,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                title: Text(
                                  _displayTitle(channel),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  [
                                    if (nowProgram != null)
                                      'Now: ${nowProgram.title}',
                                    if (nowProgram == null &&
                                        channel.group != null)
                                      channel.group!,
                                    if (channel.sourceName != null)
                                      'Source: ${channel.sourceName!}',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Wrap(
                                  spacing: 2,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (channel.sourceName != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0x3323D5C8),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          channel.sourceName!,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    IconButton(
                                      tooltip: _favorite(channel)
                                          ? 'Remove favorite'
                                          : 'Add favorite',
                                      icon: Icon(
                                        _favorite(channel)
                                            ? Icons.star
                                            : Icons.star_border,
                                        color: _favorite(channel)
                                            ? Colors.amber
                                            : null,
                                      ),
                                      onPressed: () => _toggleFavorite(channel),
                                    ),
                                    if (splitScreen)
                                      IconButton(
                                        tooltip: 'Open on focused pane',
                                        icon: const Icon(Icons.open_in_new),
                                        onPressed: () => unawaited(
                                          _openFocusedPane(channel),
                                        ),
                                      ),
                                  ],
                                ),
                                onTap: () =>
                                    unawaited(_openFocusedPane(channel)),
                              );
                            },
                          ),
                  ),
                if (!fullScreenVideo) const VerticalDivider(width: 1),
                Expanded(
                  child: KeyboardListener(
                    focusNode: fullScreenFocusNode,
                    onKeyEvent: _onFullScreenKey,
                    child: MouseRegion(
                      onEnter: (_) => _showFullScreenControlsTemporarily(),
                      onHover: (_) => _showFullScreenControlsTemporarily(),
                      child: !splitScreen && video == null
                          ? const Center(
                              child: Text(
                                'Choose a source and channel to begin playback.',
                              ),
                            )
                          : splitScreen
                          ? _buildSplitLayout()
                          : Stack(
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _showOsd,
                                  child: DecoratedBox(
                                    decoration: const BoxDecoration(
                                      color: Colors.black,
                                    ),
                                    child: Video(
                                      controller: video!,
                                      controls: NoVideoControls,
                                    ),
                                  ),
                                ),
                                if (osdVisible && selected != null)
                                  (() {
                                    final nowProgram = _currentProgram(
                                      selected!,
                                    );
                                    final nextProgram = _nextProgram(selected!);
                                    final hasGuideData =
                                        nowProgram != null ||
                                        nextProgram != null ||
                                        _programsForChannel(
                                          selected!,
                                        ).isNotEmpty;
                                    return _LiveTvOsd(
                                      channelName: selected!.title,
                                      nowProgram: nowProgram,
                                      nextProgram: nextProgram,
                                      epgProgress: _epgProgress(nowProgram),
                                      isFavorite: _favorite(selected!),
                                      recording: recording,
                                      liveOnly: lastDuration <= Duration.zero,
                                      splitScreen: splitScreen,
                                      screenCount: screenCount,
                                      hasEpg: hasGuideData,
                                      onFavorite: () =>
                                          unawaited(_toggleFavorite(selected!)),
                                      onPlayPause: () =>
                                          unawaited(_togglePlayPause()),
                                      onStop: () =>
                                          unawaited(_stopCurrentChannel()),
                                      onChannelDown: () => unawaited(
                                        _zapChannel(-1, secondary: false),
                                      ),
                                      onChannelUp: () => unawaited(
                                        _zapChannel(1, secondary: false),
                                      ),
                                      onRewind: () => unawaited(
                                        _seekRelative(
                                          const Duration(seconds: -10),
                                        ),
                                      ),
                                      onForward: () => unawaited(
                                        _seekRelative(
                                          const Duration(seconds: 10),
                                        ),
                                      ),
                                      onRecord: () => unawaited(_toggleDvr()),
                                      onSchedule: () =>
                                          unawaited(_scheduleDvrFromGuide()),
                                      onGuide: _showEpgGuide,
                                      onSplit: () =>
                                          unawaited(_toggleSplitScreen()),
                                      onFullScreen: _toggleFullScreenVideo,
                                    );
                                  })(),
                                if (fullScreenVideo)
                                  Positioned(
                                    top: 12,
                                    right: 12,
                                    child: AnimatedOpacity(
                                      opacity: fullScreenControlsVisible
                                          ? 1
                                          : 0,
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      child: IgnorePointer(
                                        ignoring: !fullScreenControlsVisible,
                                        child: IconButton.filledTonal(
                                          tooltip: 'Exit full screen',
                                          onPressed: _toggleFullScreenVideo,
                                          icon: const Icon(
                                            Icons.fullscreen_exit,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }
}

String _clockText(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final suffix = local.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $suffix';
}

class _LiveTvGuideDialog extends StatefulWidget {
  final List<LiveTvChannel> channels;
  final LiveTvChannel selected;
  final List<LiveTvProgram> Function(LiveTvChannel channel) programsForChannel;

  const _LiveTvGuideDialog({
    required this.channels,
    required this.selected,
    required this.programsForChannel,
  });

  @override
  State<_LiveTvGuideDialog> createState() => _LiveTvGuideDialogState();
}

class _LiveTvGuideDialogState extends State<_LiveTvGuideDialog> {
  static const _slotMinutes = 30;
  static const _hoursVisible = 4;
  static const _rowHeight = 62.0;
  static const _channelColumnWidth = 220.0;
  static const _pxPerMinute = 3.2;
  late final DateTime windowStartUtc;
  late final DateTime windowEndUtc;

  @override
  void initState() {
    super.initState();
    final nowUtc = DateTime.now().toUtc();
    final slotMs = const Duration(minutes: _slotMinutes).inMilliseconds;
    final roundedMs = (nowUtc.millisecondsSinceEpoch ~/ slotMs) * slotMs;
    windowStartUtc = DateTime.fromMillisecondsSinceEpoch(
      roundedMs,
      isUtc: true,
    );
    windowEndUtc = windowStartUtc.add(const Duration(hours: _hoursVisible));
  }

  List<_GuideRow> get _rows {
    final rows = <_GuideRow>[];
    for (final channel in widget.channels) {
      final entries = widget.programsForChannel(channel);
      final programs = entries
          .where(
            (item) =>
                item.end.isAfter(windowStartUtc) &&
                item.start.isBefore(windowEndUtc),
          )
          .toList();
      if (programs.isEmpty) {
        continue;
      }
      rows.add(_GuideRow(channel: channel, programs: programs));
    }
    rows.sort((a, b) {
      if (a.channel == widget.selected) {
        return -1;
      }
      if (b.channel == widget.selected) {
        return 1;
      }
      return a.channel.title.toLowerCase().compareTo(
        b.channel.title.toLowerCase(),
      );
    });
    return rows.take(80).toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final totalMinutes = windowEndUtc.difference(windowStartUtc).inMinutes;
    final timelineWidth = totalMinutes * _pxPerMinute;
    final nowUtc = DateTime.now().toUtc();
    final nowOffsetMinutes = nowUtc.difference(windowStartUtc).inMinutes;
    final nowOffset = (nowOffsetMinutes * _pxPerMinute)
        .clamp(0, timelineWidth)
        .toDouble();
    return AlertDialog(
      title: const Text('EPG Guide'),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      content: SizedBox(
        width: 1120,
        height: 640,
        child: rows.isEmpty
            ? const Center(
                child: Text(
                  'No guide rows matched these channels.\n'
                  'For Xtream, confirm XMLTV is enabled and reload channels.',
                  textAlign: TextAlign.center,
                ),
              )
            : Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: _channelColumnWidth,
                        child: Text(
                          'Channels',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Expanded(
                        child: SizedBox(
                          height: 28,
                          child: Stack(
                            children: [
                              for (
                                var step = 0;
                                step <= totalMinutes;
                                step += _slotMinutes
                              )
                                Positioned(
                                  left: step * _pxPerMinute,
                                  child: Text(
                                    _clockText(
                                      windowStartUtc.add(
                                        Duration(minutes: step),
                                      ),
                                    ),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              Positioned(
                                left: nowOffset,
                                top: 0,
                                bottom: 0,
                                child: Container(
                                  width: 2,
                                  color: Colors.redAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final highlighted = row.channel == widget.selected;
                        return SizedBox(
                          height: _rowHeight,
                          child: Row(
                            children: [
                              Container(
                                width: _channelColumnWidth,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                alignment: Alignment.centerLeft,
                                color: highlighted
                                    ? const Color(0x3348D1CC)
                                    : const Color(0x22161F33),
                                child: Text(
                                  row.channel.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: highlighted
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: ClipRect(
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: CustomPaint(
                                          painter: _GuideGridPainter(
                                            slotMinutes: _slotMinutes,
                                            pxPerMinute: _pxPerMinute,
                                          ),
                                        ),
                                      ),
                                      for (final item in row.programs)
                                        _GuideProgramTile(
                                          program: item,
                                          windowStartUtc: windowStartUtc,
                                          windowEndUtc: windowEndUtc,
                                          pxPerMinute: _pxPerMinute,
                                        ),
                                      Positioned(
                                        left: nowOffset,
                                        top: 0,
                                        bottom: 0,
                                        child: Container(
                                          width: 2,
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _GuideRow {
  final LiveTvChannel channel;
  final List<LiveTvProgram> programs;
  const _GuideRow({required this.channel, required this.programs});
}

class _GuideGridPainter extends CustomPainter {
  final int slotMinutes;
  final double pxPerMinute;
  const _GuideGridPainter({
    required this.slotMinutes,
    required this.pxPerMinute,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x334A5A7A)
      ..strokeWidth = 1;
    final step = slotMinutes * pxPerMinute;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GuideGridPainter oldDelegate) =>
      oldDelegate.slotMinutes != slotMinutes ||
      oldDelegate.pxPerMinute != pxPerMinute;
}

class _GuideProgramTile extends StatelessWidget {
  final LiveTvProgram program;
  final DateTime windowStartUtc;
  final DateTime windowEndUtc;
  final double pxPerMinute;
  const _GuideProgramTile({
    required this.program,
    required this.windowStartUtc,
    required this.windowEndUtc,
    required this.pxPerMinute,
  });

  @override
  Widget build(BuildContext context) {
    final start = program.start.isBefore(windowStartUtc)
        ? windowStartUtc
        : program.start;
    final end = program.end.isAfter(windowEndUtc) ? windowEndUtc : program.end;
    final offsetMinutes = start.difference(windowStartUtc).inMinutes;
    final widthMinutes = end
        .difference(start)
        .inMinutes
        .clamp(6, 10000)
        .toDouble();
    return Positioned(
      left: offsetMinutes * pxPerMinute,
      top: 6,
      bottom: 6,
      width: widthMinutes * pxPerMinute,
      child: Tooltip(
        message:
            '${program.title}\n${_clockText(program.start)} - ${_clockText(program.end)}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF243C63),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF3D5C8E)),
          ),
          child: Text(
            program.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _LiveTvOsd extends StatelessWidget {
  final String channelName;
  final LiveTvProgram? nowProgram;
  final LiveTvProgram? nextProgram;
  final double? epgProgress;
  final bool isFavorite;
  final bool recording;
  final bool liveOnly;
  final bool splitScreen;
  final int screenCount;
  final bool hasEpg;
  final VoidCallback onFavorite;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final VoidCallback onChannelDown;
  final VoidCallback onChannelUp;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback onRecord;
  final VoidCallback onSchedule;
  final VoidCallback onGuide;
  final VoidCallback onSplit;
  final VoidCallback onFullScreen;

  const _LiveTvOsd({
    required this.channelName,
    required this.nowProgram,
    required this.nextProgram,
    required this.epgProgress,
    required this.isFavorite,
    required this.recording,
    required this.liveOnly,
    required this.splitScreen,
    required this.screenCount,
    required this.hasEpg,
    required this.onFavorite,
    required this.onPlayPause,
    required this.onStop,
    required this.onChannelDown,
    required this.onChannelUp,
    required this.onRewind,
    required this.onForward,
    required this.onRecord,
    required this.onSchedule,
    required this.onGuide,
    required this.onSplit,
    required this.onFullScreen,
  });

  @override
  Widget build(BuildContext context) => Positioned(
    left: 20,
    right: 20,
    bottom: 20,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              channelName,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            if (nowProgram != null)
              Text(
                'Now · ${_clockText(nowProgram!.start)} - ${_clockText(nowProgram!.end)} · ${nowProgram!.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (nextProgram != null)
              Text(
                'Next · ${_clockText(nextProgram!.start)} - ${_clockText(nextProgram!.end)} · ${nextProgram!.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70),
              ),
            if (epgProgress != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: epgProgress,
                  minHeight: 8,
                  color: Colors.lightBlueAccent,
                  backgroundColor: Colors.white12,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onGuide,
                  icon: const Icon(Icons.view_agenda_outlined),
                  label: Text(hasEpg ? 'EPG Guide' : 'EPG Missing'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onFavorite,
                  icon: Icon(isFavorite ? Icons.star : Icons.star_border),
                  label: Text(isFavorite ? 'Favorite' : 'Add Favorite'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onRecord,
                  icon: Icon(
                    recording ? Icons.stop : Icons.fiber_manual_record,
                  ),
                  label: Text(recording ? 'Stop DVR' : 'Start DVR'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onSchedule,
                  icon: const Icon(Icons.event_note),
                  label: const Text('Schedule DVR'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onRewind,
                  icon: const Icon(Icons.fast_rewind),
                  label: Text(liveOnly ? 'Prev Channel' : 'Rewind 10s'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onChannelDown,
                  icon: const Icon(Icons.keyboard_arrow_down),
                  label: const Text('Channel -'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onPlayPause,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play/Pause'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Channel'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onChannelUp,
                  icon: const Icon(Icons.keyboard_arrow_up),
                  label: const Text('Channel +'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onForward,
                  icon: const Icon(Icons.fast_forward),
                  label: Text(liveOnly ? 'Next Channel' : 'Forward 10s'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onSplit,
                  icon: Icon(
                    screenCount == 1 ? Icons.view_week : Icons.grid_view,
                  ),
                  label: Text(
                    screenCount == 1
                        ? 'Split (2)'
                        : screenCount == 2
                        ? 'Split (3)'
                        : screenCount == 3
                        ? 'Split (4)'
                        : 'Single Screen',
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: onFullScreen,
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('Full Screen'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _LiveTvSourcesDialog extends StatefulWidget {
  final List<LiveTvSource> sources;
  const _LiveTvSourcesDialog({required this.sources});

  @override
  State<_LiveTvSourcesDialog> createState() => _LiveTvSourcesDialogState();
}

class _LiveTvSourcesDialogState extends State<_LiveTvSourcesDialog> {
  late List<LiveTvSource> values;
  String error = '';

  @override
  void initState() {
    super.initState();
    values = List<LiveTvSource>.of(widget.sources);
  }

  Future<void> _edit({LiveTvSource? source}) async {
    final id = source?.id ?? 'source-${DateTime.now().microsecondsSinceEpoch}';
    final name = TextEditingController(text: source?.name ?? '');
    var type = source?.type ?? 'm3u';
    final m3uUrl = TextEditingController(text: source?.m3uUrl ?? '');
    final m3uMoviesUrl = TextEditingController(
      text: source?.m3uMoviesUrl ?? '',
    );
    final m3uSeriesUrls = TextEditingController(
      text: source?.m3uSeriesUrls.join('\n') ?? '',
    );
    final epgUrl = TextEditingController(text: source?.epgUrl ?? '');
    final serverUrl = TextEditingController(text: source?.serverUrl ?? '');
    final username = TextEditingController(text: source?.username ?? '');
    final password = TextEditingController(text: source?.password ?? '');
    String localError = '';
    try {
      final saved = await showDialog<LiveTvSource>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text(source == null ? 'Add source' : 'Edit source'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Source name',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: type,
                      items: const [
                        DropdownMenuItem(
                          value: 'm3u',
                          child: Text('M3U / M3U8 URL'),
                        ),
                        DropdownMenuItem(
                          value: 'xtream',
                          child: Text('Xtream Codes (XC) API'),
                        ),
                      ],
                      onChanged: (value) =>
                          setLocal(() => type = value ?? 'm3u'),
                    ),
                    const SizedBox(height: 10),
                    if (type == 'm3u')
                      Column(
                        children: [
                          TextField(
                            controller: m3uUrl,
                            decoration: const InputDecoration(
                              labelText: 'Live TV M3U URL',
                              hintText: 'https://example.com/livetv.m3u',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: m3uMoviesUrl,
                            decoration: const InputDecoration(
                              labelText: 'Movies M3U URL (optional)',
                              hintText: 'https://example.com/movies.m3u',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: m3uSeriesUrls,
                            minLines: 3,
                            maxLines: 6,
                            decoration: const InputDecoration(
                              labelText: 'TV Shows M3U URLs (optional)',
                              hintText:
                                  'One URL per line:\nhttps://example.com/tvshows/1\nhttps://example.com/tvshows/2',
                            ),
                          ),
                        ],
                      ),
                    TextField(
                      controller: epgUrl,
                      decoration: const InputDecoration(
                        labelText: 'EPG XMLTV URL (optional)',
                        hintText: 'https://example.com/guide.xml',
                      ),
                    ),
                    if (type == 'xtream') ...[
                      TextField(
                        controller: serverUrl,
                        decoration: const InputDecoration(
                          labelText: 'Server URL',
                          hintText: 'http://provider.example:8080',
                        ),
                      ),
                      TextField(
                        controller: username,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                        ),
                      ),
                      TextField(
                        controller: password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                        ),
                      ),
                    ],
                    if (localError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          localError,
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  try {
                    final cleanedName = name.text.trim();
                    if (cleanedName.isEmpty) {
                      throw const FormatException('Enter a source name.');
                    }
                    final next = LiveTvSource.fromJson({
                      'id': id,
                      'name': cleanedName,
                      'type': type,
                      'm3uUrl': type == 'm3u'
                          ? validateLiveTvSourceUrl(m3uUrl.text)
                          : null,
                      'm3uMoviesUrl':
                          type == 'm3u' && m3uMoviesUrl.text.trim().isNotEmpty
                          ? validateLiveTvSourceUrl(m3uMoviesUrl.text)
                          : null,
                      'm3uSeriesUrls': type == 'm3u'
                          ? m3uSeriesUrls.text
                                .split(RegExp(r'[\r\n]+'))
                                .map((line) => line.trim())
                                .where((line) => line.isNotEmpty)
                                .map(validateLiveTvSourceUrl)
                                .toList()
                          : const <String>[],
                      'serverUrl': type == 'xtream'
                          ? validateLiveTvSourceUrl(serverUrl.text)
                          : null,
                      'username': type == 'xtream'
                          ? username.text.trim()
                          : null,
                      'password': type == 'xtream'
                          ? password.text.trim()
                          : null,
                      'epgUrl': epgUrl.text.trim().isEmpty
                          ? null
                          : validateLiveTvSourceUrl(epgUrl.text),
                    });
                    Navigator.pop(ctx, next);
                  } catch (e) {
                    setLocal(
                      () => localError = e.toString().replaceFirst(
                        'FormatException: ',
                        '',
                      ),
                    );
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
      if (saved == null) {
        return;
      }
      setState(() {
        final index = values.indexWhere((item) => item.id == saved.id);
        if (index >= 0) {
          values[index] = saved;
        } else {
          values.add(saved);
        }
        error = '';
      });
    } finally {
      name.dispose();
      m3uUrl.dispose();
      m3uMoviesUrl.dispose();
      m3uSeriesUrls.dispose();
      epgUrl.dispose();
      serverUrl.dispose();
      username.dispose();
      password.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Live TV sources'),
    content: SizedBox(
      width: 700,
      height: 420,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Add source'),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: values.isEmpty
                ? const Center(
                    child: Text(
                      'No sources configured.\nAdd an M3U or Xtream source.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    children: [
                      for (final item in values)
                        ListTile(
                          title: Text(item.name),
                          subtitle: Text(
                            item.isXtream
                                ? 'Xtream · ${item.serverUrl}${item.epgUrl == null ? '' : ' · EPG'}'
                                : 'M3U · Live${item.m3uMoviesUrl == null ? '' : ' · Movies'}${item.m3uSeriesUrls.isEmpty ? '' : ' · TV Shows(${item.m3uSeriesUrls.length})'}${item.epgUrl == null ? '' : ' · EPG'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                onPressed: () => _edit(source: item),
                                icon: const Icon(Icons.edit),
                                tooltip: 'Edit',
                              ),
                              IconButton(
                                onPressed: () {
                                  setState(() {
                                    values.removeWhere(
                                      (entry) => entry.id == item.id,
                                    );
                                  });
                                },
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete',
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (values.map((item) => item.id).toSet().length != values.length) {
            setState(() => error = 'Duplicate source IDs were detected.');
            return;
          }
          Navigator.pop(context, values);
        },
        child: const Text('Save sources'),
      ),
    ],
  );
}
