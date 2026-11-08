// ignore_for_file: deprecated_member_use, unnecessary_getters_setters

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../services/global_playlists.dart';
import '../widgets/mixed_playlist_picker.dart';
import '../services/device_connection.dart';
import '../services/audio_background_service.dart';
import '../services/group_listening_service.dart';
import '../services/home_preferences.dart';
import '../services/live_tv_control.dart';
import '../services/music_service.dart';
import '../services/music_widget_service.dart';
import '../services/music_mini_player.dart';
import '../services/playback_destinations_service.dart';
import '../services/speaker_discovery_service.dart';
import '../services/sleep_mode.dart';
import '../services/app_log.dart';
import '../theme/millitop_visual_theme.dart';
import 'sleep_mode_panel.dart';

enum _MusicSection { home, songs, albums, artists, playlists, favorites, radio }

enum _NowPlayingPane {
  vinyl,
  artwork,
  lyrics,
  visualizer,
  vinylVisualizer,
  artworkVisualizer,
}

class _MusicPaint {
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
  static Color get warning => _scheme.secondary;
  static Color get overlayLight => _scheme.surface.withAlpha(26);
  static Color get overlaySoft => _scheme.surface.withAlpha(51);
  static Color get overlayMuted => _scheme.surface.withAlpha(102);
  static Color get overlayOpaque => _scheme.surface.withAlpha(204);

  static Color blend(Color a, Color b, double t) => Color.lerp(a, b, t) ?? a;
}

class _NowPlayingTonearmPainter extends CustomPainter {
  const _NowPlayingTonearmPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final metalGradient = LinearGradient(
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
      colors: [
        _MusicPaint.blend(
          _MusicPaint.onSurface,
          _MusicPaint.accent,
          0.08,
        ).withAlpha(214),
        _MusicPaint.blend(
          _MusicPaint.onSurface,
          _MusicPaint.panel,
          0.35,
        ).withAlpha(168),
        _MusicPaint.blend(
          _MusicPaint.onSurface,
          _MusicPaint.accent,
          0.18,
        ).withAlpha(186),
        _MusicPaint.blend(
          _MusicPaint.onSurface,
          _MusicPaint.panel,
          0.65,
        ).withAlpha(150),
      ],
      stops: [0.0, 0.4, 0.6, 1.0],
    );

    final baseRect = Rect.fromCircle(
      center: Offset(size.width * 0.85, size.height * 0.08),
      radius: size.width * 0.12,
    );

    canvas.drawCircle(
      Offset(size.width * 0.86, size.height * 0.09),
      size.width * 0.12,
      Paint()
        ..color = _MusicPaint.overlayMuted
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    canvas.drawCircle(
      Offset(size.width * 0.85, size.height * 0.08),
      size.width * 0.12,
      Paint()
        ..shader = metalGradient.createShader(baseRect)
        ..style = PaintingStyle.fill,
    );

    canvas.drawCircle(
      Offset(size.width * 0.85, size.height * 0.08),
      size.width * 0.08,
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.onSurface,
          0.5,
        )
        ..style = PaintingStyle.fill,
    );

    final armPath = Path()..moveTo(size.width * 0.85, size.height * 0.08);
    armPath.cubicTo(
      size.width * 0.7,
      size.height * 0.15,
      size.width * 0.4,
      size.height * 0.5,
      size.width * 0.15,
      size.height * 0.82,
    );

    canvas.drawPath(
      armPath.shift(const Offset(2, 2)),
      Paint()
        ..color = _MusicPaint.overlayMuted
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    canvas.drawPath(
      armPath,
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.onSurface,
          0.55,
        )
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    canvas.drawPath(
      armPath,
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.onSurface,
          _MusicPaint.accent,
          0.12,
        )
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    final headshellRect = Rect.fromCircle(
      center: Offset(size.width * 0.15, size.height * 0.82),
      radius: size.width * 0.08,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width * 0.152, size.height * 0.825),
          width: size.width * 0.12,
          height: size.width * 0.14,
        ),
        Radius.circular(size.width * 0.02),
      ),
      Paint()
        ..color = _MusicPaint.overlaySoft
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width * 0.15, size.height * 0.82),
          width: size.width * 0.12,
          height: size.width * 0.14,
        ),
        Radius.circular(size.width * 0.02),
      ),
      Paint()
        ..shader = metalGradient.createShader(headshellRect)
        ..style = PaintingStyle.fill,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width * 0.15, size.height * 0.87),
          width: size.width * 0.06,
          height: size.width * 0.08,
        ),
        Radius.circular(size.width * 0.01),
      ),
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.onSurface,
          0.7,
        )
        ..style = PaintingStyle.fill,
    );

    final needlePath = Path()
      ..moveTo(size.width * 0.15, size.height * 0.9)
      ..lineTo(size.width * 0.14, size.height * 0.98);

    canvas.drawPath(
      needlePath,
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.onSurface,
          0.6,
        )
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    final needleTip = Path()
      ..moveTo(size.width * 0.14, size.height * 0.98)
      ..lineTo(size.width * 0.138, size.height * 0.985)
      ..lineTo(size.width * 0.14, size.height * 0.995)
      ..lineTo(size.width * 0.142, size.height * 0.985)
      ..close();

    canvas.drawPath(
      needleTip,
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.onSurface,
          _MusicPaint.accent,
          0.05,
        )
        ..style = PaintingStyle.fill,
    );

    canvas.drawCircle(
      Offset(size.width * 0.14, size.height * 0.985),
      size.width * 0.008,
      Paint()
        ..color = _MusicPaint.onSurface.withAlpha(153)
        ..style = PaintingStyle.fill,
    );

    canvas.drawCircle(
      Offset(size.width * 0.78, size.height * 0.1),
      size.width * 0.045,
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.onSurface,
          0.72,
        )
        ..style = PaintingStyle.fill,
    );

    canvas.drawCircle(
      Offset(size.width * 0.78, size.height * 0.1),
      size.width * 0.035,
      Paint()
        ..color = _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.onSurface,
          0.52,
        )
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _NowPlayingVinylGroovesPainter extends CustomPainter {
  const _NowPlayingVinylGroovesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    final groovePaint = Paint()
      ..color = _MusicPaint.overlayLight
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    final highlightPaint = Paint()
      ..color = _MusicPaint.onSurface.withAlpha(20)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    for (
      double radius = maxRadius * 0.95;
      radius > maxRadius * 0.24;
      radius -= 2.5
    ) {
      canvas.drawCircle(center, radius, groovePaint);
      canvas.drawCircle(center, radius - 0.5, highlightPaint);
    }

    canvas.drawCircle(
      center,
      maxRadius * 0.04,
      Paint()
        ..color = _MusicPaint.overlayOpaque
        ..style = PaintingStyle.fill,
    );

    canvas.drawCircle(
      center,
      maxRadius * 0.04,
      Paint()
        ..color = _MusicPaint.onSurface.withAlpha(26)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum _NowPlayingMode { standard, ipod, minimal, drive }

enum _NowPlayingTheme { auto, midnight, neon, warm }

enum _AnimationIntensity { off, low, normal, high }

enum _SongsFilter { all, favorites, mostPlayed }

enum _SongsSort { title, artist, album, plays }

enum _QueueEntryType { context, manual, recommendation }

enum _TrackAction {
  playNow,
  playNext,
  playLast,
  addToQueue,
  share,
  comment,
  report,
  toggleFavorite,
  startRadio,
  addToPlaylist,
  download,
}

enum _RepeatMode { off, all, one }

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

class _QueueEntry {
  final String entryId;
  final MusicTrack track;
  final _QueueEntryType type;
  final String? sourceLabel;
  const _QueueEntry({
    required this.entryId,
    required this.track,
    required this.type,
    this.sourceLabel,
  });

  Map<String, dynamic> toJson() => {
    'entryId': entryId,
    'track': track.toJson(),
    'type': type.name,
    'sourceLabel': sourceLabel,
  };

  static _QueueEntry? fromJson(Map<String, dynamic> json) {
    final entryId = json['entryId']?.toString().trim() ?? '';
    final trackRaw = json['track'];
    if (entryId.isEmpty || trackRaw is! Map) {
      return null;
    }
    final typeLabel = json['type']?.toString() ?? _QueueEntryType.context.name;
    final type = _QueueEntryType.values.firstWhere(
      (item) => item.name == typeLabel,
      orElse: () => _QueueEntryType.context,
    );
    try {
      return _QueueEntry(
        entryId: entryId,
        track: MusicTrack.fromJson(Map<String, dynamic>.from(trackRaw)),
        type: type,
        sourceLabel: json['sourceLabel']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

enum _ShareExpiryPreset { never, oneDay, oneWeek, oneMonth }

class _ShareLinkOptions {
  final bool allowDownload;
  final DateTime? expiresAt;
  const _ShareLinkOptions({
    required this.allowDownload,
    required this.expiresAt,
  });
}

class _ShareOptionsDialog extends StatefulWidget {
  final String label;
  const _ShareOptionsDialog({required this.label});

  @override
  State<_ShareOptionsDialog> createState() => _ShareOptionsDialogState();
}

class _ShareOptionsDialogState extends State<_ShareOptionsDialog> {
  _ShareExpiryPreset preset = _ShareExpiryPreset.oneWeek;
  bool allowDownload = true;

  DateTime? get _expiresAt {
    final now = DateTime.now();
    switch (preset) {
      case _ShareExpiryPreset.never:
        return null;
      case _ShareExpiryPreset.oneDay:
        return now.add(const Duration(days: 1));
      case _ShareExpiryPreset.oneWeek:
        return now.add(const Duration(days: 7));
      case _ShareExpiryPreset.oneMonth:
        return now.add(const Duration(days: 30));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Share options'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow download'),
              subtitle: const Text(
                'Let recipients save a copy, not just stream it.',
              ),
              value: allowDownload,
              onChanged: (value) => setState(() => allowDownload = value),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<_ShareExpiryPreset>(
              initialValue: preset,
              decoration: const InputDecoration(
                labelText: 'Link expires',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: _ShareExpiryPreset.never,
                  child: Text('Never'),
                ),
                DropdownMenuItem(
                  value: _ShareExpiryPreset.oneDay,
                  child: Text('In 1 day'),
                ),
                DropdownMenuItem(
                  value: _ShareExpiryPreset.oneWeek,
                  child: Text('In 1 week'),
                ),
                DropdownMenuItem(
                  value: _ShareExpiryPreset.oneMonth,
                  child: Text('In 1 month'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => preset = value);
                }
              },
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
          onPressed: () => Navigator.pop(
            context,
            _ShareLinkOptions(
              allowDownload: allowDownload,
              expiresAt: _expiresAt,
            ),
          ),
          child: const Text('Create link'),
        ),
      ],
    );
  }
}

class MusicScreen extends StatefulWidget {
  final int profileId;
  final String? initialSection;
  final String? initialQuery;
  final MusicTrack? initialTrack;

  /// Songs to play in this order (a mixed playlist's run of songs).
  final List<MusicTrack>? initialQueue;

  /// Start the saved listening session right away, at the saved position
  /// (used by "Continue Listening" on the home screen).
  final bool resumeSession;
  const MusicScreen({
    super.key,
    required this.profileId,
    this.initialSection,
    this.initialQuery,
    this.initialTrack,
    this.initialQueue,
    this.resumeSession = false,
  });

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool get _hasInitialPlayback =>
      widget.initialTrack != null || (widget.initialQueue?.isNotEmpty ?? false);
  final music = MusicService();
  final liveTvControl = LiveTvControlService();
  final widgetService = const MusicWidgetService();
  final playbackDestinationsService = PlaybackDestinationsService();
  final groupListeningService = GroupListeningService();
  final query = TextEditingController();
  final stationName = TextEditingController();
  final playlistName = TextEditingController();
  final setupServer = TextEditingController();
  final setupUser = TextEditingController();
  final setupPass = TextEditingController();
  final immersiveSearch = TextEditingController();
  final subs = <StreamSubscription<dynamic>>[];
  final sessionSubs = <StreamSubscription<dynamic>>[];
  final pageStorage = PageStorageBucket();

  static Player? _sharedPlayer;
  Player? get player => _sharedPlayer;
  set player(Player? value) => _sharedPlayer = value;
  AnimationController? vinylController;
  MusicServerConfig? config;
  NavidromeClient? client;
  List<MusicTrack> picks = [];
  List<MusicTrack> librarySongs = [];
  List<MusicTrack> recent = [];
  List<MusicTrack> searchResults = [];
  List<MusicStation> stations = [];
  List<MusicTrack> favorites = [];
  List<MusicPlaylist> playlists = [];
  List<MusicTrack> mostPlayed = [];
  Map<String, MusicDownloadEntry> downloadIndex = {};
  Map<String, int> playCounts = {};
  List<_QueueEntry> activeQueue = [];
  List<_QueueEntry> playedQueueHistory = [];
  List<_QueueEntry> removedQueueUndo = [];
  int activeQueueIndex = 0;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double volume = 100;
  bool loading = true;
  bool loadingLibrary = false;
  bool playing = false;
  bool syncingDownloads = false;
  bool trackLoading = false;
  bool playbackBuffering = false;
  bool shuffleEnabled = false;
  String error = '';
  String playbackError = '';
  String status = '';
  _MusicSection section = _MusicSection.home;
  _NowPlayingPane nowPlayingPane = _NowPlayingPane.vinyl;
  _NowPlayingMode nowPlayingMode = _NowPlayingMode.standard;
  _NowPlayingTheme nowPlayingTheme = _NowPlayingTheme.auto;
  _AnimationIntensity animationIntensity = _AnimationIntensity.normal;
  _SongsFilter songsFilter = _SongsFilter.all;
  _SongsSort songsSort = _SongsSort.title;
  _RepeatMode repeatMode = _RepeatMode.off;
  List<int> stableShuffleOrder = [];
  String queueContextLabel = '';
  List<Map<String, dynamic>> savedQueueSessions = [];
  List<Map<String, dynamic>> sharedQueues = [];
  List<PlaybackDestination> playbackDestinations = [];
  List<SpeakerDevice> discoveredSpeakers = [];
  List<GroupListeningSession> groupSessions = [];
  String activeSharedQueueId = '';
  bool remoteControlMode = false;
  bool reducedMotionOverride = false;
  bool visualizerEnabled = true;
  Timer? miniSyncTimer;
  String plainLyrics = '';
  List<Map<String, dynamic>> timedLyrics = [];
  List<String> credits = [];
  bool loadingLyrics = false;
  bool playerSheetOpen = false;
  bool immersiveSearchLoading = false;
  List<MusicTrack> immersiveSearchResults = [];
  final selectedTrackIds = <String>{};
  bool multiSelectMode = false;
  final homeSectionOrder = <String>[
    'recents',
    'favorites',
    'mostPlayed',
    'pinned',
  ];
  final pinnedAlbums = <String>{};
  final pinnedArtists = <String>{};
  final pinnedPlaylists = <String>{};
  Map<String, dynamic> publicProfileState = const {};
  String historyVisibility = 'private';
  List<String> followedUsers = const [];
  List<String> blockedSocialUsers = const [];
  List<Map<String, dynamic>> socialFeed = const [];
  List<Map<String, dynamic>> queueInvitationItems = const [];
  Map<String, dynamic> invitationControlState = const {
    'allowInvites': true,
    'invitePolicy': 'everyone',
  };

  /// Track currently opened in [player]; null when the queue was only
  /// restored from a saved session and nothing has been loaded yet.
  String? loadedTrackId;

  /// Where a restored session left off; used the first time Play is pressed.
  Duration resumePosition = Duration.zero;
  int _sessionSaveTick = 0;
  bool _pausedByInterruption = false;
  Duration _lastObservedPosition = Duration.zero;
  DateTime? _positionLastChangedAtUtc;
  DateTime? _lastAudioHealthLogAtUtc;

  MusicTrack? get activeTrack {
    if (activeQueue.isEmpty ||
        activeQueueIndex < 0 ||
        activeQueueIndex >= activeQueue.length) {
      return null;
    }
    return activeQueue[activeQueueIndex].track;
  }

  String get _currentUserId => 'profile-${widget.profileId}';

  void _logPlaybackAnalytics(
    String name, {
    Map<String, Object?> details = const {},
  }) {
    final track = activeTrack;
    AppLog.event(
      name,
      props: {
        'profileId': widget.profileId,
        if (track != null) 'trackId': track.id,
        if (track != null) 'title': track.title,
        'playing': playing,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'queueLength': activeQueue.length,
        'queueIndex': activeQueueIndex,
        ...details,
      },
    );
  }

  void _logPlaybackHealthIfNeeded() {
    if (!playing || playbackBuffering || trackLoading) {
      _lastObservedPosition = position;
      _positionLastChangedAtUtc = DateTime.now().toUtc();
      return;
    }
    if (position > _lastObservedPosition) {
      _lastObservedPosition = position;
      _positionLastChangedAtUtc = DateTime.now().toUtc();
      return;
    }
    final unchangedSince = _positionLastChangedAtUtc;
    if (unchangedSince == null) {
      _positionLastChangedAtUtc = DateTime.now().toUtc();
      return;
    }
    final now = DateTime.now().toUtc();
    final stalledFor = now.difference(unchangedSince);
    if (stalledFor < const Duration(seconds: 4)) {
      return;
    }
    final last = _lastAudioHealthLogAtUtc;
    if (last != null && now.difference(last) < const Duration(seconds: 20)) {
      return;
    }
    _lastAudioHealthLogAtUtc = now;
    AppLog.warn(
      LogCategory.playback,
      'Music playback position appears stalled while playing.',
      details: {
        'profileId': widget.profileId,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'stallMs': stalledFor.inMilliseconds,
        'trackLoading': trackLoading,
        'buffering': playbackBuffering,
      },
    );
    _logPlaybackAnalytics(
      'music.playback.stall',
      details: {'stallMs': stalledFor.inMilliseconds},
    );
  }

  @override
  void initState() {
    super.initState();
    MusicMiniPlayerService.instance.hideMini();
    AudioBackgroundService.instance.onPlayRequested = _togglePlayPause;
    AudioBackgroundService.instance.onPauseRequested = _pausePlayback;
    AudioBackgroundService.instance.onStopRequested = _clearQueueAndStop;
    AudioBackgroundService.instance.onSkipNextRequested = _playNextTrackInQueue;
    AudioBackgroundService.instance.onSkipPreviousRequested =
        _playPreviousTrackInQueue;
    AudioBackgroundService.instance.onPlayMediaIdRequested =
        _playFromAndroidAutoMediaId;
    AudioBackgroundService.instance.onSeekRequested = (target) async {
      final activePlayer = player;
      if (activePlayer == null) {
        return;
      }
      await activePlayer.seek(target);
    };
    WidgetsBinding.instance.addObserver(this);
    query.addListener(_onSearchChanged);
    vinylController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    );
    unawaited(_configureAudioSession());
    unawaited(_load());
    miniSyncTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _syncMiniPlayerFromState();
      _logPlaybackHealthIfNeeded();
      // Keep the saved position fresh so "Continue Listening" resumes close
      // to where playback actually stopped.
      if (playing && ++_sessionSaveTick % 10 == 0) {
        unawaited(_savePlaybackSession());
      }
    });
  }

  @override
  void dispose() {
    AudioBackgroundService.instance.onPlayRequested = null;
    AudioBackgroundService.instance.onPauseRequested = null;
    AudioBackgroundService.instance.onStopRequested = null;
    AudioBackgroundService.instance.onSkipNextRequested = null;
    AudioBackgroundService.instance.onSkipPreviousRequested = null;
    AudioBackgroundService.instance.onPlayMediaIdRequested = null;
    AudioBackgroundService.instance.onSeekRequested = null;
    WidgetsBinding.instance.removeObserver(this);
    query.removeListener(_onSearchChanged);
    query.dispose();
    stationName.dispose();
    playlistName.dispose();
    setupServer.dispose();
    setupUser.dispose();
    setupPass.dispose();
    immersiveSearch.dispose();
    for (final sub in subs) {
      unawaited(sub.cancel());
    }
    for (final sub in sessionSubs) {
      unawaited(sub.cancel());
    }
    miniSyncTimer?.cancel();
    DeviceConnection.instance.setMediaActive('music', false);
    unawaited(_savePlaybackSession());
    unawaited(_persistUiState());
    _syncMiniPlayerFromState(showMini: activeQueue.isNotEmpty);
    vinylController?.dispose();
    super.dispose();
  }

  void _syncMiniPlayerFromState({bool showMini = false}) {
    final queueTracks = activeQueue.map((item) => item.track).toList();
    final queueItems = queueTracks.map(_mediaItemForTrack).toList();
    final libraryItems = librarySongs
        .take(250)
        .map(_mediaItemForTrack)
        .toList();
    AudioBackgroundService.instance.updateBrowseCatalog(
      queueItems: queueItems,
      libraryItems: libraryItems,
      queueIndex: activeQueueIndex,
    );

    final activePlayer = player;
    if (activePlayer == null) {
      return;
    }
    MusicMiniPlayerService.instance.syncFromMusicScreen(
      player: activePlayer,
      queue: queueTracks,
      queueIndex: activeQueueIndex,
      librarySongs: librarySongs,
      playing: playing,
      position: position,
      duration: duration,
      config: config,
      loadedTrackId: loadedTrackId,
    );
    if (showMini) {
      MusicMiniPlayerService.instance.showMini();
    } else {
      MusicMiniPlayerService.instance.hideMini();
    }
  }

  MediaItem _mediaItemForTrack(MusicTrack track) {
    return MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.durationSeconds > 0
          ? Duration(seconds: track.durationSeconds)
          : null,
      artUri: _coverArtUrl(track) == null
          ? null
          : Uri.tryParse(_coverArtUrl(track)!),
      playable: true,
    );
  }

  Future<void> _playFromAndroidAutoMediaId(String mediaId) async {
    _logPlaybackAnalytics(
      'music.android_auto.play_media_id',
      details: {'mediaId': mediaId},
    );
    final queueTracks = activeQueue.map((item) => item.track).toList();
    final queueIndex = queueTracks.indexWhere((track) => track.id == mediaId);
    if (queueIndex >= 0) {
      await _playFromList(queueTracks, queueIndex);
      return;
    }
    final libraryIndex = librarySongs.indexWhere(
      (track) => track.id == mediaId,
    );
    if (libraryIndex >= 0) {
      await _playFromList(librarySongs, libraryIndex);
      return;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshFavoritesFromServerIfConnected(silent: true));
    }
  }

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      sessionSubs.add(
        session.interruptionEventStream.listen((event) {
          _logPlaybackAnalytics(
            'music.audio_session.interruption',
            details: {'begin': event.begin, 'type': event.type.name},
          );
          if (event.begin && event.type == AudioInterruptionType.pause) {
            _pausedByInterruption = true;
            AppLog.warn(
              LogCategory.playback,
              'Music playback paused due to audio interruption.',
              details: {'profileId': widget.profileId, 'type': event.type.name},
            );
            unawaited(_pausePlayback(reason: 'audio_interruption'));
          } else if (!event.begin &&
              _pausedByInterruption &&
              activeTrack != null) {
            _pausedByInterruption = false;
            unawaited(_resumeAfterInterruption());
          }
        }),
      );
      sessionSubs.add(
        session.becomingNoisyEventStream.listen((_) {
          AppLog.warn(
            LogCategory.playback,
            'Music playback paused due to becoming-noisy event.',
            details: {'profileId': widget.profileId},
          );
          _logPlaybackAnalytics('music.audio_session.becoming_noisy');
          unawaited(_pausePlayback(reason: 'becoming_noisy'));
        }),
      );
    } catch (_) {}
  }

  Future<Player> _ensurePlayer() async {
    final existing = player;
    if (existing != null) {
      return existing;
    }
    try {
      MediaKit.ensureInitialized();
      // Reuse the player that kept running in the mini player so reopening
      // Music does not start a second, overlapping stream.
      final shared = MusicMiniPlayerService.instance.player;
      final created = shared ?? Player();
      if (shared != null) {
        loadedTrackId = MusicMiniPlayerService.instance.loadedTrackId;
        playing = shared.state.playing;
        position = shared.state.position;
        duration = shared.state.duration;
      }
      subs.add(
        created.stream.position.listen((value) {
          if (mounted) {
            setState(() => position = value);
            AudioBackgroundService.instance.updatePlayback(
              playing: playing,
              position: position,
              duration: duration,
              buffering: trackLoading || playbackBuffering,
            );
          }
        }),
      );
      subs.add(
        created.stream.duration.listen((value) {
          if (mounted) {
            setState(() => duration = value);
            AudioBackgroundService.instance.updatePlayback(
              playing: playing,
              position: position,
              duration: duration,
              buffering: trackLoading || playbackBuffering,
            );
          }
        }),
      );
      subs.add(
        created.stream.playing.listen((value) {
          if (mounted) {
            setState(() => playing = value);
            DeviceConnection.instance.setMediaActive('music', value);
            if (value) {
              vinylController?.repeat();
            } else {
              vinylController?.stop();
            }
            _logPlaybackAnalytics(
              'music.playback.playing_changed',
              details: {'playing': value},
            );
            AudioBackgroundService.instance.updatePlayback(
              playing: playing,
              position: position,
              duration: duration,
              buffering: trackLoading || playbackBuffering,
            );
          }
        }),
      );
      subs.add(
        created.stream.buffering.listen((value) {
          if (!mounted) {
            return;
          }
          setState(() => playbackBuffering = value);
          _logPlaybackAnalytics(
            value
                ? 'music.playback.buffering_start'
                : 'music.playback.buffering_end',
          );
          if (value) {
            AppLog.warn(
              LogCategory.playback,
              'Music playback entered buffering state.',
              details: {
                'profileId': widget.profileId,
                'positionMs': position.inMilliseconds,
                'durationMs': duration.inMilliseconds,
              },
            );
          }
          AudioBackgroundService.instance.updatePlayback(
            playing: playing,
            position: position,
            duration: duration,
            buffering: trackLoading || playbackBuffering,
          );
        }),
      );
      subs.add(
        created.stream.error.listen((message) {
          if (!mounted) {
            return;
          }
          setState(() {
            playbackError = 'Music playback failed: $message';
            playing = false;
            playbackBuffering = false;
            trackLoading = false;
          });
          DeviceConnection.instance.setMediaActive('music', false);
          AppLog.error(
            LogCategory.playback,
            'Music playback stream error',
            error: message,
            details: {
              'profileId': widget.profileId,
              'positionMs': position.inMilliseconds,
              'durationMs': duration.inMilliseconds,
            },
          );
          _logPlaybackAnalytics(
            'music.playback.error',
            details: {'error': message.toString()},
          );
          AudioBackgroundService.instance.updatePlayback(
            playing: false,
            position: position,
            duration: duration,
            buffering: false,
          );
        }),
      );
      subs.add(
        created.stream.volume.listen((value) {
          if (mounted) {
            setState(() => volume = value.clamp(0, 100).toDouble());
          }
        }),
      );
      subs.add(
        created.stream.completed.listen((done) {
          if (done) {
            _logPlaybackAnalytics('music.playback.completed');
            unawaited(_handleTrackCompleted());
          }
        }),
      );
      player = created;
      return created;
    } catch (_) {
      throw StateError(
        'Music playback could not start on this device. Please restart the app and try again.',
      );
    }
  }

  List<MusicTrack> get _libraryTracks {
    final deduped = <String, MusicTrack>{};
    void addItems(List<MusicTrack> values) {
      for (final value in values) {
        deduped[value.id] = value;
      }
    }

    addItems(picks);
    addItems(librarySongs);
    addItems(recent);
    addItems(searchResults);
    addItems(favorites);
    addItems(mostPlayed);
    addItems(activeQueue.map((item) => item.track).toList());
    for (final station in stations) {
      addItems(station.queue);
    }
    for (final playlist in playlists) {
      addItems(playlist.tracks);
    }
    return deduped.values.toList();
  }

  Map<String, List<MusicTrack>> get _albums {
    final values = <String, List<MusicTrack>>{};
    for (final track in _libraryTracks) {
      values.putIfAbsent(track.album, () => []).add(track);
    }
    return values;
  }

  Map<String, List<MusicTrack>> get _artists {
    final values = <String, List<MusicTrack>>{};
    for (final track in _libraryTracks) {
      values.putIfAbsent(track.artist, () => []).add(track);
    }
    return values;
  }

  bool _isFavorite(String id) => favorites.any((item) => item.id == id);
  bool _hasDownload(String id) => downloadIndex.containsKey(id);

  List<_QueueEntry> _entriesFromTracks(
    List<MusicTrack> tracks, {
    _QueueEntryType type = _QueueEntryType.context,
    String? sourceLabel,
  }) {
    return tracks
        .map(
          (track) => _QueueEntry(
            entryId: const Uuid().v4(),
            track: track,
            type: type,
            sourceLabel: sourceLabel,
          ),
        )
        .toList();
  }

  void _normalizeQueueState() {
    if (activeQueue.isEmpty) {
      activeQueueIndex = 0;
      stableShuffleOrder = [];
      return;
    }
    if (activeQueueIndex < 0) {
      activeQueueIndex = 0;
    }
    if (activeQueueIndex >= activeQueue.length) {
      activeQueueIndex = activeQueue.length - 1;
    }
    stableShuffleOrder = stableShuffleOrder
        .where((item) => item >= 0 && item < activeQueue.length)
        .toList();
    if (shuffleEnabled && stableShuffleOrder.length != activeQueue.length) {
      stableShuffleOrder = List<int>.generate(activeQueue.length, (i) => i)
        ..shuffle(math.Random(activeQueue.length + 31));
    }
  }

  Map<String, dynamic> _queueSnapshot({String? name}) {
    return {
      'id': const Uuid().v4(),
      if (name != null) 'name': name,
      'queueEntries': activeQueue.map((item) => item.toJson()).toList(),
      'index': activeQueueIndex,
      'positionMs': position.inMilliseconds,
      'shuffleEnabled': shuffleEnabled,
      'shuffleOrder': stableShuffleOrder,
      'repeatMode': repeatMode.name,
      'playedHistoryEntries': playedQueueHistory
          .map((item) => item.toJson())
          .toList(),
      'queueContextLabel': queueContextLabel,
      'savedAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<void> _applyQueueSnapshot(Map<String, dynamic> snapshot) async {
    final entriesRaw = snapshot['queueEntries'];
    if (entriesRaw is! List || entriesRaw.isEmpty) {
      throw const FormatException('Queue snapshot is missing queue entries.');
    }
    final nextQueue = <_QueueEntry>[];
    for (final entry in entriesRaw) {
      if (entry is! Map) {
        continue;
      }
      final parsed = _QueueEntry.fromJson(Map<String, dynamic>.from(entry));
      if (parsed != null) {
        nextQueue.add(parsed);
      }
    }
    if (nextQueue.isEmpty) {
      throw const FormatException('Queue snapshot has no valid tracks.');
    }
    final rawIndex = int.tryParse(snapshot['index']?.toString() ?? '') ?? 0;
    final nextIndex = rawIndex.clamp(0, nextQueue.length - 1);
    final shuffleRaw = snapshot['shuffleOrder'];
    final nextShuffle = <int>[];
    if (shuffleRaw is List) {
      for (final item in shuffleRaw) {
        final parsed = int.tryParse(item.toString());
        if (parsed != null && parsed >= 0 && parsed < nextQueue.length) {
          nextShuffle.add(parsed);
        }
      }
    }
    final historyRaw = snapshot['playedHistoryEntries'];
    final nextHistory = <_QueueEntry>[];
    if (historyRaw is List) {
      for (final item in historyRaw) {
        if (item is! Map) {
          continue;
        }
        final parsed = _QueueEntry.fromJson(Map<String, dynamic>.from(item));
        if (parsed != null) {
          nextHistory.add(parsed);
        }
      }
    }
    final repeatLabel =
        snapshot['repeatMode']?.toString() ?? _RepeatMode.off.name;
    final nextRepeat = _RepeatMode.values.firstWhere(
      (item) => item.name == repeatLabel,
      orElse: () => _RepeatMode.off,
    );
    final resumeMs =
        int.tryParse(snapshot['positionMs']?.toString() ?? '') ?? 0;
    setState(() {
      activeQueue = nextQueue;
      activeQueueIndex = nextIndex;
      shuffleEnabled = snapshot['shuffleEnabled'] == true;
      stableShuffleOrder = nextShuffle;
      repeatMode = nextRepeat;
      playedQueueHistory = nextHistory;
      queueContextLabel = snapshot['queueContextLabel']?.toString() ?? '';
      status = 'Queue session loaded.';
    });
    _normalizeQueueState();
    await _playTrack(
      activeQueue[activeQueueIndex].track,
      queue: activeQueue,
      queueIndex: activeQueueIndex,
    );
    final activePlayer = player;
    if (activePlayer != null && resumeMs > 0) {
      final seekMs = resumeMs.clamp(0, duration.inMilliseconds);
      await activePlayer.seek(Duration(milliseconds: seekMs));
    }
    unawaited(_savePlaybackSession());
  }

  bool _canManageSharedQueue() {
    if (activeSharedQueueId.trim().isEmpty) {
      return true;
    }
    final shared = sharedQueues.firstWhere(
      (item) => item['id']?.toString() == activeSharedQueueId,
      orElse: () => const <String, dynamic>{},
    );
    if (shared.isEmpty) {
      return true;
    }
    final hostProfileId = int.tryParse(
      shared['hostProfileId']?.toString() ?? '',
    );
    final moderatorsRaw = shared['moderatorProfileIds'];
    final moderators = <int>{};
    if (moderatorsRaw is List) {
      for (final item in moderatorsRaw) {
        final parsed = int.tryParse(item.toString());
        if (parsed != null) {
          moderators.add(parsed);
        }
      }
    }
    return hostProfileId == widget.profileId ||
        moderators.contains(widget.profileId);
  }

  Future<void> _refreshQueueCollaboration() async {
    savedQueueSessions = await music.savedQueues(widget.profileId);
    sharedQueues = await music.sharedQueues(widget.profileId);
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _refreshDownloads() async {
    final saved = await music.downloads(widget.profileId);
    if (!mounted) {
      return;
    }
    setState(() {
      downloadIndex = {for (final item in saved) item.trackId: item};
    });
  }

  Future<void> _downloadTrack(MusicTrack track) async {
    if (syncingDownloads) {
      return;
    }
    setState(() {
      syncingDownloads = true;
      status = 'Downloading ${track.title}...';
    });
    try {
      await music.downloadTrack(widget.profileId, track);
      await _refreshDownloads();
      setState(() => status = 'Downloaded ${track.title}');
    } catch (_) {
      setState(() {
        playbackError = 'Download failed for ${track.title}.';
      });
    } finally {
      if (mounted) {
        setState(() => syncingDownloads = false);
      }
    }
  }

  Future<void> _onSearchChanged() async {
    unawaited(_persistUiState());
    if (query.text.trim().length < 2 || client == null) {
      if (searchResults.isNotEmpty && mounted) {
        setState(() => searchResults = []);
      }
      return;
    }
    await _search(query.text.trim());
  }

  Future<void> _syncProfileState() async {
    final key = DeviceConnection.instance.connectionKey;
    if (key.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      await liveTvControl.pushConfig(
        expectedConnection: key,
        profileId: widget.profileId,
        sources: await HomePreferences().liveTvSources(widget.profileId),
        tmdbApiKey: await HomePreferences().tmdbApiKey(widget.profileId),
        profileState: await HomePreferences().liveTvProfileSyncState(
          widget.profileId,
        ),
      );
    } catch (_) {}
  }

  Future<void> _persistUiState() async {
    try {
      await music.saveUiState(widget.profileId, {
        'section': section.name,
        'query': query.text.trim(),
        'remoteControlMode': remoteControlMode,
      });
      await music.saveHomeSections(widget.profileId, homeSectionOrder);
      await music.savePins(widget.profileId, {
        'albums': pinnedAlbums.toList(),
        'artists': pinnedArtists.toList(),
        'playlists': pinnedPlaylists.toList(),
      });
      await _syncProfileState();
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      config = await music.config(widget.profileId);
      stations = await music.stations(widget.profileId);
      recent = await music.recentlyPlayed(widget.profileId);
      favorites = await music.favorites(widget.profileId);
      playlists = await music.playlists(widget.profileId);
      playCounts = await music.playCounts(widget.profileId);
      mostPlayed = await music.mostPlayed(widget.profileId, limit: 12);
      savedQueueSessions = await music.savedQueues(widget.profileId);
      sharedQueues = await music.sharedQueues(widget.profileId);
      playbackDestinations = await playbackDestinationsService.list(
        widget.profileId,
      );
      groupSessions = await groupListeningService.sessions(widget.profileId);
      final savedUi = await music.uiState(widget.profileId);
      final savedSections = await music.homeSections(widget.profileId);
      final savedPins = await music.pins(widget.profileId);
      librarySongs = await music.loadLibraryCache(widget.profileId);
      final savedDownloads = await music.downloads(widget.profileId);
      downloadIndex = {for (final item in savedDownloads) item.trackId: item};
      await _loadSocialState();
      homeSectionOrder
        ..clear()
        ..addAll(savedSections);
      pinnedAlbums
        ..clear()
        ..addAll(savedPins['albums'] ?? const <String>[]);
      pinnedArtists
        ..clear()
        ..addAll(savedPins['artists'] ?? const <String>[]);
      pinnedPlaylists
        ..clear()
        ..addAll(savedPins['playlists'] ?? const <String>[]);
      final savedSection = savedUi['section']?.toString();
      if (savedSection != null) {
        final restored = _MusicSection.values.firstWhere(
          (item) => item.name == savedSection,
          orElse: () => _MusicSection.home,
        );
        section = restored;
      }
      query.text = savedUi['query']?.toString() ?? query.text;
      remoteControlMode = savedUi['remoteControlMode'] == true;
      final deepSection = widget.initialSection?.trim();
      if (deepSection != null && deepSection.isNotEmpty) {
        section = _MusicSection.values.firstWhere(
          (item) => item.name.toLowerCase() == deepSection.toLowerCase(),
          orElse: () => section,
        );
      }
      final deepQuery = widget.initialQuery?.trim();
      if (deepQuery != null && deepQuery.isNotEmpty) {
        query.text = deepQuery;
      }
      if (config != null) {
        client = NavidromeClient(config!);
        await client!.ping();
        try {
          await _syncFavoritesFromServer(client!);
          favorites = await music.favorites(widget.profileId);
        } catch (_) {
          status =
              'Could not refresh remote favorites. Showing local favorites.';
        }
        if (!_hasInitialPlayback) {
          picks = await client!.randomSongs(limit: 24);
        }
        loadingLibrary = true;
        unawaited(_hydrateLibrary(client!));
        if (!_hasInitialPlayback) {
          unawaited(_restorePlaybackSession());
        }
      }
      if (!mounted) {
        return;
      }

      setState(() {
        loading = false;
        error = '';
      });
      _syncMiniPlayerFromState();
      final initialTrack = widget.initialTrack;
      if (initialTrack != null) {
        final refreshed = MusicTrack(
          id: initialTrack.id,
          title: initialTrack.title,
          artist: initialTrack.artist,
          album: initialTrack.album,
          genre: initialTrack.genre,
          year: initialTrack.year,
          durationSeconds: initialTrack.durationSeconds,
          coverArtId: initialTrack.coverArtId,
          streamUrl:
              client?.streamUri(initialTrack.id).toString() ??
              initialTrack.streamUrl,
        );
        await _playTrack(refreshed);
      }
      final queue = widget.initialQueue;
      if (initialTrack == null && queue != null && queue.isNotEmpty) {
        final tracks = [
          for (final track in queue)
            MusicTrack(
              id: track.id,
              title: track.title,
              artist: track.artist,
              album: track.album,
              genre: track.genre,
              year: track.year,
              durationSeconds: track.durationSeconds,
              coverArtId: track.coverArtId,
              streamUrl:
                  client?.streamUri(track.id).toString() ?? track.streamUrl,
            ),
        ];
        await _playFromList(tracks, 0);
        queueContextLabel = 'Playlist';
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        loading = false;
        error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _loadSocialState() async {
    publicProfileState = await music.publicProfile(widget.profileId);
    historyVisibility = await music.personalHistoryVisibility(widget.profileId);
    followedUsers = await music.followedUsers(widget.profileId);
    blockedSocialUsers = await music.blockedUsers(widget.profileId);
    socialFeed = await music.activityFeed(
      widget.profileId,
      includePrivate: true,
    );
    queueInvitationItems = await music.queueInvitations(widget.profileId);
    invitationControlState = await music.invitationControls(widget.profileId);
  }

  Future<void> _syncFavoritesFromServer(NavidromeClient nav) async {
    final remoteFavorites = await nav.starredSongs();
    await music.saveFavorites(widget.profileId, remoteFavorites);
  }

  Future<void> _refreshFavoritesFromServerIfConnected({
    required bool silent,
  }) async {
    final nav = client;
    if (nav == null) {
      return;
    }
    try {
      await _syncFavoritesFromServer(nav);
      favorites = await music.favorites(widget.profileId);
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (!silent && mounted) {
        setState(() {
          status = 'Could not refresh favorites from Navidrome.';
        });
      }
    }
  }

  Future<void> _hydrateLibrary(NavidromeClient nav) async {
    try {
      final allSongs = await nav.allSongs();
      if (!mounted) {
        return;
      }
      setState(() {
        librarySongs = allSongs;
        loadingLibrary = false;
      });
      await music.saveLibraryCache(widget.profileId, allSongs);
      unawaited(_refreshDownloads());
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => loadingLibrary = false);
    }
  }

  Future<void> _savePlaybackSession() async {
    if (activeQueue.isEmpty || activeQueueIndex < 0) {
      return;
    }
    try {
      await music.savePlaybackSession(
        widget.profileId,
        queue: activeQueue.map((item) => item.track).toList(),
        index: activeQueueIndex.clamp(0, activeQueue.length - 1),
        positionMs: position.inMilliseconds,
        shuffleEnabled: shuffleEnabled,
        shuffleOrder: stableShuffleOrder,
        repeatMode: repeatMode.name,
        queueEntries: activeQueue.map((item) => item.toJson()).toList(),
        playedHistoryEntries: playedQueueHistory
            .map((item) => item.toJson())
            .toList(),
        queueContextLabel: queueContextLabel,
      );
    } catch (_) {}
  }

  Future<void> _restorePlaybackSession() async {
    final saved = await music.loadPlaybackSession(widget.profileId);
    if (saved == null) {
      return;
    }
    final entriesRaw = saved['queueEntries'];
    final restoredEntries = <_QueueEntry>[];
    if (entriesRaw is List) {
      for (final entry in entriesRaw) {
        if (entry is! Map) {
          continue;
        }
        final parsed = _QueueEntry.fromJson(Map<String, dynamic>.from(entry));
        if (parsed != null) {
          restoredEntries.add(parsed);
        }
      }
    }
    if (restoredEntries.isEmpty) {
      final queueRaw = saved['queue'];
      if (queueRaw is List) {
        for (final entry in queueRaw) {
          if (entry is! Map) {
            continue;
          }
          try {
            restoredEntries.add(
              _QueueEntry(
                entryId: const Uuid().v4(),
                track: MusicTrack.fromJson(Map<String, dynamic>.from(entry)),
                type: _QueueEntryType.context,
              ),
            );
          } catch (_) {}
        }
      }
    }
    if (restoredEntries.isEmpty || !mounted) {
      return;
    }
    final index = (saved['index'] as num?)?.toInt() ?? 0;
    final restoredIndex = index.clamp(0, restoredEntries.length - 1);
    final repeatLabel = saved['repeatMode']?.toString() ?? _RepeatMode.off.name;
    final repeat = _RepeatMode.values.firstWhere(
      (value) => value.name == repeatLabel,
      orElse: () => _RepeatMode.off,
    );
    final shuffleOrderRaw = saved['shuffleOrder'];
    final restoredShuffle = <int>[];
    if (shuffleOrderRaw is List) {
      for (final item in shuffleOrderRaw) {
        final value = int.tryParse(item.toString());
        if (value != null && value >= 0 && value < restoredEntries.length) {
          restoredShuffle.add(value);
        }
      }
    }
    final history = <_QueueEntry>[];
    final historyRaw = saved['playedHistoryEntries'];
    if (historyRaw is List) {
      for (final entry in historyRaw) {
        if (entry is! Map) {
          continue;
        }
        final parsed = _QueueEntry.fromJson(Map<String, dynamic>.from(entry));
        if (parsed != null) {
          history.add(parsed);
        }
      }
    }
    setState(() {
      activeQueue = restoredEntries;
      activeQueueIndex = restoredIndex;
      shuffleEnabled = saved['shuffleEnabled'] == true;
      stableShuffleOrder = restoredShuffle;
      repeatMode = repeat;
      queueContextLabel = saved['queueContextLabel']?.toString() ?? '';
      playedQueueHistory = history;
      final savedPosition = Duration(
        milliseconds: int.tryParse(saved['positionMs']?.toString() ?? '') ?? 0,
      );
      resumePosition = savedPosition;
      if (loadedTrackId == null) {
        position = savedPosition;
        duration = Duration(
          seconds: restoredEntries[restoredIndex].track.durationSeconds,
        );
      }
      status = 'Restored last listening session.';
    });
    final shared = MusicMiniPlayerService.instance;
    if (shared.player != null &&
        shared.loadedTrackId == restoredEntries[restoredIndex].track.id) {
      // Still playing in the background: attach instead of restarting.
      await _ensurePlayer();
      if (mounted) setState(() {});
      return;
    }
    if (widget.resumeSession && mounted) {
      await _resumeActiveTrack();
    }
  }

  Future<void> _saveSetup(
    String server,
    String username,
    String password,
  ) async {
    final next = MusicServerConfig(
      baseUrl: validateMusicServerUrl(server),
      username: username.trim(),
      password: password,
    );
    if (next.username.isEmpty || next.password.trim().isEmpty) {
      throw const FormatException('Username and password are required.');
    }
    final nav = NavidromeClient(next);
    await nav.ping();
    await music.saveConfig(widget.profileId, next);
    await _syncProfileState();
    if (!mounted) {
      return;
    }
    setState(() {
      config = next;
      client = nav;
      error = '';
      status = 'Connected to Navidrome.';
      loading = true;
    });
    await _load();
  }

  Future<void> _search(String text) async {
    final nav = client;
    if (nav == null) {
      return;
    }
    try {
      final results = await nav.searchSongs(text, limit: 40);
      if (!mounted || query.text.trim() != text) {
        return;
      }
      setState(() => searchResults = results);
    } catch (_) {}
  }

  Future<void> _playTrack(
    MusicTrack track, {
    List<_QueueEntry>? queue,
    int? queueIndex,
    _QueueEntryType queueEntryType = _QueueEntryType.context,
    String? queueSourceLabel,
    Duration? startAt,
  }) async {
    String? mediaSource;
    final download = downloadIndex[track.id];
    if (download != null && File(download.filePath).existsSync()) {
      mediaSource = Uri.file(download.filePath).toString();
    } else {
      mediaSource = track.streamUrl;
    }
    if (mediaSource == null || mediaSource.trim().isEmpty) {
      if (mounted) {
        setState(() {
          playbackError =
              'This song cannot be played because its stream URL is missing.';
        });
      }
      return;
    }
    final nextQueue =
        queue ??
        _entriesFromTracks(
          [track],
          type: queueEntryType,
          sourceLabel: queueSourceLabel,
        );
    final resolvedQueueIndex =
        queueIndex ?? nextQueue.indexWhere((item) => item.track.id == track.id);
    if (mounted) {
      setState(() {
        trackLoading = true;
        playbackBuffering = false;
        playbackError = '';
      });
    }
    final activePlayer = await _ensurePlayer();
    _logPlaybackAnalytics(
      'music.playback.start_requested',
      details: {'trackId': track.id},
    );
    try {
      final resumeAt = startAt != null && startAt > const Duration(seconds: 1)
          ? startAt
          : null;
      await activePlayer.open(Media(mediaSource, start: resumeAt));
      await activePlayer.play();
      loadedTrackId = track.id;
      resumePosition = Duration.zero;
    } catch (_) {
      if (mounted) {
        setState(() {
          trackLoading = false;
          playbackBuffering = false;
          playbackError =
              'Playback failed for this track. It may be unavailable or unsupported.';
        });
      }
      AppLog.warn(
        LogCategory.playback,
        'Music track failed to start.',
        details: {
          'profileId': widget.profileId,
          'trackId': track.id,
          'title': track.title,
        },
      );
      _logPlaybackAnalytics(
        'music.playback.start_failed',
        details: {'trackId': track.id},
      );
      return;
    }
    await music.upsertRecentlyPlayed(widget.profileId, track);
    await music.recordPlay(widget.profileId, track);
    recent = await music.recentlyPlayed(widget.profileId);
    playCounts = await music.playCounts(widget.profileId);
    mostPlayed = await music.mostPlayed(widget.profileId, limit: 12);
    await _syncProfileState();
    if (!mounted) {
      return;
    }
    setState(() {
      if (activeQueue.isNotEmpty &&
          activeQueueIndex >= 0 &&
          activeQueueIndex < activeQueue.length) {
        playedQueueHistory = [
          ...playedQueueHistory.take(99),
          activeQueue[activeQueueIndex],
        ];
      }
      activeQueue = nextQueue;
      activeQueueIndex = resolvedQueueIndex < 0 ? 0 : resolvedQueueIndex;
      if (shuffleEnabled && stableShuffleOrder.isEmpty) {
        stableShuffleOrder = List<int>.generate(nextQueue.length, (i) => i)
          ..shuffle(math.Random(nextQueue.length));
      } else if (!shuffleEnabled) {
        stableShuffleOrder = [];
      }
      trackLoading = false;
      playbackBuffering = false;
      playing = true;
      nowPlayingPane = _NowPlayingPane.vinyl;
      status = 'Now playing ${track.title}';
    });
    DeviceConnection.instance.setMediaActive('music', true);
    _logPlaybackAnalytics(
      'music.playback.started',
      details: {'trackId': track.id},
    );
    _syncMiniPlayerFromState();
    AudioBackgroundService.instance.updateNowPlaying(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: Duration(seconds: track.durationSeconds),
      artUri: _coverArtUrl(track) == null
          ? null
          : Uri.tryParse(_coverArtUrl(track)!),
    );
    AudioBackgroundService.instance.updatePlayback(
      playing: true,
      position: position,
      duration: duration,
      buffering: trackLoading || playbackBuffering,
    );
    unawaited(
      widgetService.update(
        title: track.title,
        artist: track.artist,
        playing: true,
      ),
    );
    vinylController?.repeat();
    unawaited(_presentPlayerSheetIfNeeded());
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
    unawaited(_feedRecommendationsIfNeeded());
    unawaited(_loadLyricsForTrack(track));
  }

  Future<void> _playFromList(List<MusicTrack> tracks, int index) async {
    if (tracks.isEmpty || index < 0 || index >= tracks.length) {
      return;
    }
    final queueEntries = _entriesFromTracks(
      tracks,
      type: _QueueEntryType.context,
    );
    queueContextLabel = 'Context queue';
    if (mounted) {
      setState(() => status = 'Queue replaced with ${tracks.length} tracks.');
    }
    if (shuffleEnabled) {
      final order = List<int>.generate(tracks.length, (i) => i)
        ..shuffle(math.Random(tracks.length));
      stableShuffleOrder = order;
      final firstIndex = order.first;
      await _playTrack(
        tracks[firstIndex],
        queue: queueEntries,
        queueIndex: firstIndex,
      );
      return;
    }
    await _playTrack(tracks[index], queue: queueEntries, queueIndex: index);
  }

  Future<void> _playShuffled(List<MusicTrack> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    final queueEntries = _entriesFromTracks(
      tracks,
      type: _QueueEntryType.context,
    );
    queueContextLabel = 'Context queue';
    final order = List<int>.generate(tracks.length, (i) => i)
      ..shuffle(math.Random(tracks.length));
    setState(() {
      shuffleEnabled = true;
      stableShuffleOrder = order;
      status = 'Queue replaced and shuffled (${order.length} tracks).';
    });
    final firstIndex = order.first;
    await _playTrack(
      tracks[firstIndex],
      queue: queueEntries,
      queueIndex: firstIndex,
    );
  }

  void _cycleRepeatMode() {
    setState(() {
      repeatMode = switch (repeatMode) {
        _RepeatMode.off => _RepeatMode.all,
        _RepeatMode.all => _RepeatMode.one,
        _RepeatMode.one => _RepeatMode.off,
      };
    });
  }

  void _toggleShuffleMode() {
    setState(() {
      shuffleEnabled = !shuffleEnabled;
      if (shuffleEnabled) {
        if (activeQueue.isEmpty) {
          stableShuffleOrder = [];
        } else {
          final current = activeQueueIndex.clamp(0, activeQueue.length - 1);
          final rest = List<int>.generate(activeQueue.length, (i) => i)
            ..remove(current)
            ..shuffle(math.Random(activeQueue.length + 1));
          stableShuffleOrder = [current, ...rest];
        }
      } else {
        stableShuffleOrder = [];
      }
    });
  }

  Future<void> _playNextTrackInQueue() async {
    if (activeQueue.isEmpty) {
      return;
    }
    final nextIndex = activeQueueIndex + 1;
    if (nextIndex >= activeQueue.length) {
      return;
    }
    await _playTrack(
      activeQueue[nextIndex].track,
      queue: activeQueue,
      queueIndex: nextIndex,
    );
    unawaited(_announceAction('Skipped to next track.'));
  }

  Future<void> _playPreviousTrackInQueue() async {
    if (activeQueue.isEmpty) {
      return;
    }
    final prevIndex = activeQueueIndex - 1;
    if (prevIndex < 0) {
      if (repeatMode == _RepeatMode.all && activeQueue.isNotEmpty) {
        await _playTrack(
          activeQueue.last.track,
          queue: activeQueue,
          queueIndex: activeQueue.length - 1,
        );
      }
      return;
    }
    await _playTrack(
      activeQueue[prevIndex].track,
      queue: activeQueue,
      queueIndex: prevIndex,
    );
    unawaited(_announceAction('Moved to previous track.'));
  }

  Future<void> _handleTrackCompleted() async {
    if (activeQueue.isEmpty) {
      return;
    }
    if (repeatMode == _RepeatMode.one) {
      await _playTrack(
        activeQueue[activeQueueIndex].track,
        queue: activeQueue,
        queueIndex: activeQueueIndex,
      );
      return;
    }
    if (shuffleEnabled && stableShuffleOrder.isNotEmpty) {
      final orderPos = stableShuffleOrder.indexOf(activeQueueIndex);
      if (orderPos >= 0 && orderPos + 1 < stableShuffleOrder.length) {
        final nextIndex = stableShuffleOrder[orderPos + 1];
        await _playTrack(
          activeQueue[nextIndex].track,
          queue: activeQueue,
          queueIndex: nextIndex,
        );
        return;
      }
      if (repeatMode == _RepeatMode.all) {
        final first = stableShuffleOrder.first;
        await _playTrack(
          activeQueue[first].track,
          queue: activeQueue,
          queueIndex: first,
        );
      }
      return;
    }
    final nextIndex = activeQueueIndex + 1;
    if (nextIndex < activeQueue.length) {
      await _playTrack(
        activeQueue[nextIndex].track,
        queue: activeQueue,
        queueIndex: nextIndex,
      );
      return;
    }
    if (repeatMode == _RepeatMode.all) {
      await _playTrack(
        activeQueue.first.track,
        queue: activeQueue,
        queueIndex: 0,
      );
    }
  }

  Future<void> _playNext(MusicTrack track) async {
    if (!_canManageSharedQueue()) {
      setState(
        () => status = 'Only host/moderators can edit this shared queue.',
      );
      return;
    }
    final next = [...activeQueue];
    if (next.isEmpty) {
      next.addAll(
        _entriesFromTracks(
          [track],
          type: _QueueEntryType.manual,
          sourceLabel: 'Play next',
        ),
      );
      setState(() {
        activeQueue = next;
        activeQueueIndex = 0;
      });
      unawaited(_persistActiveSharedQueue());
      unawaited(_savePlaybackSession());
      return;
    }
    next.insert(
      (activeQueueIndex + 1).clamp(0, next.length),
      _QueueEntry(
        entryId: const Uuid().v4(),
        track: track,
        type: _QueueEntryType.manual,
        sourceLabel: 'Play next',
      ),
    );
    setState(() {
      activeQueue = next;
      if (shuffleEnabled) {
        stableShuffleOrder = List<int>.generate(next.length, (i) => i)
          ..shuffle(math.Random(next.length));
      }
    });
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
  }

  Future<void> _playLast(MusicTrack track) async {
    if (!_canManageSharedQueue()) {
      setState(
        () => status = 'Only host/moderators can edit this shared queue.',
      );
      return;
    }
    final next = [...activeQueue];
    next.add(
      _QueueEntry(
        entryId: const Uuid().v4(),
        track: track,
        type: _QueueEntryType.manual,
        sourceLabel: 'Play last',
      ),
    );
    setState(() {
      activeQueue = next;
      _normalizeQueueState();
    });
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
  }

  Future<void> _addTracksNext(
    List<MusicTrack> tracks, {
    String sourceLabel = 'Add next',
  }) async {
    if (tracks.isEmpty) {
      return;
    }
    if (!_canManageSharedQueue()) {
      setState(
        () => status = 'Only host/moderators can edit this shared queue.',
      );
      return;
    }
    final entries = _entriesFromTracks(
      tracks,
      type: _QueueEntryType.manual,
      sourceLabel: sourceLabel,
    );
    final next = [...activeQueue];
    if (next.isEmpty) {
      next.addAll(entries);
      setState(() {
        activeQueue = next;
        activeQueueIndex = 0;
        status = 'Added ${tracks.length} tracks to queue.';
      });
      unawaited(_savePlaybackSession());
      return;
    }
    next.insertAll((activeQueueIndex + 1).clamp(0, next.length), entries);
    setState(() {
      activeQueue = next;
      _normalizeQueueState();
      status = 'Added ${tracks.length} tracks next.';
    });
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
  }

  Future<void> _addTracksLast(
    List<MusicTrack> tracks, {
    String sourceLabel = 'Add last',
  }) async {
    if (tracks.isEmpty) {
      return;
    }
    if (!_canManageSharedQueue()) {
      setState(
        () => status = 'Only host/moderators can edit this shared queue.',
      );
      return;
    }
    final entries = _entriesFromTracks(
      tracks,
      type: _QueueEntryType.manual,
      sourceLabel: sourceLabel,
    );
    setState(() {
      activeQueue = [...activeQueue, ...entries];
      _normalizeQueueState();
      status = 'Added ${tracks.length} tracks at queue end.';
    });
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
  }

  Future<void> _reorderQueueEntry(int oldIndex, int newIndex) async {
    if (!_canManageSharedQueue()) {
      setState(
        () => status = 'Only host/moderators can reorder this shared queue.',
      );
      return;
    }
    if (oldIndex < 0 || oldIndex >= activeQueue.length) {
      return;
    }
    var target = newIndex;
    if (target > oldIndex) {
      target -= 1;
    }
    if (target < 0 || target >= activeQueue.length) {
      return;
    }
    final next = [...activeQueue];
    final moved = next.removeAt(oldIndex);
    next.insert(target, moved);
    setState(() {
      activeQueue = next;
      if (activeQueueIndex == oldIndex) {
        activeQueueIndex = target;
      } else if (oldIndex < activeQueueIndex && target >= activeQueueIndex) {
        activeQueueIndex -= 1;
      } else if (oldIndex > activeQueueIndex && target <= activeQueueIndex) {
        activeQueueIndex += 1;
      }
      _normalizeQueueState();
    });
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
  }

  Future<void> _removeQueueEntryAt(int index) async {
    if (!_canManageSharedQueue()) {
      setState(
        () => status =
            'Only host/moderators can remove items from this shared queue.',
      );
      return;
    }
    if (index < 0 || index >= activeQueue.length) {
      return;
    }
    final removed = activeQueue[index];
    final next = [...activeQueue]..removeAt(index);
    setState(() {
      removedQueueUndo = [removed, ...removedQueueUndo].take(12).toList();
      activeQueue = next;
      if (index < activeQueueIndex) {
        activeQueueIndex -= 1;
      } else if (index == activeQueueIndex && activeQueueIndex >= next.length) {
        activeQueueIndex = (next.length - 1).clamp(0, next.length);
      }
      _normalizeQueueState();
      status = 'Removed ${removed.track.title} from queue.';
    });
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
  }

  Future<void> _undoRemoveQueueEntry() async {
    if (removedQueueUndo.isEmpty) {
      return;
    }
    final restored = removedQueueUndo.first;
    final nextUndo = removedQueueUndo.skip(1).toList();
    final nextQueue = [...activeQueue, restored];
    setState(() {
      removedQueueUndo = nextUndo;
      activeQueue = nextQueue;
      _normalizeQueueState();
      status = 'Undo: restored ${restored.track.title}.';
    });
    unawaited(_savePlaybackSession());
  }

  Future<void> _clearUpcomingQueue() async {
    if (!_canManageSharedQueue()) {
      setState(
        () => status = 'Only host/moderators can clear this shared queue.',
      );
      return;
    }
    if (activeQueue.isEmpty || activeQueueIndex >= activeQueue.length - 1) {
      return;
    }
    final removed = activeQueue.skip(activeQueueIndex + 1).toList();
    setState(() {
      removedQueueUndo = [
        ...removed.reversed,
        ...removedQueueUndo,
      ].take(20).toList();
      activeQueue = activeQueue.take(activeQueueIndex + 1).toList();
      _normalizeQueueState();
      status = 'Cleared upcoming queue items.';
    });
    unawaited(_persistActiveSharedQueue());
    unawaited(_savePlaybackSession());
  }

  Future<void> _clearQueueAndStop() async {
    final activePlayer = player;
    if (activePlayer != null) {
      try {
        await activePlayer.pause();
        await activePlayer.seek(Duration.zero);
      } catch (_) {}
    }
    DeviceConnection.instance.setMediaActive('music', false);
    _logPlaybackAnalytics('music.playback.stopped');
    if (!mounted) {
      return;
    }
    setState(() {
      activeQueue = [];
      playedQueueHistory = [];
      stableShuffleOrder = [];
      activeQueueIndex = 0;
      activeSharedQueueId = '';
      playing = false;
      playbackBuffering = false;
      status = 'Playback stopped.';
    });
    _syncMiniPlayerFromState();
    AudioBackgroundService.instance.clear();
    unawaited(widgetService.update(title: '', artist: '', playing: false));
    vinylController?.stop();
    unawaited(_persistActiveSharedQueue(clear: true));
    unawaited(_savePlaybackSession());
  }

  Future<void> _persistActiveSharedQueue({bool clear = false}) async {
    if (activeSharedQueueId.trim().isEmpty) {
      return;
    }
    final shared = sharedQueues.firstWhere(
      (item) => item['id']?.toString() == activeSharedQueueId,
      orElse: () => const <String, dynamic>{},
    );
    if (shared.isEmpty) {
      return;
    }
    final payload = {
      ...shared,
      if (!clear) ..._queueSnapshot(name: shared['name']?.toString()),
      'id': activeSharedQueueId,
      'name': shared['name']?.toString() ?? 'Shared queue',
      if (clear) 'queueEntries': const <Map<String, dynamic>>[],
      if (clear) 'index': 0,
      if (clear) 'positionMs': 0,
    };
    await music.upsertSharedQueue(widget.profileId, payload);
    await _refreshQueueCollaboration();
    await _syncProfileState();
  }

  Future<void> _saveCurrentAsNamedSession() async {
    if (activeQueue.isEmpty) {
      setState(() => status = 'Start playback before saving a session.');
      return;
    }
    final controller = TextEditingController(
      text:
          'Session ${DateTime.now().toLocal().toIso8601String().substring(0, 19)}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save listening session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Session name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) {
      return;
    }
    final snapshot = _queueSnapshot(name: name.trim());
    final payload = {...snapshot, 'id': const Uuid().v4(), 'name': name.trim()};
    await music.upsertSavedQueue(widget.profileId, payload);
    await _refreshQueueCollaboration();
    await _syncProfileState();
    if (mounted) {
      setState(() => status = 'Saved session "${name.trim()}".');
    }
  }

  Future<void> _loadSavedSessionChooser() async {
    if (savedQueueSessions.isEmpty) {
      setState(() => status = 'No saved listening sessions yet.');
      return;
    }
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Load listening session'),
        children: [
          for (final item in savedQueueSessions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, item),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item['name']?.toString() ?? 'Session'),
                  Text(
                    item['updatedAtUtc']?.toString() ?? '',
                    style: TextStyle(
                      color: _MusicPaint.onSurface60,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null) {
      return;
    }
    await _applyQueueSnapshot(selected);
    activeSharedQueueId = '';
    if (mounted) {
      setState(
        () =>
            status = 'Loaded saved session "${selected['name'] ?? 'Session'}".',
      );
    }
  }

  Future<void> _createSharedQueueFromCurrent() async {
    if (activeQueue.isEmpty) {
      setState(() => status = 'Start playback before creating a shared queue.');
      return;
    }
    final controller = TextEditingController(
      text:
          'Shared ${DateTime.now().toLocal().toIso8601String().substring(0, 19)}',
    );
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create shared queue'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Shared queue name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (label == null || label.trim().isEmpty) {
      return;
    }
    final payload = {
      ..._queueSnapshot(name: label.trim()),
      'id': const Uuid().v4(),
      'name': label.trim(),
      'hostProfileId': widget.profileId,
      'moderatorProfileIds': <int>[widget.profileId],
      'votes': <String, int>{},
      'participants': <int>[widget.profileId],
    };
    await music.upsertSharedQueue(widget.profileId, payload);
    activeSharedQueueId = payload['id']!.toString();
    await _refreshQueueCollaboration();
    await _syncProfileState();
    if (mounted) {
      setState(() => status = 'Shared queue created: ${label.trim()}');
    }
  }

  Future<void> _joinSharedQueueChooser() async {
    if (sharedQueues.isEmpty) {
      setState(() => status = 'No shared queues available.');
      return;
    }
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Join shared queue'),
        children: [
          for (final item in sharedQueues)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, item),
              child: Text(item['name']?.toString() ?? 'Shared queue'),
            ),
        ],
      ),
    );
    if (selected == null) {
      return;
    }
    await _applyQueueSnapshot(selected);
    activeSharedQueueId = selected['id']?.toString() ?? '';
    final participantsRaw = selected['participants'];
    final participants = <int>{
      widget.profileId,
      if (participantsRaw is List)
        ...participantsRaw
            .map((item) => int.tryParse(item.toString()))
            .whereType<int>(),
    }.toList();
    await music.upsertSharedQueue(widget.profileId, {
      ...selected,
      'participants': participants,
    });
    await _refreshQueueCollaboration();
    await _syncProfileState();
    if (mounted) {
      setState(() => status = 'Joined shared queue ${selected['name'] ?? ''}.');
    }
  }

  Future<void> _voteQueueEntry(_QueueEntry entry, int delta) async {
    if (activeSharedQueueId.trim().isEmpty) {
      setState(() => status = 'Voting is available in shared queues only.');
      return;
    }
    await music.voteSharedQueueEntry(
      widget.profileId,
      queueId: activeSharedQueueId,
      entryId: entry.entryId,
      delta: delta,
    );
    await _refreshQueueCollaboration();
    final shared = sharedQueues.firstWhere(
      (item) => item['id']?.toString() == activeSharedQueueId,
      orElse: () => const <String, dynamic>{},
    );
    final votesRaw = shared['votes'];
    final votes = <String, int>{};
    if (votesRaw is Map) {
      for (final item in votesRaw.entries) {
        votes[item.key.toString()] = int.tryParse(item.value.toString()) ?? 0;
      }
    }
    final head = activeQueue.take(activeQueueIndex + 1).toList();
    final tail = activeQueue.skip(activeQueueIndex + 1).toList()
      ..sort(
        (a, b) => (votes[b.entryId] ?? 0).compareTo(votes[a.entryId] ?? 0),
      );
    setState(() {
      activeQueue = [...head, ...tail];
      _normalizeQueueState();
      status = 'Vote applied to queue order.';
    });
    await _persistActiveSharedQueue();
  }

  Future<void> _handoffSessionToAnotherDevice() async {
    if (activeQueue.isEmpty) {
      setState(() => status = 'Start playback before creating a handoff.');
      return;
    }
    final code = await music.createQueueHandoff(
      widget.profileId,
      snapshot: _queueSnapshot(),
      label: activeSharedQueueId.trim().isEmpty
          ? 'Personal queue'
          : 'Shared queue handoff',
    );
    await _syncProfileState();
    if (!mounted) {
      return;
    }
    setState(() {
      status = 'Handoff code: $code (valid 24h).';
    });
  }

  Future<void> _continueSessionFromCode() async {
    final codeController = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Continue on this device'),
        content: TextField(
          controller: codeController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Enter handoff code'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, codeController.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) {
      return;
    }
    final snapshot = await music.consumeQueueHandoff(widget.profileId, code);
    if (snapshot == null) {
      setState(() => status = 'Handoff code not found or expired.');
      return;
    }
    await _applyQueueSnapshot(snapshot);
    await _syncProfileState();
    if (mounted) {
      setState(() => status = 'Session continued from another device.');
    }
  }

  Future<void> _toggleRemoteControlMode() async {
    if (!mounted) {
      return;
    }
    setState(() {
      remoteControlMode = !remoteControlMode;
      status = remoteControlMode
          ? 'Remote-control mode enabled.'
          : 'Remote-control mode disabled.';
    });
    await _persistUiState();
  }

  Future<void> _discoverSpeakersAndRegisterDestinations() async {
    final found = await SpeakerDiscoveryService.instance.discover();
    for (final speaker in found) {
      await playbackDestinationsService.upsert(
        widget.profileId,
        PlaybackDestination(
          id: speaker.id,
          name: speaker.name,
          type: speaker.protocol,
          host: speaker.host,
          port: speaker.port,
          selected: false,
        ),
      );
    }
    playbackDestinations = await playbackDestinationsService.list(
      widget.profileId,
    );
    discoveredSpeakers = found;
    if (mounted) {
      setState(() {
        status = found.isEmpty
            ? 'No speakers discovered on this network.'
            : 'Discovered ${found.length} speaker destinations.';
      });
    }
  }

  Future<void> _selectPlaybackDestination(String destinationId) async {
    await playbackDestinationsService.select(widget.profileId, destinationId);
    playbackDestinations = await playbackDestinationsService.list(
      widget.profileId,
    );
    if (mounted) {
      final selected = playbackDestinations.firstWhere(
        (item) => item.selected,
        orElse: () => const PlaybackDestination(
          id: '',
          name: 'System default output',
          type: 'local',
          host: '',
          port: 0,
        ),
      );
      setState(() {
        status = selected.id.isEmpty
            ? 'Using system output.'
            : 'Playback destination set to ${selected.name}.';
      });
    }
  }

  Future<void> _saveCurrentGroupListeningSession() async {
    final track = activeTrack;
    if (track == null) {
      return;
    }
    final session = GroupListeningSession(
      id: const Uuid().v4(),
      name:
          'Group ${DateTime.now().toLocal().toIso8601String().substring(11, 19)}',
      trackId: track.id,
      positionMs: position.inMilliseconds,
      members: const <GroupSessionMember>[
        GroupSessionMember(deviceId: 'local', label: 'This device'),
      ],
      updatedAtUtc: DateTime.now().toUtc(),
    );
    await groupListeningService.upsertSession(widget.profileId, session);
    groupSessions = await groupListeningService.sessions(widget.profileId);
    if (mounted) {
      setState(() {
        status = 'Saved synchronized group session.';
      });
    }
  }

  Future<void> _resumeGroupSession() async {
    if (groupSessions.isEmpty) {
      return;
    }
    final latest = groupSessions.first;
    final all = librarySongs.isNotEmpty
        ? librarySongs
        : await music.loadLibraryCache(widget.profileId);
    final trackIndex = all.indexWhere((item) => item.id == latest.trackId);
    if (trackIndex < 0) {
      if (mounted) {
        setState(
          () => status =
              'Group session track is unavailable in local library cache.',
        );
      }
      return;
    }
    await _playTrack(
      all[trackIndex],
      queue: _entriesFromTracks(all),
      queueIndex: trackIndex,
    );
    final activePlayer = player;
    if (activePlayer != null && latest.positionMs > 0) {
      await activePlayer.seek(Duration(milliseconds: latest.positionMs));
    }
    if (mounted) {
      setState(() => status = 'Resumed synchronized group session.');
    }
  }

  Future<void> _feedRecommendationsIfNeeded() async {
    final nav = client;
    final track = activeTrack;
    if (nav == null || track == null) {
      return;
    }
    final upcoming = activeQueue.length - activeQueueIndex - 1;
    if (upcoming >= 6) {
      return;
    }
    final existingIds = activeQueue.map((item) => item.track.id).toSet();
    final recPool = await nav.stationFromSeed(track, limit: 40);
    final additions = <MusicTrack>[];
    for (final candidate in recPool) {
      if (existingIds.contains(candidate.id)) {
        continue;
      }
      additions.add(candidate);
      existingIds.add(candidate.id);
      if (additions.length >= 8) {
        break;
      }
    }
    if (additions.isEmpty) {
      return;
    }
    final entries = _entriesFromTracks(
      additions,
      type: _QueueEntryType.recommendation,
      sourceLabel: 'Auto radio recommendations',
    );
    setState(() {
      activeQueue = [...activeQueue, ...entries];
      _normalizeQueueState();
      status = 'Added ${entries.length} recommended songs.';
    });
    await _persistActiveSharedQueue();
    unawaited(_savePlaybackSession());
  }

  Future<void> _loadLyricsForTrack(MusicTrack track) async {
    final nav = client;
    if (nav == null) {
      return;
    }
    setState(() => loadingLyrics = true);
    try {
      final payload = await nav.lyricsForSong(track);
      if (!mounted) {
        return;
      }
      setState(() {
        plainLyrics = payload['plain']?.toString() ?? '';
        credits = payload['credits'] is List
            ? (payload['credits'] as List)
                  .map((item) => item.toString().trim())
                  .where((item) => item.isNotEmpty)
                  .toList()
            : <String>[];
        final timedRaw = payload['timed'];
        timedLyrics = [];
        if (timedRaw is List) {
          for (final item in timedRaw) {
            if (item is! Map) {
              continue;
            }
            final text = item['text']?.toString().trim() ?? '';
            final ms = int.tryParse(item['timeMs']?.toString() ?? '');
            if (text.isEmpty || ms == null || ms < 0) {
              continue;
            }
            timedLyrics.add({'text': text, 'timeMs': ms});
          }
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        plainLyrics = '';
        timedLyrics = [];
        credits = [];
      });
    } finally {
      if (mounted) {
        setState(() => loadingLyrics = false);
      }
    }
  }

  Future<void> _seekToLyric(int timeMs) async {
    final activePlayer = player;
    if (activePlayer == null || duration.inMilliseconds <= 0) {
      return;
    }
    final target = timeMs.clamp(0, duration.inMilliseconds);
    await activePlayer.seek(Duration(milliseconds: target));
  }

  Future<void> _startSleepTimer(int minutes) async {
    await SleepMode.instance.startTimer(minutes);
    await _announceAction('Sleep timer set for $minutes minutes.');
  }

  Future<void> _cancelSleepTimer() async {
    SleepMode.instance.cancelTimer();
    await _announceAction('Sleep timer canceled.');
  }

  Future<String?> _promptForText({
    required String title,
    required String label,
    String initialValue = '',
    String? helper,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(labelText: label, helperText: helper),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _appendActivity({
    required String type,
    required String targetType,
    required String targetId,
    String visibility = 'private',
    Map<String, dynamic> metadata = const {},
  }) async {
    await music.appendActivity(
      widget.profileId,
      actorUserId: _currentUserId,
      type: type,
      targetType: targetType,
      targetId: targetId,
      visibility: visibility,
      metadata: metadata,
    );
    socialFeed = await music.activityFeed(
      widget.profileId,
      includePrivate: true,
    );
  }

  Future<void> _shareEntity({
    required String contentType,
    required String contentId,
    required String label,
    required List<String> trackIds,
    Map<String, dynamic> metadata = const {},
    String? subject,
  }) async {
    final nav = client;
    if (nav == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connect a music server before sharing.'),
          ),
        );
      }
      return;
    }
    final ids = trackIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Nothing to share yet.')));
      }
      return;
    }
    final options = await showDialog<_ShareLinkOptions>(
      context: context,
      builder: (context) => _ShareOptionsDialog(label: label),
    );
    if (options == null || !mounted) {
      return;
    }
    Map<String, dynamic> share;
    try {
      share = await nav.createShare(
        ids: ids,
        description: label,
        expires: options.expiresAt,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create share link: $e')),
        );
      }
      return;
    }
    final link = share['url']?.toString().trim() ?? '';
    if (link.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The music server did not return a share link.'),
          ),
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    final shouldShare = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share link ready'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SelectableText(link),
              const SizedBox(height: 8),
              Text(
                options.allowDownload
                    ? 'In-app, recipients will see a download option for this share.'
                    : 'In-app, recipients can only stream this share — no download button is shown.',
                style: TextStyle(color: _MusicPaint.onSurface70, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                'Opened in a browser, downloads follow the music server\'s own setting.',
                style: TextStyle(color: _MusicPaint.onSurface70, fontSize: 12),
              ),
              if (options.expiresAt != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Expires ${options.expiresAt!.toLocal()}',
                  style: TextStyle(
                    color: _MusicPaint.onSurface70,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (context.mounted) {
                Navigator.pop(context, false);
              }
            },
            child: const Text('Copy link'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Done'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Share now'),
          ),
        ],
      ),
    );
    if (shouldShare == true) {
      await SharePlus.instance.share(
        ShareParams(
          text: '$label\n$link',
          subject: subject ?? 'Shared from MILLITOP Music',
        ),
      );
    }
    await _appendActivity(
      type: 'share',
      targetType: contentType,
      targetId: contentId,
      visibility: 'public',
      metadata: {
        'label': label,
        'link': link,
        'allowDownload': options.allowDownload,
      },
    );
    if (mounted) {
      setState(() => status = 'Share link ready for $label');
    }
  }

  Future<void> _shareTrack(MusicTrack track) async {
    await _shareEntity(
      contentType: 'track',
      contentId: track.id,
      trackIds: [track.id],
      label: '${track.title} — ${track.artist} • ${track.album}',
      metadata: {'artist': track.artist, 'album': track.album},
      subject: 'Now playing: ${track.title}',
    );
    await _announceAction('Track shared.');
  }

  Future<void> _shareAlbum(
    String albumName,
    List<MusicTrack> albumTracks,
  ) async {
    final normalizedId = 'album:${albumName.trim().toLowerCase()}';
    final artist = albumTracks.isEmpty ? '' : albumTracks.first.artist;
    await _shareEntity(
      contentType: 'album',
      contentId: normalizedId,
      trackIds: albumTracks.map((track) => track.id).toList(),
      label: '$albumName${artist.trim().isEmpty ? '' : ' — $artist'}',
      metadata: {'trackCount': albumTracks.length, 'artist': artist},
      subject: 'Album share: $albumName',
    );
  }

  Future<void> _shareArtist(
    String artistName,
    List<MusicTrack> artistTracks,
  ) async {
    await _shareEntity(
      contentType: 'artist',
      contentId: 'artist:${artistName.trim().toLowerCase()}',
      trackIds: artistTracks.map((track) => track.id).toList(),
      label: '$artistName • ${artistTracks.length} songs',
      metadata: {'trackCount': artistTracks.length},
      subject: 'Artist share: $artistName',
    );
  }

  Future<void> _sharePlaylist(MusicPlaylist playlist) async {
    await _shareEntity(
      contentType: 'playlist',
      contentId: playlist.id,
      trackIds: playlist.tracks.map((track) => track.id).toList(),
      label: '${playlist.name} • ${playlist.tracks.length} tracks',
      metadata: {'trackCount': playlist.tracks.length},
      subject: 'Playlist share: ${playlist.name}',
    );
  }

  Future<void> _commentOnTarget({
    required String targetType,
    required String targetId,
    required String label,
  }) async {
    final text = await _promptForText(
      title: 'Add comment',
      label: 'Comment on $label',
      helper: 'Comments are logged in activity and moderation feed.',
    );
    if (text == null) {
      return;
    }
    await music.addComment(
      widget.profileId,
      targetType: targetType,
      targetId: targetId,
      userId: _currentUserId,
      text: text,
    );
    await _appendActivity(
      type: 'comment',
      targetType: targetType,
      targetId: targetId,
      visibility: 'public',
      metadata: {'text': text},
    );
    if (mounted) {
      setState(() => status = 'Comment added.');
    }
  }

  Future<void> _reportTarget({
    required String targetType,
    required String targetId,
    required String label,
  }) async {
    final details = await _promptForText(
      title: 'Report content',
      label: 'Reason for reporting',
      helper: 'Describe the issue for moderation review.',
    );
    if (details == null) {
      return;
    }
    await music.fileAbuseReport(
      widget.profileId,
      reporterUserId: _currentUserId,
      targetType: targetType,
      targetId: targetId,
      details: details,
    );
    await music.addModerationAction(
      widget.profileId,
      moderatorUserId: _currentUserId,
      action: 'report_submitted',
      targetType: targetType,
      targetId: targetId,
      reason: details,
    );
    if (mounted) {
      setState(() => status = 'Report submitted for $label.');
    }
  }

  Future<void> _openFeedPanel() async {
    await _loadSocialState();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Activity feed'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: socialFeed.isEmpty
              ? const Center(child: Text('No activity yet.'))
              : ListView.builder(
                  itemCount: socialFeed.length,
                  itemBuilder: (context, index) {
                    final item = socialFeed[index];
                    final type = item['type']?.toString() ?? 'activity';
                    final targetType = item['targetType']?.toString() ?? 'item';
                    final targetId = item['targetId']?.toString() ?? '';
                    final created = item['createdAtUtc']?.toString() ?? '';
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.bolt_outlined),
                      title: Text('$type • $targetType'),
                      subtitle: Text('$targetId\n$created'),
                      isThreeLine: true,
                    );
                  },
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

  Future<void> _openProfileScreen() async {
    await _loadSocialState();
    if (!mounted) {
      return;
    }
    final displayNameController = TextEditingController(
      text: publicProfileState['displayName']?.toString() ?? '',
    );
    final bioController = TextEditingController(
      text: publicProfileState['bio']?.toString() ?? '',
    );
    final followController = TextEditingController();
    final blockController = TextEditingController();
    var isPublic = publicProfileState['enabled'] == true;
    var historyPublic = historyVisibility == 'public';
    var allowInvites = invitationControlState['allowInvites'] != false;
    var invitePolicy =
        invitationControlState['invitePolicy']?.toString() ?? 'everyone';
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Social profile'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    value: isPublic,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Public profile'),
                    onChanged: (value) => setLocal(() => isPublic = value),
                  ),
                  SwitchListTile(
                    value: historyPublic,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Public listening history'),
                    onChanged: (value) => setLocal(() => historyPublic = value),
                  ),
                  TextField(
                    controller: displayNameController,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: bioController,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Bio'),
                  ),
                  const SizedBox(height: 12),
                  const Text('Invitation controls'),
                  SwitchListTile(
                    value: allowInvites,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow invitations'),
                    onChanged: (value) => setLocal(() => allowInvites = value),
                  ),
                  DropdownButton<String>(
                    value: invitePolicy,
                    isExpanded: true,
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setLocal(() => invitePolicy = value);
                    },
                    items: const [
                      DropdownMenuItem(
                        value: 'everyone',
                        child: Text('Policy: everyone'),
                      ),
                      DropdownMenuItem(
                        value: 'following',
                        child: Text('Policy: following'),
                      ),
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('Policy: none'),
                      ),
                    ],
                  ),
                  const Divider(),
                  const Text('Follow users'),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: followController,
                          decoration: const InputDecoration(
                            hintText: 'user id',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async {
                          final target = followController.text.trim();
                          if (target.isEmpty) {
                            return;
                          }
                          await music.followUser(widget.profileId, target);
                          followedUsers = await music.followedUsers(
                            widget.profileId,
                          );
                          followController.clear();
                          setLocal(() {});
                        },
                        child: const Text('Follow'),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in followedUsers)
                        InputChip(
                          label: Text(id),
                          onDeleted: () async {
                            await music.unfollowUser(widget.profileId, id);
                            followedUsers = await music.followedUsers(
                              widget.profileId,
                            );
                            setLocal(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text('Blocked users'),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: blockController,
                          decoration: const InputDecoration(
                            hintText: 'user id',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async {
                          final target = blockController.text.trim();
                          if (target.isEmpty) {
                            return;
                          }
                          await music.blockUser(widget.profileId, target);
                          blockedSocialUsers = await music.blockedUsers(
                            widget.profileId,
                          );
                          blockController.clear();
                          setLocal(() {});
                        },
                        child: const Text('Block'),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in blockedSocialUsers)
                        InputChip(
                          label: Text(id),
                          onDeleted: () async {
                            await music.unblockUser(widget.profileId, id);
                            blockedSocialUsers = await music.blockedUsers(
                              widget.profileId,
                            );
                            setLocal(() {});
                          },
                        ),
                    ],
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
            FilledButton(
              onPressed: () async {
                await music.savePublicProfile(
                  widget.profileId,
                  enabled: isPublic,
                  displayName: displayNameController.text,
                  bio: bioController.text,
                );
                await music.setPersonalHistoryVisibility(
                  widget.profileId,
                  historyPublic ? 'public' : 'private',
                );
                await music.saveInvitationControls(
                  widget.profileId,
                  allowInvites: allowInvites,
                  invitePolicy: invitePolicy,
                );
                await _loadSocialState();
                if (mounted) {
                  setState(() => status = 'Social profile updated.');
                }
                if (context.mounted) {
                  Navigator.pop(context);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openModerationPanel() async {
    final reports = await music.abuseReports(widget.profileId);
    final actions = await music.moderationActions(widget.profileId);
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Moderation & reports'),
        content: SizedBox(
          width: 580,
          height: 440,
          child: ListView(
            children: [
              const Text(
                'Abuse reports',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              if (reports.isEmpty)
                const Text('No abuse reports.')
              else
                for (final report in reports.take(50))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.report_gmailerrorred_outlined),
                    title: Text(
                      '${report['targetType'] ?? 'item'} • ${report['targetId'] ?? ''}',
                    ),
                    subtitle: Text(report['details']?.toString() ?? ''),
                  ),
              const Divider(),
              const Text(
                'Moderation actions',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              if (actions.isEmpty)
                const Text('No moderation actions.')
              else
                for (final action in actions.take(50))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.shield_outlined),
                    title: Text(action['action']?.toString() ?? 'action'),
                    subtitle: Text(
                      '${action['targetType'] ?? 'item'} • ${action['targetId'] ?? ''}\n${action['reason'] ?? ''}',
                    ),
                    isThreeLine: true,
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
      ),
    );
  }

  Future<void> _openSocialCenter() async {
    await _loadSocialState();
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.9,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Social center',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => unawaited(_openProfileScreen()),
                    icon: const Icon(Icons.person_outline),
                    label: const Text('Profile'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_openFeedPanel()),
                    icon: const Icon(Icons.dynamic_feed_outlined),
                    label: const Text('Activity feed'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_openModerationPanel()),
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                    label: const Text('Moderation'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    Text('Followed users: ${followedUsers.length}'),
                    const SizedBox(height: 4),
                    Text('Blocked users: ${blockedSocialUsers.length}'),
                    const SizedBox(height: 4),
                    Text(
                      'Profile visibility: ${publicProfileState['enabled'] == true ? 'Public' : 'Private'}',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'History visibility: ${historyVisibility == 'public' ? 'Public' : 'Private'}',
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Queue invitations',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    if (queueInvitationItems.isEmpty)
                      const Text('No invitations.')
                    else
                      for (final invitation in queueInvitationItems.take(10))
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.mail_outline),
                          title: Text(
                            'Queue ${invitation['queueId'] ?? ''} • ${invitation['invitedUserId'] ?? ''}',
                          ),
                          subtitle: Text(
                            'Status: ${invitation['status'] ?? 'pending'}',
                          ),
                          trailing:
                              invitation['status']?.toString() == 'pending'
                              ? Wrap(
                                  spacing: 6,
                                  children: [
                                    TextButton(
                                      onPressed: () async {
                                        await music.respondToQueueInvitation(
                                          widget.profileId,
                                          invitationId:
                                              invitation['id']?.toString() ??
                                              '',
                                          accept: false,
                                        );
                                        await _loadSocialState();
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                        if (mounted) {
                                          unawaited(_openSocialCenter());
                                        }
                                      },
                                      child: const Text('Decline'),
                                    ),
                                    FilledButton(
                                      onPressed: () async {
                                        await music.respondToQueueInvitation(
                                          widget.profileId,
                                          invitationId:
                                              invitation['id']?.toString() ??
                                              '',
                                          accept: true,
                                        );
                                        await _loadSocialState();
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                        if (mounted) {
                                          unawaited(_openSocialCenter());
                                        }
                                      },
                                      child: const Text('Accept'),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                    const SizedBox(height: 10),
                    const Text(
                      'Recent social activity',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    if (socialFeed.isEmpty)
                      const Text('No activity yet.')
                    else
                      for (final item in socialFeed.take(12))
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.bubble_chart_outlined),
                          title: Text(
                            '${item['type'] ?? 'activity'} • ${item['targetType'] ?? 'item'}',
                          ),
                          subtitle: Text(
                            '${item['targetId'] ?? ''}\n${item['createdAtUtc'] ?? ''}',
                          ),
                          isThreeLine: true,
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAlbumContext(MusicTrack track) async {
    query.text = track.album;
    _setSection(_MusicSection.albums);
  }

  Future<void> _openArtistContext(MusicTrack track) async {
    query.text = track.artist;
    _setSection(_MusicSection.artists);
  }

  Future<void> _presentPlayerSheetIfNeeded() async {
    if (!mounted || playerSheetOpen) {
      return;
    }
    final compact = MediaQuery.sizeOf(context).width < 1100;
    if (!compact || activeTrack == null) {
      return;
    }
    playerSheetOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          FractionallySizedBox(heightFactor: 0.94, child: _mobilePlayerSheet()),
    );
    if (mounted) {
      setState(() => playerSheetOpen = false);
    } else {
      playerSheetOpen = false;
    }
  }

  Future<void> _togglePin({required String type, required String value}) async {
    final target = switch (type) {
      'album' => pinnedAlbums,
      'artist' => pinnedArtists,
      'playlist' => pinnedPlaylists,
      _ => pinnedAlbums,
    };
    if (target.contains(value)) {
      target.remove(value);
      await _announceAction('Unpinned $value');
    } else {
      target.add(value);
      await _announceAction('Pinned $value');
    }
    if (mounted) {
      setState(() {});
    }
    unawaited(_persistUiState());
  }

  Future<void> _openHomeCustomization() async {
    final choices = <String>{...homeSectionOrder};
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Customize home'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in const [
                  'recents',
                  'favorites',
                  'mostPlayed',
                  'pinned',
                ])
                  CheckboxListTile(
                    value: choices.contains(item),
                    title: Text(item),
                    onChanged: (value) {
                      setLocal(() {
                        if (value == true) {
                          choices.add(item);
                        } else {
                          choices.remove(item);
                        }
                      });
                    },
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
                homeSectionOrder
                  ..clear()
                  ..addAll(choices);
                if (homeSectionOrder.isEmpty) {
                  homeSectionOrder.add('recents');
                }
                Navigator.pop(context);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
    unawaited(_persistUiState());
  }

  Future<void> _toggleTrackSelection(MusicTrack track) async {
    if (selectedTrackIds.contains(track.id)) {
      selectedTrackIds.remove(track.id);
    } else {
      selectedTrackIds.add(track.id);
    }
    if (mounted) {
      setState(() {});
    }
    await HapticFeedback.selectionClick();
  }

  Future<void> _addSelectedToQueue(List<MusicTrack> universe) async {
    final tracks = universe
        .where((item) => selectedTrackIds.contains(item.id))
        .toList();
    if (tracks.isEmpty) {
      return;
    }
    await _addTracksLast(tracks, sourceLabel: 'Multi-select add');
    selectedTrackIds.clear();
    if (mounted) {
      setState(() => multiSelectMode = false);
    }
    await _announceAction('Added ${tracks.length} selected tracks to queue.');
  }

  Future<void> _removeFirstQueuedTrackById(String trackId) async {
    final index = activeQueue.indexWhere((item) => item.track.id == trackId);
    if (index < 0) {
      return;
    }
    await _removeQueueEntryAt(index);
  }

  void _setSection(_MusicSection next) {
    if (!mounted) {
      return;
    }
    setState(() => section = next);
    if (next == _MusicSection.favorites) {
      unawaited(_refreshFavoritesFromServerIfConnected(silent: false));
    }
    unawaited(HapticFeedback.selectionClick());
    unawaited(_persistUiState());
  }

  Widget _withKeyboardShortcuts(Widget child) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): _PlayPauseIntent(),
        SingleActivator(LogicalKeyboardKey.mediaPlayPause): _PlayPauseIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
            _NextIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            _PreviousIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PlayPauseIntent: CallbackAction<_PlayPauseIntent>(
            onInvoke: (_) => unawaited(_togglePlayPause()),
          ),
          _NextIntent: CallbackAction<_NextIntent>(
            onInvoke: (_) => unawaited(_playNextTrackInQueue()),
          ),
          _PreviousIntent: CallbackAction<_PreviousIntent>(
            onInvoke: (_) => unawaited(_playPreviousTrackInQueue()),
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }

  Future<void> _toggleFavorite(MusicTrack track) async {
    final next = !_isFavorite(track.id);
    final nav = client;
    if (nav != null) {
      try {
        await nav.setSongFavorite(track.id, next);
        await _syncFavoritesFromServer(nav);
      } catch (_) {
        if (mounted) {
          setState(() {
            status = 'Could not update favorite on Navidrome.';
          });
        }
        return;
      }
    }
    await music.setFavorite(widget.profileId, track, next);
    favorites = await music.favorites(widget.profileId);
    await _syncProfileState();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _exitToAppHome() async {
    if (!mounted) {
      return;
    }
    await Navigator.of(context).maybePop();
  }

  Future<void> _createStation(MusicTrack seed) async {
    final nav = client;
    if (nav == null) {
      return;
    }
    final custom = stationName.text.trim();
    final label = custom.isEmpty ? 'Song Radio · ${seed.title}' : custom;
    setState(() => status = 'Building station from ${seed.title}...');
    final queue = await nav.stationFromSeed(seed, limit: 30);
    final station = MusicStation(
      id: const Uuid().v4(),
      name: label,
      seedTrackId: seed.id,
      seedTitle: seed.title,
      createdAtUtc: DateTime.now().toUtc(),
      queue: queue,
    );
    await music.upsertStation(widget.profileId, station);
    await _syncProfileState();
    stations = await music.stations(widget.profileId);
    if (!mounted) {
      return;
    }
    setState(() {
      stationName.clear();
      status = 'Station created: ${station.name}';
    });
    _setSection(_MusicSection.radio);
  }

  Future<void> _createPlaylistFromName() async {
    final name = playlistName.text.trim();
    if (name.isEmpty) {
      return;
    }
    final playlist = MusicPlaylist(
      id: const Uuid().v4(),
      name: name,
      createdAtUtc: DateTime.now().toUtc(),
      tracks: const [],
    );
    await music.upsertPlaylist(widget.profileId, playlist);
    playlists = await music.playlists(widget.profileId);
    await _syncProfileState();
    if (mounted) {
      setState(() {
        playlistName.clear();
      });
      _setSection(_MusicSection.playlists);
    }
  }

  Future<void> _addTrackToPlaylist(
    MusicTrack track,
    MusicPlaylist playlist,
  ) async {
    final next = [
      track,
      ...playlist.tracks.where((item) => item.id != track.id),
    ];
    await music.upsertPlaylist(
      widget.profileId,
      MusicPlaylist(
        id: playlist.id,
        name: playlist.name,
        createdAtUtc: playlist.createdAtUtc,
        tracks: next,
      ),
    );
    playlists = await music.playlists(widget.profileId);
    await _syncProfileState();
    if (mounted) {
      setState(() => status = 'Added to ${playlist.name}');
    }
  }

  Future<void> _pickPlaylistForTrack(MusicTrack track) async {
    if (playlists.isEmpty) {
      await addToMixedPlaylist(
        context,
        profileId: widget.profileId,
        item: HubItem.song(track),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to playlist'),
        content: SizedBox(
          width: math.min(360, MediaQuery.sizeOf(context).width - 48),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                key: const ValueKey('music-mixed-playlist'),
                leading: const Icon(Icons.playlist_add_circle_outlined),
                title: const Text('Mixed playlist...'),
                subtitle: const Text('Mix with videos, shows and podcasts'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(
                    addToMixedPlaylist(
                      this.context,
                      profileId: widget.profileId,
                      item: HubItem.song(track),
                    ),
                  );
                },
              ),
              const Divider(),
              for (final list in playlists)
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(list.name),
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_addTrackToPlaylist(track, list));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportPlaylist(MusicPlaylist playlist) async {
    final file = await music.exportPlaylistAsM3u(
      widget.profileId,
      playlistId: playlist.id,
    );
    await _appendActivity(
      type: 'playlist_export',
      targetType: 'playlist',
      targetId: playlist.id,
      visibility: 'private',
      metadata: {'path': file.path},
    );
    if (mounted) {
      setState(() => status = 'Exported ${playlist.name} to ${file.path}');
    }
  }

  Future<void> _togglePlaylistPublic(MusicPlaylist playlist) async {
    final current = await music.isPlaylistPublic(widget.profileId, playlist.id);
    await music.setPlaylistPublic(
      widget.profileId,
      playlistId: playlist.id,
      isPublic: !current,
    );
    await _appendActivity(
      type: 'playlist_visibility',
      targetType: 'playlist',
      targetId: playlist.id,
      visibility: 'private',
      metadata: {'public': !current},
    );
    if (mounted) {
      setState(() {
        status = !current
            ? '${playlist.name} is now public.'
            : '${playlist.name} is now private.';
      });
    }
  }

  Future<void> _configureCollaborativePlaylist(MusicPlaylist playlist) async {
    final editors = await _promptForText(
      title: 'Collaborative playlist editors',
      label: 'Comma-separated user IDs',
      helper: 'Example: profile-2, profile-9',
    );
    if (editors == null) {
      return;
    }
    final ids = editors
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();
    await music.setCollaborativePlaylist(
      widget.profileId,
      playlistId: playlist.id,
      enabled: ids.isNotEmpty,
      editorUserIds: ids,
    );
    await _appendActivity(
      type: 'collaborative_playlist_update',
      targetType: 'playlist',
      targetId: playlist.id,
      visibility: 'private',
      metadata: {'editorCount': ids.length},
    );
    if (mounted) {
      setState(
        () => status = 'Updated collaborative editors for ${playlist.name}.',
      );
    }
  }

  Future<void> _inviteUserToSharedQueue() async {
    if (activeSharedQueueId.trim().isEmpty) {
      if (mounted) {
        setState(() => status = 'Create or join a shared queue first.');
      }
      return;
    }
    final userId = await _promptForText(
      title: 'Invite to queue',
      label: 'User ID',
      helper: 'Example: profile-2',
    );
    if (userId == null) {
      return;
    }
    await music.inviteToQueue(
      widget.profileId,
      queueId: activeSharedQueueId,
      invitedUserId: userId,
      role: 'listener',
    );
    await _appendActivity(
      type: 'queue_invite',
      targetType: 'shared_queue',
      targetId: activeSharedQueueId,
      visibility: 'private',
      metadata: {'invitedUserId': userId},
    );
    if (mounted) {
      setState(() => status = 'Invitation sent to $userId.');
    }
  }

  Future<void> _onTrackAction(MusicTrack track, _TrackAction action) async {
    switch (action) {
      case _TrackAction.playNow:
        if (mounted) {
          setState(() => status = 'Queue replaced with selected track.');
        }
        await _playTrack(track);
        break;
      case _TrackAction.playNext:
        await _playNext(track);
        break;
      case _TrackAction.playLast:
        await _playLast(track);
        break;
      case _TrackAction.addToQueue:
        await _addTracksLast([track], sourceLabel: 'Add to queue');
        break;
      case _TrackAction.share:
        await _shareTrack(track);
        break;
      case _TrackAction.comment:
        await _commentOnTarget(
          targetType: 'track',
          targetId: track.id,
          label: track.title,
        );
        break;
      case _TrackAction.report:
        await _reportTarget(
          targetType: 'track',
          targetId: track.id,
          label: track.title,
        );
        break;
      case _TrackAction.toggleFavorite:
        await _toggleFavorite(track);
        break;
      case _TrackAction.startRadio:
        await _createStation(track);
        break;
      case _TrackAction.addToPlaylist:
        await _pickPlaylistForTrack(track);
        break;
      case _TrackAction.download:
        await _downloadTrack(track);
        break;
    }
  }

  Future<void> _removeStation(MusicStation station) async {
    await music.removeStation(widget.profileId, station.id);
    await _syncProfileState();
    stations = await music.stations(widget.profileId);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final activePlayer = player;
    if (activePlayer == null || duration <= Duration.zero) {
      return;
    }
    final target = (position + Duration(seconds: seconds)).inMilliseconds.clamp(
      0,
      duration.inMilliseconds,
    );
    await activePlayer.seek(Duration(milliseconds: target));
    unawaited(_savePlaybackSession());
  }

  /// Plays the current queue entry, from the saved position when the queue
  /// was restored from an earlier session.
  Future<void> _resumeActiveTrack() async {
    final track = activeTrack;
    if (track == null) {
      return;
    }
    await _playTrack(
      _withFreshStream(track),
      queue: activeQueue,
      queueIndex: activeQueueIndex,
      startAt: resumePosition,
    );
  }

  MusicTrack _withFreshStream(MusicTrack track) {
    final nav = client;
    if (nav == null) {
      return track;
    }
    return MusicTrack(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      genre: track.genre,
      year: track.year,
      durationSeconds: track.durationSeconds,
      coverArtId: track.coverArtId,
      streamUrl: nav.streamUri(track.id).toString(),
    );
  }

  Future<void> _togglePlayPause() async {
    final track = activeTrack;
    if (track == null) {
      // Nothing queued yet: Play starts the songs on screen.
      final tracks = _libraryTracks;
      if (tracks.isNotEmpty) {
        await _playFromList(tracks, 0);
      }
      return;
    }
    final activePlayer = player;
    if (activePlayer == null || loadedTrackId != track.id) {
      // The queue came from a saved session (or the track changed) but the
      // player has nothing loaded, so play() alone would do nothing.
      await _resumeActiveTrack();
      return;
    }
    if (playing) {
      await activePlayer.pause();
      DeviceConnection.instance.setMediaActive('music', false);
      _logPlaybackAnalytics('music.playback.paused');
      unawaited(_savePlaybackSession());
      AudioBackgroundService.instance.updatePlayback(
        playing: false,
        position: position,
        duration: duration,
        buffering: trackLoading || playbackBuffering,
      );
      unawaited(_announceAction('Playback paused.'));
      final track = activeTrack;
      if (track != null) {
        unawaited(
          widgetService.update(
            title: track.title,
            artist: track.artist,
            playing: false,
          ),
        );
      }
    } else {
      await activePlayer.play();
      DeviceConnection.instance.setMediaActive('music', true);
      _logPlaybackAnalytics('music.playback.resumed');
      AudioBackgroundService.instance.updatePlayback(
        playing: true,
        position: position,
        duration: duration,
        buffering: trackLoading || playbackBuffering,
      );
      unawaited(_announceAction('Playback resumed.'));
      final track = activeTrack;
      if (track != null) {
        unawaited(
          widgetService.update(
            title: track.title,
            artist: track.artist,
            playing: true,
          ),
        );
      }
    }
    unawaited(_savePlaybackSession());
  }

  Future<void> _pausePlayback({String reason = 'manual'}) async {
    final activePlayer = player;
    if (activePlayer == null) {
      return;
    }
    try {
      await activePlayer.pause();
      DeviceConnection.instance.setMediaActive('music', false);
      _logPlaybackAnalytics(
        'music.playback.paused',
        details: {'reason': reason},
      );
      AudioBackgroundService.instance.updatePlayback(
        playing: false,
        position: position,
        duration: duration,
        buffering: trackLoading || playbackBuffering,
      );
    } catch (_) {}
  }

  Future<void> _resumeAfterInterruption() async {
    final activePlayer = player;
    if (activePlayer == null || activeTrack == null || playing) {
      return;
    }
    try {
      await activePlayer.play();
      DeviceConnection.instance.setMediaActive('music', true);
      _logPlaybackAnalytics(
        'music.playback.resumed',
        details: {'reason': 'audio_interruption_end'},
      );
      AudioBackgroundService.instance.updatePlayback(
        playing: true,
        position: position,
        duration: duration,
        buffering: trackLoading || playbackBuffering,
      );
    } catch (error, stack) {
      AppLog.warn(
        LogCategory.playback,
        'Music playback did not resume after interruption.',
        error: error,
        stackTrace: stack,
        details: {'profileId': widget.profileId},
      );
    }
  }

  Future<void> _setVolume(double value) async {
    final activePlayer = player;
    if (activePlayer == null) {
      return;
    }
    await activePlayer.setVolume(value.clamp(0, 100));
  }

  String _clock(Duration value) {
    final total = value.inSeconds.clamp(0, 359999);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _durationLabel(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final m = safe ~/ 60;
    final s = (safe % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _metadata(MusicTrack track) {
    final bits = <String>[
      track.album,
      if (track.year != null) '${track.year}',
      if (track.genre != null && track.genre!.trim().isNotEmpty) track.genre!,
    ];
    return bits.join(' • ');
  }

  String _sourceLabelForTrack(MusicTrack track) {
    final entry = downloadIndex[track.id];
    if (entry == null) {
      return 'Source: Streamed • Remote';
    }
    final exists = File(entry.filePath).existsSync();
    final mb = entry.sizeBytes <= 0
        ? ''
        : ' • ${(entry.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (exists) {
      return 'Source: Downloaded • Local$mb';
    }
    return 'Source: Cached metadata only$mb';
  }

  String _audioFormatLabel(MusicTrack track) {
    final entry = downloadIndex[track.id];
    final source = entry != null ? entry.filePath : (track.streamUrl ?? '');
    final lower = source.toLowerCase();
    String format = 'Unknown format';
    if (lower.contains('.flac')) {
      format = 'FLAC';
    } else if (lower.contains('.mp3')) {
      format = 'MP3';
    } else if (lower.contains('.aac') || lower.contains('.m4a')) {
      format = 'AAC';
    } else if (lower.contains('.ogg') || lower.contains('.opus')) {
      format = 'Ogg/Opus';
    } else if (lower.contains('.wav')) {
      format = 'WAV';
    } else if (lower.isNotEmpty) {
      format = 'Container stream';
    }
    final size = entry == null || entry.sizeBytes <= 0
        ? ''
        : ' • ${(entry.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '$format$size';
  }

  String _outputDeviceLabel() {
    if (DeviceConnection.instance.isConnected) {
      return 'Output: Household connected device';
    }
    return 'Output: System default device';
  }

  bool _reducedMotionActive(BuildContext context) {
    return reducedMotionOverride ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
  }

  double _animationTurnsMultiplier(BuildContext context) {
    if (_reducedMotionActive(context)) {
      return 0;
    }
    return switch (animationIntensity) {
      _AnimationIntensity.off => 0,
      _AnimationIntensity.low => 0.4,
      _AnimationIntensity.normal => 1,
      _AnimationIntensity.high => 1.8,
    };
  }

  Color _artworkDerivedColor(MusicTrack track) {
    final hash = track.id.codeUnits.fold<int>(
      0,
      (sum, value) => (sum * 31 + value) & 0xFFFFFFFF,
    );
    final hue = (hash % 360).toDouble();
    return HSVColor.fromAHSV(1, hue, 0.55, 0.9).toColor();
  }

  List<Color> _panelColors(MusicTrack track) {
    final accent = _artworkDerivedColor(track);
    switch (nowPlayingTheme) {
      case _NowPlayingTheme.neon:
        return [
          accent.withOpacity(0.35),
          _MusicPaint.blend(_MusicPaint.panel, _MusicPaint.overlayOpaque, 0.7),
        ];
      case _NowPlayingTheme.warm:
        return [
          _MusicPaint.blend(_MusicPaint.warning, _MusicPaint.panel, 0.55),
          _MusicPaint.blend(_MusicPaint.panel, _MusicPaint.overlayOpaque, 0.84),
        ];
      case _NowPlayingTheme.midnight:
        return [
          _MusicPaint.blend(_MusicPaint.panel, _MusicPaint.accent, 0.22),
          _MusicPaint.blend(_MusicPaint.panel, _MusicPaint.overlayOpaque, 0.82),
        ];
      case _NowPlayingTheme.auto:
        return [
          accent.withOpacity(0.22),
          _MusicPaint.blend(_MusicPaint.panel, _MusicPaint.overlayOpaque, 0.8),
        ];
    }
  }

  Future<void> _announceAction(String message) async {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
    final direction = Directionality.of(context);
    SemanticsService.announce(message, direction);
  }

  Widget _visualizerWidget(BuildContext context) {
    final turns = _animationTurnsMultiplier(context);
    if (!visualizerEnabled || turns <= 0 || !playing) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 46,
      child: AnimatedBuilder(
        animation: vinylController!,
        builder: (context, _) {
          final t = (vinylController?.value ?? 0) * math.pi * 2;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(16, (index) {
              final wave = (math.sin(t * (1.2 + (index * 0.14))) + 1) * 0.5;
              final h = 8 + (wave * 30 * turns.clamp(0.2, 2.0));
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Container(
                    height: h,
                    decoration: BoxDecoration(
                      color: _MusicPaint.accent.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  double _playbackProgressRatio() {
    if (duration.inMilliseconds <= 0) {
      return 0;
    }
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);
  }

  Widget _vinylDeck(
    BuildContext context,
    MusicTrack track, {
    required double size,
    bool includeVisualizer = false,
    bool immersive = false,
  }) {
    final progress = _playbackProgressRatio();
    final recordSize = size * 0.86;
    final tonearmProgress = playing
        ? (duration.inMilliseconds > 0 ? progress.clamp(0.0, 1.0) : 0.05)
        : 0.0;
    final tonearmAngle = playing
        ? Tween<double>(begin: -18, end: 16).transform(tonearmProgress)
        : -28.0;
    return GestureDetector(
      onTap: () => unawaited(_openImmersiveListeningMode()),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: vinylController!,
              builder: (context, _) => Transform.rotate(
                angle: (vinylController?.value ?? 0) * math.pi * 2,
                child: Container(
                  width: recordSize,
                  height: recordSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        _MusicPaint.blend(
                          _MusicPaint.panel,
                          _MusicPaint.onSurface,
                          0.5,
                        ),
                        _MusicPaint.blend(
                          _MusicPaint.panel,
                          _MusicPaint.overlayOpaque,
                          0.75,
                        ),
                      ],
                    ),
                    border: Border.all(
                      color: _MusicPaint.blend(
                        _MusicPaint.panel,
                        _MusicPaint.onSurface,
                        0.42,
                      ),
                      width: 2,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(painter: _NowPlayingVinylGroovesPainter()),
                      Center(
                        child: ClipOval(
                          child: SizedBox(
                            width: recordSize * 0.42,
                            height: recordSize * 0.42,
                            child: _coverArt(track, radius: recordSize),
                          ),
                        ),
                      ),
                      Center(
                        child: Container(
                          width: recordSize * 0.065,
                          height: recordSize * 0.065,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _MusicPaint.blend(
                              _MusicPaint.onSurface,
                              _MusicPaint.accent,
                              0.05,
                            ),
                            border: Border.all(
                              color: _MusicPaint.overlaySoft,
                              width: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: recordSize * 0.02,
              right: recordSize * 0.14,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: tonearmAngle),
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                builder: (context, angle, child) => Transform.rotate(
                  angle: angle * math.pi / 180,
                  alignment: Alignment.topRight,
                  child: child,
                ),
                child: SizedBox(
                  width: recordSize * (immersive ? 0.41 : 0.38),
                  height: recordSize * (immersive ? 0.60 : 0.55),
                  child: CustomPaint(painter: _NowPlayingTonearmPainter()),
                ),
              ),
            ),
            if (includeVisualizer)
              Positioned(
                left: 14,
                right: 14,
                bottom: 10,
                child: _visualizerWidget(context),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _searchImmersiveSongs(String text) async {
    final nav = client;
    if (nav == null || text.trim().length < 2) {
      if (mounted) {
        setState(() => immersiveSearchResults = []);
      }
      return;
    }
    setState(() => immersiveSearchLoading = true);
    try {
      final results = await nav.searchSongs(text.trim(), limit: 24);
      if (!mounted) {
        return;
      }
      setState(() => immersiveSearchResults = results);
    } finally {
      if (mounted) {
        setState(() => immersiveSearchLoading = false);
      }
    }
  }

  Future<void> _openNowPlayingOptionsMenu() async {
    final track = activeTrack;
    if (track == null || !mounted) {
      return;
    }
    final upNext = activeQueue.isEmpty
        ? const <_QueueEntry>[]
        : activeQueue
              .skip((activeQueueIndex + 1).clamp(0, activeQueue.length))
              .toList();
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 84, right: 12, left: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 720),
            child: Material(
              color: _MusicPaint.blend(
                _MusicPaint.panel,
                _MusicPaint.accent,
                0.2,
              ),
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: StatefulBuilder(
                builder: (context, setLocal) => SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Now Playing Options',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text('Display'),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<_NowPlayingPane>(
                            segments: const [
                              ButtonSegment(
                                value: _NowPlayingPane.vinyl,
                                label: Text('Vinyl'),
                              ),
                              ButtonSegment(
                                value: _NowPlayingPane.lyrics,
                                label: Text('Lyrics'),
                              ),
                              ButtonSegment(
                                value: _NowPlayingPane.visualizer,
                                label: Text('Visualizer'),
                              ),
                              ButtonSegment(
                                value: _NowPlayingPane.vinylVisualizer,
                                label: Text('Vinyl+Vis'),
                              ),
                              ButtonSegment(
                                value: _NowPlayingPane.artworkVisualizer,
                                label: Text('Art+Vis'),
                              ),
                            ],
                            selected: {nowPlayingPane},
                            onSelectionChanged: (value) {
                              setState(() => nowPlayingPane = value.first);
                              setLocal(() {});
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text('Mode'),
                        SegmentedButton<_NowPlayingMode>(
                          segments: const [
                            ButtonSegment(
                              value: _NowPlayingMode.standard,
                              label: Text('Standard'),
                            ),
                            ButtonSegment(
                              value: _NowPlayingMode.ipod,
                              label: Text('iPod'),
                            ),
                            ButtonSegment(
                              value: _NowPlayingMode.minimal,
                              label: Text('Minimal'),
                            ),
                            ButtonSegment(
                              value: _NowPlayingMode.drive,
                              label: Text('Drive'),
                            ),
                          ],
                          selected: {nowPlayingMode},
                          onSelectionChanged: (value) {
                            setState(() => nowPlayingMode = value.first);
                            setLocal(() {});
                          },
                        ),
                        const SizedBox(height: 8),
                        DropdownButton<_NowPlayingTheme>(
                          value: nowPlayingTheme,
                          isExpanded: true,
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => nowPlayingTheme = value);
                            setLocal(() {});
                          },
                          items: const [
                            DropdownMenuItem(
                              value: _NowPlayingTheme.auto,
                              child: Text('Theme: artwork-derived'),
                            ),
                            DropdownMenuItem(
                              value: _NowPlayingTheme.midnight,
                              child: Text('Theme: midnight'),
                            ),
                            DropdownMenuItem(
                              value: _NowPlayingTheme.neon,
                              child: Text('Theme: neon'),
                            ),
                            DropdownMenuItem(
                              value: _NowPlayingTheme.warm,
                              child: Text('Theme: warm'),
                            ),
                          ],
                        ),
                        DropdownButton<_AnimationIntensity>(
                          value: animationIntensity,
                          isExpanded: true,
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => animationIntensity = value);
                            setLocal(() {});
                          },
                          items: const [
                            DropdownMenuItem(
                              value: _AnimationIntensity.off,
                              child: Text('Animation: off'),
                            ),
                            DropdownMenuItem(
                              value: _AnimationIntensity.low,
                              child: Text('Animation: low'),
                            ),
                            DropdownMenuItem(
                              value: _AnimationIntensity.normal,
                              child: Text('Animation: normal'),
                            ),
                            DropdownMenuItem(
                              value: _AnimationIntensity.high,
                              child: Text('Animation: high'),
                            ),
                          ],
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Reduced motion'),
                          value: reducedMotionOverride,
                          onChanged: (value) {
                            setState(() => reducedMotionOverride = value);
                            setLocal(() {});
                          },
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Visualizer'),
                          value: visualizerEnabled,
                          onChanged: (value) {
                            setState(() => visualizerEnabled = value);
                            setLocal(() {});
                          },
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => unawaited(_createStation(track)),
                              icon: const Icon(Icons.radio),
                              label: const Text('Start radio'),
                            ),
                            OutlinedButton.icon(
                              onPressed: upNext.isEmpty
                                  ? null
                                  : () => unawaited(_clearUpcomingQueue()),
                              icon: const Icon(Icons.clear_all),
                              label: const Text('Clear upcoming'),
                            ),
                            OutlinedButton.icon(
                              onPressed: removedQueueUndo.isEmpty
                                  ? null
                                  : () => unawaited(_undoRemoveQueueEntry()),
                              icon: const Icon(Icons.undo),
                              label: const Text('Undo remove'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => unawaited(_shareTrack(track)),
                              icon: const Icon(Icons.share),
                              label: const Text('Share'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  unawaited(_pickPlaylistForTrack(track)),
                              icon: const Icon(Icons.playlist_add),
                              label: const Text('Add to playlist'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => unawaited(_downloadTrack(track)),
                              icon: const Icon(Icons.download),
                              label: const Text('Download'),
                            ),
                            OutlinedButton.icon(
                              onPressed: activeQueue.isEmpty
                                  ? null
                                  : () async {
                                      final name =
                                          'Queue ${DateTime.now().toLocal().toIso8601String().substring(0, 19)}';
                                      final list = MusicPlaylist(
                                        id: const Uuid().v4(),
                                        name: name,
                                        createdAtUtc: DateTime.now().toUtc(),
                                        tracks: activeQueue
                                            .map((e) => e.track)
                                            .toList(),
                                      );
                                      await music.upsertPlaylist(
                                        widget.profileId,
                                        list,
                                      );
                                      playlists = await music.playlists(
                                        widget.profileId,
                                      );
                                      if (mounted) {
                                        setState(
                                          () => status =
                                              'Saved queue as playlist.',
                                        );
                                      }
                                    },
                              icon: const Icon(Icons.playlist_add),
                              label: const Text('Save queue'),
                            ),
                            OutlinedButton.icon(
                              onPressed: activeQueue.isEmpty
                                  ? null
                                  : () =>
                                        unawaited(_saveCurrentAsNamedSession()),
                              icon: const Icon(Icons.bookmark_add_outlined),
                              label: const Text('Save session'),
                            ),
                            OutlinedButton.icon(
                              onPressed: savedQueueSessions.isEmpty
                                  ? null
                                  : () => unawaited(_loadSavedSessionChooser()),
                              icon: const Icon(Icons.history),
                              label: const Text('Load session'),
                            ),
                            OutlinedButton.icon(
                              onPressed: activeQueue.isEmpty
                                  ? null
                                  : () => unawaited(
                                      _createSharedQueueFromCurrent(),
                                    ),
                              icon: const Icon(Icons.group_add_outlined),
                              label: const Text('Share queue'),
                            ),
                            OutlinedButton.icon(
                              onPressed: sharedQueues.isEmpty
                                  ? null
                                  : () => unawaited(_joinSharedQueueChooser()),
                              icon: const Icon(Icons.groups_outlined),
                              label: const Text('Join shared'),
                            ),
                            OutlinedButton.icon(
                              onPressed: activeQueue.isEmpty
                                  ? null
                                  : () => unawaited(
                                      _handoffSessionToAnotherDevice(),
                                    ),
                              icon: const Icon(Icons.send_to_mobile_outlined),
                              label: const Text('Continue on device'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  unawaited(_continueSessionFromCode()),
                              icon: const Icon(Icons.mobile_friendly_outlined),
                              label: const Text('Resume by code'),
                            ),
                            OutlinedButton.icon(
                              onPressed: activeTrack == null
                                  ? null
                                  : () => unawaited(
                                      _feedRecommendationsIfNeeded(),
                                    ),
                              icon: const Icon(Icons.auto_awesome_outlined),
                              label: const Text('Auto recommendations'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => unawaited(
                                _discoverSpeakersAndRegisterDestinations(),
                              ),
                              icon: const Icon(Icons.speaker_group_outlined),
                              label: const Text('Discover speakers'),
                            ),
                            OutlinedButton.icon(
                              onPressed: playbackDestinations.isEmpty
                                  ? null
                                  : () async {
                                      final selectedDestinationId =
                                          playbackDestinations
                                              .firstWhere(
                                                (item) => item.selected,
                                                orElse: () =>
                                                    playbackDestinations.first,
                                              )
                                              .id;
                                      final selectedId = await showDialog<String>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text(
                                            'Playback destination',
                                          ),
                                          content: SizedBox(
                                            width: 420,
                                            child: ListView(
                                              shrinkWrap: true,
                                              children: [
                                                for (final destination
                                                    in playbackDestinations)
                                                  RadioListTile<String>(
                                                    value: destination.id,
                                                    groupValue:
                                                        selectedDestinationId,
                                                    title: Text(
                                                      destination.name,
                                                    ),
                                                    subtitle: Text(
                                                      '${destination.type} • ${destination.host}:${destination.port}',
                                                    ),
                                                    onChanged: (value) =>
                                                        Navigator.pop(
                                                          context,
                                                          value,
                                                        ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('Cancel'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (selectedId == null ||
                                          selectedId.trim().isEmpty) {
                                        return;
                                      }
                                      await _selectPlaybackDestination(
                                        selectedId,
                                      );
                                      if (mounted) {
                                        setLocal(() {});
                                      }
                                    },
                              icon: const Icon(Icons.output_outlined),
                              label: const Text('Select output'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  unawaited(_toggleRemoteControlMode()),
                              icon: Icon(
                                remoteControlMode
                                    ? Icons.settings_remote
                                    : Icons.settings_remote_outlined,
                              ),
                              label: Text(
                                remoteControlMode
                                    ? 'Disable remote mode'
                                    : 'Enable remote mode',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: activeTrack == null
                                  ? null
                                  : () => unawaited(
                                      _saveCurrentGroupListeningSession(),
                                    ),
                              icon: const Icon(Icons.group_add_outlined),
                              label: const Text('Start group listening'),
                            ),
                            OutlinedButton.icon(
                              onPressed: groupSessions.isEmpty
                                  ? null
                                  : () => unawaited(_resumeGroupSession()),
                              icon: const Icon(Icons.group_work_outlined),
                              label: const Text('Resume group session'),
                            ),
                          ],
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

  Future<void> _openImmersiveListeningMode() async {
    final track = activeTrack;
    if (track == null || !mounted) {
      return;
    }
    immersiveSearch.clear();
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog.fullscreen(
        child: StatefulBuilder(
          builder: (context, setLocal) => Scaffold(
            appBar: AppBar(
              title: const Text('Immersive Listening'),
              actions: [
                IconButton(
                  tooltip: 'Sleep timer',
                  onPressed: () => unawaited(
                    showSleepModeSheet(context, profileId: widget.profileId),
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
                IconButton(
                  tooltip: 'Options',
                  onPressed: () => unawaited(_openNowPlayingOptionsMenu()),
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [
                        _vinylDeck(
                          context,
                          activeTrack ?? track,
                          size: 440,
                          includeVisualizer: true,
                          immersive: true,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed: () =>
                                  unawaited(_playPreviousTrackInQueue()),
                              icon: const Icon(Icons.skip_previous, size: 34),
                            ),
                            IconButton(
                              onPressed: () => unawaited(_togglePlayPause()),
                              icon: Icon(
                                playing
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill,
                                size: 58,
                              ),
                            ),
                            IconButton(
                              onPressed: () =>
                                  unawaited(_playNextTrackInQueue()),
                              icon: const Icon(Icons.skip_next, size: 34),
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
                          onChanged:
                              duration.inMilliseconds <= 0 || player == null
                              ? null
                              : (value) => unawaited(
                                  player!.seek(
                                    Duration(milliseconds: value.toInt()),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Queue',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView(
                            children: [
                              for (final item
                                  in activeQueue
                                      .skip(
                                        (activeQueueIndex + 1).clamp(
                                          0,
                                          activeQueue.length,
                                        ),
                                      )
                                      .take(20))
                                ListTile(
                                  dense: true,
                                  title: Text(
                                    item.track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    item.track.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Play next',
                                    onPressed: () => unawaited(
                                      _playTrack(
                                        item.track,
                                        queue: activeQueue,
                                        queueIndex: activeQueue.indexOf(item),
                                      ),
                                    ),
                                    icon: const Icon(Icons.play_arrow),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: immersiveSearch,
                          decoration: const InputDecoration(
                            hintText: 'Search songs to add to queue',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (value) {
                            unawaited(_searchImmersiveSongs(value));
                            setLocal(() {});
                          },
                        ),
                        if (immersiveSearchLoading)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        if (immersiveSearchResults.isNotEmpty)
                          SizedBox(
                            height: 180,
                            child: ListView.builder(
                              itemCount: immersiveSearchResults.length,
                              itemBuilder: (context, index) {
                                final song = immersiveSearchResults[index];
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    song.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Add to queue',
                                    onPressed: () => unawaited(
                                      _addTracksLast([
                                        song,
                                      ], sourceLabel: 'Immersive add'),
                                    ),
                                    icon: const Icon(Icons.add),
                                  ),
                                );
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
        ),
      ),
    );
  }

  Widget _lyricsWidget() {
    if (loadingLyrics) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (timedLyrics.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Synced lyrics',
            style: TextStyle(color: _MusicPaint.onSurface70),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 220,
            child: ListView.builder(
              itemCount: timedLyrics.length,
              itemBuilder: (context, index) {
                final line = timedLyrics[index];
                final text = line['text']?.toString() ?? '';
                final timeMs =
                    int.tryParse(line['timeMs']?.toString() ?? '') ?? 0;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text(
                    _clock(Duration(milliseconds: timeMs)),
                    style: TextStyle(
                      fontSize: 11,
                      color: _MusicPaint.onSurface54,
                    ),
                  ),
                  title: Text(text),
                  onTap: () => unawaited(_seekToLyric(timeMs)),
                );
              },
            ),
          ),
        ],
      );
    }
    if (plainLyrics.trim().isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Lyrics', style: TextStyle(color: _MusicPaint.onSurface70)),
          const SizedBox(height: 6),
          Text(plainLyrics, style: TextStyle(color: _MusicPaint.onSurface70)),
        ],
      );
    }
    return Text(
      'Lyrics unavailable for this track.',
      style: TextStyle(color: _MusicPaint.onSurface60),
    );
  }

  String? _coverArtUrl(MusicTrack track) {
    final nav = client;
    final art = track.coverArtId;
    if (nav == null || art == null || art.trim().isEmpty) {
      return null;
    }
    return nav.coverArtUri(art).toString();
  }

  Widget _coverArt(MusicTrack track, {double radius = 12}) {
    final url = _coverArtUrl(track);
    if (url == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _MusicPaint.blend(_MusicPaint.accent, _MusicPaint.panel, 0.5),
              _MusicPaint.blend(
                _MusicPaint.panel,
                _MusicPaint.overlayOpaque,
                0.65,
              ),
            ],
          ),
        ),
        child: Center(
          child: Icon(Icons.music_note_rounded, color: _MusicPaint.onSurface70),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  Widget _setupView() {
    if (setupServer.text.trim().isEmpty) {
      setupServer.text = config?.baseUrl ?? 'https://';
    }
    if (setupUser.text.trim().isEmpty) {
      setupUser.text = config?.username ?? '';
    }
    if (setupPass.text.trim().isEmpty) {
      setupPass.text = config?.password ?? '';
    }
    bool busy = false;
    String localError = '';
    return StatefulBuilder(
      builder: (context, setLocal) => Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Card(
              color: _MusicPaint.blend(
                _MusicPaint.panel,
                _MusicPaint.overlayOpaque,
                0.58,
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Connect Navidrome',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Sign in once and MILLITOP will sync songs, playlists, favorites, stations, and playback parity across household devices.',
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: setupServer,
                      autocorrect: false,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: 'Navidrome server origin',
                        hintText: 'https://music.yourdomain.com',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: setupUser,
                      enabled: !busy,
                      decoration: const InputDecoration(labelText: 'Username'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: setupPass,
                      enabled: !busy,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                    ),
                    if (localError.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        localError,
                        style: TextStyle(color: _MusicPaint.warning),
                      ),
                    ],
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              setLocal(() {
                                busy = true;
                                localError = '';
                              });
                              try {
                                await _saveSetup(
                                  setupServer.text,
                                  setupUser.text,
                                  setupPass.text,
                                );
                              } catch (e) {
                                setLocal(() {
                                  localError = e.toString().replaceFirst(
                                    'FormatException: ',
                                    '',
                                  );
                                });
                              } finally {
                                setLocal(() => busy = false);
                              }
                            },
                      icon: const Icon(Icons.link),
                      label: Text(busy ? 'Connecting...' : 'Connect music'),
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

  Widget _trackTile(MusicTrack track, {VoidCallback? onTap}) {
    final selected = selectedTrackIds.contains(track.id);
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: SizedBox(
        width: 48,
        height: 48,
        child: _coverArt(track, radius: 8),
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${track.artist} • ${_metadata(track)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (multiSelectMode)
            Checkbox(
              value: selected,
              onChanged: (_) => unawaited(_toggleTrackSelection(track)),
            ),
          if (_hasDownload(track.id))
            Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(
                Icons.download_done_rounded,
                size: 18,
                color: _MusicPaint.accent,
              ),
            ),
          Text(_durationLabel(track.durationSeconds)),
          PopupMenuButton<_TrackAction>(
            tooltip: 'More',
            onSelected: (action) => unawaited(_onTrackAction(track, action)),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _TrackAction.playNow,
                child: Text('Play now'),
              ),
              const PopupMenuItem(
                value: _TrackAction.playNext,
                child: Text('Play next'),
              ),
              const PopupMenuItem(
                value: _TrackAction.playLast,
                child: Text('Play last'),
              ),
              const PopupMenuItem(
                value: _TrackAction.addToQueue,
                child: Text('Add to queue'),
              ),
              const PopupMenuItem(
                value: _TrackAction.share,
                child: Text('Share'),
              ),
              const PopupMenuItem(
                value: _TrackAction.comment,
                child: Text('Comment'),
              ),
              const PopupMenuItem(
                value: _TrackAction.report,
                child: Text('Report'),
              ),
              PopupMenuItem(
                value: _TrackAction.toggleFavorite,
                child: Text(
                  _isFavorite(track.id) ? 'Remove favorite' : 'Add favorite',
                ),
              ),
              const PopupMenuItem(
                value: _TrackAction.startRadio,
                child: Text('Start song radio'),
              ),
              const PopupMenuItem(
                value: _TrackAction.addToPlaylist,
                child: Text('Add to playlist...'),
              ),
              PopupMenuItem(
                value: _TrackAction.download,
                child: Text(
                  _hasDownload(track.id)
                      ? 'Re-download for repair'
                      : 'Download offline',
                ),
              ),
            ],
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      onTap: multiSelectMode
          ? () => unawaited(_toggleTrackSelection(track))
          : onTap ?? () => unawaited(_playTrack(track)),
      onLongPress: () {
        setState(() {
          multiSelectMode = true;
          selectedTrackIds.add(track.id);
        });
        unawaited(HapticFeedback.mediumImpact());
      },
    );
    if (multiSelectMode) {
      return tile;
    }
    return Dismissible(
      key: ValueKey('track-${track.id}-${track.title}'),
      direction: DismissDirection.horizontal,
      background: Container(
        color: _MusicPaint.blend(_MusicPaint.warning, _MusicPaint.accent, 0.55),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Icon(Icons.favorite, color: _MusicPaint.onSurface),
      ),
      secondaryBackground: Container(
        color: _MusicPaint.blend(_MusicPaint.accent, _MusicPaint.panel, 0.35),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Icon(Icons.queue_music, color: _MusicPaint.onSurface),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          final wasFavorite = _isFavorite(track.id);
          await _toggleFavorite(track);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  wasFavorite ? 'Removed favorite' : 'Added favorite',
                ),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () => unawaited(_toggleFavorite(track)),
                ),
              ),
            );
          }
        } else {
          await _playNext(track);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Added to play next'),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () =>
                      unawaited(_removeFirstQueuedTrackById(track.id)),
                ),
              ),
            );
          }
        }
        await HapticFeedback.lightImpact();
        return false;
      },
      child: tile,
    );
  }

  Widget _nowPlayingPanel() {
    final track = activeTrack;
    final upNext = activeQueue.isEmpty
        ? const <_QueueEntry>[]
        : activeQueue
              .skip((activeQueueIndex + 1).clamp(0, activeQueue.length))
              .toList();
    final played = playedQueueHistory.reversed.take(8).toList();
    final panelGradient = track == null
        ? <Color>[
            _MusicPaint.blend(
              _MusicPaint.panel,
              _MusicPaint.overlayOpaque,
              0.8,
            ),
            _MusicPaint.blend(
              _MusicPaint.panel,
              _MusicPaint.overlayOpaque,
              0.8,
            ),
          ]
        : _panelColors(track);
    final titleSize = switch (nowPlayingMode) {
      _NowPlayingMode.drive => 38.0,
      _NowPlayingMode.minimal => 26.0,
      _NowPlayingMode.ipod => 24.0,
      _NowPlayingMode.standard => 30.0,
    };
    final artistSize = switch (nowPlayingMode) {
      _NowPlayingMode.drive => 22.0,
      _NowPlayingMode.minimal => 14.0,
      _NowPlayingMode.ipod => 16.0,
      _NowPlayingMode.standard => 18.0,
    };
    final artHeight = switch (nowPlayingMode) {
      _NowPlayingMode.drive => 300.0,
      _NowPlayingMode.minimal => 210.0,
      _NowPlayingMode.ipod => 240.0,
      _NowPlayingMode.standard => 260.0,
    };
    final minimalMode = nowPlayingMode == _NowPlayingMode.minimal;
    final driveMode = nowPlayingMode == _NowPlayingMode.drive;
    return Container(
      width: 360,
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: panelGradient,
        ),
        border: Border(
          left: BorderSide(
            color: _MusicPaint.blend(
              _MusicPaint.panel,
              _MusicPaint.onSurface,
              0.25,
            ),
          ),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: track == null
            ? Center(
                child: Text(
                  'Start playback to open your now playing panel.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _MusicPaint.onSurface60),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'NOW PLAYING',
                    style: TextStyle(color: _MusicPaint.onSurface60),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            height: artHeight,
                            child: switch (nowPlayingPane) {
                              _NowPlayingPane.vinyl => _vinylDeck(
                                context,
                                track,
                                size: artHeight * 0.95,
                              ),
                              _NowPlayingPane.visualizer => Column(
                                children: [
                                  const Spacer(),
                                  _visualizerWidget(context),
                                  const Spacer(),
                                ],
                              ),
                              _NowPlayingPane.vinylVisualizer => _vinylDeck(
                                context,
                                track,
                                size: artHeight * 0.95,
                                includeVisualizer: true,
                              ),
                              _NowPlayingPane.artworkVisualizer => Stack(
                                fit: StackFit.expand,
                                children: [
                                  _coverArt(track),
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: _visualizerWidget(context),
                                    ),
                                  ),
                                ],
                              ),
                              _NowPlayingPane.lyrics => Container(
                                color: _MusicPaint.overlayOpaque,
                                padding: const EdgeInsets.all(12),
                                child: SingleChildScrollView(
                                  child: _lyricsWidget(),
                                ),
                              ),
                              _NowPlayingPane.artwork => GestureDetector(
                                onTap: () =>
                                    unawaited(_openImmersiveListeningMode()),
                                child: _coverArt(track),
                              ),
                            },
                          ),
                          const SizedBox(height: 10),
                          Text(
                            track.title,
                            style: TextStyle(
                              fontSize: titleSize,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            track.artist,
                            style: TextStyle(
                              color: _MusicPaint.onSurface70,
                              fontSize: artistSize,
                            ),
                          ),
                          if (!minimalMode)
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                TextButton(
                                  onPressed: () =>
                                      unawaited(_openAlbumContext(track)),
                                  child: Text('Album: ${track.album}'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      unawaited(_openArtistContext(track)),
                                  child: Text('Artist: ${track.artist}'),
                                ),
                              ],
                            ),
                          if (!minimalMode) ...[
                            Text(
                              _sourceLabelForTrack(track),
                              style: TextStyle(
                                color: _MusicPaint.onSurface54,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              _outputDeviceLabel(),
                              style: TextStyle(
                                color: _MusicPaint.onSurface54,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              'Download: ${_hasDownload(track.id) ? 'Available offline' : 'Not downloaded'}',
                              style: TextStyle(
                                color: _MusicPaint.onSurface54,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              'Audio: ${_audioFormatLabel(track)}',
                              style: TextStyle(
                                color: _MusicPaint.onSurface54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
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
                            onChanged:
                                duration.inMilliseconds <= 0 || player == null
                                ? null
                                : (value) => unawaited(
                                    player!.seek(
                                      Duration(milliseconds: value.toInt()),
                                    ),
                                  ),
                            onChangeEnd: (_) =>
                                unawaited(_savePlaybackSession()),
                          ),
                          Row(
                            children: [
                              Text(
                                _clock(position),
                                style: const TextStyle(fontSize: 11),
                              ),
                              const Spacer(),
                              Text(
                                _clock(duration),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                IconButton(
                                  onPressed: () =>
                                      unawaited(_playPreviousTrackInQueue()),
                                  icon: Icon(
                                    Icons.skip_previous,
                                    size: driveMode ? 36 : 24,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      unawaited(_togglePlayPause()),
                                  icon: Icon(
                                    playing
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_fill,
                                    size: driveMode ? 54 : 36,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      unawaited(_playNextTrackInQueue()),
                                  icon: Icon(
                                    Icons.skip_next,
                                    size: driveMode ? 36 : 24,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      unawaited(_seekRelative(-10)),
                                  icon: const Icon(Icons.replay_10),
                                ),
                                IconButton(
                                  onPressed: () => unawaited(_seekRelative(10)),
                                  icon: const Icon(Icons.forward_10),
                                ),
                                IconButton(
                                  tooltip: 'Stop playback',
                                  onPressed: () =>
                                      unawaited(_clearQueueAndStop()),
                                  icon: const Icon(Icons.stop_circle_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Favorite',
                                  onPressed: () =>
                                      unawaited(_toggleFavorite(track)),
                                  icon: Icon(
                                    _isFavorite(track.id)
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: 'Now playing actions',
                                  onSelected: (value) async {
                                    switch (value) {
                                      case 'options':
                                        await _openNowPlayingOptionsMenu();
                                        break;
                                      case 'share':
                                        await _shareTrack(track);
                                        break;
                                      case 'playlist':
                                        await _pickPlaylistForTrack(track);
                                        break;
                                      case 'radio':
                                        await _createStation(track);
                                        break;
                                      case 'download':
                                        await _downloadTrack(track);
                                        break;
                                      case 'comment':
                                        await _commentOnTarget(
                                          targetType: 'track',
                                          targetId: track.id,
                                          label: track.title,
                                        );
                                        break;
                                      case 'report':
                                        await _reportTarget(
                                          targetType: 'track',
                                          targetId: track.id,
                                          label: track.title,
                                        );
                                        break;
                                      case 'invite':
                                        await _inviteUserToSharedQueue();
                                        break;
                                      case 'social':
                                        await _openSocialCenter();
                                        break;
                                      case 'sleep30':
                                        await _startSleepTimer(30);
                                        break;
                                      case 'sleep60':
                                        await _startSleepTimer(60);
                                        break;
                                      case 'sleepOff':
                                        await _cancelSleepTimer();
                                        break;
                                    }
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                      value: 'options',
                                      child: Text('Now Playing options'),
                                    ),
                                    PopupMenuDivider(),
                                    PopupMenuItem(
                                      value: 'share',
                                      child: Text('Share track'),
                                    ),
                                    PopupMenuItem(
                                      value: 'playlist',
                                      child: Text('Add to playlist'),
                                    ),
                                    PopupMenuItem(
                                      value: 'radio',
                                      child: Text('Start radio'),
                                    ),
                                    PopupMenuItem(
                                      value: 'download',
                                      child: Text('Download / repair'),
                                    ),
                                    PopupMenuItem(
                                      value: 'comment',
                                      child: Text('Comment'),
                                    ),
                                    PopupMenuItem(
                                      value: 'report',
                                      child: Text('Report'),
                                    ),
                                    PopupMenuItem(
                                      value: 'invite',
                                      child: Text('Invite to shared queue'),
                                    ),
                                    PopupMenuItem(
                                      value: 'social',
                                      child: Text('Open social center'),
                                    ),
                                    PopupMenuDivider(),
                                    PopupMenuItem(
                                      value: 'sleep30',
                                      child: Text('Sleep timer 30 min'),
                                    ),
                                    PopupMenuItem(
                                      value: 'sleep60',
                                      child: Text('Sleep timer 60 min'),
                                    ),
                                    PopupMenuItem(
                                      value: 'sleepOff',
                                      child: Text('Cancel sleep timer'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (nowPlayingMode == _NowPlayingMode.ipod)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Container(
                                height: 84,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(18),
                                  color: _MusicPaint.overlayLight,
                                  border: Border.all(
                                    color: _MusicPaint.onSurface.withAlpha(51),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    IconButton(
                                      onPressed: () => unawaited(
                                        _playPreviousTrackInQueue(),
                                      ),
                                      icon: const Icon(Icons.skip_previous),
                                    ),
                                    IconButton(
                                      onPressed: () =>
                                          unawaited(_togglePlayPause()),
                                      icon: Icon(
                                        playing
                                            ? Icons.pause_circle_filled
                                            : Icons.play_circle_fill,
                                        size: 34,
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () =>
                                          unawaited(_playNextTrackInQueue()),
                                      icon: const Icon(Icons.skip_next),
                                    ),
                                    IconButton(
                                      tooltip: 'Immersive',
                                      onPressed: () => unawaited(
                                        _openImmersiveListeningMode(),
                                      ),
                                      icon: const Icon(Icons.graphic_eq),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ListenableBuilder(
                            listenable: SleepMode.instance,
                            builder: (context, _) {
                              final deadline = SleepMode.instance.deadline;
                              if (deadline == null) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                'Sleep timer: ${_clock(SleepMode.instance.remaining)} remaining',
                                style: TextStyle(
                                  color: _MusicPaint.onSurface60,
                                  fontSize: 11,
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'UP NEXT',
                            style: TextStyle(color: _MusicPaint.onSurface60),
                          ),
                          if (queueContextLabel.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Source context: $queueContextLabel (snapshot retained)',
                                style: TextStyle(
                                  color: _MusicPaint.onSurface54,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          if (shuffleEnabled && stableShuffleOrder.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Shuffle order: ${stableShuffleOrder.take(12).map((item) => item + 1).join(' · ')}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _MusicPaint.accent,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          if (upNext.isEmpty)
                            Text(
                              'Queue is empty.',
                              style: TextStyle(color: _MusicPaint.onSurface60),
                            )
                          else
                            SizedBox(
                              height: 400,
                              child: ReorderableListView.builder(
                                buildDefaultDragHandles: false,
                                padding: const EdgeInsets.only(right: 28),
                                itemCount: upNext.length,
                                onReorderItem: (oldIndex, newIndex) =>
                                    unawaited(
                                      _reorderQueueEntry(
                                        oldIndex + activeQueueIndex + 1,
                                        newIndex + activeQueueIndex + 1,
                                      ),
                                    ),
                                itemBuilder: (context, index) {
                                  final item = upNext[index];
                                  final globalIndex =
                                      index + activeQueueIndex + 1;
                                  final shared = sharedQueues.firstWhere(
                                    (entry) =>
                                        entry['id']?.toString() ==
                                        activeSharedQueueId,
                                    orElse: () => const <String, dynamic>{},
                                  );
                                  final votesRaw = shared['votes'];
                                  final voteScore = votesRaw is Map
                                      ? (int.tryParse(
                                              votesRaw[item.entryId]
                                                      ?.toString() ??
                                                  '0',
                                            ) ??
                                            0)
                                      : 0;
                                  return ListTile(
                                    key: ValueKey(item.entryId),
                                    contentPadding: const EdgeInsets.only(
                                      right: 8,
                                    ),
                                    leading: SizedBox(
                                      width: 42,
                                      height: 42,
                                      child: _coverArt(item.track, radius: 8),
                                    ),
                                    title: Text(
                                      item.track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '${item.track.artist} • ${item.type.name}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (activeSharedQueueId
                                            .trim()
                                            .isNotEmpty) ...[
                                          IconButton(
                                            tooltip: 'Vote up',
                                            onPressed: () => unawaited(
                                              _voteQueueEntry(item, 1),
                                            ),
                                            icon: const Icon(
                                              Icons.thumb_up_alt_outlined,
                                              size: 18,
                                            ),
                                          ),
                                          Text(
                                            '$voteScore',
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Vote down',
                                            onPressed: () => unawaited(
                                              _voteQueueEntry(item, -1),
                                            ),
                                            icon: const Icon(
                                              Icons.thumb_down_alt_outlined,
                                              size: 18,
                                            ),
                                          ),
                                        ],
                                        Text(
                                          _durationLabel(
                                            item.track.durationSeconds,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Remove from queue',
                                          onPressed: () => unawaited(
                                            _removeQueueEntryAt(globalIndex),
                                          ),
                                          icon: const Icon(Icons.close),
                                        ),
                                        ReorderableDragStartListener(
                                          index: index,
                                          child: const Padding(
                                            padding: EdgeInsets.only(left: 8),
                                            child: Icon(Icons.drag_indicator),
                                          ),
                                        ),
                                      ],
                                    ),
                                    onTap: () => unawaited(
                                      _playTrack(
                                        item.track,
                                        queue: activeQueue,
                                        queueIndex: globalIndex,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          if (played.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Text(
                              'PLAYED',
                              style: TextStyle(color: _MusicPaint.onSurface60),
                            ),
                            const SizedBox(height: 6),
                            for (final item in played)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: SizedBox(
                                  width: 30,
                                  height: 30,
                                  child: _coverArt(item.track, radius: 6),
                                ),
                                title: Text(
                                  item.track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  item.track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _centerContent(bool compact) {
    final tracks = query.text.trim().length >= 2
        ? searchResults
        : (librarySongs.isNotEmpty ? librarySongs : _libraryTracks);
    switch (section) {
      case _MusicSection.songs:
        var filtered = tracks;
        switch (songsFilter) {
          case _SongsFilter.favorites:
            filtered = tracks.where((item) => _isFavorite(item.id)).toList();
            break;
          case _SongsFilter.mostPlayed:
            filtered = tracks
                .where((item) => (playCounts[item.id] ?? 0) > 0)
                .toList();
            break;
          case _SongsFilter.all:
            break;
        }
        switch (songsSort) {
          case _SongsSort.artist:
            filtered.sort(
              (a, b) =>
                  a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
            );
            break;
          case _SongsSort.album:
            filtered.sort(
              (a, b) => a.album.toLowerCase().compareTo(b.album.toLowerCase()),
            );
            break;
          case _SongsSort.plays:
            filtered.sort(
              (a, b) =>
                  (playCounts[b.id] ?? 0).compareTo(playCounts[a.id] ?? 0),
            );
            break;
          case _SongsSort.title:
            filtered.sort(
              (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
            );
            break;
        }
        return Column(
          children: [
            Row(
              children: [
                SegmentedButton<_SongsFilter>(
                  segments: const [
                    ButtonSegment(value: _SongsFilter.all, label: Text('All')),
                    ButtonSegment(
                      value: _SongsFilter.favorites,
                      label: Text('Favorites'),
                    ),
                    ButtonSegment(
                      value: _SongsFilter.mostPlayed,
                      label: Text('Most played'),
                    ),
                  ],
                  selected: {songsFilter},
                  onSelectionChanged: (value) =>
                      setState(() => songsFilter = value.first),
                ),
                const Spacer(),
                DropdownButton<_SongsSort>(
                  value: songsSort,
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() => songsSort = value);
                  },
                  items: const [
                    DropdownMenuItem(
                      value: _SongsSort.title,
                      child: Text('Sort: title'),
                    ),
                    DropdownMenuItem(
                      value: _SongsSort.artist,
                      child: Text('Sort: artist'),
                    ),
                    DropdownMenuItem(
                      value: _SongsSort.album,
                      child: Text('Sort: album'),
                    ),
                    DropdownMenuItem(
                      value: _SongsSort.plays,
                      child: Text('Sort: plays'),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: filtered.isEmpty
                      ? null
                      : () => unawaited(_playShuffled(filtered)),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle all'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      multiSelectMode = !multiSelectMode;
                      if (!multiSelectMode) {
                        selectedTrackIds.clear();
                      }
                    });
                  },
                  icon: Icon(
                    multiSelectMode
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                  ),
                  label: Text(multiSelectMode ? 'Selecting' : 'Select'),
                ),
                if (multiSelectMode) ...[
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: selectedTrackIds.isEmpty
                        ? null
                        : () => unawaited(_addSelectedToQueue(filtered)),
                    icon: const Icon(Icons.queue_music),
                    label: const Text('Queue selected'),
                  ),
                ],
              ],
            ),
            if (loadingLibrary)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Loading full library...'),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                key: const PageStorageKey('songs-list'),
                itemCount: filtered.length,
                itemBuilder: (context, index) => _trackTile(
                  filtered[index],
                  onTap: () => unawaited(_playFromList(filtered, index)),
                ),
              ),
            ),
          ],
        );
      case _MusicSection.albums:
        final entries = _albums.entries.toList()
          ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
        return GridView.builder(
          key: const PageStorageKey('albums-grid'),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: compact ? 240 : 280,
            childAspectRatio: 0.9,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final albumTracks = entries[index].value;
            return Card(
              child: InkWell(
                onTap: () => unawaited(_playFromList(albumTracks, 0)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SizedBox(
                          width: double.infinity,
                          child: _coverArt(albumTracks.first),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        entries[index].key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${albumTracks.first.artist} • ${albumTracks.length} songs',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _MusicPaint.onSurface70),
                      ),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () =>
                                unawaited(_playFromList(albumTracks, 0)),
                            child: const Text('Play'),
                          ),
                          TextButton(
                            onPressed: () => unawaited(
                              _addTracksNext(
                                albumTracks,
                                sourceLabel: 'Album: ${entries[index].key}',
                              ),
                            ),
                            child: const Text('Play next'),
                          ),
                          TextButton(
                            onPressed: () =>
                                unawaited(_playShuffled(albumTracks)),
                            child: const Text('Shuffle'),
                          ),
                          IconButton(
                            tooltip: 'Share album',
                            onPressed: () => unawaited(
                              _shareAlbum(entries[index].key, albumTracks),
                            ),
                            icon: const Icon(Icons.share_outlined),
                          ),
                          IconButton(
                            tooltip: pinnedAlbums.contains(entries[index].key)
                                ? 'Unpin album'
                                : 'Pin album',
                            onPressed: () => unawaited(
                              _togglePin(
                                type: 'album',
                                value: entries[index].key,
                              ),
                            ),
                            icon: Icon(
                              pinnedAlbums.contains(entries[index].key)
                                  ? Icons.push_pin
                                  : Icons.push_pin_outlined,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      case _MusicSection.artists:
        final entries = _artists.entries.toList()
          ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
        return ListView(
          key: const PageStorageKey('artists-list'),
          children: [
            for (final entry in entries)
              ListTile(
                leading: CircleAvatar(
                  child: Text(entry.key.substring(0, 1).toUpperCase()),
                ),
                title: Text(entry.key),
                subtitle: Text('${entry.value.length} songs'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Shuffle artist',
                      onPressed: () => unawaited(_playShuffled(entry.value)),
                      icon: const Icon(Icons.shuffle),
                    ),
                    IconButton(
                      tooltip: pinnedArtists.contains(entry.key)
                          ? 'Unpin artist'
                          : 'Pin artist',
                      onPressed: () => unawaited(
                        _togglePin(type: 'artist', value: entry.key),
                      ),
                      icon: Icon(
                        pinnedArtists.contains(entry.key)
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Share artist',
                      onPressed: () =>
                          unawaited(_shareArtist(entry.key, entry.value)),
                      icon: const Icon(Icons.share_outlined),
                    ),
                  ],
                ),
                onTap: () => unawaited(_playFromList(entry.value, 0)),
              ),
          ],
        );
      case _MusicSection.playlists:
        return ListView(
          key: const PageStorageKey('playlists-list'),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: playlistName,
                      decoration: const InputDecoration(
                        hintText: 'Create playlist',
                        prefixIcon: Icon(Icons.playlist_add),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => unawaited(_createPlaylistFromName()),
                    child: const Text('Create'),
                  ),
                ],
              ),
            ),
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('No playlists yet. Create one above.'),
              )
            else
              for (final list in playlists)
                Card(
                  child: ExpansionTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(list.name),
                    subtitle: Text('${list.tracks.length} tracks'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Play playlist',
                          onPressed: list.tracks.isEmpty
                              ? null
                              : () => unawaited(_playFromList(list.tracks, 0)),
                          icon: const Icon(Icons.play_arrow),
                        ),
                        IconButton(
                          tooltip: 'Shuffle playlist',
                          onPressed: list.tracks.isEmpty
                              ? null
                              : () => unawaited(_playShuffled(list.tracks)),
                          icon: const Icon(Icons.shuffle),
                        ),
                        IconButton(
                          tooltip: 'Add playlist next',
                          onPressed: list.tracks.isEmpty
                              ? null
                              : () => unawaited(
                                  _addTracksNext(
                                    list.tracks,
                                    sourceLabel: 'Playlist: ${list.name}',
                                  ),
                                ),
                          icon: const Icon(Icons.queue_play_next_outlined),
                        ),
                        IconButton(
                          tooltip: 'Delete playlist',
                          onPressed: () async {
                            await music.removePlaylist(
                              widget.profileId,
                              list.id,
                            );
                            playlists = await music.playlists(widget.profileId);
                            await _syncProfileState();
                            if (mounted) {
                              setState(() {});
                            }
                          },
                          icon: const Icon(Icons.delete_outline),
                        ),
                        IconButton(
                          tooltip: pinnedPlaylists.contains(list.name)
                              ? 'Unpin playlist'
                              : 'Pin playlist',
                          onPressed: () => unawaited(
                            _togglePin(type: 'playlist', value: list.name),
                          ),
                          icon: Icon(
                            pinnedPlaylists.contains(list.name)
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Playlist actions',
                          onSelected: (value) async {
                            switch (value) {
                              case 'share':
                                await _sharePlaylist(list);
                                break;
                              case 'export':
                                await _exportPlaylist(list);
                                break;
                              case 'public':
                                await _togglePlaylistPublic(list);
                                break;
                              case 'collab':
                                await _configureCollaborativePlaylist(list);
                                break;
                              case 'comment':
                                await _commentOnTarget(
                                  targetType: 'playlist',
                                  targetId: list.id,
                                  label: list.name,
                                );
                                break;
                              case 'report':
                                await _reportTarget(
                                  targetType: 'playlist',
                                  targetId: list.id,
                                  label: list.name,
                                );
                                break;
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'share',
                              child: Text('Share playlist'),
                            ),
                            PopupMenuItem(
                              value: 'export',
                              child: Text('Export playlist (.m3u)'),
                            ),
                            PopupMenuItem(
                              value: 'public',
                              child: Text('Toggle public/private'),
                            ),
                            PopupMenuItem(
                              value: 'collab',
                              child: Text('Collaborative editors'),
                            ),
                            PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'comment',
                              child: Text('Comment'),
                            ),
                            PopupMenuItem(
                              value: 'report',
                              child: Text('Report'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    children: [
                      for (var i = 0; i < list.tracks.length; i++)
                        _trackTile(
                          list.tracks[i],
                          onTap: () => unawaited(_playFromList(list.tracks, i)),
                        ),
                    ],
                  ),
                ),
          ],
        );
      case _MusicSection.favorites:
        return favorites.isEmpty
            ? const Center(
                child: Text('No favorites yet. Tap hearts to save songs.'),
              )
            : ListView.builder(
                key: const PageStorageKey('favorites-list'),
                itemCount: favorites.length,
                itemBuilder: (context, index) => _trackTile(
                  favorites[index],
                  onTap: () => unawaited(_playFromList(favorites, index)),
                ),
              );
      case _MusicSection.radio:
        return ListView(
          key: const PageStorageKey('radio-list'),
          children: [
            if (stations.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'No stations yet. Use "Start song radio" to create one.',
                ),
              ),
            for (final station in stations)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.radio),
                  title: Text(station.name),
                  subtitle: Text(
                    '${station.seedTitle} • ${station.queue.length} tracks',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Shuffle station',
                        onPressed: station.queue.isEmpty
                            ? null
                            : () => unawaited(_playShuffled(station.queue)),
                        icon: const Icon(Icons.shuffle),
                      ),
                      IconButton(
                        onPressed: () => unawaited(_removeStation(station)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  onTap: () => unawaited(_playFromList(station.queue, 0)),
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'Most played',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (mostPlayed.isEmpty)
              const Text('Play songs to build most-played recommendations.')
            else
              for (final item in mostPlayed)
                ListTile(
                  leading: SizedBox(
                    width: 42,
                    height: 42,
                    child: _coverArt(item, radius: 8),
                  ),
                  title: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${item.artist} • ${playCounts[item.id] ?? 0} plays',
                  ),
                  trailing: Text(_durationLabel(item.durationSeconds)),
                  onTap: () => unawaited(_playTrack(item)),
                ),
          ],
        );
      case _MusicSection.home:
        return ListView(
          key: const PageStorageKey('home-list'),
          children: [
            Text(
              'Your music.\nRediscovered.',
              style: TextStyle(
                fontSize: compact ? 34 : 52,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Fresh connections from your own collection.',
              style: TextStyle(color: _MusicPaint.onSurface70),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => unawaited(_openHomeCustomization()),
                  icon: const Icon(Icons.tune),
                  label: const Text('Customize home'),
                ),
                if (homeSectionOrder.contains('pinned'))
                  const Chip(label: Text('Pinned section enabled')),
              ],
            ),
            const SizedBox(height: 14),
            Card(
              color: _MusicPaint.blend(
                _MusicPaint.panel,
                _MusicPaint.overlayOpaque,
                0.62,
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    SizedBox(
                      width: compact ? 100 : 180,
                      height: compact ? 80 : 120,
                      child: picks.isEmpty
                          ? const SizedBox.shrink()
                          : _coverArt(picks.first, radius: 10),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Start with a favorite.',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text('A station built from your library.'),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: picks.isEmpty
                                    ? null
                                    : () => unawaited(
                                        _createStation(picks.first),
                                      ),
                                icon: const Icon(Icons.radio),
                                label: const Text('Start radio'),
                              ),
                              OutlinedButton(
                                onPressed: () =>
                                    _setSection(_MusicSection.songs),
                                child: const Text('Pick a song'),
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
            if (homeSectionOrder.contains('mostPlayed')) ...[
              const SizedBox(height: 14),
              const Text(
                'Made from your library',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 220,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: picks.length.clamp(0, 12),
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) => SizedBox(
                    width: compact ? 170 : 220,
                    child: Card(
                      child: InkWell(
                        onTap: () => unawaited(_playFromList(picks, index)),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SizedBox(
                                  width: double.infinity,
                                  child: _coverArt(picks[index], radius: 10),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                picks[index].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                picks[index].artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _MusicPaint.onSurface70,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (homeSectionOrder.contains('pinned')) ...[
              const SizedBox(height: 12),
              const Text(
                'Pinned',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (pinnedAlbums.isEmpty &&
                  pinnedArtists.isEmpty &&
                  pinnedPlaylists.isEmpty)
                const Text(
                  'Pin albums, artists, or playlists from their lists.',
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final value in pinnedAlbums)
                      ActionChip(
                        label: Text('Album: $value'),
                        onPressed: () =>
                            unawaited(_togglePin(type: 'album', value: value)),
                      ),
                    for (final value in pinnedArtists)
                      ActionChip(
                        label: Text('Artist: $value'),
                        onPressed: () =>
                            unawaited(_togglePin(type: 'artist', value: value)),
                      ),
                    for (final value in pinnedPlaylists)
                      ActionChip(
                        label: Text('Playlist: $value'),
                        onPressed: () => unawaited(
                          _togglePin(type: 'playlist', value: value),
                        ),
                      ),
                  ],
                ),
            ],
            if (homeSectionOrder.contains('recents')) ...[
              const SizedBox(height: 12),
              const Text(
                'Keep listening',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (recent.isEmpty)
                const Text('Nothing in recently played yet.')
              else
                for (var i = 0; i < recent.length && i < 10; i++)
                  _trackTile(
                    recent[i],
                    onTap: () => unawaited(_playFromList(recent, i)),
                  ),
            ],
          ],
        );
    }
  }

  Widget _sidebar(MillitopLayoutPreset preset) {
    final tokens = context.millitopTheme;
    final compactRail = preset == MillitopLayoutPreset.haloSplit;
    Widget navItem(String label, IconData icon, _MusicSection value) {
      final selected = value == section;
      return Tooltip(
        message: label,
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          selected: selected,
          selectedColor: _MusicPaint.onSurface,
          selectedTileColor: tokens.selectedSurface,
          leading: Icon(icon, size: 20),
          title: compactRail ? null : Text(label),
          onTap: () => _setSection(value),
        ),
      );
    }

    return Container(
      width: compactRail ? 92 : 220,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: tokens.softBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: compactRail
                ? const Icon(Icons.multitrack_audio, size: 28)
                : const Text(
                    'navidrome',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_back),
            title: compactRail ? null : const Text('Back to app home'),
            onTap: () => unawaited(_exitToAppHome()),
          ),
          const SizedBox(height: 8),
          navItem('Home', Icons.home_outlined, _MusicSection.home),
          navItem('Discover', Icons.explore_outlined, _MusicSection.songs),
          navItem('Radio', Icons.radio_outlined, _MusicSection.radio),
          const SizedBox(height: 12),
          if (!compactRail)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'LIBRARY',
                style: TextStyle(color: _MusicPaint.onSurface60),
              ),
            ),
          navItem('Songs', Icons.music_note_rounded, _MusicSection.songs),
          navItem('Albums', Icons.album_outlined, _MusicSection.albums),
          navItem('Artists', Icons.person_outline, _MusicSection.artists),
          navItem('Playlists', Icons.queue_music, _MusicSection.playlists),
          navItem('Favorites', Icons.favorite_outline, _MusicSection.favorites),
          const Spacer(),
          ListTile(
            leading: const Icon(Icons.people_alt_outlined),
            title: compactRail ? null : const Text('Social center'),
            onTap: () => unawaited(_openSocialCenter()),
          ),
          ListTile(
            leading: const Icon(Icons.dynamic_feed_outlined),
            title: compactRail ? null : const Text('Activity feed'),
            onTap: () => unawaited(_openFeedPanel()),
          ),
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: compactRail ? null : const Text('Moderation'),
            onTap: () => unawaited(_openModerationPanel()),
          ),
        ],
      ),
    );
  }

  Widget _bottomPlayerBar() {
    final track = activeTrack;
    if (track == null) {
      return const SizedBox.shrink();
    }
    return Container(
      height: 88,
      decoration: BoxDecoration(
        color: _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.overlayOpaque,
          0.6,
        ),
        border: Border(
          top: BorderSide(
            color: _MusicPaint.blend(
              _MusicPaint.panel,
              _MusicPaint.onSurface,
              0.28,
            ),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox(width: 54, height: 54, child: _coverArt(track, radius: 8)),
          const SizedBox(width: 10),
          SizedBox(
            width: (MediaQuery.sizeOf(context).width * 0.12).clamp(
              110.0,
              220.0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _MusicPaint.onSurface70),
                ),
                Text(
                  _sourceLabelForTrack(track),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _MusicPaint.onSurface54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Favorite',
            onPressed: () => unawaited(_toggleFavorite(track)),
            icon: Icon(
              _isFavorite(track.id) ? Icons.favorite : Icons.favorite_border,
            ),
          ),
          IconButton(
            tooltip: shuffleEnabled ? 'Shuffle on' : 'Shuffle off',
            onPressed: _toggleShuffleMode,
            icon: Icon(
              Icons.shuffle,
              color: shuffleEnabled ? _MusicPaint.accent : null,
            ),
          ),
          IconButton(
            tooltip: 'Repeat: ${repeatMode.name}',
            onPressed: _cycleRepeatMode,
            icon: Icon(
              repeatMode == _RepeatMode.one ? Icons.repeat_one : Icons.repeat,
              color: repeatMode == _RepeatMode.off ? null : _MusicPaint.accent,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: () => unawaited(_playPreviousTrackInQueue()),
            icon: const Icon(Icons.skip_previous),
          ),
          IconButton(
            onPressed: () => unawaited(_seekRelative(-10)),
            icon: const Icon(Icons.replay_10),
          ),
          IconButton(
            onPressed: () => unawaited(_togglePlayPause()),
            icon: Icon(
              playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              size: 38,
            ),
          ),
          IconButton(
            onPressed: () => unawaited(_seekRelative(10)),
            icon: const Icon(Icons.forward_10),
          ),
          IconButton(
            onPressed: () => unawaited(_playNextTrackInQueue()),
            icon: const Icon(Icons.skip_next),
          ),
          IconButton(
            tooltip: 'Stop playback',
            onPressed: () => unawaited(_clearQueueAndStop()),
            icon: const Icon(Icons.stop_circle_outlined),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: (MediaQuery.sizeOf(context).width * 0.20).clamp(
              180.0,
              360.0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (trackLoading)
                  const LinearProgressIndicator(minHeight: 2)
                else if (playbackError.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      playbackError,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: _MusicPaint.warning,
                      ),
                    ),
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
                  onChanged: duration.inMilliseconds <= 0 || player == null
                      ? null
                      : (value) => unawaited(
                          player!.seek(Duration(milliseconds: value.toInt())),
                        ),
                  onChangeEnd: (value) => unawaited(_savePlaybackSession()),
                ),
                Row(
                  children: [
                    Text(
                      _clock(position),
                      style: const TextStyle(fontSize: 12),
                    ),
                    const Spacer(),
                    Text(
                      _clock(duration),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          const Icon(Icons.volume_up_rounded),
          SizedBox(
            width: (MediaQuery.sizeOf(context).width * 0.06).clamp(60.0, 120.0),
            child: Slider(
              value: volume.clamp(0, 100),
              min: 0,
              max: 100,
              onChanged: player == null
                  ? null
                  : (value) => unawaited(_setVolume(value)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobilePlayerSheet() {
    final track = activeTrack;
    if (track == null) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      child: Container(
        color: _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.overlayOpaque,
          0.76,
        ),
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 24),
        child: Column(
          children: [
            const SizedBox(height: 8),
            SizedBox(
              width: 280,
              height: 280,
              child: _vinylDeck(
                context,
                track,
                size: 280,
                includeVisualizer: false,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              track.title,
              style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700),
            ),
            Text(
              track.artist,
              style: TextStyle(color: _MusicPaint.onSurface70, fontSize: 22),
            ),
            TextButton(
              onPressed: () => unawaited(_openAlbumContext(track)),
              child: Text(track.album),
            ),
            const SizedBox(height: 4),
            Text(
              _sourceLabelForTrack(track),
              style: TextStyle(color: _MusicPaint.onSurface54, fontSize: 14),
            ),
            Text(
              _outputDeviceLabel(),
              style: TextStyle(color: _MusicPaint.onSurface54, fontSize: 12),
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
              onChanged: duration.inMilliseconds <= 0 || player == null
                  ? null
                  : (value) => unawaited(
                      player!.seek(Duration(milliseconds: value.toInt())),
                    ),
              onChangeEnd: (value) => unawaited(_savePlaybackSession()),
            ),
            Row(
              children: [
                Text(_clock(position), style: const TextStyle(fontSize: 12)),
                const Spacer(),
                Text(_clock(duration), style: const TextStyle(fontSize: 12)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => unawaited(_playPreviousTrackInQueue()),
                  icon: const Icon(Icons.skip_previous, size: 34),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: () => unawaited(_togglePlayPause()),
                  icon: Icon(
                    playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    size: 72,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: () => unawaited(_playNextTrackInQueue()),
                  icon: const Icon(Icons.skip_next, size: 34),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Favorite',
                  onPressed: () => unawaited(_toggleFavorite(track)),
                  icon: Icon(
                    _isFavorite(track.id)
                        ? Icons.favorite
                        : Icons.favorite_border,
                  ),
                ),
                IconButton(
                  onPressed: _toggleShuffleMode,
                  icon: Icon(
                    Icons.shuffle,
                    color: shuffleEnabled ? _MusicPaint.accent : null,
                  ),
                ),
                IconButton(
                  onPressed: _cycleRepeatMode,
                  icon: Icon(
                    repeatMode == _RepeatMode.one
                        ? Icons.repeat_one
                        : Icons.repeat,
                    color: repeatMode == _RepeatMode.off
                        ? null
                        : _MusicPaint.accent,
                  ),
                ),
                PopupMenuButton<String>(
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'share', child: Text('Share')),
                    PopupMenuItem(
                      value: 'playlist',
                      child: Text('Add to playlist'),
                    ),
                    PopupMenuItem(
                      value: 'download',
                      child: Text('Download offline'),
                    ),
                    PopupMenuItem(value: 'comment', child: Text('Comment')),
                    PopupMenuItem(value: 'report', child: Text('Report')),
                    PopupMenuItem(
                      value: 'social',
                      child: Text('Open social center'),
                    ),
                  ],
                  onSelected: (value) async {
                    switch (value) {
                      case 'share':
                        await _shareTrack(track);
                        break;
                      case 'playlist':
                        await _pickPlaylistForTrack(track);
                        break;
                      case 'download':
                        await _downloadTrack(track);
                        break;
                      case 'comment':
                        await _commentOnTarget(
                          targetType: 'track',
                          targetId: track.id,
                          label: track.title,
                        );
                        break;
                      case 'report':
                        await _reportTarget(
                          targetType: 'track',
                          targetId: track.id,
                          label: track.title,
                        );
                        break;
                      case 'social':
                        await _openSocialCenter();
                        break;
                    }
                  },
                ),
              ],
            ),
            if (trackLoading)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (playbackError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  playbackError,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _MusicPaint.warning),
                ),
              ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => unawaited(_createStation(track)),
              icon: const Icon(Icons.radio),
              label: const Text('Start song radio'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => Dialog.fullscreen(
                      child: Scaffold(
                        appBar: AppBar(title: const Text('Lyrics')),
                        body: Padding(
                          padding: const EdgeInsets.all(16),
                          child: SingleChildScrollView(child: _lyricsWidget()),
                        ),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('Lyrics full-screen'),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_startSleepTimer(30)),
                  icon: const Icon(Icons.bedtime_outlined),
                  label: const Text('Sleep 30m'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Queue (${(activeQueue.length - activeQueueIndex - 1).clamp(0, 999)} up next)',
                style: TextStyle(color: _MusicPaint.onSurface70),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 200,
              child: ListView(
                children: [
                  for (final item
                      in activeQueue
                          .skip(
                            (activeQueueIndex + 1).clamp(0, activeQueue.length),
                          )
                          .take(8))
                    ListTile(
                      dense: true,
                      leading: SizedBox(
                        width: 34,
                        height: 34,
                        child: _coverArt(item.track, radius: 6),
                      ),
                      title: Text(
                        item.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => unawaited(
                        _playTrack(
                          item.track,
                          queue: activeQueue,
                          queueIndex: activeQueue.indexOf(item),
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

  Widget _mobileScaffold() {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final bodyPadding = screenWidth >= 700 ? 18.0 : 12.0;
    Widget? playerStrip;
    if (activeTrack != null) {
      playerStrip = Material(
        color: _MusicPaint.blend(
          _MusicPaint.panel,
          _MusicPaint.overlayOpaque,
          0.64,
        ),
        child: ListTile(
          dense: true,
          leading: SizedBox(
            width: 42,
            height: 42,
            child: _coverArt(activeTrack!, radius: 8),
          ),
          title: Text(
            activeTrack!.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            activeTrack!.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: screenWidth < 500
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: playing ? 'Pause' : 'Play',
                      onPressed: () => unawaited(_togglePlayPause()),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                    PopupMenuButton<int>(
                      tooltip: 'Playback actions',
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: -1, child: Text('Previous')),
                        PopupMenuItem(value: 1, child: Text('Next')),
                        PopupMenuItem(value: 0, child: Text('Stop playback')),
                      ],
                      onSelected: (value) {
                        if (value == -1) {
                          unawaited(_playPreviousTrackInQueue());
                        } else if (value == 1) {
                          unawaited(_playNextTrackInQueue());
                        } else {
                          unawaited(_clearQueueAndStop());
                        }
                      },
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Previous',
                      onPressed: () => unawaited(_playPreviousTrackInQueue()),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    IconButton(
                      onPressed: () => unawaited(_togglePlayPause()),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                    IconButton(
                      tooltip: 'Next',
                      onPressed: () => unawaited(_playNextTrackInQueue()),
                      icon: const Icon(Icons.skip_next),
                    ),
                    IconButton(
                      tooltip: 'Stop playback',
                      onPressed: () => unawaited(_clearQueueAndStop()),
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                  ],
                ),
          onTap: () async {
            if (playerSheetOpen) {
              return;
            }
            playerSheetOpen = true;
            await showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => FractionallySizedBox(
                heightFactor: 0.94,
                child: _mobilePlayerSheet(),
              ),
            );
            if (mounted) {
              setState(() => playerSheetOpen = false);
            } else {
              playerSheetOpen = false;
            }
          },
        ),
      );
    }
    return _withKeyboardShortcuts(
      Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back to app home',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => unawaited(_exitToAppHome()),
          ),
          title: const Text('navidrome'),
          actions: [
            IconButton(
              tooltip: 'Sleep timer',
              onPressed: () => unawaited(
                showSleepModeSheet(context, profileId: widget.profileId),
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
            IconButton(
              tooltip: 'Social center',
              onPressed: config == null
                  ? null
                  : () => unawaited(_openSocialCenter()),
              icon: const Icon(Icons.people_alt_outlined),
            ),
            IconButton(
              tooltip: 'Disconnect music profile',
              onPressed: config == null
                  ? null
                  : () {
                      setState(() {
                        config = null;
                        client = null;
                      });
                    },
              icon: const Icon(Icons.person_outline),
            ),
          ],
        ),
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(error),
                  ),
                )
              : config == null
              ? _setupView()
              : Padding(
                  padding: EdgeInsets.all(bodyPadding),
                  child: Column(
                    children: [
                      TextField(
                        controller: query,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search your music',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: PageStorage(
                          bucket: pageStorage,
                          child: _centerContent(true),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        bottomNavigationBar: loading || config == null
            ? null
            : SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (playerStrip != null) playerStrip,
                    BottomNavigationBar(
                      type: BottomNavigationBarType.fixed,
                      showUnselectedLabels: true,
                      currentIndex: [
                        _MusicSection.home,
                        _MusicSection.songs,
                        _MusicSection.radio,
                        _MusicSection.favorites,
                      ].indexOf(section).clamp(0, 3),
                      onTap: (value) {
                        final sections = [
                          _MusicSection.home,
                          _MusicSection.songs,
                          _MusicSection.radio,
                          _MusicSection.favorites,
                        ];
                        _setSection(sections[value]);
                      },
                      items: const [
                        BottomNavigationBarItem(
                          icon: Icon(Icons.home),
                          label: 'Home',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(Icons.explore_outlined),
                          label: 'Discover',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(Icons.radio_outlined),
                          label: 'Radio',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(Icons.favorite_outline),
                          label: 'Library',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 1100;
    final preset = context.millitopTheme.layoutPreset;
    if (compact) {
      return _mobileScaffold();
    }
    final contentPane = Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      child: Column(
        children: [
          TextField(
            controller: query,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search your music',
            ),
          ),
          if (status.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                status,
                style: TextStyle(color: _MusicPaint.onSurface70),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: PageStorage(
              bucket: pageStorage,
              child: _centerContent(false),
            ),
          ),
        ],
      ),
    );

    Widget desktopBody;
    switch (preset) {
      case MillitopLayoutPreset.commandDeck:
        desktopBody = Row(
          children: [
            _nowPlayingPanel(),
            Expanded(child: contentPane),
            _sidebar(preset),
          ],
        );
        break;
      case MillitopLayoutPreset.haloSplit:
        desktopBody = Row(
          children: [
            _sidebar(preset),
            Expanded(
              child: Column(
                children: [
                  SizedBox(height: 300, child: _nowPlayingPanel()),
                  Expanded(child: contentPane),
                ],
              ),
            ),
          ],
        );
        break;
      case MillitopLayoutPreset.emberStack:
        desktopBody = Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _sidebar(preset),
                  Expanded(child: contentPane),
                ],
              ),
            ),
            SizedBox(height: 250, child: _nowPlayingPanel()),
          ],
        );
        break;
      case MillitopLayoutPreset.streamRail:
      case MillitopLayoutPreset.cinematicTopBar:
        desktopBody = Row(
          children: [
            _sidebar(preset),
            Expanded(child: contentPane),
            _nowPlayingPanel(),
          ],
        );
        break;
    }

    return _withKeyboardShortcuts(
      Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      error,
                      style: TextStyle(color: _MusicPaint.warning),
                    ),
                  ),
                )
              : config == null
              ? _setupView()
              : Column(
                  children: [
                    Expanded(child: desktopBody),
                    _bottomPlayerBar(),
                  ],
                ),
        ),
      ),
    );
  }
}
