import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:millitop_tv/services/live_tv_epg.dart';
import 'package:millitop_tv/widgets/live_tv_osd.dart';

Widget _hostedOsd({
  required LiveTvOsd osd,
  double width = 900,
  double height = 520,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(children: [
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: 1,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(ignoring: false, child: osd),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

LiveTvOsd _buildOsd({
  required bool hasEpg,
  required bool recording,
  required Duration position,
  required Duration duration,
  bool isPlaying = true,
  bool isFavorite = false,
  VoidCallback? onFavorite,
  VoidCallback? onPlayPause,
  VoidCallback? onStop,
  VoidCallback? onChannelDown,
  VoidCallback? onChannelUp,
  VoidCallback? onRewind,
  VoidCallback? onForward,
  VoidCallback? onGoLive,
  VoidCallback? onRecord,
  VoidCallback? onSchedule,
  VoidCallback? onGuide,
  VoidCallback? onSplit,
  VoidCallback? onFullScreen,
  VoidCallback? onInteraction,
}) {
  final now = LiveTvProgram(
    title: 'Now Playing',
    start: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    end: DateTime.now().toUtc().add(const Duration(minutes: 25)),
  );
  final next = LiveTvProgram(
    title: 'Up Next Show',
    start: DateTime.now().toUtc().add(const Duration(minutes: 25)),
    end: DateTime.now().toUtc().add(const Duration(minutes: 55)),
  );
  return LiveTvOsd(
    channelName: 'Sample Channel',
    channelLogo: null,
    nowProgram: hasEpg ? now : null,
    nextProgram: hasEpg ? next : null,
    epgProgress: hasEpg ? 0.4 : null,
    isFavorite: isFavorite,
    recording: recording,
    liveOnly: duration <= Duration.zero,
    splitScreen: false,
    screenCount: 1,
    hasEpg: hasEpg,
    isPlaying: isPlaying,
    position: position,
    duration: duration,
    isFullScreen: false,
    onFavorite: onFavorite ?? () {},
    onPlayPause: onPlayPause ?? () {},
    onStop: onStop ?? () {},
    onChannelDown: onChannelDown ?? () {},
    onChannelUp: onChannelUp ?? () {},
    onRewind: onRewind ?? () {},
    onForward: onForward ?? () {},
    onGoLive: onGoLive ?? () {},
    onRecord: onRecord ?? () {},
    onSchedule: onSchedule ?? () {},
    onGuide: onGuide ?? () {},
    onSplit: onSplit ?? () {},
    onFullScreen: onFullScreen ?? () {},
    onInteraction: onInteraction ?? () {},
  );
}

void main() {
  for (final width in [320.0, 360.0, 412.0, 1280.0, 1920.0]) {
    testWidgets('overlay fits $width and preserves keyboard focus traversal', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 720);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_hostedOsd(
        width: width,
        height: 260,
        osd: _buildOsd(hasEpg: true, recording: false, position: const Duration(seconds: 30), duration: const Duration(minutes: 3)),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.text('Sample Channel')).right,
        lessThanOrEqualTo(tester.getRect(find.byTooltip('Guide')).left));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final first = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(same(first)));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('live-only mode hides seek buttons and shows LIVE chip', (
    tester,
  ) async {
    await tester.pumpWidget(
      _hostedOsd(
        osd: _buildOsd(
          hasEpg: true,
          recording: false,
          position: Duration.zero,
          duration: Duration.zero,
        ),
      ),
    );

    expect(find.byIcon(Icons.replay_10), findsNothing);
    expect(find.byIcon(Icons.forward_10), findsNothing);
    expect(find.textContaining('LIVE'), findsOneWidget);
  });

  testWidgets('timeshift mode shows seek controls and behind-live text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _hostedOsd(
        osd: _buildOsd(
          hasEpg: true,
          recording: false,
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
        ),
      ),
    );

    expect(find.byIcon(Icons.replay_10), findsOneWidget);
    expect(find.byIcon(Icons.forward_10), findsOneWidget);
    expect(find.text('GO LIVE'), findsOneWidget);
    expect(find.textContaining('behind live'), findsOneWidget);
  });

  testWidgets('missing EPG shows no-guide message and Match EPG action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _hostedOsd(
        osd: _buildOsd(
          hasEpg: false,
          recording: false,
          position: Duration.zero,
          duration: Duration.zero,
        ),
      ),
    );

    expect(find.text('No guide data for this channel'), findsOneWidget);
    expect(find.text('Match EPG'), findsOneWidget);
  });

  testWidgets('recording mode uses red record icon and direct callback', (
    tester,
  ) async {
    var recordTapped = 0;
    await tester.pumpWidget(
      _hostedOsd(
        osd: _buildOsd(
          hasEpg: true,
          recording: true,
          position: const Duration(seconds: 1),
          duration: const Duration(minutes: 1),
          onRecord: () => recordTapped++,
        ),
      ),
    );

    final icon = tester.widget<Icon>(find.byIcon(Icons.fiber_manual_record));
    expect(icon.color, const Color(0xFFE5383B));

    await tester.tap(find.byIcon(Icons.fiber_manual_record));
    await tester.pump();
    expect(recordTapped, 1);
    expect(find.text('Record now'), findsNothing);
  });

  testWidgets('all callbacks can be triggered from controls', (tester) async {
    var favorite = 0;
    var playPause = 0;
    var stop = 0;
    var down = 0;
    var up = 0;
    var rewind = 0;
    var forward = 0;
    var goLive = 0;
    var record = 0;
    var schedule = 0;
    var guide = 0;
    var split = 0;
    var full = 0;
    var interaction = 0;

    await tester.pumpWidget(
      _hostedOsd(
        osd: _buildOsd(
          hasEpg: true,
          recording: false,
          isFavorite: false,
          isPlaying: true,
          position: const Duration(seconds: 20),
          duration: const Duration(minutes: 2),
          onFavorite: () => favorite++,
          onPlayPause: () => playPause++,
          onStop: () => stop++,
          onChannelDown: () => down++,
          onChannelUp: () => up++,
          onRewind: () => rewind++,
          onForward: () => forward++,
          onGoLive: () => goLive++,
          onRecord: () => record++,
          onSchedule: () => schedule++,
          onGuide: () => guide++,
          onSplit: () => split++,
          onFullScreen: () => full++,
          onInteraction: () => interaction++,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.calendar_view_day_outlined));
    await tester.tap(find.byIcon(Icons.close));
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.tap(find.byIcon(Icons.star_border));
    await tester.tap(find.byIcon(Icons.replay_10));
    await tester.tap(find.byIcon(Icons.pause));
    await tester.tap(find.byIcon(Icons.forward_10));
    await tester.tap(find.text('GO LIVE'));
    await tester.tap(find.byIcon(Icons.view_week));
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.fiber_manual_record));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record now'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.fiber_manual_record));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Schedule from guide'));
    await tester.pumpAndSettle();

    expect(favorite, 1);
    expect(playPause, 1);
    expect(stop, 1);
    expect(down, 1);
    expect(up, 1);
    expect(rewind, 1);
    expect(forward, 1);
    expect(goLive, 1);
    expect(record, 1);
    expect(schedule, 1);
    expect(guide, 1);
    expect(split, 1);
    expect(full, 1);
    expect(interaction, greaterThan(0));
  });
}
