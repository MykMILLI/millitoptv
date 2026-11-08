import 'package:flutter/material.dart';

class MediaQueueRow {
  const MediaQueueRow({
    required this.id,
    required this.title,
    required this.subtitle,
    this.poster,
    this.nowPlaying = false,
    this.canMoveUp = false,
    this.canMoveDown = false,
    this.canRemove = true,
  });
  final String id, title, subtitle;
  final Widget? poster;
  final bool nowPlaying;
  final bool canMoveUp;
  final bool canMoveDown;
  final bool canRemove;
}

/// Parent supplies stable source-qualified IDs and owns the actual queue.
class MovieQueuePanel extends StatelessWidget {
  const MovieQueuePanel({
    super.key,
    required this.items,
    required this.autoplay,
    required this.onAutoplayChanged,
    required this.onPlay,
    required this.onRemove,
    required this.onReorder,
    required this.onMoveUp,
    required this.onMoveDown,
  });
  final List<MediaQueueRow> items;
  final bool autoplay;
  final ValueChanged<bool> onAutoplayChanged;
  final ValueChanged<String> onPlay, onRemove;
  final ValueChanged<String> onMoveUp, onMoveDown;

  /// Receives normalized indices from [onReorderItem].
  final void Function(int oldIndex, int newIndex) onReorder;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (items.isEmpty)
        const Expanded(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('Your queue is empty. Add movies from your library.'),
            ),
          ),
        )
      else
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: items.length,
            onReorderItem: onReorder,
            itemBuilder: (context, index) {
              final item = items[index];
              return ListTile(
                key: ValueKey(item.id),
                selected: item.nowPlaying,
                leading: item.poster == null
                    ? const Icon(Icons.movie_outlined)
                    : SizedBox(width: 36, height: 54, child: item.poster),
                title: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.nowPlaying ? 'Now playing' : item.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => onPlay(item.id),
                trailing: item.nowPlaying
                    ? const Icon(Icons.equalizer)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Move up',
                            onPressed: item.canMoveUp
                                ? () => onMoveUp(item.id)
                                : null,
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            tooltip: 'Move down',
                            onPressed: item.canMoveDown
                                ? () => onMoveDown(item.id)
                                : null,
                            icon: const Icon(Icons.arrow_downward),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: const Tooltip(
                              message: 'Drag to reorder',
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.drag_handle),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove from queue',
                            onPressed: item.canRemove
                                ? () => onRemove(item.id)
                                : null,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
              );
            },
          ),
        ),
      SwitchListTile(
        title: const Text('Autoplay queue'),
        value: autoplay,
        onChanged: onAutoplayChanged,
      ),
    ],
  );
}

class EpisodeRow {
  const EpisodeRow({
    required this.id,
    required this.season,
    required this.number,
    required this.title,
    required this.subtitle,
    this.thumbnail,
    this.nowPlaying = false,
  });
  final String id, title, subtitle;
  final int season, number;
  final Widget? thumbnail;
  final bool nowPlaying;
}

class SeriesEpisodesPanel extends StatelessWidget {
  const SeriesEpisodesPanel({
    super.key,
    required this.seasons,
    required this.selectedSeason,
    required this.onSeasonChanged,
    required this.episodes,
    required this.onPlay,
    required this.autoplay,
    required this.onAutoplayChanged,
    this.loading = false,
    this.error,
    this.onRetry,
  });
  final List<int> seasons;
  final int? selectedSeason;
  final ValueChanged<int> onSeasonChanged;
  final List<EpisodeRow> episodes;
  final ValueChanged<String> onPlay;
  final bool autoplay, loading;
  final ValueChanged<bool> onAutoplayChanged;
  final String? error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final uniqueSeasons = seasons.toSet().toList()..sort();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButton<int>(
            isExpanded: true,
            hint: const Text('Choose season'),
            value: uniqueSeasons.contains(selectedSeason)
                ? selectedSeason
                : null,
            items: [
              for (final season in uniqueSeasons)
                DropdownMenuItem(
                  value: season,
                  child: Text(season == 0 ? 'Specials' : 'Season $season'),
                ),
            ],
            onChanged: (v) {
              if (v != null) onSeasonChanged(v);
            },
          ),
        ),
        if (loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (error != null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  if (onRetry != null)
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              children: [
                if (!episodes.any((e) => e.season == selectedSeason))
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No episodes in this season.'),
                  ),
                for (final episode in episodes.where(
                  (e) => e.season == selectedSeason,
                ))
                  ListTile(
                    selected: episode.nowPlaying,
                    leading: episode.thumbnail == null
                        ? const Icon(Icons.tv)
                        : SizedBox(
                            width: 72,
                            height: 44,
                            child: episode.thumbnail,
                          ),
                    title: Text(
                      'E${episode.number} • ${episode.title}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      episode.nowPlaying ? 'Now playing' : episode.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.play_arrow),
                    onTap: () => onPlay(episode.id),
                  ),
              ],
            ),
          ),
        SwitchListTile(
          title: const Text('Autoplay next episode'),
          value: autoplay,
          onChanged: onAutoplayChanged,
        ),
      ],
    );
  }
}
