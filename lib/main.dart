import 'features/millitop_ai/mavae_host.dart';
import 'screens/watch_party_panel.dart';
import 'screens/overnight_window_guard.dart';
import 'services/sleep_mode.dart';
import 'services/home_preferences.dart';
import 'screens/sleep_mode_panel.dart';
import 'screens/home_app_tiles.dart';
import 'screens/app_settings_screen.dart';
import 'screens/customer_account_panel.dart';
import 'services/web_app_catalog.dart';
import 'widgets/launcher_footer.dart';
import 'screens/media_library_home.dart';
import 'screens/playlists_screen.dart';
import 'store/store_job.dart';
import 'services/app_updates.dart';
import 'screens/app_update_overlay.dart';
import 'screens/live_weather_card.dart';
import 'screens/app_store_screen.dart';
import 'services/remote_inbox.dart';
import 'screens/message_inbox.dart';
import 'services/device_connection.dart';
import 'services/live_tv_control.dart';
import 'screens/device_setup_screen.dart';
import 'profiles/profile_gate.dart';
import 'services/pip_playback.dart';
import 'services/music_mini_player.dart';
import 'services/audio_background_service.dart';
import 'services/deep_link_service.dart';
import 'services/platform_shortcuts_service.dart';
import 'services/shared_family_album_service.dart';
import 'screens/music_screen.dart';
import 'screens/podcasts_screen.dart';
import 'services/podcast_playback.dart';
import 'services/sleep_sounds_controller.dart';
import 'widgets/podcast_player_bar.dart';
import 'screens/live_tv_screen.dart';
import 'theme/millitop_visual_theme.dart';
import 'services/app_log.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'package:flutter/material.dart';
import 'widgets/rotating_welcome_message.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

Future<void> main() async {
  // Every uncaught error (framework, platform channel, async zone) lands in
  // the app log with a fix hint, so troubleshooting starts in
  // Settings > Diagnostics instead of guessing.
  await runZonedGuarded(_main, (error, stack) {
    AppLog.error(
      LogCategory.app,
      'Uncaught async error',
      error: error,
      stackTrace: stack,
    );
  });
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.error(
      LogCategory.app,
      'Flutter error${details.library == null ? '' : ' in ${details.library}'}',
      error: details.exception,
      stackTrace: details.stack,
      details: {
        if (details.context != null) 'context': details.context.toString(),
      },
    );
    previousFlutterError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error(
      LogCategory.app,
      'Uncaught platform error',
      error: error,
      stackTrace: stack,
    );
    return true;
  };
  await AppLog.instance.init();
  unawaited(_describeAppForLog());
  AppLog.instance.uploader = _uploadTelemetry;
  final desktopWindowMode =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);
  if (desktopWindowMode) {
    await windowManager.ensureInitialized();
  }

  runApp(const MillitopApp());
  unawaited(DeviceConnection.instance.start());
  unawaited(WebAppCatalog.instance.start());
  unawaited(AppUpdates.instance.start());
  unawaited(initializeAudioBackgroundService());
  unawaited(DeepLinkService.instance.start());
  unawaited(PlatformShortcutsService.instance.start());

  if (desktopWindowMode) {
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'MILLITOP TV',
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        await windowManager.setFullScreen(true);
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  try {
    await RemoteInbox.instance.start();
  } catch (error) {
    debugPrint('Admin inbox initialization failed: $error');
  }
}

Color get background => MillitopThemeController.instance.current.background;
Color get panel => MillitopThemeController.instance.current.surfaceVariant;
Color get accent => MillitopThemeController.instance.current.accent;
Color get muted => MillitopThemeController.instance.current.muted;

class HoverLift extends StatefulWidget {
  final Widget child;
  final double lift;
  final double scale;
  const HoverLift({
    super.key,
    required this.child,
    this.lift = 0.02,
    this.scale = 1.012,
  });

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => hovering = true),
      onExit: (_) => setState(() => hovering = false),
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOutCubic,
        offset: hovering ? Offset(0, -widget.lift) : Offset.zero,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutCubic,
          scale: hovering ? widget.scale : 1,
          child: widget.child,
        ),
      ),
    );
  }
}

Future<void> _describeAppForLog() async {
  try {
    final info = await PackageInfo.fromPlatform();
    AppLog.instance.appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {}
  AppLog.info(
    LogCategory.app,
    'App started',
    details: {
      'version': AppLog.instance.appVersion,
      'platform': AppLog.instance.platform,
    },
  );
}

/// Sends redacted warnings, errors, audit and usage events to the dashboard
/// (opt-out in Settings > Diagnostics). Skipped when the device is not paired.
Future<void> _uploadTelemetry(List<Map<String, Object?>> batch) async {
  final connection = DeviceConnection.instance;
  if (connection.connectionKey.isEmpty || !connection.isConnected) {
    throw StateError('Device not paired');
  }
  await connection.postDevice('/api/device/telemetry', {
    'sessionId': AppLog.instance.sessionId,
    'appVersion': AppLog.instance.appVersion,
    'platform': AppLog.instance.platform,
    'events': batch,
  }, expectedConnection: connection.connectionKey);
}

final AppLogNavigatorObserver appLogNavigatorObserver =
    AppLogNavigatorObserver();

class MillitopApp extends StatefulWidget {
  const MillitopApp({super.key});

  @override
  State<MillitopApp> createState() => _MillitopAppState();
}

class _MillitopAppState extends State<MillitopApp> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MillitopThemeController.instance,
      builder: (context, _) => MaterialApp(
        navigatorKey: overnightNavigatorKey,
        navigatorObservers: [appLogNavigatorObserver],
        title: 'MILLITOP TV',
        debugShowCheckedModeBanner: false,
        builder: (context, child) => Listener(
          onPointerDown: (_) => DeviceConnection.instance.noteInteraction(),
          onPointerHover: (_) => DeviceConnection.instance.noteInteraction(),
          onPointerSignal: (_) => DeviceConnection.instance.noteInteraction(),
          child: OvernightWindowGuard(
            child: WatchPartyOverlay(
              child: AppUpdateOverlay(child: child ?? const SizedBox.shrink()),
            ),
          ),
        ),
        theme: MillitopThemeController.instance.materialTheme,
        home: ProfileGate(
          builder: (profile) => MavaeHost(
            key: ValueKey('mavae-profile-${profile.id}'),
            profileId: profile.id,
            child: Launcher(key: ValueKey(profile.id), profileId: profile.id),
          ),
        ),
      ),
    );
  }
}

class TvButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final bool autofocus;
  final bool selected;
  final double height;
  final Color? iconColor;
  final String? imageAsset;

  const TvButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.autofocus = false,
    this.selected = false,
    this.height = 64,
    this.iconColor,
    this.imageAsset,
  });

  @override
  State<TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<TvButton> {
  bool focused = false;
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.millitopTheme;
    return Semantics(
      button: true,
      label: widget.label,
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (value) {
          setState(() => focused = value);
          if (value) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Scrollable.ensureVisible(
                  context,
                  duration: const Duration(milliseconds: 180),
                );
              }
            });
          }
        },
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }

          DeviceConnection.instance.noteInteraction();
          final key = event.logicalKey;

          final directions = <LogicalKeyboardKey, TraversalDirection>{
            LogicalKeyboardKey.arrowUp: TraversalDirection.up,
            LogicalKeyboardKey.arrowDown: TraversalDirection.down,
            LogicalKeyboardKey.arrowLeft: TraversalDirection.left,
            LogicalKeyboardKey.arrowRight: TraversalDirection.right,
          };

          final direction = directions[key];

          if (direction != null) {
            node.focusInDirection(direction);
            return KeyEventResult.handled;
          }

          if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.select) {
            if (event is KeyDownEvent) {
              widget.onPressed();
            }
            return KeyEventResult.handled;
          }

          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (buttonContext) => MouseRegion(
            onEnter: (_) => setState(() => hovered = true),
            onExit: (_) => setState(() => hovered = false),
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              offset: hovered ? const Offset(0, -0.03) : Offset.zero,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                scale: hovered ? 1.012 : 1,
                child: GestureDetector(
                  onTap: () {
                    Focus.of(buttonContext).requestFocus();
                    widget.onPressed();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: widget.height,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: focused
                          ? tokens.selectedSurface
                          : widget.selected
                          ? tokens.panelColor.withAlpha(222)
                          : panel,
                      borderRadius: BorderRadius.circular(tokens.buttonRadius),
                      border: Border.all(
                        color: (focused || hovered)
                            ? tokens.accentColor
                            : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: (focused || hovered)
                          ? [
                              BoxShadow(
                                color: tokens.accentColor.withAlpha(34),
                                blurRadius: 20,
                              ),
                            ]
                          : [],
                    ),
                    child: widget.height > 110
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (widget.icon != null) ...[
                                widget.imageAsset == null
                                    ? Icon(
                                        widget.icon,
                                        size: 48,
                                        color:
                                            widget.iconColor ??
                                            tokens.accentColor,
                                      )
                                    : Image.asset(
                                        widget.imageAsset!,
                                        width: 58,
                                        height: 58,
                                        fit: BoxFit.contain,
                                        filterQuality: FilterQuality.high,
                                        errorBuilder: (context, error, stack) =>
                                            Icon(
                                              widget.icon,
                                              size: 48,
                                              color:
                                                  widget.iconColor ??
                                                  tokens.accentColor,
                                            ),
                                      ),
                                const SizedBox(height: 18),
                              ],
                              Text(
                                widget.label,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (widget.icon != null) ...[
                                Icon(
                                  widget.icon,
                                  color: widget.iconColor ?? tokens.accentColor,
                                ),
                                const SizedBox(width: 10),
                              ],
                              Flexible(
                                child: Text(
                                  widget.label,
                                  style: const TextStyle(fontSize: 19),
                                  overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}

class Launcher extends StatefulWidget {
  final int profileId;

  const Launcher({super.key, required this.profileId});

  @override
  State<Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<Launcher>
    with SingleTickerProviderStateMixin {
  static const bool _sharedFamilyAlbumEnabled = false;
  final pages = ['Home', 'Playlists', 'DVR', 'Account', 'Updates'];
  final liveTvControl = LiveTvControlService();
  int page = 0;
  DateTime now = DateTime.now();
  Timer? clock;
  Timer? serviceAccessPoll;
  late final AnimationController musicMiniSpinController;
  bool serviceLocked = false;
  String serviceLockReason = '';
  Offset pipMiniPlayerOffset = const Offset(0, 0);
  StreamSubscription<String>? shortcutSub;
  StreamSubscription<DeepLinkAction>? deepLinkSub;
  Timer? welcomeFadeTimer;
  Timer? welcomeRemoveTimer;
  bool showWelcomeSplash = true;
  bool welcomeVisible = true;
  int welcomeSayingIndex = RotatingWelcomeMessage.nextInitialIndex();
  bool showLoginActionOverlay = false;
  bool showMusicMiniQueuePanel = false;
  int _handledSleepPromptId = 0;
  bool _sleepPromptVisible = false;
  final TextEditingController musicMiniSearch = TextEditingController();
  DateTime? loginPromptSnoozeUntilUtc;
  bool loginOverlayDismissed = false;
  SharedFamilyAlbumSettings sharedFamilyAlbumSettings =
      const SharedFamilyAlbumSettings();
  List<SharedFamilyAsset> sharedFamilyAssets = const [];
  int sharedFamilyIndex = 0;
  bool sharedFamilyPlaying = true;
  bool sharedFamilyVideoMuted = true;
  String? sharedFamilyStatus;
  Timer? sharedFamilyTimer;
  Player? sharedFamilyPlayer;
  VideoController? sharedFamilyVideoController;
  final List<StreamSubscription<dynamic>> sharedFamilySubscriptions = [];
  Future<void> _loadHomePreferences() async {
    try {
      final prefs = HomePreferences();
      await prefs.setLastActiveProfileId(widget.profileId);
      AppLog.instance.profileId = widget.profileId;
      AppLog.audit('Profile opened', details: {'profileId': widget.profileId});
      final savedThemeId = MillitopThemeController.fromStorage(
        await prefs.visualTheme(widget.profileId),
      );
      loginPromptSnoozeUntilUtc = await prefs.launcherPromptSnoozeUntil(
        widget.profileId,
      );
      if (_sharedFamilyAlbumEnabled) {
        sharedFamilyAlbumSettings = await prefs.sharedFamilyAlbumSettings(
          widget.profileId,
        );
      }
      MillitopThemeController.instance.setTheme(savedThemeId);
      if (_sharedFamilyAlbumEnabled) {
        await _refreshSharedFamilyAssets();
      } else {
        sharedFamilyAssets = const [];
        sharedFamilyStatus = null;
      }
      if (mounted) {
        setState(() {});
        _evaluateLoginActionOverlay();
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    musicMiniSpinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
    MusicMiniPlayerService.instance.addListener(_onMusicMiniStateChanged);
    unawaited(_loadHomePreferences());
    DeviceConnection.instance.status.addListener(_onConnectionStatusChanged);
    unawaited(_refreshServiceAccess());
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => now = DateTime.now());
    });
    serviceAccessPoll = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(_refreshServiceAccess());
    });
    shortcutSub = PlatformShortcutsService.instance.actions.listen(
      _handleShortcutAction,
    );
    SleepMode.instance.addListener(_onSleepModeChanged);
    deepLinkSub = DeepLinkService.instance.actions.listen(
      _handleDeepLinkAction,
    );
    RemoteInbox.instance.notices.addListener(_onInboxUpdated);
    welcomeFadeTimer = Timer(const Duration(milliseconds: 1650), () {
      if (mounted) {
        setState(() => welcomeVisible = false);
      }
    });
    welcomeRemoveTimer = Timer(const Duration(milliseconds: 2350), () {
      if (mounted) {
        setState(() => showWelcomeSplash = false);
        _evaluateLoginActionOverlay();
      }
    });
  }

  @override
  void didUpdateWidget(covariant Launcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileId != widget.profileId) {
      welcomeSayingIndex = RotatingWelcomeMessage.nextInitialIndex();
      unawaited(_loadHomePreferences());
    }
  }

  @override
  void dispose() {
    if (PodcastPlayback.instance.profileId == widget.profileId) {
      unawaited(
        PodcastPlayback.instance.stop().catchError((Object error) {
          debugPrint('Could not stop podcasts when leaving profile: $error');
        }),
      );
    }
    MusicMiniPlayerService.instance.removeListener(_onMusicMiniStateChanged);
    musicMiniSpinController.dispose();
    musicMiniSearch.dispose();
    clock?.cancel();
    serviceAccessPoll?.cancel();
    welcomeFadeTimer?.cancel();
    welcomeRemoveTimer?.cancel();
    sharedFamilyTimer?.cancel();
    for (final sub in sharedFamilySubscriptions) {
      unawaited(sub.cancel());
    }
    sharedFamilySubscriptions.clear();
    unawaited(sharedFamilyPlayer?.dispose());
    unawaited(shortcutSub?.cancel());
    unawaited(deepLinkSub?.cancel());
    RemoteInbox.instance.notices.removeListener(_onInboxUpdated);
    DeviceConnection.instance.status.removeListener(_onConnectionStatusChanged);
    SleepMode.instance.removeListener(_onSleepModeChanged);
    super.dispose();
  }

  Future<void> _onSleepModeChanged() async {
    if (!mounted || _sleepPromptVisible) {
      return;
    }
    final sleep = SleepMode.instance;
    if (sleep.countdownPromptId <= _handledSleepPromptId ||
        sleep.deadline == null) {
      return;
    }
    _handledSleepPromptId = sleep.countdownPromptId;
    _sleepPromptVisible = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Viewing timer ending soon'),
          content: ListenableBuilder(
            listenable: sleep,
            builder: (_, __) {
              final seconds = sleep.remaining.inSeconds.clamp(0, 30);
              final end = sleep.deadline;
              final endText = end == null
                  ? ''
                  : ' Ends at ${TimeOfDay.fromDateTime(end.toLocal()).format(ctx)}.';
              return Text(
                seconds > 0
                    ? 'Your session ends in $seconds second${seconds == 1 ? '' : 's'}.$endText'
                    : 'Your timer is ending now.$endText',
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                try {
                  sleep.extend(5);
                  Navigator.of(ctx).pop();
                } catch (error) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              },
              child: const Text('+5 min'),
            ),
            TextButton(
              onPressed: () {
                try {
                  sleep.extend(15);
                  Navigator.of(ctx).pop();
                } catch (error) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              },
              child: const Text('+15 min'),
            ),
            TextButton(
              onPressed: () {
                try {
                  sleep.extend(30);
                  Navigator.of(ctx).pop();
                } catch (error) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              },
              child: const Text('+30 min'),
            ),
            FilledButton(
              onPressed: () {
                sleep.cancelTimer();
                Navigator.of(ctx).pop();
              },
              child: const Text('Cancel timer'),
            ),
          ],
        ),
      );
    } finally {
      _sleepPromptVisible = false;
    }
  }

  void _onMusicMiniStateChanged() {
    final mini = MusicMiniPlayerService.instance;
    if (mini.playing) {
      if (!musicMiniSpinController.isAnimating) {
        musicMiniSpinController.repeat();
      }
    } else {
      musicMiniSpinController.stop();
    }
    if (!mini.visible && showMusicMiniQueuePanel && mounted) {
      setState(() => showMusicMiniQueuePanel = false);
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openMusicFromMiniPlayer() async {
    MusicMiniPlayerService.instance.hideMini();
    if (mounted) {
      setState(() => showMusicMiniQueuePanel = false);
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MusicScreen(profileId: widget.profileId),
      ),
    );
  }

  Map<String, String>? _sharedFamilyHeadersForUrl(String url) {
    final parsed = Uri.tryParse(url);
    final path = parsed?.path.toLowerCase() ?? '';
    if (path.contains('/api/immich/assets/')) {
      return null;
    }
    return {'x-api-key': sharedFamilyAlbumSettings.apiKey.trim()};
  }

  SharedFamilyAsset? get _activeSharedFamilyAsset =>
      sharedFamilyAssets.isEmpty ? null : sharedFamilyAssets[sharedFamilyIndex];

  Future<void> _ensureSharedFamilyPlayer() async {
    if (sharedFamilyPlayer != null) {
      return;
    }
    MediaKit.ensureInitialized();
    final created = Player();
    final controller = VideoController(created);
    sharedFamilyPlayer = created;
    sharedFamilyVideoController = controller;
    sharedFamilySubscriptions.add(
      created.stream.completed.listen((done) {
        if (done) {
          unawaited(_advanceSharedFamily(next: true));
        }
      }),
    );
    sharedFamilySubscriptions.add(
      created.stream.error.listen((message) {
        if (!mounted) {
          return;
        }
        setState(
          () => sharedFamilyStatus =
              'Video could not play. Moving to the next item.',
        );
        unawaited(_advanceSharedFamily(next: true));
      }),
    );
  }

  void _scheduleSharedFamilyAdvance() {
    sharedFamilyTimer?.cancel();
    if (!sharedFamilyPlaying) {
      return;
    }
    final active = _activeSharedFamilyAsset;
    if (active == null || active.isVideo) {
      return;
    }
    sharedFamilyTimer = Timer(
      Duration(seconds: sharedFamilyAlbumSettings.seconds),
      () => unawaited(_advanceSharedFamily(next: true)),
    );
  }

  Future<void> _openSharedFamilyVideo(SharedFamilyAsset asset) async {
    await _ensureSharedFamilyPlayer();
    final player = sharedFamilyPlayer;
    if (player == null) {
      return;
    }
    await player.setVolume(sharedFamilyVideoMuted ? 0 : 100);
    await player.open(
      Media(
        asset.playbackUrl,
        httpHeaders: _sharedFamilyHeadersForUrl(asset.playbackUrl),
      ),
    );
    if (!sharedFamilyPlaying) {
      await player.pause();
    }
  }

  Future<void> _prepareSharedFamilyActive() async {
    final active = _activeSharedFamilyAsset;
    sharedFamilyTimer?.cancel();
    if (active == null) {
      return;
    }
    if (active.isVideo) {
      await _openSharedFamilyVideo(active);
      return;
    }
    if (sharedFamilyPlayer != null) {
      await sharedFamilyPlayer!.stop();
    }
    _scheduleSharedFamilyAdvance();
    final nextIndex = sharedFamilyAssets.length <= 1
        ? -1
        : (sharedFamilyIndex + 1) % sharedFamilyAssets.length;
    if (!mounted || nextIndex < 0) {
      return;
    }
    final next = sharedFamilyAssets[nextIndex];
    if (!next.isVideo) {
      unawaited(
        precacheImage(
          NetworkImage(
            next.thumbnailUrl,
            headers: _sharedFamilyHeadersForUrl(next.thumbnailUrl),
          ),
          context,
        ),
      );
    }
  }

  Future<void> _advanceSharedFamily({required bool next}) async {
    if (sharedFamilyAssets.length <= 1) {
      return;
    }
    final delta = next ? 1 : -1;
    setState(() {
      sharedFamilyIndex =
          (sharedFamilyIndex + delta + sharedFamilyAssets.length) %
          sharedFamilyAssets.length;
      sharedFamilyStatus = null;
    });
    await _prepareSharedFamilyActive();
  }

  Future<void> _toggleSharedFamilyPlayPause() async {
    final active = _activeSharedFamilyAsset;
    if (active == null) {
      return;
    }
    setState(() => sharedFamilyPlaying = !sharedFamilyPlaying);
    if (active.isVideo) {
      final player = sharedFamilyPlayer;
      if (player == null) {
        return;
      }
      if (sharedFamilyPlaying) {
        await player.play();
      } else {
        await player.pause();
      }
      return;
    }
    _scheduleSharedFamilyAdvance();
  }

  Future<void> _toggleSharedFamilySound() async {
    final player = sharedFamilyPlayer;
    if (player == null) {
      return;
    }
    setState(() => sharedFamilyVideoMuted = !sharedFamilyVideoMuted);
    await player.setVolume(sharedFamilyVideoMuted ? 0 : 100);
  }

  Future<void> _refreshSharedFamilyAssets() async {
    sharedFamilyTimer?.cancel();
    if (!sharedFamilyAlbumSettings.isConfigured) {
      if (sharedFamilyPlayer != null) {
        await sharedFamilyPlayer!.stop();
      }
      if (mounted) {
        setState(() {
          sharedFamilyAssets = const [];
          sharedFamilyIndex = 0;
          sharedFamilyStatus = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() => sharedFamilyStatus = 'Loading Family slideshow...');
    }
    try {
      final loaded = await const SharedFamilyAlbumService().assets(
        proxyUrl: sharedFamilyAlbumSettings.proxyUrl,
        host: sharedFamilyAlbumSettings.serverUrl,
        apiKey: sharedFamilyAlbumSettings.apiKey,
        albumIds: sharedFamilyAlbumSettings.albumIds,
      );
      if (!mounted) {
        return;
      }
      if (loaded.isEmpty) {
        setState(() {
          sharedFamilyAssets = const [];
          sharedFamilyIndex = 0;
          sharedFamilyStatus =
              'No photos/videos found in the selected Immich album.';
        });
        return;
      }
      final ordered = List<SharedFamilyAsset>.from(loaded);
      if (sharedFamilyAlbumSettings.shuffle) {
        ordered.shuffle();
      }
      setState(() {
        sharedFamilyAssets = ordered;
        sharedFamilyIndex = 0;
        sharedFamilyPlaying = true;
        sharedFamilyVideoMuted = true;
        sharedFamilyStatus = null;
      });
      await _prepareSharedFamilyActive();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(
        () => sharedFamilyStatus =
            'Could not load Family slideshow. Check Immich host/key/album.',
      );
    }
  }

  Future<void> _openSharedFamilyFullscreen() async {
    final active = _activeSharedFamilyAsset;
    if (active == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: active.isVideo
                  ? (sharedFamilyVideoController == null
                        ? const Center(child: CircularProgressIndicator())
                        : Video(
                            controller: sharedFamilyVideoController!,
                            controls: NoVideoControls,
                          ))
                  : InteractiveViewer(
                      child: Center(
                        child: Image.network(
                          active.originalUrl,
                          headers: _sharedFamilyHeadersForUrl(
                            active.originalUrl,
                          ),
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
            ),
            Positioned(
              right: 16,
              top: 16,
              child: IconButton.filled(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onInboxUpdated() {
    if (!mounted) {
      return;
    }
    _evaluateLoginActionOverlay();
  }

  bool get _hasUnreadInboxMessage =>
      RemoteInbox.instance.notices.value.any((message) => !message.opened);

  bool get _hasBillingPrompt {
    if (serviceLocked) {
      return true;
    }
    final reason = serviceLockReason.toLowerCase();
    return reason.contains('balance') ||
        reason.contains('billing') ||
        reason.contains('payment') ||
        reason.contains('due');
  }

  bool get _isPromptSnoozed =>
      loginPromptSnoozeUntilUtc != null &&
      loginPromptSnoozeUntilUtc!.isAfter(DateTime.now().toUtc());

  void _evaluateLoginActionOverlay() {
    if (!mounted || showWelcomeSplash) {
      return;
    }
    final shouldShow =
        !loginOverlayDismissed &&
        !_isPromptSnoozed &&
        (_hasUnreadInboxMessage || _hasBillingPrompt);
    if (shouldShow == showLoginActionOverlay) {
      return;
    }
    setState(() => showLoginActionOverlay = shouldShow);
  }

  void _handleShortcutAction(String action) {
    if (!mounted) {
      return;
    }
    switch (action) {
      case 'open_music':
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => MusicScreen(profileId: widget.profileId),
            ),
          ),
        );
        break;
      case 'open_live_tv':
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => LiveTvScreen(profileId: widget.profileId),
            ),
          ),
        );
        break;
      case 'resume_playback':
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => MusicScreen(profileId: widget.profileId),
            ),
          ),
        );
        break;
    }
  }

  void _handleDeepLinkAction(DeepLinkAction action) {
    if (!mounted) {
      return;
    }
    switch (action.route) {
      case 'music':
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => MusicScreen(
                profileId: widget.profileId,
                initialSection: action.query['section'],
                initialQuery: action.query['query'],
              ),
            ),
          ),
        );
        break;
      case 'livetv':
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => LiveTvScreen(profileId: widget.profileId),
            ),
          ),
        );
        break;
      case 'home':
      default:
        setState(() => page = 0);
        break;
    }
  }

  void _onConnectionStatusChanged() {
    unawaited(_refreshServiceAccess());
  }

  Future<void> _refreshServiceAccess() async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      if (mounted) {
        setState(() {
          serviceLocked = false;
          serviceLockReason = '';
        });
        _evaluateLoginActionOverlay();
      }
      return;
    }
    try {
      final response = await liveTvControl.serviceAccess(
        expectedConnection: connection,
        profileId: widget.profileId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        serviceLocked = response['locked'] == true;
        serviceLockReason = response['reason']?.toString().trim() ?? '';
      });
      _evaluateLoginActionOverlay();
    } catch (_) {}
  }

  Future<void> _refreshHomeFromPullDown() async {
    final connection = DeviceConnection.instance;
    await connection.checkNow();
    await AppUpdates.instance.check();
    await _refreshServiceAccess();
    if (!mounted) {
      return;
    }
    setState(() {
      now = DateTime.now();
    });
  }

  String get time {
    final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final minute = now.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${now.hour >= 12 ? "PM" : "AM"}';
  }

  String get date {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}';
  }

  String get greeting {
    if (now.hour < 12) return 'Good morning';
    if (now.hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  Future<void> notice(String title, String message) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: Text(message, style: const TextStyle(fontSize: 20)),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget card(Widget child) {
    return HoverLift(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withAlpha(12)),
        ),
        child: child,
      ),
    );
  }

  Widget heading(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: TextStyle(fontSize: 19, color: muted)),
        ],
      ),
    );
  }

  Widget _welcomeOverlayContent(String profileName) {
    final salutation = profileName.isEmpty
        ? 'Welcome back'
        : 'Welcome back, $profileName';
    return AnimatedOpacity(
      opacity: welcomeVisible ? 1 : 0,
      duration: const Duration(milliseconds: 620),
      curve: Curves.easeOutCubic,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              MillitopThemeController.instance.current.surface.withAlpha(238),
              panel.withAlpha(222),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.waving_hand_rounded, size: 64, color: accent),
              const SizedBox(height: 14),
              Text(
                salutation,
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                welcomeSayings[welcomeSayingIndex],
                style: TextStyle(fontSize: 22, color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _welcomeOverlay(String profileName) {
    return AbsorbPointer(
      absorbing: true,
      child: _welcomeOverlayContent(profileName),
    );
  }

  Widget _sharedFamilyCard({required bool compact}) {
    final active = _activeSharedFamilyAsset;
    final statusText = sharedFamilyStatus;
    final controlsEnabled = active != null && sharedFamilyAssets.length > 1;
    return card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sharedFamilyAlbumSettings.albumLabel.isEmpty
                ? 'Family Slideshow'
                : sharedFamilyAlbumSettings.albumLabel,
            style: TextStyle(
              fontSize: compact ? 18 : 21,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Colors.black),
                child: active == null
                    ? Center(
                        child: Text(
                          statusText ??
                              'Set Immich host, API key, and album in Settings.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: muted),
                        ),
                      )
                    : Stack(
                        children: [
                          Positioned.fill(
                            child: active.isVideo
                                ? (sharedFamilyVideoController == null
                                      ? const Center(
                                          child: CircularProgressIndicator(),
                                        )
                                      : Video(
                                          controller:
                                              sharedFamilyVideoController!,
                                          controls: NoVideoControls,
                                        ))
                                : Image.network(
                                    active.thumbnailUrl,
                                    fit: BoxFit.cover,
                                    headers: _sharedFamilyHeadersForUrl(
                                      active.thumbnailUrl,
                                    ),
                                    errorBuilder: (_, __, ___) => Center(
                                      child: Text(
                                        'Image unavailable',
                                        style: TextStyle(color: muted),
                                      ),
                                    ),
                                  ),
                          ),
                          if (active.isVideo && sharedFamilyVideoMuted)
                            Positioned(
                              right: 10,
                              bottom: 10,
                              child: FilledButton.icon(
                                onPressed: _toggleSharedFamilySound,
                                icon: const Icon(Icons.volume_up),
                                label: const Text('Play with sound'),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            statusText ??
                (active == null
                    ? 'Not configured.'
                    : '${active.type} • ${active.filename}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton(
                onPressed: controlsEnabled
                    ? () => unawaited(_advanceSharedFamily(next: false))
                    : null,
                icon: const Icon(Icons.skip_previous),
                tooltip: 'Previous',
              ),
              IconButton.filled(
                onPressed: active == null
                    ? null
                    : () => unawaited(_toggleSharedFamilyPlayPause()),
                icon: Icon(
                  sharedFamilyPlaying ? Icons.pause : Icons.play_arrow,
                ),
                tooltip: sharedFamilyPlaying ? 'Pause' : 'Play',
              ),
              IconButton(
                onPressed: controlsEnabled
                    ? () => unawaited(_advanceSharedFamily(next: true))
                    : null,
                icon: const Icon(Icons.skip_next),
                tooltip: 'Next',
              ),
              IconButton(
                onPressed: active == null
                    ? null
                    : () => unawaited(_refreshSharedFamilyAssets()),
                icon: const Icon(Icons.shuffle),
                tooltip: 'Shuffle now',
              ),
              IconButton(
                onPressed: active == null
                    ? null
                    : () => unawaited(_toggleSharedFamilySound()),
                icon: Icon(
                  sharedFamilyVideoMuted ? Icons.volume_off : Icons.volume_up,
                ),
                tooltip: 'Toggle sound',
              ),
              IconButton(
                onPressed: active == null
                    ? null
                    : () => unawaited(_openSharedFamilyFullscreen()),
                icon: const Icon(Icons.fullscreen),
                tooltip: 'Fullscreen',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget home() {
    final compact = MediaQuery.sizeOf(context).width < 1000;
    final preset = context.millitopTheme.layoutPreset;
    final profileName =
        SelectedProfileScope.maybeOf(context)?.profile.name.trim() ?? '';
    final greetingWithName = profileName.isEmpty
        ? greeting
        : '$greeting, $profileName';
    Widget welcomeMessage() => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        height: compact ? 38 : 42,
        child: RotatingWelcomeMessage(
          initialIndex: welcomeSayingIndex,
          style: TextStyle(fontSize: compact ? 15 : 18, color: muted),
        ),
      ),
    );
    final hero = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                greetingWithName,
                style: TextStyle(fontSize: 22, color: muted),
              ),
              welcomeMessage(),
              const SizedBox(height: 6),
              Text(
                time,
                style: const TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w300,
                ),
              ),
              Text(date, style: TextStyle(fontSize: 16, color: muted)),
              const SizedBox(height: 16),
              card(LiveWeatherCard(profileId: widget.profileId)),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: switch (preset) {
              MillitopLayoutPreset.haloSplit => [
                Expanded(
                  child: card(LiveWeatherCard(profileId: widget.profileId)),
                ),
                const SizedBox(width: 28),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        greetingWithName,
                        style: TextStyle(fontSize: 28, color: muted),
                      ),
                      welcomeMessage(),
                      const SizedBox(height: 6),
                      Text(
                        time,
                        style: const TextStyle(
                          fontSize: 64,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      Text(date, style: TextStyle(fontSize: 21, color: muted)),
                    ],
                  ),
                ),
              ],
              _ => [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        greetingWithName,
                        style: TextStyle(fontSize: 28, color: muted),
                      ),
                      welcomeMessage(),
                      const SizedBox(height: 6),
                      Text(
                        time,
                        style: const TextStyle(
                          fontSize: 64,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      Text(date, style: TextStyle(fontSize: 21, color: muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(
                  child: card(LiveWeatherCard(profileId: widget.profileId)),
                ),
              ],
            },
          );

    final infoBlocks = compact
        ? <Widget>[
            // Family Album temporarily disabled.
            if (_sharedFamilyAlbumEnabled) _sharedFamilyCard(compact: true),
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'From your support team',
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 10),
                  ValueListenableBuilder<List<RemoteNotice>>(
                    valueListenable: RemoteInbox.instance.notices,
                    builder: (context, messages, _) => Text(
                      messages.isEmpty
                          ? 'No admin messages received yet.'
                          : '${messages.where((m) => !m.opened).length} unread - ${messages.first.title}',
                      style: TextStyle(
                        fontSize: 15,
                        color: muted,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TvButton(
                    label: 'View messages',
                    icon: Icons.campaign_outlined,
                    onPressed: () => setState(() => page = 4),
                  ),
                ],
              ),
            ),
          ]
        : <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Family Album temporarily disabled.
                if (_sharedFamilyAlbumEnabled) ...[
                  Expanded(flex: 4, child: _sharedFamilyCard(compact: false)),
                  const SizedBox(width: 18),
                ],
                Expanded(
                  flex: _sharedFamilyAlbumEnabled ? 3 : 1,
                  child: card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'From your support team',
                          style: TextStyle(fontSize: 21),
                        ),
                        const SizedBox(height: 10),
                        ValueListenableBuilder<List<RemoteNotice>>(
                          valueListenable: RemoteInbox.instance.notices,
                          builder: (context, messages, _) => Text(
                            messages.isEmpty
                                ? 'No admin messages received yet.'
                                : '${messages.where((m) => !m.opened).length} unread - ${messages.first.title}',
                            style: TextStyle(
                              fontSize: 18,
                              color: muted,
                              height: 1.4,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TvButton(
                          label: 'View messages',
                          icon: Icons.campaign_outlined,
                          onPressed: () => setState(() => page = 4),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ];

    final actionButtons = compact
        ? <Widget>[
            TvButton(
              label: 'Support Assist',
              icon: Icons.support_agent,
              onPressed: support,
            ),
            const SizedBox(height: 12),
            TvButton(
              label: 'App Store',
              icon: Icons.apps,
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => AppStoreScreen(profileId: widget.profileId),
                ),
              ),
            ),
          ]
        : <Widget>[
            Row(
              children: [
                Expanded(
                  child: TvButton(
                    label: 'Support Assist',
                    icon: Icons.support_agent,
                    onPressed: support,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: TvButton(
                    label: 'App Store',
                    icon: Icons.apps,
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            AppStoreScreen(profileId: widget.profileId),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ];

    final contentOrder = <Widget>[
      hero,
      SizedBox(height: compact ? 20 : 32),
      HomeAppTiles(profileId: widget.profileId),
      SizedBox(height: compact ? 16 : 26),
      ...infoBlocks,
      const SizedBox(height: 24),
      ...actionButtons,
    ];
    if (!compact && preset == MillitopLayoutPreset.commandDeck) {
      contentOrder
        ..clear()
        ..addAll([
          HomeAppTiles(profileId: widget.profileId),
          const SizedBox(height: 30),
          hero,
          const SizedBox(height: 24),
          ...infoBlocks,
          const SizedBox(height: 24),
          ...actionButtons,
        ]);
    } else if (!compact && preset == MillitopLayoutPreset.emberStack) {
      contentOrder
        ..clear()
        ..addAll([
          hero,
          const SizedBox(height: 20),
          ...infoBlocks,
          const SizedBox(height: 22),
          HomeAppTiles(profileId: widget.profileId),
          const SizedBox(height: 24),
          ...actionButtons,
        ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: contentOrder,
    );
  }

  Widget _buildMusicMiniPlayerOverlay() {
    final mini = MusicMiniPlayerService.instance;
    final active = mini.activeTrack;
    if (!mini.visible || active == null) {
      return const SizedBox.shrink();
    }
    final cover = mini.coverArtUrl(active);
    final searchText = musicMiniSearch.text.trim();
    final results = mini.searchSongs(searchText);
    return Positioned(
      right: 18,
      bottom: 110,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showMusicMiniQueuePanel)
            Container(
              width: 360,
              height: 420,
              margin: const EdgeInsets.only(right: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: musicMiniSearch,
                        decoration: const InputDecoration(
                          labelText: 'Add song to queue',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView(
                          children: [
                            const Text(
                              'Now playing queue',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 6),
                            const Divider(),
                            for (int i = 0; i < mini.queue.length; i++)
                              ListTile(
                                dense: true,
                                selected: i == mini.queueIndex,
                                title: Text(
                                  mini.queue[i].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  mini.queue[i].artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => unawaited(
                                  MusicMiniPlayerService.instance.playAt(i),
                                ),
                              ),
                            const SizedBox(height: 10),
                            const Text(
                              'Search to add',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            if (searchText.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  'Type in search to add more songs to this queue.',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                            for (final track in results)
                              ListTile(
                                dense: true,
                                title: Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${track.artist} • ${track.album}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  icon: const Icon(
                                    Icons.queue_play_next_outlined,
                                  ),
                                  onPressed: () {
                                    MusicMiniPlayerService.instance.addToQueue(
                                      track,
                                    );
                                    setState(() {});
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
          SizedBox(
            width: 320,
            child: Card(
              elevation: 10,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        RotationTransition(
                          turns: musicMiniSpinController,
                          child: ClipOval(
                            child: Container(
                              width: 62,
                              height: 62,
                              color: const Color(0xFF141414),
                              child: cover == null
                                  ? const Icon(
                                      Icons.album,
                                      color: Colors.white70,
                                    )
                                  : Image.network(
                                      cover,
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.album,
                                        color: Colors.white70,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                active.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                active.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close mini player',
                          onPressed: () => unawaited(
                            MusicMiniPlayerService.instance.closeMini(),
                          ),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => unawaited(
                            MusicMiniPlayerService.instance.playPrevious(),
                          ),
                          icon: const Icon(Icons.skip_previous),
                        ),
                        IconButton.filled(
                          onPressed: () => unawaited(
                            MusicMiniPlayerService.instance.togglePlayPause(),
                          ),
                          icon: Icon(
                            mini.playing ? Icons.pause : Icons.play_arrow,
                          ),
                        ),
                        IconButton(
                          onPressed: () => unawaited(
                            MusicMiniPlayerService.instance.playNext(),
                          ),
                          icon: const Icon(Icons.skip_next),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: () => setState(
                            () => showMusicMiniQueuePanel =
                                !showMusicMiniQueuePanel,
                          ),
                          icon: const Icon(Icons.queue_music),
                          label: const Text('Queue'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => unawaited(_openMusicFromMiniPlayer()),
                        child: const Text('Go to Music'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSleepModeModal() async {
    await showSleepModeSheet(context, profileId: widget.profileId);
  }

  Future<void> _toggleSleepSoundsPlayback() async {
    final sounds = SleepSoundsController.instance;
    try {
      if (sounds.state == SleepSoundsState.paused) {
        await sounds.resume();
      } else {
        await sounds.pause();
      }
    } catch (e) {
      if (mounted) {
        await notice(
          'Sleep Sounds',
          e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _stopSleepSoundsFromOverlay() async {
    try {
      await SleepSoundsController.instance.stop();
    } catch (e) {
      if (mounted) {
        await notice(
          'Sleep Sounds',
          e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Widget _buildSleepSoundsOverlay() {
    return AnimatedBuilder(
      animation: SleepSoundsController.instance,
      builder: (context, _) {
        final sounds = SleepSoundsController.instance;
        if (!sounds.running) {
          return const SizedBox.shrink();
        }
        return Positioned(
          left: 16,
          right: 16,
          bottom: 76,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Icon(Icons.nightlight_round),
                  Text('Sleep Sounds: ${sounds.state.name}'),
                  if (sounds.activeLayers.isNotEmpty)
                    Text(
                      sounds.activeLayers.join(', '),
                      style: const TextStyle(color: Colors.white70),
                    ),
                  OutlinedButton.icon(
                    onPressed: sounds.capabilities.supportsPauseResume
                        ? () => unawaited(_toggleSleepSoundsPlayback())
                        : null,
                    icon: Icon(
                      sounds.state == SleepSoundsState.paused
                          ? Icons.play_arrow
                          : Icons.pause,
                    ),
                    label: Text(
                      sounds.state == SleepSoundsState.paused
                          ? 'Resume'
                          : 'Pause',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_stopSleepSoundsFromOverlay()),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                  TextButton(
                    onPressed: _openSleepModeModal,
                    child: const Text('Open timer controls'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDarkScreenOverlay() {
    return ListenableBuilder(
      listenable: SleepMode.instance,
      builder: (context, _) {
        if (!SleepMode.instance.darkScreenModeEnabled) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            child: SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.tonalIcon(
                    onPressed: () =>
                        SleepMode.instance.setDarkScreenMode(false),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('Exit dark-screen mode'),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> support() async {
    try {
      await SleepMode.instance.openSupport(widget.profileId);
    } catch (e) {
      if (mounted) {
        await notice(
          'Support Assist',
          e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Widget dvr() =>
      MediaLibraryHome(profileId: widget.profileId, recordings: true);

  Widget updates() => MessageInbox(profileId: widget.profileId);

  Widget account() => CustomerAccountPanel(profileId: widget.profileId);

  void _openSettings() {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (_) => AppSettingsScreen(profileId: widget.profileId),
          ),
        )
        .then((_) => _loadHomePreferences());
  }

  Future<void> _openThemePicker() async {
    var draft = MillitopThemeController.instance.current.id;
    final selected = await showDialog<MillitopThemeId>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose interface theme'),
        content: SizedBox(
          width: 520,
          child: StatefulBuilder(
            builder: (context, setLocal) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final spec in MillitopThemeController.themes)
                    RadioListTile<MillitopThemeId>(
                      value: spec.id,
                      groupValue: draft,
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setLocal(() => draft = value);
                      },
                      title: Text(spec.label),
                      subtitle: Text(spec.summary),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('Apply theme'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) {
      return;
    }
    try {
      await HomePreferences().setVisualTheme(
        widget.profileId,
        MillitopThemeController.toStorage(selected),
      );
      MillitopThemeController.instance.setTheme(selected);
      setState(() {});
    } catch (_) {}
  }

  Future<void> _dismissLoginActionOverlay() async {
    if (!mounted) {
      return;
    }
    setState(() => showLoginActionOverlay = false);
    loginOverlayDismissed = true;
  }

  Future<void> _snoozeLoginActionOverlay(Duration duration) async {
    final until = DateTime.now().toUtc().add(duration);
    try {
      await HomePreferences().setLauncherPromptSnoozeUntil(
        widget.profileId,
        until,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        loginPromptSnoozeUntilUtc = until;
        showLoginActionOverlay = false;
        loginOverlayDismissed = true;
      });
    } catch (_) {}
  }

  Widget _loginActionOverlay() {
    final unread = RemoteInbox.instance.notices.value.where((m) => !m.opened);
    final latestMessage = unread.isNotEmpty ? unread.first : null;
    final hasBillingPrompt = _hasBillingPrompt;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withAlpha(178)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.notifications_active_rounded, color: accent),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Before you continue',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (latestMessage != null) ...[
                    Text(
                      'Admin message: ${latestMessage.title}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      latestMessage.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (hasBillingPrompt) ...[
                    const Text(
                      'Billing action needed',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      serviceLockReason.isEmpty
                          ? 'Your account needs attention before all services are available.'
                          : serviceLockReason,
                    ),
                    const SizedBox(height: 16),
                  ],
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (hasBillingPrompt)
                        FilledButton.icon(
                          onPressed: () {
                            setState(() {
                              page = 3;
                              showLoginActionOverlay = false;
                              loginOverlayDismissed = true;
                            });
                          },
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('Pay now'),
                        ),
                      if (latestMessage != null)
                        FilledButton.tonalIcon(
                          onPressed: () {
                            setState(() {
                              page = 4;
                              showLoginActionOverlay = false;
                              loginOverlayDismissed = true;
                            });
                          },
                          icon: const Icon(Icons.mark_chat_read_outlined),
                          label: const Text('View message'),
                        ),
                      OutlinedButton(
                        onPressed: () =>
                            unawaited(_dismissLoginActionOverlay()),
                        child: const Text('Pay/View later'),
                      ),
                      PopupMenuButton<Duration>(
                        onSelected: (value) =>
                            unawaited(_snoozeLoginActionOverlay(value)),
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: Duration(minutes: 30),
                            child: Text('Remind me in 30 minutes'),
                          ),
                          PopupMenuItem(
                            value: Duration(hours: 2),
                            child: Text('Remind me in 2 hours'),
                          ),
                          PopupMenuItem(
                            value: Duration(hours: 24),
                            child: Text('Remind me tomorrow'),
                          ),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Text('Remind me in...'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _selectPage(int index) {
    if (serviceLocked && index != 3) {
      unawaited(
        notice(
          'Service locked',
          serviceLockReason.isEmpty
              ? 'This service is currently locked until billing is restored.'
              : serviceLockReason,
        ),
      );
      return;
    }
    setState(() => page = index);
  }

  Widget _navigationHeader(bool compact, MillitopLayoutPreset preset) {
    if (compact) {
      return Column(
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('launcher-settings'),
                onPressed: _openSettings,
                icon: const Icon(Icons.settings),
                tooltip: 'Settings',
              ),
              IconButton(
                key: const ValueKey('launcher-themes'),
                onPressed: () => unawaited(_openThemePicker()),
                icon: const Icon(Icons.palette_outlined),
                tooltip: 'Themes',
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'MILLITOP TV',
                  style: TextStyle(
                    fontSize: 18,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: pages.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) => SizedBox(
                width: 118,
                child: TvButton(
                  label: pages[i],
                  selected: page == i,
                  onPressed: () => _selectPage(i),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final navButtons = <Widget>[
      for (int i = 0; i < pages.length; i++)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: TvButton(
              label: pages[i],
              height: 58,
              selected: page == i,
              onPressed: () => _selectPage(i),
            ),
          ),
        ),
    ];

    switch (preset) {
      case MillitopLayoutPreset.commandDeck:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 220,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text(
                        'MILLITOP TV',
                        style: TextStyle(
                          fontSize: 21,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        key: const ValueKey('launcher-settings'),
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings),
                        tooltip: 'Settings',
                      ),
                      IconButton(
                        key: const ValueKey('launcher-themes'),
                        onPressed: () => unawaited(_openThemePicker()),
                        icon: const Icon(Icons.palette_outlined),
                        tooltip: 'Themes',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < pages.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: TvButton(
                        label: pages[i],
                        selected: page == i,
                        height: 56,
                        onPressed: () => _selectPage(i),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Container(
                height: 68,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    context.millitopTheme.cardRadius,
                  ),
                  color: panel.withAlpha(190),
                  border: Border.all(color: context.millitopTheme.softBorder),
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  'Now viewing: ${pages[page]}',
                  style: TextStyle(
                    fontSize: 20,
                    color: context.millitopTheme.mutedColor,
                  ),
                ),
              ),
            ),
          ],
        );
      case MillitopLayoutPreset.haloSplit:
        return Column(
          children: [
            Row(
              children: [
                IconButton(
                  key: const ValueKey('launcher-settings'),
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings),
                  tooltip: 'Settings',
                ),
                IconButton(
                  key: const ValueKey('launcher-themes'),
                  onPressed: () => unawaited(_openThemePicker()),
                  icon: const Icon(Icons.palette_outlined),
                  tooltip: 'Themes',
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'MILLITOP TV',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      letterSpacing: 2.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: navButtons),
          ],
        );
      case MillitopLayoutPreset.emberStack:
        return Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'MILLITOP TV',
                    style: TextStyle(
                      fontSize: 23,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('launcher-settings'),
                  onPressed: _openSettings,
                  icon: const Icon(Icons.tune),
                  label: const Text('Settings'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const ValueKey('launcher-themes'),
                  onPressed: () => unawaited(_openThemePicker()),
                  icon: const Icon(Icons.palette_outlined),
                  label: const Text('Themes'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (int i = 0; i < pages.length; i++)
                  SizedBox(
                    width: 180,
                    child: TvButton(
                      label: pages[i],
                      selected: page == i,
                      height: 54,
                      onPressed: () => _selectPage(i),
                    ),
                  ),
              ],
            ),
          ],
        );
      case MillitopLayoutPreset.streamRail:
      case MillitopLayoutPreset.cinematicTopBar:
        return Row(
          children: [
            IconButton(
              key: const ValueKey('launcher-settings'),
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
            ),
            IconButton(
              key: const ValueKey('launcher-themes'),
              onPressed: () => unawaited(_openThemePicker()),
              icon: const Icon(Icons.palette_outlined),
              tooltip: 'Themes',
            ),
            const SizedBox(width: 8),
            const Text(
              'MILLITOP TV',
              style: TextStyle(
                fontSize: 21,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 30),
            Expanded(child: Row(children: navButtons)),
          ],
        );
    }
  }

  Widget _pagedScrollBody({required bool alwaysScrollable}) {
    return SingleChildScrollView(
      key: ValueKey(page),
      physics: alwaysScrollable ? const AlwaysScrollableScrollPhysics() : null,
      padding: const EdgeInsets.only(bottom: 20),
      child: Stack(
        children: [
          IgnorePointer(
            ignoring: serviceLocked && page != 3,
            child: switch (page) {
              1 => const SizedBox(height: 400),
              2 => dvr(),
              3 => account(),
              4 => updates(),
              _ => home(),
            },
          ),
          if (serviceLocked && page != 3)
            Positioned.fill(
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Color(0xAA000000)),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline, size: 40),
                          const SizedBox(height: 10),
                          const Text(
                            'Service locked',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            serviceLockReason.isEmpty
                                ? 'Open Account to restore access.'
                                : serviceLockReason,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          FilledButton(
                            onPressed: () => setState(() => page = 3),
                            child: const Text('Open Account'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 1000;
    final themePreset = context.millitopTheme.layoutPreset;
    final activeProfileName =
        SelectedProfileScope.maybeOf(context)?.profile.name.trim() ?? '';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (page != 0) setState(() => page = 0);
        },
      },
      child: Scaffold(
        body: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    panel.withAlpha(214),
                    background,
                    background.withAlpha(236),
                  ],
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 12 : 36,
                    compact ? 12 : 24,
                    compact ? 12 : 36,
                    16,
                  ),
                  child: Column(
                    children: [
                      _navigationHeader(compact, themePreset),
                      SizedBox(height: compact ? 14 : 30),
                      Expanded(
                        child: FocusTraversalGroup(
                          policy: ReadingOrderTraversalPolicy(),
                          child: page == 1 && !serviceLocked
                              ? PlaylistsScreen(
                                  key: ValueKey(widget.profileId),
                                  profileId: widget.profileId,
                                  embedded: true,
                                )
                              : page == 0
                              ? RefreshIndicator(
                                  onRefresh: _refreshHomeFromPullDown,
                                  child: _pagedScrollBody(
                                    alwaysScrollable: true,
                                  ),
                                )
                              : _pagedScrollBody(alwaysScrollable: false),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: PipPlaybackController.instance,
                        builder: (context, _) {
                          final session =
                              PipPlaybackController.instance.session;
                          if (session == null ||
                              !PipPlaybackController
                                  .instance
                                  .hasVisibleMiniPlayer) {
                            return const SizedBox.shrink();
                          }
                          return LayoutBuilder(
                            builder: (context, constraints) {
                              const miniWidth = 360.0;
                              const miniHeight = 255.0;
                              const edgePadding = 8.0;
                              final maxX = (constraints.maxWidth - miniWidth)
                                  .clamp(0.0, double.infinity);
                              final maxY = (miniHeight + 20.0).clamp(
                                0.0,
                                double.infinity,
                              );
                              final clampedOffset = Offset(
                                pipMiniPlayerOffset.dx.clamp(0.0, maxX),
                                pipMiniPlayerOffset.dy.clamp(0.0, maxY),
                              );
                              if (clampedOffset != pipMiniPlayerOffset) {
                                pipMiniPlayerOffset = clampedOffset;
                              }
                              return SizedBox(
                                width: double.infinity,
                                height: miniHeight + 20,
                                child: Stack(
                                  children: [
                                    Positioned(
                                      left: clampedOffset.dx,
                                      top: clampedOffset.dy,
                                      child: GestureDetector(
                                        onPanUpdate: (details) {
                                          setState(() {
                                            pipMiniPlayerOffset = Offset(
                                              (pipMiniPlayerOffset.dx +
                                                      details.delta.dx)
                                                  .clamp(0.0, maxX),
                                              (pipMiniPlayerOffset.dy +
                                                      details.delta.dy)
                                                  .clamp(0.0, maxY),
                                            );
                                          });
                                        },
                                        child: SizedBox(
                                          width: miniWidth,
                                          child: Card(
                                            elevation: 10,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                AspectRatio(
                                                  aspectRatio: 16 / 9,
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        const BorderRadius.vertical(
                                                          top: Radius.circular(
                                                            12,
                                                          ),
                                                        ),
                                                    child: DecoratedBox(
                                                      decoration:
                                                          const BoxDecoration(
                                                            color: Colors.black,
                                                          ),
                                                      child: Video(
                                                        controller:
                                                            session.video,
                                                        controls:
                                                            NoVideoControls,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                        10,
                                                        edgePadding,
                                                        edgePadding,
                                                        edgePadding,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              session.title,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                            ),
                                                            if (session.subtitle !=
                                                                    null &&
                                                                session
                                                                    .subtitle!
                                                                    .trim()
                                                                    .isNotEmpty)
                                                              Text(
                                                                session
                                                                    .subtitle!,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: const TextStyle(
                                                                  color: Colors
                                                                      .white70,
                                                                  fontSize: 12,
                                                                ),
                                                              ),
                                                            const Text(
                                                              'Drag mini player',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white54,
                                                                fontSize: 11,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      IconButton(
                                                        tooltip: 'Expand',
                                                        onPressed: () async {
                                                          final active =
                                                              await PipPlaybackController
                                                                  .instance
                                                                  .beginExpand();
                                                          if (active == null ||
                                                              !context
                                                                  .mounted) {
                                                            return;
                                                          }
                                                          await Navigator.of(
                                                            context,
                                                          ).push<void>(
                                                            MaterialPageRoute<
                                                              void
                                                            >(
                                                              builder: (_) =>
                                                                  _PipExpandedScreen(
                                                                    session:
                                                                        active,
                                                                  ),
                                                            ),
                                                          );
                                                          PipPlaybackController
                                                              .instance
                                                              .endExpand();
                                                        },
                                                        icon: const Icon(
                                                          Icons.open_in_full,
                                                        ),
                                                      ),
                                                      IconButton(
                                                        tooltip:
                                                            'Close mini player',
                                                        onPressed: () => unawaited(
                                                          PipPlaybackController
                                                              .instance
                                                              .close(),
                                                        ),
                                                        icon: const Icon(
                                                          Icons.close,
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
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      ValueListenableBuilder<AppUpdateView>(
                        valueListenable: AppUpdates.instance.view,
                        builder: (context, update, _) {
                          final profile = SelectedProfileScope.maybeOf(context);
                          bool canLeave() =>
                              !AppUpdates.instance.view.value.busy &&
                              !AppUpdates.instance.recoveryRequired &&
                              !StoreJob.operationActive;
                          return LauncherFooter(
                            profileName: profile?.profile.name ?? 'Profile',
                            onSwitchProfile: profile?.switchProfile,
                            blocked:
                                update.busy ||
                                AppUpdates.instance.recoveryRequired ||
                                StoreJob.operationActive ||
                                (serviceLocked && page != 3),
                            canLeave: canLeave,
                            connection: ValueListenableBuilder<String>(
                              valueListenable: DeviceConnection.instance.status,
                              builder: (context, status, _) =>
                                  OutlinedButton.icon(
                                    key: const ValueKey('footer-connection'),
                                    onPressed: !canLeave()
                                        ? null
                                        : () =>
                                              Navigator.of(context).push<void>(
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      const DeviceSetupScreen(),
                                                ),
                                              ),
                                    icon: Icon(
                                      DeviceConnection.instance.isConnected
                                          ? Icons.cloud_done_outlined
                                          : Icons.cloud_off_outlined,
                                    ),
                                    label: Text(
                                      DeviceConnection.instance.isConnected
                                          ? 'Connected'
                                          : 'Disconnected',
                                    ),
                                  ),
                            ),
                            sleepChip: ListenableBuilder(
                              listenable: Listenable.merge([
                                SleepMode.instance,
                                SleepSoundsController.instance,
                              ]),
                              builder: (context, _) {
                                final sleep = SleepMode.instance;
                                final sounds = SleepSoundsController.instance;
                                final soundState = sounds.running
                                    ? ' · Sounds ${sounds.state.name}'
                                    : '';
                                final timerText = sleep.deadline == null
                                    ? 'Sleep sounds & timer$soundState'
                                    : '${sleep.remaining.inMinutes}:${(sleep.remaining.inSeconds % 60).toString().padLeft(2, '0')} left';
                                return OutlinedButton.icon(
                                  key: const ValueKey('footer-sleep-timer'),
                                  onPressed: !canLeave()
                                      ? null
                                      : _openSleepModeModal,
                                  icon: const Icon(Icons.nightlight_round),
                                  label: Text(timerText),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            showWelcomeSplash
                ? Positioned.fill(child: _welcomeOverlay(activeProfileName))
                : const SizedBox.shrink(),
            !showWelcomeSplash && showLoginActionOverlay
                ? Positioned.fill(child: _loginActionOverlay())
                : const SizedBox.shrink(),
            _buildMusicMiniPlayerOverlay(),
            _buildSleepSoundsOverlay(),
            AnimatedBuilder(
              animation: PodcastPlayback.instance,
              builder: (context, _) {
                final podcasts = PodcastPlayback.instance;
                if (podcasts.profileId != widget.profileId ||
                    podcasts.active == null) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  left: 16,
                  right: 16,
                  bottom: 76,
                  child: PodcastPlayerBar(
                    onOpenQueue: () => unawaited(showPodcastQueue(context)),
                    onOpenPodcasts: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            PodcastsScreen(profileId: widget.profileId),
                      ),
                    ),
                  ),
                );
              },
            ),
            _buildDarkScreenOverlay(),
          ],
        ),
      ),
    );
  }
}

class _PipExpandedScreen extends StatefulWidget {
  final PipPlaybackSession session;
  const _PipExpandedScreen({required this.session});

  @override
  State<_PipExpandedScreen> createState() => _PipExpandedScreenState();
}

class _PipExpandedScreenState extends State<_PipExpandedScreen> {
  Duration duration = Duration.zero;
  Duration position = Duration.zero;
  bool playing = false;
  final subscriptions = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    final current = widget.session.player;
    subscriptions.add(
      current.stream.duration.listen((value) {
        if (mounted) {
          setState(() => duration = value);
        }
      }),
    );
    subscriptions.add(
      current.stream.position.listen((value) {
        if (mounted) {
          setState(() => position = value);
        }
      }),
    );
    subscriptions.add(
      current.stream.playing.listen((value) {
        if (mounted) {
          setState(() => playing = value);
        }
      }),
    );
  }

  @override
  void dispose() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
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

  Future<void> _togglePlayPause() async {
    if (playing) {
      await widget.session.player.pause();
    } else {
      await widget.session.player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.title),
        actions: [
          IconButton(
            tooltip: 'Close playback',
            onPressed: () async {
              await PipPlaybackController.instance.close();
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black),
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Video(
                    controller: widget.session.video,
                    controls: NoVideoControls,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              children: [
                Slider(
                  value: duration.inMilliseconds <= 0
                      ? 0
                      : position.inMilliseconds
                            .clamp(0, duration.inMilliseconds)
                            .toDouble(),
                  max: duration.inMilliseconds <= 0
                      ? 1
                      : duration.inMilliseconds.toDouble(),
                  onChanged:
                      !widget.session.seekable || duration <= Duration.zero
                      ? null
                      : (value) => unawaited(
                          widget.session.player.seek(
                            Duration(milliseconds: value.toInt()),
                          ),
                        ),
                ),
                Row(
                  children: [
                    Text(_clockText(position)),
                    const Spacer(),
                    if (widget.session.seekable && duration > Duration.zero)
                      Text(
                        '-${_clockText((duration - position).isNegative ? Duration.zero : duration - position)}',
                      ),
                    const SizedBox(width: 14),
                    IconButton.filledTonal(
                      onPressed: _togglePlayPause,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
