import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/live_tv_epg.dart';
import '../theme/millitop_visual_theme.dart';

class LiveTvOsd extends StatefulWidget {
  final String channelName;
  final String? channelLogo;
  final LiveTvProgram? nowProgram;
  final LiveTvProgram? nextProgram;
  final double? epgProgress;
  final bool isFavorite;
  final bool recording;
  final bool liveOnly;
  final bool splitScreen;
  final int screenCount;
  final bool hasEpg;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final bool isFullScreen;
  final VoidCallback onFavorite;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final VoidCallback onChannelDown;
  final VoidCallback onChannelUp;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback onGoLive;
  final VoidCallback onRecord;
  final VoidCallback onSchedule;
  final VoidCallback onGuide;
  final VoidCallback onSplit;
  final VoidCallback onFullScreen;
  final VoidCallback onInteraction;

  const LiveTvOsd({
    super.key,
    required this.channelName,
    required this.channelLogo,
    required this.nowProgram,
    required this.nextProgram,
    required this.epgProgress,
    required this.isFavorite,
    required this.recording,
    required this.liveOnly,
    required this.splitScreen,
    required this.screenCount,
    required this.hasEpg,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.isFullScreen,
    required this.onFavorite,
    required this.onPlayPause,
    required this.onStop,
    required this.onChannelDown,
    required this.onChannelUp,
    required this.onRewind,
    required this.onForward,
    required this.onGoLive,
    required this.onRecord,
    required this.onSchedule,
    required this.onGuide,
    required this.onSplit,
    required this.onFullScreen,
    required this.onInteraction,
  });

  @override
  State<LiveTvOsd> createState() => _LiveTvOsdState();
}

class _LiveTvOsdState extends State<LiveTvOsd> {
  Timer? _recordMenuKeepAlive;

  @override
  void dispose() {
    _recordMenuKeepAlive?.cancel();
    super.dispose();
  }

  bool get _timeshiftAvailable => widget.duration > Duration.zero;

  Duration get _behindLive {
    final delta = widget.duration - widget.position;
    return delta.isNegative ? Duration.zero : delta;
  }

  bool get _isLiveNow =>
      !_timeshiftAvailable || _behindLive <= const Duration(seconds: 5);

  String get _splitLabel => switch (widget.screenCount) {
    1 => 'Split (2)',
    2 => 'Split (3)',
    3 => 'Split (4)',
    _ => 'Single screen',
  };

  String _logoFallbackLabel() {
    final words = widget.channelName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return 'TV';
    }
    if (words.length == 1) {
      final token = words.first.toUpperCase();
      return token.length <= 3 ? token : token.substring(0, 3);
    }
    return words.take(3).map((word) => word[0]).join().toUpperCase();
  }

  String _behindLiveText() {
    final behind = _behindLive;
    final totalSeconds = behind.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds behind live';
  }

  void _perform(VoidCallback callback) {
    widget.onInteraction();
    callback();
  }

  void _startRecordMenuKeepAlive() {
    _recordMenuKeepAlive?.cancel();
    widget.onInteraction();
    _recordMenuKeepAlive = Timer.periodic(const Duration(seconds: 2), (_) {
      widget.onInteraction();
    });
  }

  void _stopRecordMenuKeepAlive() {
    _recordMenuKeepAlive?.cancel();
    _recordMenuKeepAlive = null;
    widget.onInteraction();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.millitopTheme;
    return MouseRegion(
      onHover: (_) => widget.onInteraction(),
      child: Focus(
        onFocusChange: (focused) {
          widget.onInteraction();
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 600;
            return Stack(
              children: [
                IgnorePointer(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      height: constraints.maxHeight * 0.30,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xBF000000), Color(0x00000000)],
                        ),
                      ),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: constraints.maxHeight * 0.55,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0xE0000000)],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: compact ? 120 : 210,
                  top: 16,
                  child: _buildChannelIdentity(context),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!compact)
                        Text(
                          _clockText(DateTime.now()),
                          style: const TextStyle(
                            color: Color(0xD9FFFFFF),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (!compact) const SizedBox(width: 8),
                      _OsdIconControl(
                        tooltip: 'Guide',
                        icon: Icons.calendar_view_day_outlined,
                        accentColor: tokens.accentColor,
                        onPressed: () => _perform(widget.onGuide),
                      ),
                      const SizedBox(width: 8),
                      _OsdIconControl(
                        tooltip: 'Stop & close',
                        icon: Icons.close,
                        accentColor: tokens.accentColor,
                        onPressed: () => _perform(widget.onStop),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildProgramRow(context, compact: compact),
                      const SizedBox(height: 10),
                      _buildProgress(context),
                      const SizedBox(height: 10),
                      _buildControlBar(context, compact: compact),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildChannelIdentity(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 40,
            height: 40,
            child:
                widget.channelLogo != null &&
                    widget.channelLogo!.trim().isNotEmpty
                ? Image.network(
                    widget.channelLogo!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _logoFallback(),
                  )
                : _logoFallback(),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.channelName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isLiveNow)
                    _statusChip(
                      label: '● LIVE',
                      background: const Color(0xFFE5383B),
                    ),
                  if (_timeshiftAvailable && !_isLiveNow) ...[
                    _statusChip(
                      label: 'TIMESHIFT',
                      background: const Color(0x33FFFFFF),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _logoFallback() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          _logoFallbackLabel(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w800,
            fontSize: 12,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }

  Widget _statusChip({required String label, required Color background}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _buildProgramRow(BuildContext context, {required bool compact}) {
    if (!widget.hasEpg) {
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.channelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'No guide data for this channel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xBFFFFFFF),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () => _perform(widget.onGuide),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              foregroundColor: Colors.white,
              backgroundColor: const Color(0x22FFFFFF),
              shape: const StadiumBorder(),
            ),
            child: const Text(
              'Match EPG',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    final now = widget.nowProgram;
    final next = widget.nextProgram;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                now?.title ?? widget.channelName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                now == null
                    ? 'No guide data for this channel'
                    : '${_clockText(now.start)} – ${_clockText(now.end)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xBFFFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text(
                  'Up next',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  next == null
                      ? 'No upcoming program'
                      : '${next.title} · ${_clockText(next.start)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    final now = widget.nowProgram;
    if (!_timeshiftAvailable && widget.epgProgress == null) {
      return const SizedBox.shrink();
    }

    final ratio = _timeshiftAvailable
        ? widget.position.inMilliseconds /
              math.max(1, widget.duration.inMilliseconds)
        : widget.epgProgress!.clamp(0.0, 1.0);
    final clamped = ratio.clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 12,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final playedWidth = constraints.maxWidth * clamped;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    top: 4,
                    bottom: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0x38FFFFFF),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 4,
                    bottom: 4,
                    width: playedWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  if (_timeshiftAvailable)
                    Positioned(
                      left: (playedWidth - 6).clamp(
                        0.0,
                        math.max(0.0, constraints.maxWidth - 12),
                      ),
                      top: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  const Positioned(
                    right: 0,
                    top: 2,
                    bottom: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0xFFE5383B),
                        borderRadius: BorderRadius.all(Radius.circular(999)),
                      ),
                      child: SizedBox(width: 2),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                now == null ? '' : _clockText(now.start),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 11),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _timeshiftAvailable
                    ? (_isLiveNow ? 'Live' : _behindLiveText())
                    : 'On now',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 11),
              ),
            ),
            Expanded(
              child: Text(
                now == null ? '' : _clockText(now.end),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 11),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildControlBar(BuildContext context, {required bool compact}) {
    final liveEdge = _isLiveNow;
    final splitTooltip = _splitLabel;
    final fullScreenTooltip = widget.isFullScreen
        ? 'Exit full screen'
        : 'Full screen';
    final tokens = context.millitopTheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0x1AFFFFFF),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _OsdIconControl(
                  tooltip: 'Channel down',
                  icon: Icons.keyboard_arrow_down,
                  accentColor: tokens.accentColor,
                  onPressed: () => _perform(widget.onChannelDown),
                ),
                _verticalDivider(),
                _OsdIconControl(
                  tooltip: 'Channel up',
                  icon: Icons.keyboard_arrow_up,
                  accentColor: tokens.accentColor,
                  onPressed: () => _perform(widget.onChannelUp),
                ),
              ],
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 8),
            _verticalDivider(),
            const SizedBox(width: 8),
            _OsdIconControl(
              tooltip: widget.isFavorite ? 'Unfavorite' : 'Favorite',
              icon: widget.isFavorite ? Icons.star : Icons.star_border,
              iconColor: widget.isFavorite
                  ? const Color(0xFFF5C518)
                  : Colors.white,
              accentColor: tokens.accentColor,
              onPressed: () => _perform(widget.onFavorite),
            ),
          ],
          const SizedBox(width: 14),
          if (_timeshiftAvailable)
            _OsdIconControl(
              tooltip: 'Back 10 seconds',
              icon: Icons.replay_10,
              accentColor: tokens.accentColor,
              onPressed: () => _perform(widget.onRewind),
            ),
          const SizedBox(width: 8),
          _PrimaryPlayPauseButton(
            isPlaying: widget.isPlaying,
            accentColor: tokens.accentColor,
            onPressed: () => _perform(widget.onPlayPause),
          ),
          if (_timeshiftAvailable) ...[
            const SizedBox(width: 8),
            _OsdIconControl(
              tooltip: 'Forward 10 seconds',
              icon: Icons.forward_10,
              accentColor: tokens.accentColor,
              onPressed: () => _perform(widget.onForward),
            ),
            const SizedBox(width: 8),
            _OsdPillButton(
              tooltip: 'Go live',
              label: 'GO LIVE',
              accentColor: tokens.accentColor,
              foregroundColor: liveEdge
                  ? const Color(0xFFE5383B)
                  : Colors.white,
              borderColor: liveEdge
                  ? const Color(0xFFE5383B)
                  : const Color(0x80FFFFFF),
              onPressed: () => _perform(widget.onGoLive),
            ),
          ],
          const SizedBox(width: 14),
          if (widget.recording)
            _OsdIconControl(
              tooltip: 'Stop recording',
              icon: Icons.fiber_manual_record,
              iconColor: const Color(0xFFE5383B),
              accentColor: tokens.accentColor,
              onPressed: () => _perform(widget.onRecord),
            )
          else
            PopupMenuButton<String>(
              tooltip: 'Record options',
              color: const Color(0xFF121721),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              onOpened: _startRecordMenuKeepAlive,
              onCanceled: _stopRecordMenuKeepAlive,
              onSelected: (value) {
                _stopRecordMenuKeepAlive();
                if (value == 'record_now') {
                  _perform(widget.onRecord);
                } else if (value == 'schedule') {
                  _perform(widget.onSchedule);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem<String>(
                  value: 'record_now',
                  child: Text('Record now'),
                ),
                PopupMenuItem<String>(
                  value: 'schedule',
                  child: Text('Schedule from guide…'),
                ),
              ],
              child: _OsdMenuTrigger(icon: Icons.fiber_manual_record),
            ),
          const SizedBox(width: 8),
          _OsdIconControl(
            tooltip: splitTooltip,
            icon: widget.screenCount == 1 ? Icons.view_week : Icons.grid_view,
            accentColor: tokens.accentColor,
            onPressed: () => _perform(widget.onSplit),
          ),
          const SizedBox(width: 8),
          _OsdIconControl(
            tooltip: fullScreenTooltip,
            icon: widget.isFullScreen
                ? Icons.fullscreen_exit
                : Icons.fullscreen,
            accentColor: tokens.accentColor,
            onPressed: () => _perform(widget.onFullScreen),
          ),
        ],
      ),
    );
  }

  Widget _verticalDivider() =>
      Container(width: 1, height: 24, color: const Color(0x4DFFFFFF));
}

class _OsdIconControl extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final Color iconColor;
  final Color accentColor;
  final VoidCallback? onPressed;

  const _OsdIconControl({
    required this.tooltip,
    required this.icon,
    required this.accentColor,
    required this.onPressed,
    this.iconColor = Colors.white,
  });

  @override
  State<_OsdIconControl> createState() => _OsdIconControlState();
}

class _OsdIconControlState extends State<_OsdIconControl> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hovered || _focused
                  ? const Color(0x2EFFFFFF)
                  : Colors.transparent,
              border: Border.all(
                color: _focused ? widget.accentColor : Colors.transparent,
                width: _focused ? 2 : 0,
              ),
            ),
            child: IconButton(
              onPressed: widget.onPressed,
              icon: Icon(widget.icon, color: widget.iconColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryPlayPauseButton extends StatefulWidget {
  final bool isPlaying;
  final Color accentColor;
  final VoidCallback onPressed;
  const _PrimaryPlayPauseButton({
    required this.isPlaying,
    required this.accentColor,
    required this.onPressed,
  });

  @override
  State<_PrimaryPlayPauseButton> createState() =>
      _PrimaryPlayPauseButtonState();
}

class _PrimaryPlayPauseButtonState extends State<_PrimaryPlayPauseButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.isPlaying ? 'Pause' : 'Play',
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: _focused ? widget.accentColor : Colors.transparent,
                width: _focused ? 2 : 0,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hovered ? const Color(0xFFF5F5F5) : Colors.white,
              ),
              child: IconButton(
                onPressed: widget.onPressed,
                icon: Icon(
                  widget.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.black,
                  size: 30,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OsdPillButton extends StatefulWidget {
  final String tooltip;
  final String label;
  final Color borderColor;
  final Color foregroundColor;
  final Color accentColor;
  final VoidCallback onPressed;
  const _OsdPillButton({
    required this.tooltip,
    required this.label,
    required this.borderColor,
    required this.foregroundColor,
    required this.accentColor,
    required this.onPressed,
  });

  @override
  State<_OsdPillButton> createState() => _OsdPillButtonState();
}

class _OsdPillButtonState extends State<_OsdPillButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: OutlinedButton(
            onPressed: widget.onPressed,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              side: BorderSide(
                color: _focused ? widget.accentColor : widget.borderColor,
                width: _focused ? 2 : 1.4,
              ),
              backgroundColor: _hovered
                  ? const Color(0x1FFFFFFF)
                  : Colors.transparent,
              shape: const StadiumBorder(),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.foregroundColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OsdMenuTrigger extends StatelessWidget {
  final IconData icon;
  const _OsdMenuTrigger({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.transparent),
      ),
      child: Icon(icon, color: Colors.white),
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
