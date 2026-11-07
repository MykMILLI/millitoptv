import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_log.dart';
import 'global_playlists.dart';
import 'music_mini_player.dart';

/// One step of playlist playback. Consecutive songs are grouped so they play
/// as a single Music queue (gapless, with background audio); every other
/// item is its own step.
class PlaylistSegment {
  final List<HubItem> items;
  const PlaylistSegment(this.items);
  bool get isMusic => items.first.type == HubMediaType.song;
  HubItem get first => items.first;
  String get title => isMusic && items.length > 1
      ? '${items.first.title} + ${items.length - 1} more songs'
      : items.first.title;
}

/// Opens one segment and completes when the user is done with it (its
/// screen was closed).
typedef PlaylistSegmentOpener =
    Future<void> Function(BuildContext context, PlaylistSegment segment);

/// Plays a mixed playlist in order or shuffled: songs, YouTube videos,
/// movies, episodes, channels and podcasts one after another.
class PlaylistPlayback {
  final int profileId;
  final PlaylistSegmentOpener open;
  final math.Random random;

  /// Seconds the "Up next" prompt waits before continuing on its own.
  final int upNextSeconds;

  PlaylistPlayback({
    required this.profileId,
    required this.open,
    math.Random? random,
    this.upNextSeconds = 8,
  }) : random = random ?? math.Random();

  /// Order used for playback; shuffled copies never change the saved list.
  List<HubItem> order(List<HubItem> items, {required bool shuffle}) {
    final values = List<HubItem>.from(items);
    if (shuffle) values.shuffle(random);
    return values;
  }

  static List<PlaylistSegment> segments(List<HubItem> items) {
    final result = <PlaylistSegment>[];
    var songs = <HubItem>[];
    for (final item in items) {
      if (item.type == HubMediaType.song) {
        songs.add(item);
        continue;
      }
      if (songs.isNotEmpty) {
        result.add(PlaylistSegment(songs));
        songs = <HubItem>[];
      }
      result.add(PlaylistSegment([item]));
    }
    if (songs.isNotEmpty) result.add(PlaylistSegment(songs));
    return result;
  }

  Future<void> play(
    BuildContext context, {
    required String name,
    required List<HubItem> items,
    bool shuffle = false,
  }) async {
    if (items.isEmpty) return;
    final ordered = order(items, shuffle: shuffle);
    final steps = segments(ordered);
    AppLog.event(
      'playlist.play',
      props: {
        'items': items.length,
        'shuffle': shuffle,
        'types': {for (final item in items) item.type.name}.toList(),
      },
    );
    for (var index = 0; index < steps.length; index++) {
      if (!context.mounted) return;
      final step = steps[index];
      if (index > 0) {
        final next = await _upNext(
          context,
          playlist: name,
          segment: step,
          position: index + 1,
          total: steps.length,
        );
        if (next != true || !context.mounted) return;
      }
      // Songs keep playing in the background after Music closes; stop them
      // before a video or show starts so audio never overlaps.
      if (!step.isMusic && index > 0 && steps[index - 1].isMusic) {
        await MusicMiniPlayerService.instance.closeMini();
      }
      try {
        if (!context.mounted) return;
        await open(context, step);
      } catch (error, stack) {
        AppLog.error(
          LogCategory.playback,
          'Playlist item could not open',
          error: error,
          stackTrace: stack,
          details: {'type': step.first.type.name, 'position': index + 1},
        );
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Skipped "${step.first.title}". $error')),
          );
        }
      }
    }
  }

  Future<bool?> _upNext(
    BuildContext context, {
    required String playlist,
    required PlaylistSegment segment,
    required int position,
    required int total,
  }) => showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpNextDialog(
      playlist: playlist,
      segment: segment,
      position: position,
      total: total,
      seconds: upNextSeconds,
    ),
  );
}

class _UpNextDialog extends StatefulWidget {
  final String playlist;
  final PlaylistSegment segment;
  final int position, total, seconds;
  const _UpNextDialog({
    required this.playlist,
    required this.segment,
    required this.position,
    required this.total,
    required this.seconds,
  });
  @override
  State<_UpNextDialog> createState() => _UpNextDialogState();
}

class _UpNextDialogState extends State<_UpNextDialog> {
  late int remaining = widget.seconds;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    if (widget.seconds > 0) {
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (remaining <= 1) {
          timer?.cancel();
          Navigator.pop(context, true);
          return;
        }
        setState(() => remaining--);
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('playlist-up-next'),
    title: Text('Up next in ${widget.playlist}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.segment.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '${widget.segment.first.label} · ${widget.position} of ${widget.total}'
          '${widget.seconds > 0 ? ' · starts in ${remaining}s' : ''}',
        ),
      ],
    ),
    actions: [
      TextButton(
        key: const ValueKey('playlist-up-next-stop'),
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Stop'),
      ),
      FilledButton(
        key: const ValueKey('playlist-up-next-play'),
        autofocus: true,
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Play now'),
      ),
    ],
  );
}
