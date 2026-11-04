import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/music_playback.dart';
import '../services/music_service.dart';

const musicAccent = Color(0xFFB79AFF);
const musicSurface = Color(0xFF24232C);

/// Resolves artwork using the current connection, never a persisted signed URL.
class MusicCover extends StatefulWidget {
  final MusicTrack? track;
  final NavidromeClient? client;
  final double? size;
  const MusicCover({super.key, this.track, this.client, this.size});

  @override
  State<MusicCover> createState() => _MusicCoverState();
}

class _MusicCoverState extends State<MusicCover> {
  Uri? _uri;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(MusicCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.track?.coverArtId != widget.track?.coverArtId) {
      _resolve();
    }
  }

  void _resolve() {
    final id = widget.track?.coverArtId;
    _uri = null;
    if (id != null && id.isNotEmpty && widget.client != null) {
      try {
        _uri = widget.client!.coverArtUri(id);
      } catch (_) {
        // A missing connection must not prevent the player from rendering.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: const Color(0xFF393047),
      child: const Center(
        child: Icon(Icons.album_outlined, color: musicAccent, size: 32),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _uri == null
            ? fallback
            : Image.network(
                _uri.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class VinylArtwork extends StatefulWidget {
  final MusicTrack? track;
  final NavidromeClient? client;
  final bool playing;
  final bool vinyl;
  const VinylArtwork({
    super.key,
    this.track,
    this.client,
    required this.playing,
    required this.vinyl,
  });

  @override
  State<VinylArtwork> createState() => _VinylArtworkState();
}

class _VinylArtworkState extends State<VinylArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );

  void _updateMotion() {
    if (widget.playing &&
        widget.vinyl &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context)) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(VinylArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.vinyl ? 'Vinyl record artwork' : 'Album artwork',
    image: true,
    child: AspectRatio(
      aspectRatio: 1,
      child: widget.vinyl
          ? LayoutBuilder(
              builder: (context, constraints) => Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 0,
                    top: constraints.maxHeight * .16,
                    bottom: constraints.maxHeight * .16,
                    width: constraints.maxWidth * .65,
                    child: MusicCover(
                      track: widget.track,
                      client: widget.client,
                    ),
                  ),
                  Positioned(
                    right: 0,
                    width: constraints.maxWidth * .88,
                    height: constraints.maxHeight * .88,
                    child: RotationTransition(
                      key: const ValueKey('vinyl-rotation'),
                      turns: _rotation,
                      child: CustomPaint(
                        painter: const _Grooves(),
                        child: Center(
                          child: FractionallySizedBox(
                            widthFactor: .34,
                            heightFactor: .34,
                            child: ClipOval(
                              child: MusicCover(
                                track: widget.track,
                                client: widget.client,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    right: 8,
                    top: 8,
                    child: Icon(Icons.circle, size: 8, color: musicAccent),
                  ),
                ],
              ),
            )
          : MusicCover(track: widget.track, client: widget.client),
    ),
  );
}

class _Grooves extends CustomPainter {
  const _Grooves();
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF111116));
    final line = Paint()
      ..color = const Color(0xFF34333C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    for (double r = radius * .4; r < radius * .96; r += 4) {
      canvas.drawCircle(center, r, line);
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * .77),
      -.9,
      .75,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: .1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * .22,
    );
  }

  @override
  bool shouldRepaint(_Grooves oldDelegate) => false;
}

Future<void> _command(Future<void> Function() action) async {
  try {
    await action();
  } catch (_) {
    // The controller exposes a sanitized, persistent playback error.
  }
}

class MusicTransport extends StatelessWidget {
  final MusicPlayback playback;
  const MusicTransport({super.key, required this.playback});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: playback.index <= 0 ? 'No previous track' : 'Previous track',
        onPressed: playback.current == null || playback.index <= 0
            ? null
            : () => unawaited(_command(playback.previous)),
        icon: const Icon(Icons.skip_previous_rounded),
      ),
      IconButton.filled(
        tooltip: playback.playing ? 'Pause' : 'Play',
        onPressed: playback.current == null
            ? null
            : () => unawaited(_command(playback.toggle)),
        icon: Icon(
          playback.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ),
      ),
      IconButton(
        tooltip: playback.index + 1 >= playback.queue.length
            ? 'No next track'
            : 'Next track',
        onPressed: playback.current == null ||
                playback.index + 1 >= playback.queue.length
            ? null
            : () => unawaited(_command(playback.next)),
        icon: const Icon(Icons.skip_next_rounded),
      ),
    ],
  );
}

String musicClock(Duration value) {
  final seconds = math.max(0, value.inSeconds);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class MusicSeekBar extends StatelessWidget {
  final MusicPlayback playback;
  const MusicSeekBar({super.key, required this.playback});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<MusicProgress>(
    valueListenable: playback.progress,
    builder: (context, progress, _) {
      final duration = progress.duration.inMilliseconds.toDouble();
      return Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 64),
            child: Text(musicClock(progress.position), maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
          ),
          Expanded(
            child: Slider(
              label: musicClock(progress.position),
              semanticFormatterCallback: (v) =>
                  musicClock(Duration(milliseconds: v.round())),
              min: 0,
              max: math.max(1, duration).toDouble(),
              value: progress.position.inMilliseconds
                  .toDouble()
                  .clamp(0, math.max(1, duration)).toDouble(),
              onChanged: duration <= 0
                  ? null
                  : (v) => unawaited(
                      _command(() => playback.seek(Duration(milliseconds: v.round()))),
                    ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 64),
            child: Text(musicClock(progress.duration), maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
          ),
        ],
      );
    },
  );
}

class MusicVolume extends StatelessWidget {
  final MusicPlayback playback;
  const MusicVolume({super.key, required this.playback});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.volume_up_outlined, size: 20),
      Expanded(
        child: Slider(
          label: 'Volume ${playback.volume.round()}%',
          max: 100,
          value: playback.volume.clamp(0, 100).toDouble(),
          onChanged: (v) => unawaited(_command(() => playback.setVolume(v))),
          semanticFormatterCallback: (v) => 'Volume ${v.round()} percent',
        ),
      ),
    ],
  );
}

class MusicQueue extends StatelessWidget {
  final MusicPlayback playback;
  final NavidromeClient? client;
  const MusicQueue({super.key, required this.playback, this.client});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('UP NEXT', style: TextStyle(letterSpacing: 2, color: Colors.white60)),
      const SizedBox(height: 8),
      if (playback.index + 1 >= playback.queue.length)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Your queue is clear.', style: TextStyle(color: Colors.white54)),
        ),
      for (var i = playback.index + 1; i < playback.queue.length; i++)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: MusicCover(track: playback.queue[i], client: client, size: 40),
          title: Text(playback.queue[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(playback.queue[i].artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.play_arrow, size: 18),
          onTap: () => unawaited(_command(() => playback.select(i))),
        ),
    ],
  );
}

void openMusicQueue(BuildContext context, MusicPlayback playback, NavidromeClient? client) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: ListenableBuilder(
          listenable: playback,
          builder: (_, _) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: MusicQueue(playback: playback, client: client),
          ),
        ),
      ),
    ),
  );
}

class MusicNowPlaying extends StatefulWidget {
  final MusicPlayback playback;
  final NavidromeClient? client;
  final VoidCallback? onRadio;
  final VoidCallback? onSaveStation;
  final bool fullScreen;
  final bool buildingRadio;
  final String? radioDescription;
  const MusicNowPlaying({
    super.key,
    required this.playback,
    this.client,
    this.onRadio,
    this.onSaveStation,
    this.fullScreen = false,
    this.buildingRadio = false,
    this.radioDescription,
  });

  @override
  State<MusicNowPlaying> createState() => _MusicNowPlayingState();
}

class _MusicNowPlayingState extends State<MusicNowPlaying> {
  bool _vinyl = true;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.playback,
    builder: (context, _) {
      final playback = widget.playback;
      final track = playback.current;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('NOW PLAYING', style: TextStyle(letterSpacing: 3, color: Colors.white60, fontSize: 11)),
            const SizedBox(height: 18),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: VinylArtwork(
                  track: track,
                  client: widget.client,
                  playing: playback.playing,
                  vinyl: _vinyl,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Vinyl'),
                    selected: _vinyl,
                    onSelected: (_) => setState(() => _vinyl = true),
                  ),
                  ChoiceChip(
                    label: const Text('Artwork'),
                    selected: !_vinyl,
                    onSelected: (_) => setState(() => _vinyl = false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Text(track?.title ?? 'Find your next favorite',
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(track == null ? 'Choose a song to begin' : '${track.artist} · ${track.album}',
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60)),
            if (playback.buffering) const LinearProgressIndicator(),
            if (playback.error != null)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Playback unavailable. Try another track or reconnect in setup.',
                    style: TextStyle(color: musicAccent)),
              ),
            if (widget.fullScreen) ...[
              const SizedBox(height: 14),
              MusicSeekBar(playback: playback),
              Center(child: MusicTransport(playback: playback)),
              MusicVolume(playback: playback),
            ],
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: track == null || widget.buildingRadio
                      ? null
                      : widget.onRadio,
                  icon: const Icon(Icons.sensors, size: 18),
                  label: Text(widget.buildingRadio ? 'Building radio…' : 'Start radio'),
                ),
                if (widget.onSaveStation != null)
                  TextButton(
                    onPressed: widget.onSaveStation,
                    child: const Text('Save station'),
                  ),
              ],
            ),
            if (widget.radioDescription != null) ...[
              const SizedBox(height: 16),
              const Text('RADIO SOURCE', style: TextStyle(
                  color: musicAccent, letterSpacing: 2, fontSize: 11)),
              const SizedBox(height: 6),
              Text(widget.radioDescription!,
                  style: const TextStyle(color: Colors.white60)),
            ],
            const Divider(height: 36),
            MusicQueue(playback: playback, client: widget.client),
          ],
        ),
      );
    },
  );
}

class MusicPlayerBar extends StatelessWidget {
  final MusicPlayback playback;
  final NavidromeClient? client;
  final VoidCallback onOpen;
  const MusicPlayerBar({
    super.key,
    required this.playback,
    this.client,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: playback,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 850;
        final track = playback.current;
        final metadata = Expanded(
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  MusicCover(track: track, client: client, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track?.title ?? 'Nothing playing', maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(track?.artist ?? 'Discover your music', maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return ColoredBox(
          color: musicSurface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  metadata,
                  if (desktop) ...[
                    const SizedBox(width: 20),
                    SizedBox(
                      width: constraints.maxWidth * .4,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MusicTransport(playback: playback),
                          MusicSeekBar(playback: playback),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    SizedBox(width: 140, child: MusicVolume(playback: playback)),
                  ] else
                    IconButton(
                      tooltip: playback.playing ? 'Pause' : 'Play',
                      onPressed: track == null ? null : () => unawaited(_command(playback.toggle)),
                      icon: Icon(playback.playing ? Icons.pause : Icons.play_arrow),
                    ),
                  IconButton(
                    tooltip: 'Open queue',
                    onPressed: () => openMusicQueue(context, playback, client),
                    icon: const Icon(Icons.queue_music),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
