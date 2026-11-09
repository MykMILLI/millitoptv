import '../screens/watch_party_panel.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/podcast_playback.dart';
import '../theme/millitop_visual_theme.dart';

String podcastTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 1 << 40);
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

class PodcastPlayerBar extends StatelessWidget {
  final VoidCallback onOpenQueue;
  final VoidCallback? onOpenPodcasts;
  final PodcastPlayback? playback;
  PodcastPlayback get controller => playback ?? PodcastPlayback.instance;
  const PodcastPlayerBar({
    super.key,
    required this.onOpenQueue,
    this.onOpenPodcasts,
    this.playback,
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final playback = controller;
      final active = playback.active;
      if (active == null) return const SizedBox.shrink();
      final tokens = context.millitopTheme;
      Future<void> run(Future<void> Function() action) async {
        try {
          await action();
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Podcast control failed: $e')),
            );
          }
        }
      }

      final available = playback.duration.inMilliseconds > 0;
      final fraction = available
          ? (playback.position.inMilliseconds /
                    playback.duration.inMilliseconds)
                .clamp(0.0, 1.0)
          : 0.0;
      return Material(
        color: tokens.panelColor,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 950;
              final title = ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  active.video ? Icons.videocam : Icons.podcasts,
                  color: tokens.accentColor,
                ),
                title: Text(
                  active.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  active.show.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: onOpenPodcasts,
              );
              final controls = [
                IconButton(
                  tooltip: 'Back 15 seconds',
                  icon: const Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(Icons.replay),
                      Text('15', style: TextStyle(fontSize: 8)),
                    ],
                  ),
                  onPressed: () => unawaited(
                    run(
                      () => playback.seek(
                        playback.position - const Duration(seconds: 15),
                      ),
                    ),
                  ),
                ),
                IconButton.filled(
                  tooltip: playback.playing ? 'Pause podcast' : 'Play podcast',
                  icon: Icon(playback.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: playback.opening
                      ? null
                      : () => unawaited(run(playback.toggle)),
                ),
                IconButton(
                  tooltip: 'Forward 30 seconds',
                  icon: const Icon(Icons.forward_30),
                  onPressed: () => unawaited(
                    run(
                      () => playback.seek(
                        playback.position + const Duration(seconds: 30),
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<double>(
                  tooltip: 'Playback speed',
                  initialValue: playback.library.speed,
                  onSelected: (value) =>
                      unawaited(run(() => playback.setSpeed(value))),
                  itemBuilder: (_) => [
                    for (final speed in [
                      0.5,
                      0.75,
                      1.0,
                      1.25,
                      1.5,
                      1.75,
                      2.0,
                      3.0,
                    ])
                      PopupMenuItem(value: speed, child: Text('${speed}x')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('${playback.library.speed}x'),
                  ),
                ),
                if (!compact)
                  Expanded(
                    child: Slider(
                      value: fraction,
                      onChanged: available
                          ? (value) => unawaited(
                              run(
                                () => playback.seek(
                                  Duration(
                                    milliseconds:
                                        (value *
                                                playback
                                                    .duration
                                                    .inMilliseconds)
                                            .round(),
                                  ),
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                Text(
                  podcastTime(playback.position),
                  style: TextStyle(color: tokens.mutedColor),
                ),
                IconButton(
                  tooltip: 'Podcast queue',
                  onPressed: onOpenQueue,
                  icon: const Icon(Icons.queue_music),
                ),
                const WatchPartyIconButton(),
                PopupMenuButton<int>(
                  tooltip: playback.sleepUntil == null
                      ? 'Sleep timer'
                      : 'Sleep timer active',
                  onSelected: (minutes) => playback.setSleep(
                    minutes == 0 ? null : Duration(minutes: minutes),
                  ),
                  itemBuilder: (_) => [
                    for (final minutes in [0, 15, 30, 45, 60])
                      PopupMenuItem(
                        value: minutes,
                        child: Text(
                          minutes == 0
                              ? 'Cancel sleep timer'
                              : '$minutes minutes',
                        ),
                      ),
                  ],
                  icon: Icon(
                    Icons.bedtime_outlined,
                    color: playback.sleepUntil != null
                        ? tokens.accentColor
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: 'Stop podcast',
                  onPressed: () => unawaited(run(playback.stop)),
                  icon: const Icon(Icons.close),
                ),
              ];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (playback.opening || playback.buffering)
                    const LinearProgressIndicator(),
                  if (playback.error.isNotEmpty)
                    Text(
                      playback.error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (compact) ...[
                    title,
                    Slider(
                      value: fraction,
                      onChanged: available
                          ? (value) => unawaited(
                              run(
                                () => playback.seek(
                                  Duration(
                                    milliseconds:
                                        (value *
                                                playback
                                                    .duration
                                                    .inMilliseconds)
                                            .round(),
                                  ),
                                ),
                              ),
                            )
                          : null,
                    ),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: controls,
                    ),
                  ] else
                    Row(
                      children: [
                        SizedBox(width: 220, child: title),
                        Expanded(child: Row(children: controls)),
                        SizedBox(
                          width: 100,
                          child: Slider(
                            value: playback.volume,
                            max: 100,
                            semanticFormatterCallback: (value) =>
                                'Volume ${value.round()} percent',
                            onChanged: (value) =>
                                unawaited(run(() => playback.setVolume(value))),
                          ),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> showPodcastQueue(
  BuildContext context, {
  PodcastPlayback? controller,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: 420,
      child: AnimatedBuilder(
        animation: controller ?? PodcastPlayback.instance,
        builder: (context, _) {
          final playback = controller ?? PodcastPlayback.instance;
          return Column(
            children: [
              const ListTile(
                title: Text('Playing queue'),
                subtitle: Text('Episodes play in this order.'),
              ),
              Expanded(
                child: playback.library.queue.isEmpty
                    ? const Center(
                        child: Text(
                          'Queue is empty. Add episodes with the queue button.',
                        ),
                      )
                    : ListView(
                        children: [
                          for (final episode in playback.library.queue)
                            ListTile(
                              title: Text(
                                episode.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                episode.show.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              leading: IconButton(
                                tooltip: 'Play queued episode',
                                icon: const Icon(Icons.play_arrow),
                                onPressed: () =>
                                    unawaited(playback.play(episode)),
                              ),
                              trailing: IconButton(
                                tooltip: 'Remove from queue',
                                icon: const Icon(Icons.close),
                                onPressed: () async {
                                  try {
                                    await playback.removeQueued(episode);
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text('$e')),
                                      );
                                    }
                                  }
                                },
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    ),
  ),
);
