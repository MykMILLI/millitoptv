import 'screens/overnight_window_guard.dart';
import 'services/sleep_mode.dart';
import 'services/home_preferences.dart';
import 'screens/sleep_mode_panel.dart';
import 'screens/home_app_tiles.dart';
import 'screens/gallery_panel.dart';
import 'screens/app_settings_screen.dart';
import 'screens/customer_account_panel.dart';
import 'services/web_app_catalog.dart';
import 'widgets/launcher_footer.dart';
import 'screens/media_library_home.dart';
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
import 'services/music_playback.dart';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

const background = Color(0xFF0B1425);
const panel = Color(0xFF16243A);
const accent = Color(0xFF63DFCB);
const muted = Color(0xFFA4B3C8);

class MillitopApp extends StatelessWidget {
  const MillitopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: overnightNavigatorKey,
      title: 'MILLITOP TV',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Listener(
        onPointerDown: (_) => DeviceConnection.instance.noteInteraction(),
        onPointerHover: (_) => DeviceConnection.instance.noteInteraction(),
        onPointerSignal: (_) => DeviceConnection.instance.noteInteraction(),
        child: OvernightWindowGuard(
          child: AppUpdateOverlay(child: child ?? const SizedBox.shrink()),
        ),
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(primary: accent, surface: panel),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      home: ProfileGate(
        builder: (profile) =>
            Launcher(key: ValueKey(profile.id), profileId: profile.id),
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

  @override
  Widget build(BuildContext context) {
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
          builder: (buttonContext) => GestureDetector(
            onTap: () {
              Focus.of(buttonContext).requestFocus();
              widget.onPressed();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              height: widget.height,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: focused
                    ? const Color(0xFF23423F)
                    : widget.selected
                    ? const Color(0xFF22354B)
                    : panel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: focused ? accent : Colors.transparent,
                  width: 3,
                ),
                boxShadow: focused
                    ? [BoxShadow(color: accent.withAlpha(28), blurRadius: 20)]
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
                                  color: widget.iconColor ?? accent,
                                )
                              : Image.asset(
                                  widget.imageAsset!,
                                  width: 58,
                                  height: 58,
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.high,
                                  errorBuilder: (context, error, stack) => Icon(
                                    widget.icon,
                                    size: 48,
                                    color: widget.iconColor ?? accent,
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
                          Icon(widget.icon, color: widget.iconColor ?? accent),
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
    );
  }
}

class Launcher extends StatefulWidget {
  final int profileId;

  const Launcher({super.key, required this.profileId});

  @override
  State<Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<Launcher> {
  final pages = ['Home', 'Files', 'DVR', 'Account', 'Gallery', 'Updates'];
  final liveTvControl = LiveTvControlService();
  int page = 0;
  DateTime now = DateTime.now();
  Timer? clock;
  Timer? serviceAccessPoll;
  bool familyMoments = true;
  bool serviceLocked = false;
  String serviceLockReason = '';
  Offset pipMiniPlayerOffset = const Offset(0, 0);
  Future<void> _loadHomePreferences() async {
    try {
      final visible = await HomePreferences().familyMoments(widget.profileId);
      if (mounted) {
        setState(() => familyMoments = visible);
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadHomePreferences());
    DeviceConnection.instance.status.addListener(_onConnectionStatusChanged);
    unawaited(_refreshServiceAccess());
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => now = DateTime.now());
    });
    serviceAccessPoll = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(_refreshServiceAccess());
    });
  }

  @override
  void dispose() {
    clock?.cancel();
    serviceAccessPoll?.cancel();
    DeviceConnection.instance.status.removeListener(_onConnectionStatusChanged);
    super.dispose();
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
    } catch (_) {}
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withAlpha(12)),
      ),
      child: child,
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
          Text(subtitle, style: const TextStyle(fontSize: 19, color: muted)),
        ],
      ),
    );
  }

  Widget home() {
    final compact = MediaQuery.sizeOf(context).width < 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (compact) ...[
          Text(
            greeting,
            style: const TextStyle(fontSize: 22, color: muted),
          ),
          const SizedBox(height: 6),
          Text(
            time,
            style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w300),
          ),
          Text(
            date,
            style: const TextStyle(fontSize: 16, color: muted),
          ),
          const SizedBox(height: 16),
          card(LiveWeatherCard(profileId: widget.profileId)),
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greeting,
                      style: const TextStyle(fontSize: 28, color: muted),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      time,
                      style: const TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    Text(
                      date,
                      style: const TextStyle(fontSize: 21, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 28),
              Expanded(child: card(LiveWeatherCard(profileId: widget.profileId))),
            ],
          ),
        ],
        SizedBox(height: compact ? 20 : 32),
        HomeAppTiles(profileId: widget.profileId),
        SizedBox(height: compact ? 16 : 26),
        if (compact) ...[
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
                    style: const TextStyle(
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
                  onPressed: () => setState(() => page = 5),
                ),
              ],
            ),
          ),
          if (familyMoments) ...[
            const SizedBox(height: 14),
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.photo_library_outlined, color: accent),
                      SizedBox(width: 12),
                      Text(
                        'Family moments',
                        style: TextStyle(fontSize: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Browse your photos and videos, or start a slideshow.\n'
                    'Your family folders are saved for this profile.',
                    style: TextStyle(
                      fontSize: 15,
                      color: muted,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TvButton(
                    label: 'Open gallery',
                    onPressed: () => setState(() => page = 4),
                  ),
                ],
              ),
            ),
          ],
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
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
                          style: const TextStyle(
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
                        onPressed: () => setState(() => page = 5),
                      ),
                    ],
                  ),
                ),
              ),
              if (familyMoments) const SizedBox(width: 22),
              if (familyMoments)
                Expanded(
                  flex: 2,
                  child: card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.photo_library_outlined, color: accent),
                            SizedBox(width: 12),
                            Text(
                              'Family moments',
                              style: TextStyle(fontSize: 21),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Browse your photos and videos, or start a slideshow.\n'
                          'Your family folders are saved for this profile.',
                          style: TextStyle(
                            fontSize: 18,
                            color: muted,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TvButton(
                          label: 'Open gallery',
                          onPressed: () => setState(() => page = 4),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        if (compact) ...[
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
        ] else
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
                      builder: (_) => AppStoreScreen(profileId: widget.profileId),
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _openSleepModeModal() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E1B33),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SleepModePanel(profileId: widget.profileId),
        ),
      ),
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

  Widget files() => MediaLibraryHome(profileId: widget.profileId);

  Widget dvr() =>
      MediaLibraryHome(profileId: widget.profileId, recordings: true);

  Widget updates() => MessageInbox(profileId: widget.profileId);

  Widget gallery() => GalleryPanel(profileId: widget.profileId);

  Widget account() => CustomerAccountPanel(profileId: widget.profileId);

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 1000;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (page != 0) setState(() => page = 0);
        },
      },
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF14283C), background, Color(0xFF101A2C)],
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
                  if (compact) ...[
                    Row(
                      children: [
                        IconButton(
                          key: const ValueKey('launcher-settings'),
                          onPressed: () => Navigator.of(context)
                              .push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => AppSettingsScreen(
                                    profileId: widget.profileId,
                                  ),
                                ),
                              )
                              .then((_) => _loadHomePreferences()),
                          icon: const Icon(Icons.settings),
                          tooltip: 'Settings',
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
                            onPressed: () {
                              if (serviceLocked && i != 3) {
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
                              setState(() => page = i);
                            },
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        IconButton(
                          key: const ValueKey('launcher-settings'),
                          onPressed: () => Navigator.of(context)
                              .push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => AppSettingsScreen(
                                    profileId: widget.profileId,
                                  ),
                                ),
                              )
                              .then((_) => _loadHomePreferences()),
                          icon: const Icon(Icons.settings),
                          tooltip: 'Settings',
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
                        Expanded(
                          child: Row(
                            children: [
                              for (int i = 0; i < pages.length; i++)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: TvButton(
                                      label: pages[i],
                                      height: 58,
                                      selected: page == i,
                                      onPressed: () {
                                        if (serviceLocked && i != 3) {
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
                                        setState(() => page = i);
                                      },
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: compact ? 14 : 30),
                  Expanded(
                    child: FocusTraversalGroup(
                      policy: ReadingOrderTraversalPolicy(),
                      child: SingleChildScrollView(
                        key: ValueKey(page),
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Stack(
                          children: [
                            IgnorePointer(
                              ignoring: serviceLocked && page != 3,
                              child: switch (page) {
                                1 => files(),
                                2 => dvr(),
                                3 => account(),
                                4 => gallery(),
                                5 => updates(),
                                _ => home(),
                              },
                            ),
                            if (serviceLocked && page != 3)
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    color: Color(0xAA000000),
                                  ),
                                  child: Center(
                                    child: Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(18),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.lock_outline,
                                              size: 40,
                                            ),
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
                                              onPressed: () =>
                                                  setState(() => page = 3),
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
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: PipPlaybackController.instance,
                    builder: (context, _) {
                      final session = PipPlaybackController.instance.session;
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
                                                      top: Radius.circular(12),
                                                    ),
                                                child: DecoratedBox(
                                                  decoration: const BoxDecoration(
                                                    color: Colors.black,
                                                  ),
                                                  child: Video(
                                                    controller: session.video,
                                                    controls: NoVideoControls,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Padding(
                                              padding: const EdgeInsets.fromLTRB(
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
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: const TextStyle(
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                        ),
                                                        if (session.subtitle !=
                                                                null &&
                                                            session.subtitle!
                                                                .trim()
                                                                .isNotEmpty)
                                                          Text(
                                                            session.subtitle!,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white70,
                                                                  fontSize: 12,
                                                                ),
                                                          ),
                                                        const Text(
                                                          'Drag mini player',
                                                          style: TextStyle(
                                                            color:
                                                                Colors.white54,
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
                                                          !context.mounted) {
                                                        return;
                                                      }
                                                      await Navigator.of(
                                                        context,
                                                      ).push<void>(
                                                        MaterialPageRoute<void>(
                                                          builder: (_) =>
                                                              _PipExpandedScreen(
                                                                session: active,
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
                                                    tooltip: 'Close mini player',
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
                          builder: (context, status, _) => OutlinedButton.icon(
                            key: const ValueKey('footer-connection'),
                            onPressed: !canLeave()
                                ? null
                                : () => Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const DeviceSetupScreen(),
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
                        sleepChip: OutlinedButton.icon(
                          key: const ValueKey('footer-sleep-timer'),
                          onPressed: !canLeave() ? null : _openSleepModeModal,
                          icon: const Icon(Icons.nightlight_round),
                          label: const Text('Sleep sounds & timer'),
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
      await MusicPlayback.instance.pause();
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
