import 'package:flutter/material.dart';

enum PlayerSidePanel { none, queue, episodes }

/// Overlay only. Does not create, open, dispose or replace the native player.
class MediaPlayerChrome extends StatefulWidget {
  const MediaPlayerChrome({
    super.key,
    required this.video,
    required this.title,
    required this.metadata,
    this.description,
    this.poster,
    required this.playing,
    required this.position,
    required this.duration,
    required this.volume,
    required this.muted,
    required this.speed,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onToggleMute,
    required this.onVolumeChanged,
    required this.onDescription,
    required this.onSubtitles,
    required this.onSpeed,
    required this.onSettings,
    required this.onFullscreen,
    required this.onBack,
    this.onSleepTimer,
    this.sleepTimerActive = false,
    this.onPipHome,
    this.onToggleFavorite,
    this.favoriteActive = false,
    this.onAddToPlaylist,
    this.onPreviousQueueItem,
    this.onNextQueueItem,
    this.queuePositionLabel,
    required this.panel,
    required this.onPanelChanged,
    required this.queuePanel,
    required this.seekIntervalSeconds,
    this.episodesPanel,
    this.onPreviousEpisode,
    this.onNextEpisode,
    this.fullscreen = false,
    this.visible = true,
    this.onReveal,
  });
  final Widget video;
  final String title, metadata;
  final String? description;
  final Widget? poster;
  final bool playing, muted, fullscreen, visible;
  final Duration position, duration;
  final double volume, speed;
  final VoidCallback onPlayPause, onSeekBack, onSeekForward, onToggleMute;
  final VoidCallback onDescription,
      onSubtitles,
      onSpeed,
      onSettings,
      onFullscreen,
      onBack;
  final VoidCallback? onSleepTimer;
  final bool sleepTimerActive;
  final VoidCallback? onPipHome;
  final VoidCallback? onToggleFavorite;
  final bool favoriteActive;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onPreviousQueueItem;
  final VoidCallback? onNextQueueItem;
  final String? queuePositionLabel;
  final VoidCallback? onPreviousEpisode, onNextEpisode, onReveal;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolumeChanged;
  final PlayerSidePanel panel;
  final ValueChanged<PlayerSidePanel> onPanelChanged;
  final Widget queuePanel;
  final Widget? episodesPanel;
  final int seekIntervalSeconds;
  @override
  State<MediaPlayerChrome> createState() => _MediaPlayerChromeState();
}

class _MediaPlayerChromeState extends State<MediaPlayerChrome> {
  double? _scrub;
  String _time(Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    final mm = ((s ~/ 60) % 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return s >= 3600 ? '${s ~/ 3600}:$mm:$ss' : '${s ~/ 60}:$ss';
  }

  Widget _button(
    String label,
    IconData icon,
    VoidCallback? action, {
    bool selected = false,
  }) => IconButton(
    tooltip: label,
    onPressed: action,
    color: selected ? Theme.of(context).colorScheme.primary : null,
    icon: Icon(icon),
  );
  void _toggle(PlayerSidePanel panel) => widget.onPanelChanged(
    widget.panel == panel ? PlayerSidePanel.none : panel,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 1150;
      final compact = box.maxWidth < 600;
      final show = widget.visible || widget.panel != PlayerSidePanel.none;
      final max = widget.duration.inMilliseconds > 0
          ? widget.duration.inMilliseconds.toDouble()
          : 1.0;
      final pos = (_scrub ?? widget.position.inMilliseconds.toDouble())
          .clamp(0.0, max)
          .toDouble();
      final playback = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.onPreviousQueueItem != null)
            _button(
              'Previous queue item',
              Icons.skip_previous,
              widget.onPreviousQueueItem,
            ),
          if (widget.queuePositionLabel?.trim().isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(widget.queuePositionLabel!.trim()),
            ),
          if (widget.onNextQueueItem != null)
            _button('Next queue item', Icons.skip_next, widget.onNextQueueItem),
          if (widget.episodesPanel != null)
            _button(
              'Previous episode',
              Icons.skip_previous,
              widget.onPreviousEpisode,
            ),
          _button(
            'Seek backward ${widget.seekIntervalSeconds}s',
            Icons.replay,
            widget.onSeekBack,
          ),
          IconButton.filled(
            tooltip: widget.playing ? 'Pause' : 'Play',
            iconSize: 32,
            onPressed: widget.onPlayPause,
            icon: Icon(widget.playing ? Icons.pause : Icons.play_arrow),
          ),
          _button(
            'Seek forward ${widget.seekIntervalSeconds}s',
            Icons.forward,
            widget.onSeekForward,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('${widget.seekIntervalSeconds}s'),
          ),
          if (widget.episodesPanel != null)
            _button('Next episode', Icons.skip_next, widget.onNextEpisode),
        ],
      );
      final volume = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _button(
            widget.muted ? 'Unmute' : 'Mute',
            widget.muted || widget.volume == 0
                ? Icons.volume_off
                : Icons.volume_up,
            widget.onToggleMute,
          ),
          SizedBox(
            width: compact ? 76 : 110,
            child: Slider(
              value: widget.volume.clamp(0.0, 100.0).toDouble(),
              min: 0,
              max: 100,
              label: '${widget.volume.round()}%',
              onChanged: widget.onVolumeChanged,
            ),
          ),
        ],
      );
      final options = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (widget.episodesPanel != null)
            TextButton.icon(
              onPressed: () => _toggle(PlayerSidePanel.episodes),
              style: TextButton.styleFrom(
                foregroundColor: widget.panel == PlayerSidePanel.episodes
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              icon: const Icon(Icons.video_library_outlined),
              label: const Text('Episodes'),
            ),
          TextButton.icon(
            onPressed: () => _toggle(PlayerSidePanel.queue),
            style: TextButton.styleFrom(
              foregroundColor: widget.panel == PlayerSidePanel.queue
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            icon: const Icon(Icons.playlist_play),
            label: const Text('Queue'),
          ),
          if (widget.onToggleFavorite != null)
            _button(
              widget.favoriteActive ? 'Remove favorite' : 'Add favorite',
              widget.favoriteActive ? Icons.favorite : Icons.favorite_border,
              widget.onToggleFavorite,
            ),
          if (widget.onAddToPlaylist != null)
            _button(
              'Add to playlist',
              Icons.playlist_add,
              widget.onAddToPlaylist,
            ),
          _button(
            'Subtitles',
            Icons.closed_caption_outlined,
            widget.onSubtitles,
          ),
          TextButton(
            onPressed: widget.onSpeed,
            child: Text('${widget.speed.toStringAsFixed(2)}×'),
          ),
          _button(
            'Playback settings',
            Icons.settings_outlined,
            widget.onSettings,
          ),
          _button(
            widget.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
            widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            widget.onFullscreen,
          ),
        ],
      );
      final controls = Material(
        color: Theme.of(context).colorScheme.surface.withAlpha(240),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(_time(Duration(milliseconds: pos.round()))),
                  Expanded(
                    child: Slider(
                      value: pos,
                      max: max,
                      onChangeStart: widget.duration > Duration.zero
                          ? (v) => setState(() => _scrub = v)
                          : null,
                      onChanged: widget.duration > Duration.zero
                          ? (v) => setState(() => _scrub = v)
                          : null,
                      onChangeEnd: widget.duration > Duration.zero
                          ? (v) {
                              widget.onSeek(Duration(milliseconds: v.round()));
                              setState(() => _scrub = null);
                            }
                          : null,
                    ),
                  ),
                  Text(_time(widget.duration)),
                ],
              ),
              if (wide)
                SizedBox(
                  height: 72,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final sideWidth = (constraints.maxWidth * 0.28).clamp(
                        220.0,
                        360.0,
                      );
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned(
                            left: 0,
                            width: sideWidth,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: volume,
                            ),
                          ),
                          Center(child: playback),
                          Positioned(
                            right: 0,
                            width: sideWidth,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: options,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                )
              else ...[
                Center(child: playback),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [volume, options],
                ),
              ],
            ],
          ),
        ),
      );
      final panel = widget.panel == PlayerSidePanel.episodes
          ? widget.episodesPanel
          : widget.queuePanel;
      return Stack(
        children: [
          Positioned.fill(child: widget.video),
          if (!show && widget.onReveal != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: widget.onReveal,
                child: const SizedBox.expand(),
              ),
            ),
          if (show)
            Positioned.fill(
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.all(compact ? 8 : 24),
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _button('Back', Icons.arrow_back, widget.onBack),
                          if (widget.onSleepTimer != null)
                            _button(
                              widget.sleepTimerActive
                                  ? 'Sleep timer running'
                                  : 'Sleep timer',
                              widget.sleepTimerActive
                                  ? Icons.timer_outlined
                                  : Icons.nightlight_round_outlined,
                              widget.onSleepTimer,
                            ),
                          if (widget.onPipHome != null)
                            _button(
                              'PiP and Home',
                              Icons.picture_in_picture_alt_outlined,
                              widget.onPipHome,
                            ),
                          if (widget.poster != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: SizedBox(
                                width: compact ? 60 : 84,
                                height: compact ? 90 : 126,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: widget.poster!,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Text(
                                  widget.metadata,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          _button(
                            'Movie or episode description',
                            Icons.info_outline,
                            widget.onDescription,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child:
                              widget.panel == PlayerSidePanel.none ||
                                  panel == null
                              ? const SizedBox.shrink()
                              : SizedBox(
                                  width: box.maxWidth < 440
                                      ? box.maxWidth
                                      : 360,
                                  child: Material(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surface.withAlpha(245),
                                    borderRadius: BorderRadius.circular(16),
                                    clipBehavior: Clip.antiAlias,
                                    child: Column(
                                      children: [
                                        ListTile(
                                          title: Text(
                                            widget.panel ==
                                                    PlayerSidePanel.episodes
                                                ? 'Episodes'
                                                : 'Movie Queue',
                                          ),
                                          trailing: _button(
                                            'Close panel',
                                            Icons.close,
                                            () => widget.onPanelChanged(
                                              PlayerSidePanel.none,
                                            ),
                                          ),
                                        ),
                                        Expanded(child: panel),
                                      ],
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // At short heights the chrome scrolls rather than overflowing vertically.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: box.maxHeight * .48,
                        ),
                        child: SingleChildScrollView(child: controls),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
