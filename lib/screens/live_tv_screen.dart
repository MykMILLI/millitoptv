import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/app_log.dart';
import '../services/device_connection.dart';
import '../services/home_preferences.dart';
import '../services/global_playlists.dart';
import '../services/playlist_hub.dart';
import '../services/live_tv_epg.dart';
import '../services/live_tv_playlist.dart';
import '../services/live_tv_source.dart';
import '../services/live_tv_sync.dart';
import '../services/live_tv_control.dart';
import '../services/playback_performance.dart';
import '../services/pip_playback.dart';
import '../services/sleep_mode.dart';
import '../services/viewing_sessions.dart';
import '../theme/millitop_visual_theme.dart';
import '../widgets/live_tv_osd.dart';
import 'sleep_mode_panel.dart';

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
  final FocusNode searchFocusNode = FocusNode();
  final FocusNode screenFocusNode = FocusNode();
  final FocusNode fullScreenFocusNode = FocusNode();
  final ScrollController channelScrollController = ScrollController();
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

  /// Cloud DVR recordings running in this household, keyed by channel key.
  Map<String, Map<String, dynamic>> activeRecordings = {};
  bool dvrBusy = false;
  Timer? dvrStatusTimer;
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
  DateTime? bufferingStartedAtUtc;
  Duration lastPosition = Duration.zero;
  Duration lastDuration = Duration.zero;
  bool isPlaying = false;
  int reconnectAttempts = 0;
  int bufferingEpisodes = 0;
  int bufferingSessionMs = 0;
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
  int focusedChannelIndex = 0;
  DateTime? backExitArmedUntil;

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
      if (visibleChannels.isEmpty) {
        focusedChannelIndex = 0;
      } else if (focusedChannelIndex >= visibleChannels.length) {
        focusedChannelIndex = visibleChannels.length - 1;
      } else if (focusedChannelIndex < 0) {
        focusedChannelIndex = 0;
      }
    });
  }

  LiveTvChannel? get _focusedChannel =>
      visibleChannels.isEmpty ? null : visibleChannels[focusedChannelIndex];

  void _focusChannelByOffset(int delta) {
    if (visibleChannels.isEmpty) {
      return;
    }
    final next = (focusedChannelIndex + delta).clamp(
      0,
      visibleChannels.length - 1,
    );
    if (next == focusedChannelIndex) {
      return;
    }
    _setState(() => focusedChannelIndex = next);
    final targetOffset = (74.0 * next) - 148.0;
    if (!channelScrollController.hasClients) {
      return;
    }
    channelScrollController.animateTo(
      targetOffset.clamp(0, channelScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
    );
  }

  void _focusChannelByPage(int pages) {
    if (visibleChannels.isEmpty) {
      return;
    }
    _focusChannelByOffset(8 * pages);
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

  LiveTvChannel? get _dvrChannel =>
      _channelForPane(splitScreen ? focusedPane : 0);

  /// True while the focused channel is being recorded (by any paired device).
  bool get recording {
    final channel = _dvrChannel;
    return channel != null &&
        activeRecordings.containsKey(_channelKey(channel));
  }

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
    unawaited(_refreshActiveRecordings());
    dvrStatusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_refreshActiveRecordings()),
    );
  }

  @override
  void dispose() {
    _finishBufferingTelemetry(aborted: true);
    dvrStatusTimer?.cancel();
    watchdog?.cancel();
    reconnectMessageClear?.cancel();
    osdHide?.cancel();
    fullScreenControlsHide?.cancel();
    profileSyncDebounce?.cancel();
    playbackStatusTimer?.cancel();
    searchFocusNode.dispose();
    screenFocusNode.dispose();
    fullScreenFocusNode.dispose();
    channelScrollController.dispose();
    search.dispose();
    ViewingSessions.instance.remove(timerSessionKey);
    ViewingSessions.instance.remove(secondaryTimerSessionKey);
    ViewingSessions.instance.remove('native-live-tv-tertiary');
    ViewingSessions.instance.remove('native-live-tv-quaternary');
    unawaited(_disposePlayer());
    unawaited(_disposeSecondaryPlayer());
    unawaited(_disposeTertiaryPlayer());
    unawaited(_disposeQuaternaryPlayer());
    unawaited(_applyPlatformFullscreen(false));
    super.dispose();
  }

  void _setState(VoidCallback update) {
    if (mounted) {
      setState(update);
    }
  }

  bool get _isTextInputFocused {
    if (searchFocusNode.hasFocus) {
      return true;
    }
    final focused = FocusManager.instance.primaryFocus;
    final context = focused?.context;
    if (context == null) {
      return false;
    }
    return context.widget is EditableText;
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
          () => status =
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
    Set<String>? savedFavorites;
    try {
      savedFavorites = await channelFavoriteKeys(widget.profileId);
    } catch (e) {
      debugPrint('Saved channel favorites could not load: $e');
      _setState(
        () => syncStatus = 'Saved channel favorites could not load. $e',
      );
    }
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
      if (savedFavorites != null) {
        favorites = savedFavorites;
      }
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
        final requestedSource = widget.initialSourceId;
        if (requestedSource != null &&
            !sources.any((s) => s.id == requestedSource)) {
          throw StateError(
            'The saved channel source is unavailable. Reconnect it in Manage Sources.',
          );
        }
        toOpen = _channelByKey(requested.trim());
        if (toOpen == null ||
            (requestedSource != null && toOpen.sourceId != requestedSource)) {
          throw StateError(
            'This saved channel is no longer available from its source.',
          );
        }
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
      final activeSources = allSourcesSelected
          ? sources
          : <LiveTvSource>[source!];
      final historyKeys = <String>[];
      var unavailable = 0;
      for (final activeSource in activeSources) {
        final snapshot = await syncService.load(
          expectedConnection: connection,
          profileId: widget.profileId,
          sourceId: activeSource.id,
        );
        if (!mounted) return;
        historyKeys.addAll(snapshot.history);
        final library = await GlobalPlaylistStore().load(widget.profileId);
        for (final key in snapshot.favorites) {
          final matches = channels.where(
            (channel) =>
                channel.sourceId == activeSource.id &&
                (_channelKey(channel) == key || _channelToken(channel) == key),
          );
          if (matches.isEmpty) {
            unavailable++;
            continue;
          }
          final saved = vodHubItem(_channelLibraryItem(matches.first));
          if (!library.favorites.containsKey(saved.key)) {
            await PlaylistHubRepository().setFavorite(
              widget.profileId,
              saved,
              true,
            );
          }
        }
      }
      final savedFavorites = await channelFavoriteKeys(widget.profileId);
      if (!mounted || source == null) {
        return;
      }
      _setState(() {
        favorites = savedFavorites;
        history = [
          ...historyKeys,
          ...history.where((value) => !historyKeys.contains(value)),
        ].take(50).toList();
        syncStatus = unavailable == 0
            ? ''
            : '$unavailable saved channels are unavailable from their sources.';
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
      created.stream.buffering.listen((value) {
        if (value) {
          unawaited(_emitBufferingStartTelemetry());
        } else {
          _finishBufferingTelemetry();
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

  Future<void> _emitBufferingStartTelemetry() async {
    if (bufferingStartedAtUtc != null) {
      return;
    }
    final channel = selected;
    bufferingStartedAtUtc = DateTime.now().toUtc();
    bufferingEpisodes += 1;
    AppLog.event(
      'live_tv.buffer.start',
      props: {
        'title': channel?.title ?? 'Unknown channel',
        'sourceId': source?.id ?? '',
        'channelId': channel == null ? '' : _channelKey(channel),
        'positionMs': lastPosition.inMilliseconds,
        'reconnectAttempts': reconnectAttempts,
      },
    );
  }

  void _finishBufferingTelemetry({bool aborted = false}) {
    final started = bufferingStartedAtUtc;
    if (started == null) {
      return;
    }
    bufferingStartedAtUtc = null;
    final channel = selected;
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
        'title': channel?.title ?? 'Unknown channel',
        'sourceId': source?.id ?? '',
        'channelId': channel == null ? '' : _channelKey(channel),
        'positionMs': lastPosition.inMilliseconds,
        'bufferedMs': bufferedMs,
        'aborted': aborted,
        'reconnectAttempts': reconnectAttempts,
      },
    );
    if (bufferedMs >= 4000) {
      AppLog.warn(
        LogCategory.playback,
        'Live TV buffering spike',
        details: {
          'title': channel?.title ?? 'Unknown channel',
          'bufferedMs': bufferedMs,
          'sourceId': source?.id ?? '',
          'channelId': channel == null ? '' : _channelKey(channel),
          'positionMs': lastPosition.inMilliseconds,
        },
      );
    }
  }

  Future<void> _disposePlayer() async {
    _finishBufferingTelemetry(aborted: true);
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

  LiveTvLibraryItem _channelLibraryItem(LiveTvChannel channel) =>
      LiveTvLibraryItem(
        sourceId: channel.sourceId ?? source!.id,
        sourceName: channel.sourceName ?? source?.name ?? 'Live TV',
        mediaType: 'channel',
        mediaId: _channelToken(channel),
        title: channel.title,
        posterUrl: channel.logo,
        streamUrl: channel.streamUrl,
      );

  Future<void> _toggleFavorite(LiveTvChannel channel) async {
    final key = _channelKey(channel);
    final next = Set<String>.from(favorites);
    if (!next.remove(key)) {
      next.add(key);
    }
    try {
      await PlaylistHubRepository().setFavorite(
        widget.profileId,
        vodHubItem(_channelLibraryItem(channel)),
        next.contains(key),
      );
    } catch (e) {
      _setState(() => error = 'Could not save your channel favorite. $e');
      return;
    }
    if (!mounted) return;
    favorites = next;
    _recomputeChannelViews();
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
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
        favorites: next
            .where((key) => key.startsWith('${selectedSource.id}|'))
            .toSet(),
      );
      await controlService.pushConfig(
        expectedConnection: connection,
        profileId: widget.profileId,
        sources: await HomePreferences().liveTvSources(widget.profileId),
        tmdbApiKey: await HomePreferences().tmdbApiKey(widget.profileId),
        profileState: await HomePreferences().liveTvProfileSyncState(
          widget.profileId,
        ),
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
    if (reconnectAttempts >= 3) {
      _setState(() {
        error =
            'Automatic reconnect paused to avoid restart loops. Open the channel again to retry.';
        status = 'Reconnect paused';
      });
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

  void _dvrNotice(String message, {bool error = false}) {
    if (!mounted) {
      return;
    }
    _setState(() => syncStatus = message);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? const Color(0xFF8B1E1E) : null,
        duration: Duration(seconds: error ? 6 : 3),
      ),
    );
  }

  String _dvrErrorText(Object error, String fallback) {
    if (error is DeviceRequestFailure) {
      if (error.message.isNotEmpty) {
        return error.message;
      }
      if (error.statusCode == 404) {
        return 'This Millitop server does not support DVR yet. Update the dashboard server to enable recording.';
      }
    }
    if (error is TimeoutException) {
      return 'The Millitop server did not respond in time. Try again.';
    }
    return fallback;
  }

  /// Loads recordings running anywhere in the household so the record button
  /// shows the correct state after reopening Live TV or switching devices.
  Future<void> _refreshActiveRecordings() async {
    final connection = DeviceConnection.instance.connectionKey;
    if (dvrBusy ||
        connection.isEmpty ||
        !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      final rows = await syncService.dvrActive(expectedConnection: connection);
      if (!mounted || dvrBusy) {
        return;
      }
      _setState(() {
        activeRecordings = {
          for (final row in rows)
            if ((row['channelId'] ?? '').toString().isNotEmpty)
              row['channelId'].toString(): row,
        };
      });
    } catch (_) {
      // Older servers without DVR support; leave the button idle.
    }
  }

  Future<void> _toggleDvr() async {
    if (dvrBusy) {
      return;
    }
    final channel = _dvrChannel;
    final selectedSource = channel == null ? null : _sourceForChannel(channel);
    if (channel == null || selectedSource == null) {
      _dvrNotice('Choose a channel before recording.', error: true);
      return;
    }
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      _dvrNotice(
        'Pair this device with your Millitop server to record. Recordings are saved to your DVR on the server.',
        error: true,
      );
      return;
    }
    final channelKey = _channelKey(channel);
    final active = activeRecordings[channelKey];
    final start = active == null;
    _setState(() => dvrBusy = true);
    if (start) {
      _dvrNotice('Starting recording on ${channel.title}...');
    }
    try {
      final program = _currentProgram(channel);
      final now = DateTime.now();
      final fallbackTitle =
          '${channel.title} · ${now.month}/${now.day} ${_clockText(now.toUtc())}';
      final response = await syncService.dvr(
        expectedConnection: connection,
        profileId: widget.profileId,
        sourceId: selectedSource.id,
        channelId: channelKey,
        channelName: channel.title,
        start: start,
        streamUrl: channel.streamUrl,
        title: program?.title.trim().isNotEmpty == true
            ? program!.title
            : fallbackTitle,
        recordingId: active?['id']?.toString(),
      );
      final record = response['recording'] is Map
          ? Map<String, dynamic>.from(response['recording'] as Map)
          : <String, dynamic>{};
      if (!mounted) {
        return;
      }
      _setState(() {
        final next = Map<String, Map<String, dynamic>>.from(activeRecordings);
        if (start) {
          next[channelKey] = record;
        } else {
          next.remove(channelKey);
        }
        activeRecordings = next;
      });
      if (start) {
        _dvrNotice(
          response['alreadyRecording'] == true
              ? '${channel.title} is already recording.'
              : 'Recording ${channel.title}. Press the red button to stop.',
        );
      } else if (record['status'] == 'failed') {
        _dvrNotice(
          record['note']?.toString() ?? 'The recording could not be saved.',
          error: true,
        );
      } else {
        _dvrNotice('Recording saved to DVR.');
      }
      _showOsd();
    } catch (e) {
      if (!start && e is DeviceRequestFailure && e.statusCode == 404) {
        // Already stopped elsewhere (another device or a schedule ending).
        _setState(() {
          activeRecordings = Map.of(activeRecordings)..remove(channelKey);
        });
        _dvrNotice('Recording already stopped. Find it in DVR.');
      } else {
        _dvrNotice(
          _dvrErrorText(
            e,
            start ? 'Recording could not start.' : 'Recording could not stop.',
          ),
          error: true,
        );
      }
    } finally {
      if (mounted) {
        _setState(() => dvrBusy = false);
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
        streamUrl: channel.streamUrl,
      );
      _dvrNotice(
        'Scheduled "${selectedProgram.title}". It will appear in DVR.',
      );
      unawaited(_refreshActiveRecordings());
    } catch (e) {
      _dvrNotice(_dvrErrorText(e, 'DVR scheduling failed.'), error: true);
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
      final channelId = _channelKey(channel);
      AppLog.event(
        'live_tv.buffer.stall',
        props: {
          'title': channel.title,
          'sourceId': source?.id ?? '',
          'channelId': channelId,
          'progressAgeMs': progressAge.inMilliseconds,
          'isPlaying': isPlaying,
          'durationMs': lastDuration.inMilliseconds,
          'positionMs': lastPosition.inMilliseconds,
          'reconnectAttempts': reconnectAttempts,
        },
      );
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
    unawaited(_applyPlatformFullscreen(next));
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

  Future<void> _applyPlatformFullscreen(bool value) async {
    if (!mounted) {
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        if (value) {
          await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.immersiveSticky,
          );
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        } else {
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
          await SystemChrome.setPreferredOrientations(const []);
        }
      } catch (_) {}
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
                color: focused ? const Color(0xFF6DF1EC) : Colors.transparent,
                width: focused ? 3 : 2,
              ),
              borderRadius: BorderRadius.circular(4),
              boxShadow: focused
                  ? const [
                      BoxShadow(
                        color: Color(0x5548D1CC),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
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
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
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
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
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

  Future<void> _openFocusedChannelMenu() async {
    final channel = _focusedChannel;
    if (channel == null) {
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(channel.title),
        content: const Text('Remote actions'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'favorite'),
            child: Text(
              _favorite(channel) ? 'Remove favorite' : 'Add favorite',
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'open'),
            child: const Text('Play on focused pane'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'guide'),
            child: const Text('Open guide'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'schedule'),
            child: const Text('Schedule DVR'),
          ),
        ],
      ),
    );
    switch (action) {
      case 'favorite':
        await _toggleFavorite(channel);
        break;
      case 'open':
        await _openFocusedPane(channel);
        break;
      case 'guide':
        _showEpgGuide();
        break;
      case 'schedule':
        await _scheduleDvrFromGuide();
        break;
    }
  }

  Future<void> _openSearchKeyboard() async {
    final controller = TextEditingController(text: search.text);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Channel search'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            labelText: 'Search channels',
            hintText: 'Type channel, group, or program',
          ),
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
    _recomputeChannelViews();
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
              'Use your system keyboard microphone button to dictate a search query where supported by this device.',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Voice query',
                hintText: 'Dictate or type',
              ),
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
    _recomputeChannelViews();
  }

  Future<void> _handleBackIntent() async {
    final now = DateTime.now();
    final armed = backExitArmedUntil;
    if (armed != null && armed.isAfter(now)) {
      await _minimizeToPipAndGoHome();
      return;
    }
    _setState(() {
      backExitArmedUntil = now.add(const Duration(seconds: 2));
      status = 'Press Back again to return home.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeTokens = context.millitopTheme;
    final preset = themeTokens.layoutPreset;
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 900;
    final shortScreen = viewport.height < 500;
    final channelRailOnRight =
        preset == MillitopLayoutPreset.commandDeck ||
        preset == MillitopLayoutPreset.haloSplit;
    Widget premiumCard({
      required Widget child,
      EdgeInsetsGeometry padding = const EdgeInsets.all(12),
      EdgeInsetsGeometry margin = const EdgeInsets.fromLTRB(12, 0, 12, 10),
    }) => Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: themeTokens.panelColor.withAlpha(130),
        borderRadius: BorderRadius.circular(themeTokens.cardRadius),
        border: Border.all(color: themeTokens.panelBorder),
      ),
      child: child,
    );
    ButtonStyle tvButtonStyle({required bool prominent}) => ButtonStyle(
      minimumSize: WidgetStateProperty.all(
        Size(prominent ? 184 : 168, prominent ? 56 : 52),
      ),
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
      textStyle: WidgetStateProperty.all(
        const TextStyle(
          fontSize: 16.5,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return BorderSide(color: themeTokens.accentColor, width: 2);
        }
        if (states.contains(WidgetState.hovered)) {
          return BorderSide(
            color: themeTokens.accentColor.withAlpha(200),
            width: 1.4,
          );
        }
        return BorderSide(
          color: themeTokens.panelBorder.withAlpha(160),
          width: 1,
        );
      }),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, __) {
        unawaited(_handleBackIntent());
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            unawaited(_handleBackIntent());
          },
          const SingleActivator(LogicalKeyboardKey.goBack): () {
            unawaited(_handleBackIntent());
          },
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () {
            if (_isTextInputFocused) {
              return;
            }
            unawaited(_togglePlayPause());
          },
          const SingleActivator(LogicalKeyboardKey.space): () {
            if (_isTextInputFocused) {
              return;
            }
            unawaited(_togglePlayPause());
          },
          const SingleActivator(LogicalKeyboardKey.arrowUp): () {
            if (_isTextInputFocused) {
              return;
            }
            if (fullScreenVideo) {
              unawaited(_zapChannel(-1, secondary: splitScreen));
            } else {
              _focusChannelByOffset(-1);
            }
          },
          const SingleActivator(LogicalKeyboardKey.arrowDown): () {
            if (_isTextInputFocused) {
              return;
            }
            if (fullScreenVideo) {
              unawaited(_zapChannel(1, secondary: splitScreen));
            } else {
              _focusChannelByOffset(1);
            }
          },
          const SingleActivator(LogicalKeyboardKey.pageUp): () {
            if (_isTextInputFocused) {
              return;
            }
            _focusChannelByPage(-1);
          },
          const SingleActivator(LogicalKeyboardKey.pageDown): () {
            if (_isTextInputFocused) {
              return;
            }
            _focusChannelByPage(1);
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            if (_isTextInputFocused) {
              return;
            }
            unawaited(
              _seekRelative(
                const Duration(seconds: -30),
                secondary: splitScreen,
              ),
            );
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            if (_isTextInputFocused) {
              return;
            }
            unawaited(
              _seekRelative(
                const Duration(seconds: 30),
                secondary: splitScreen,
              ),
            );
          },
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (_isTextInputFocused) {
              return;
            }
            final channel = _focusedChannel;
            if (channel != null) {
              unawaited(_openFocusedPane(channel));
            }
          },
          const SingleActivator(LogicalKeyboardKey.select): () {
            if (_isTextInputFocused) {
              return;
            }
            final channel = _focusedChannel;
            if (channel != null) {
              unawaited(_openFocusedPane(channel));
            }
          },
          const SingleActivator(LogicalKeyboardKey.keyF): () {
            if (_isTextInputFocused) {
              return;
            }
            final channel = _focusedChannel;
            if (channel != null) {
              unawaited(_toggleFavorite(channel));
            }
          },
          const SingleActivator(LogicalKeyboardKey.keyG): () {
            if (_isTextInputFocused) {
              return;
            }
            _showEpgGuide();
          },
          const SingleActivator(LogicalKeyboardKey.keyM): () {
            if (_isTextInputFocused) {
              return;
            }
            unawaited(_openFocusedChannelMenu());
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
          const SingleActivator(LogicalKeyboardKey.keyR): () {
            if (_isTextInputFocused) {
              return;
            }
            unawaited(_scheduleDvrFromGuide());
          },
          const SingleActivator(LogicalKeyboardKey.keyS): () {
            if (_isTextInputFocused) {
              return;
            }
            unawaited(_toggleSplitScreen());
          },
          const SingleActivator(LogicalKeyboardKey.keyL): () {
            if (_isTextInputFocused) {
              return;
            }
            _toggleFullScreenVideo();
          },
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
            if (_isTextInputFocused) {
              return;
            }
            screenFocusNode.requestFocus();
            unawaited(_openSearchKeyboard());
          },
        },
        child: Focus(
          autofocus: true,
          focusNode: screenFocusNode,
          child: Theme(
            data: Theme.of(context).copyWith(
              filledButtonTheme: FilledButtonThemeData(
                style: tvButtonStyle(prominent: true),
              ),
              outlinedButtonTheme: OutlinedButtonThemeData(
                style: tvButtonStyle(prominent: false),
              ),
              textButtonTheme: TextButtonThemeData(
                style: tvButtonStyle(prominent: false),
              ),
            ),
            child: Scaffold(
              appBar: fullScreenVideo
                  ? null
                  : AppBar(
                      title: Text(switch (preset) {
                        MillitopLayoutPreset.commandDeck => 'Live Command',
                        MillitopLayoutPreset.haloSplit => 'Live Grid',
                        MillitopLayoutPreset.emberStack => 'Live Lounge',
                        _ => 'Live TV',
                      }),
                      leading: IconButton(
                        tooltip: 'Home (PiP)',
                        onPressed: () => unawaited(_handleBackIntent()),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      actions: [
                        IconButton(
                          tooltip: 'Sleep timer',
                          onPressed: () => unawaited(
                            showSleepModeSheet(
                              context,
                              profileId: widget.profileId,
                            ),
                          ),
                          icon: ListenableBuilder(
                            listenable: SleepMode.instance,
                            builder: (context, _) => Icon(
                              SleepMode.instance.deadline == null
                                  ? Icons.nightlight_round_outlined
                                  : Icons.timer_outlined,
                            ),
                          ),
                        ),
                        if (compact)
                          PopupMenuButton<String>(
                            tooltip: 'Live TV options',
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'sources',
                                enabled: !opening,
                                child: const Text('Manage Sources'),
                              ),
                              PopupMenuItem(
                                value: 'reload',
                                enabled: !loading && !opening && source != null,
                                child: const Text('Reload'),
                              ),
                              PopupMenuItem(
                                value: 'split',
                                enabled: !loading && !opening,
                                child: Text(
                                  screenCount == 4
                                      ? 'Return to single screen'
                                      : 'Enable ${screenCount + 1}-screen',
                                ),
                              ),
                            ],
                            onSelected: (value) {
                              switch (value) {
                                case 'sources':
                                  unawaited(_manageSources());
                                  break;
                                case 'reload':
                                  unawaited(_loadChannels());
                                  break;
                                case 'split':
                                  unawaited(_toggleSplitScreen());
                                  break;
                              }
                            },
                          )
                        else
                          TextButton(
                            onPressed: opening ? null : _manageSources,
                            child: const Text('Manage Sources'),
                          ),
                        if (!compact)
                          TextButton(
                            onPressed: loading || opening || source == null
                                ? null
                                : _loadChannels,
                            child: const Text('Reload'),
                          ),
                        IconButton(
                          tooltip: 'Guide',
                          onPressed:
                              _channelForPane(splitScreen ? focusedPane : 0) ==
                                  null
                              ? null
                              : _showEpgGuide,
                          icon: const Icon(Icons.view_agenda_outlined),
                        ),
                        if (!compact)
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
                              screenCount == 1
                                  ? Icons.view_week
                                  : Icons.grid_view,
                            ),
                          ),
                        IconButton(
                          tooltip: fullScreenVideo
                              ? 'Exit full screen'
                              : 'Full screen',
                          onPressed: _toggleFullScreenVideo,
                          icon: Icon(
                            fullScreenVideo
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                          ),
                        ),
                      ],
                      bottom: preset == MillitopLayoutPreset.streamRail
                          ? PreferredSize(
                              preferredSize: const Size.fromHeight(42),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  0,
                                  14,
                                  8,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        splitScreen
                                            ? '$screenCount screens'
                                            : 'Single screen',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: themeTokens.mutedColor,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '${visibleChannels.length} channels',
                                      style: TextStyle(
                                        color: themeTokens.mutedColor,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : null,
                    ),
              body: SafeArea(
                child: Column(
                  children: [
                    if (!fullScreenVideo && (loading || opening))
                      const LinearProgressIndicator(),
                    if (!fullScreenVideo)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: compact
                              ? (shortScreen ? 80 : 160)
                              : double.infinity,
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              if (!fullScreenVideo &&
                                  (status.isNotEmpty ||
                                      syncStatus.isNotEmpty ||
                                      error.isNotEmpty))
                                premiumCard(
                                  margin: const EdgeInsets.fromLTRB(
                                    12,
                                    10,
                                    12,
                                    10,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (status.isNotEmpty)
                                        Text(
                                          status,
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      if (syncStatus.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          syncStatus,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                      if (error.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          error,
                                          style: const TextStyle(
                                            color: Colors.orangeAccent,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              if (!fullScreenVideo)
                                premiumCard(
                                  margin: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    10,
                                  ),
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    12,
                                    12,
                                    12,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Channel discovery',
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: DropdownButtonFormField<String>(
                                              isExpanded: true,
                                              key: ValueKey(
                                                allSourcesSelected
                                                    ? 'source-all'
                                                    : (source?.id ??
                                                          'no-source'),
                                              ),
                                              initialValue: allSourcesSelected
                                                  ? 'all'
                                                  : source?.id,
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
                                                  (
                                                    item,
                                                  ) => DropdownMenuItem<String>(
                                                    value: item.id,
                                                    child: Text(
                                                      '${item.name} (${item.isXtream ? 'Xtream' : 'M3U'})',
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              onChanged: loading || opening
                                                  ? null
                                                  : (value) async {
                                                      if (value == 'all') {
                                                        _setState(() {
                                                          allSourcesSelected =
                                                              true;
                                                          selectedGroup =
                                                              selectedGroupByScope[_sourceId()] ??
                                                              'All';
                                                        });
                                                        await _scheduleProfileSync();
                                                        await _loadChannels();
                                                        return;
                                                      }
                                                      final next = sources
                                                          .firstWhere(
                                                            (item) =>
                                                                item.id ==
                                                                value,
                                                            orElse: () =>
                                                                sources.first,
                                                          );
                                                      _setState(() {
                                                        source = next;
                                                        allSourcesSelected =
                                                            false;
                                                        selectedGroup =
                                                            selectedGroupByScope[_sourceId()] ??
                                                            'All';
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
                                              focusNode: searchFocusNode,
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
                                            onPressed: loading || opening
                                                ? null
                                                : _manageChannelScope,
                                            icon: const Icon(Icons.tune),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              if (!fullScreenVideo)
                                premiumCard(
                                  margin: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    10,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        flex: 2,
                                        child:
                                            DropdownButtonFormField<
                                              _ChannelFilterMode
                                            >(
                                              isExpanded: true,
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
                                                  value: _ChannelFilterMode
                                                      .favorites,
                                                  child: Text('Favorites'),
                                                ),
                                                DropdownMenuItem(
                                                  value:
                                                      _ChannelFilterMode.recent,
                                                  child: Text(
                                                    'Continue Watching',
                                                  ),
                                                ),
                                              ],
                                              onChanged: (value) {
                                                if (value == null) {
                                                  return;
                                                }
                                                _setState(
                                                  () => filterMode = value,
                                                );
                                                _recomputeChannelViews();
                                              },
                                            ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        flex: 3,
                                        child: DropdownButtonFormField<String>(
                                          isExpanded: true,
                                          key: ValueKey(
                                            'group-$selectedGroup-${groupOptions.length}',
                                          ),
                                          initialValue:
                                              groupOptions.contains(
                                                selectedGroup,
                                              )
                                              ? selectedGroup
                                              : groupOptions.first,
                                          decoration: const InputDecoration(
                                            labelText: 'Category',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: groupOptions
                                              .map(
                                                (group) =>
                                                    DropdownMenuItem<String>(
                                                      value: group,
                                                      child: Text(
                                                        group,
                                                        overflow: TextOverflow
                                                            .ellipsis,
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
                                              selectedGroupByScope[_sourceId()] =
                                                  value;
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
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: Flex(
                        direction: compact ? Axis.vertical : Axis.horizontal,
                        verticalDirection: compact
                            ? VerticalDirection.up
                            : VerticalDirection.down,
                        textDirection: channelRailOnRight
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        children: [
                          if (!fullScreenVideo)
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Container(
                                width: compact ? double.infinity : 470,
                                height: compact
                                    ? (shortScreen ? 96 : 160)
                                    : null,
                                margin: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  10,
                                  12,
                                ),
                                decoration: BoxDecoration(
                                  color: themeTokens.panelColor.withAlpha(130),
                                  borderRadius: BorderRadius.circular(
                                    themeTokens.cardRadius,
                                  ),
                                  border: Border.all(
                                    color: themeTokens.panelBorder,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        14,
                                        12,
                                        14,
                                        8,
                                      ),
                                      child: Text(
                                        'Channels',
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: visibleChannels.isEmpty
                                          ? const Center(
                                              child: Text(
                                                'No channels match the current filter.',
                                              ),
                                            )
                                          : ListView.builder(
                                              controller:
                                                  channelScrollController,
                                              itemExtent: 74,
                                              itemCount: visibleChannels.length,
                                              itemBuilder: (context, index) {
                                                final channel =
                                                    visibleChannels[index];
                                                final focused =
                                                    index ==
                                                    focusedChannelIndex;
                                                final active =
                                                    selected == channel ||
                                                    selectedSecondary ==
                                                        channel ||
                                                    selectedTertiary ==
                                                        channel ||
                                                    selectedQuaternary ==
                                                        channel;
                                                final nowProgram =
                                                    _currentProgram(channel);
                                                return ListTile(
                                                  minVerticalPadding: 9,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                    side: BorderSide(
                                                      color: focused
                                                          ? themeTokens
                                                                .accentColor
                                                          : Colors.transparent,
                                                      width: focused ? 1.4 : 1,
                                                    ),
                                                  ),
                                                  selected: active,
                                                  tileColor: focused
                                                      ? themeTokens
                                                            .selectedSurface
                                                      : null,
                                                  leading: SizedBox(
                                                    width: 62,
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        if (active)
                                                          const Padding(
                                                            padding:
                                                                EdgeInsets.only(
                                                                  right: 4,
                                                                ),
                                                            child: Icon(
                                                              Icons.play_arrow,
                                                              size: 14,
                                                              color: Colors
                                                                  .greenAccent,
                                                            ),
                                                          ),
                                                        Text('${index + 1}'),
                                                        if (_favorite(channel))
                                                          const Padding(
                                                            padding:
                                                                EdgeInsets.only(
                                                                  left: 4,
                                                                ),
                                                            child: Icon(
                                                              Icons.star,
                                                              size: 14,
                                                              color:
                                                                  Colors.amber,
                                                            ),
                                                          ),
                                                        if (selectedSecondary ==
                                                                channel ||
                                                            selectedTertiary ==
                                                                channel ||
                                                            selectedQuaternary ==
                                                                channel)
                                                          const Padding(
                                                            padding:
                                                                EdgeInsets.only(
                                                                  left: 4,
                                                                ),
                                                            child: Icon(
                                                              Icons.splitscreen,
                                                              size: 14,
                                                              color: Colors
                                                                  .lightBlueAccent,
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                  title: Text(
                                                    _displayTitle(channel),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 17,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      height: 1.2,
                                                    ),
                                                  ),
                                                  subtitle: Text(
                                                    [
                                                      if (nowProgram != null)
                                                        'Now: ${nowProgram.title}',
                                                      if (nowProgram == null &&
                                                          channel.group != null)
                                                        channel.group!,
                                                      if (!compact &&
                                                          channel.sourceName !=
                                                              null)
                                                        'Source: ${channel.sourceName!}',
                                                    ].join(' · '),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 13.5,
                                                      color: Colors.white70,
                                                      height: 1.35,
                                                    ),
                                                  ),
                                                  trailing: Wrap(
                                                    spacing: 2,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment
                                                            .center,
                                                    children: [
                                                      if (channel.sourceName !=
                                                          null)
                                                        Container(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 8,
                                                                vertical: 3,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color: const Color(
                                                              0x3323D5C8,
                                                            ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  12,
                                                                ),
                                                          ),
                                                          child: Text(
                                                            channel.sourceName!,
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 11,
                                                                ),
                                                          ),
                                                        ),
                                                      IconButton(
                                                        tooltip:
                                                            _favorite(channel)
                                                            ? 'Remove favorite'
                                                            : 'Add favorite',
                                                        icon: Icon(
                                                          _favorite(channel)
                                                              ? Icons.star
                                                              : Icons
                                                                    .star_border,
                                                          color:
                                                              _favorite(channel)
                                                              ? Colors.amber
                                                              : null,
                                                        ),
                                                        onPressed: () =>
                                                            _toggleFavorite(
                                                              channel,
                                                            ),
                                                      ),
                                                      if (splitScreen)
                                                        IconButton(
                                                          tooltip:
                                                              'Open on focused pane',
                                                          icon: const Icon(
                                                            Icons.open_in_new,
                                                          ),
                                                          onPressed: () =>
                                                              unawaited(
                                                                _openFocusedPane(
                                                                  channel,
                                                                ),
                                                              ),
                                                        ),
                                                    ],
                                                  ),
                                                  onTap: () => unawaited(
                                                    _openFocusedPane(channel),
                                                  ),
                                                  onFocusChange: (value) {
                                                    if (value) {
                                                      _setState(
                                                        () =>
                                                            focusedChannelIndex =
                                                                index,
                                                      );
                                                    }
                                                  },
                                                );
                                              },
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          SizedBox(width: fullScreenVideo ? 0 : 2),
                          Expanded(
                            child: KeyboardListener(
                              focusNode: fullScreenFocusNode,
                              onKeyEvent: _onFullScreenKey,
                              child: MouseRegion(
                                onEnter: (_) {
                                  _showFullScreenControlsTemporarily();
                                  _showOsd();
                                },
                                onHover: (_) {
                                  _showFullScreenControlsTemporarily();
                                  _showOsd();
                                },
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
                                          if (selected != null)
                                            (() {
                                              final nowProgram =
                                                  _currentProgram(selected!);
                                              final nextProgram = _nextProgram(
                                                selected!,
                                              );
                                              final hasGuideData =
                                                  nowProgram != null ||
                                                  nextProgram != null ||
                                                  _programsForChannel(
                                                    selected!,
                                                  ).isNotEmpty;
                                              return Positioned.fill(
                                                child: AnimatedOpacity(
                                                  opacity: osdVisible ? 1 : 0,
                                                  duration: const Duration(
                                                    milliseconds: 200,
                                                  ),
                                                  curve: Curves.easeOutCubic,
                                                  child: IgnorePointer(
                                                    ignoring: !osdVisible,
                                                    child: LiveTvOsd(
                                                      channelName:
                                                          selected!.title,
                                                      channelLogo:
                                                          selected!.logo,
                                                      nowProgram: nowProgram,
                                                      nextProgram: nextProgram,
                                                      epgProgress: _epgProgress(
                                                        nowProgram,
                                                      ),
                                                      isFavorite: _favorite(
                                                        selected!,
                                                      ),
                                                      recording: recording,
                                                      recordingBusy: dvrBusy,
                                                      liveOnly:
                                                          lastDuration <=
                                                          Duration.zero,
                                                      isPlaying: isPlaying,
                                                      position: lastPosition,
                                                      duration: lastDuration,
                                                      isFullScreen:
                                                          fullScreenVideo,
                                                      splitScreen: splitScreen,
                                                      screenCount: screenCount,
                                                      hasEpg: hasGuideData,
                                                      onGoLive: () => unawaited(
                                                        _seekRelative(
                                                          lastDuration -
                                                              lastPosition,
                                                        ),
                                                      ),
                                                      onInteraction: _showOsd,
                                                      onFavorite: () =>
                                                          unawaited(
                                                            _toggleFavorite(
                                                              selected!,
                                                            ),
                                                          ),
                                                      onPlayPause: () =>
                                                          unawaited(
                                                            _togglePlayPause(),
                                                          ),
                                                      onStop: () => unawaited(
                                                        _stopCurrentChannel(),
                                                      ),
                                                      onChannelDown: () =>
                                                          unawaited(
                                                            _zapChannel(
                                                              -1,
                                                              secondary: false,
                                                            ),
                                                          ),
                                                      onChannelUp: () =>
                                                          unawaited(
                                                            _zapChannel(
                                                              1,
                                                              secondary: false,
                                                            ),
                                                          ),
                                                      onRewind: () => unawaited(
                                                        _seekRelative(
                                                          const Duration(
                                                            seconds: -10,
                                                          ),
                                                        ),
                                                      ),
                                                      onForward: () =>
                                                          unawaited(
                                                            _seekRelative(
                                                              const Duration(
                                                                seconds: 10,
                                                              ),
                                                            ),
                                                          ),
                                                      onRecord: () => unawaited(
                                                        _toggleDvr(),
                                                      ),
                                                      onSchedule: () => unawaited(
                                                        _scheduleDvrFromGuide(),
                                                      ),
                                                      onGuide: _showEpgGuide,
                                                      onSplit: () => unawaited(
                                                        _toggleSplitScreen(),
                                                      ),
                                                      onFullScreen:
                                                          _toggleFullScreenVideo,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            })(),
                                          if (recording && !osdVisible)
                                            const Positioned(
                                              top: 12,
                                              left: 12,
                                              child: IgnorePointer(
                                                child: DvrRecordingBadge(),
                                              ),
                                            ),
                                          if (fullScreenVideo && !osdVisible)
                                            Positioned(
                                              top: 12,
                                              right: 12,
                                              child: AnimatedOpacity(
                                                opacity:
                                                    fullScreenControlsVisible
                                                    ? 1
                                                    : 0,
                                                duration: const Duration(
                                                  milliseconds: 180,
                                                ),
                                                child: IgnorePointer(
                                                  ignoring:
                                                      !fullScreenControlsVisible,
                                                  child: IconButton.filledTonal(
                                                    tooltip: 'Exit full screen',
                                                    onPressed:
                                                        _toggleFullScreenVideo,
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
            ),
          ),
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

class _LiveTvGuideDialogState extends State<_LiveTvGuideDialog>
    with SingleTickerProviderStateMixin {
  static const _slotMinutes = 30;
  static const _hoursVisible = 4;
  static const _rowHeight = 74.0;
  static const _channelColumnWidth = 250.0;
  static const _pxPerMinute = 3.6;
  late final DateTime windowStartUtc;
  late final DateTime windowEndUtc;
  late final AnimationController _pulseController;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1450),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOutCubic,
    );
    final nowUtc = DateTime.now().toUtc();
    final slotMs = const Duration(minutes: _slotMinutes).inMilliseconds;
    final roundedMs = (nowUtc.millisecondsSinceEpoch ~/ slotMs) * slotMs;
    windowStartUtc = DateTime.fromMillisecondsSinceEpoch(
      roundedMs,
      isUtc: true,
    );
    windowEndUtc = windowStartUtc.add(const Duration(hours: _hoursVisible));
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Widget _buildNowMarker({required double left, required bool compact}) {
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final width = compact
              ? 2.0 + (_pulse.value * 0.6)
              : 2.0 + (_pulse.value * 0.8);
          final glow = 0.32 + (_pulse.value * 0.3);
          return Container(
            width: width,
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.92),
              boxShadow: [
                BoxShadow(
                  color: Colors.redAccent.withValues(alpha: glow),
                  blurRadius: compact ? 7 : 10,
                  spreadRadius: compact ? 0.2 : 0.5,
                ),
              ],
            ),
          );
        },
      ),
    );
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
    final tokens = context.millitopTheme;
    final rows = _rows;
    final totalMinutes = windowEndUtc.difference(windowStartUtc).inMinutes;
    final timelineWidth = totalMinutes * _pxPerMinute;
    final nowUtc = DateTime.now().toUtc();
    final nowOffsetMinutes = nowUtc.difference(windowStartUtc).inMinutes;
    final nowOffset = (nowOffsetMinutes * _pxPerMinute)
        .clamp(0, timelineWidth)
        .toDouble();
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: Theme.of(context).colorScheme.surface,
      titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
      contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      title: Row(
        children: [
          Icon(Icons.view_agenda_outlined, color: tokens.accentColor),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'EPG Guide',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tokens.selectedSurface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: tokens.panelBorder),
            ),
            child: Text(
              '${rows.length} channels',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: tokens.accentColor,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 1160,
        height: 680,
        child: rows.isEmpty
            ? const Center(
                child: Text(
                  'No guide rows matched these channels.\n'
                  'For Xtream, confirm XMLTV is enabled and reload channels.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, height: 1.4),
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  color: tokens.panelColor.withAlpha(120),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: tokens.panelBorder),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: tokens.panelBorder),
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: _channelColumnWidth,
                            child: Text(
                              'Channels',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SizedBox(
                              height: 34,
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
                                        style: const TextStyle(
                                          fontSize: 13,
                                          height: 1.2,
                                          color: Colors.white70,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  _buildNowMarker(
                                    left: nowOffset,
                                    compact: true,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Scrollbar(
                        thumbVisibility: true,
                        child: ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            final highlighted = row.channel == widget.selected;
                            return SizedBox(
                              height: _rowHeight,
                              child: Row(
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOutCubic,
                                    width: _channelColumnWidth,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    alignment: Alignment.centerLeft,
                                    decoration: BoxDecoration(
                                      color: highlighted
                                          ? const Color(0x3A48D1CC)
                                          : const Color(0x1A1B273D),
                                      border: const Border(
                                        bottom: BorderSide(
                                          color: Color(0x223D5C8E),
                                        ),
                                      ),
                                    ),
                                    child: AnimatedDefaultTextStyle(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      style: TextStyle(
                                        fontSize: 15.5,
                                        height: 1.3,
                                        color: highlighted
                                            ? const Color(0xFFE7FFFF)
                                            : Colors.white,
                                        fontWeight: highlighted
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                      ),
                                      child: Text(
                                        row.channel.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
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
                                              rowHighlighted: highlighted,
                                            ),
                                          _buildNowMarker(
                                            left: nowOffset,
                                            compact: false,
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

class _GuideProgramTile extends StatefulWidget {
  final LiveTvProgram program;
  final DateTime windowStartUtc;
  final DateTime windowEndUtc;
  final double pxPerMinute;
  final bool rowHighlighted;
  const _GuideProgramTile({
    required this.program,
    required this.windowStartUtc,
    required this.windowEndUtc,
    required this.pxPerMinute,
    required this.rowHighlighted,
  });

  @override
  State<_GuideProgramTile> createState() => _GuideProgramTileState();
}

class _GuideProgramTileState extends State<_GuideProgramTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final start = widget.program.start.isBefore(widget.windowStartUtc)
        ? widget.windowStartUtc
        : widget.program.start;
    final end = widget.program.end.isAfter(widget.windowEndUtc)
        ? widget.windowEndUtc
        : widget.program.end;
    final offsetMinutes = start.difference(widget.windowStartUtc).inMinutes;
    final widthMinutes = end
        .difference(start)
        .inMinutes
        .clamp(6, 10000)
        .toDouble();
    final nowUtc = DateTime.now().toUtc();
    final isLiveNow =
        !nowUtc.isBefore(widget.program.start) &&
        nowUtc.isBefore(widget.program.end);
    final emphasized = _hovered || _focused || widget.rowHighlighted;
    final scale = emphasized ? 1.02 : 1.0;
    final borderWidth = isLiveNow ? 1.4 : (emphasized ? 1.3 : 1.0);
    return Positioned(
      left: offsetMinutes * widget.pxPerMinute,
      top: 6,
      bottom: 6,
      width: widthMinutes * widget.pxPerMinute,
      child: Tooltip(
        message:
            '${widget.program.title}\n${_clockText(widget.program.start)} - ${_clockText(widget.program.end)}',
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 1, end: scale),
              duration: const Duration(milliseconds: 170),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) => Transform.scale(
                scale: value,
                alignment: Alignment.centerLeft,
                child: child,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 190),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isLiveNow
                        ? const [Color(0xFF256B63), Color(0xFF1D4D7A)]
                        : emphasized
                        ? const [Color(0xFF2B4A78), Color(0xFF26426A)]
                        : const [Color(0xFF243C63), Color(0xFF223553)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isLiveNow
                        ? const Color(0xFF82F8EC)
                        : emphasized
                        ? const Color(0xFF7EDAEF)
                        : const Color(0xFF3D5C8E),
                    width: borderWidth,
                  ),
                  boxShadow: emphasized
                      ? const [
                          BoxShadow(
                            color: Color(0x3348D1CC),
                            blurRadius: 12,
                            spreadRadius: 0.5,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  widget.program.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    fontWeight: emphasized ? FontWeight.w800 : FontWeight.w700,
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
