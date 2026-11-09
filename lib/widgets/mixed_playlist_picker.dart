import 'package:flutter/material.dart';

import '../services/app_log.dart';
import '../services/global_playlists.dart';
import '../services/profile_sync.dart';

/// Lets the user drop any media (song, YouTube video, movie, episode,
/// channel, podcast) into one of their mixed playlists, or start a new one.
/// Saves, schedules a profile sync and shows a confirmation. Returns the
/// playlist the item was added to, or null when cancelled.
Future<HubPlaylist?> addToMixedPlaylist(
  BuildContext context, {
  required int profileId,
  required HubItem item,
  GlobalPlaylistStore? store,
}) => addToMixedPlaylistItems(
  context,
  profileId: profileId,
  items: [item],
  store: store,
);

Future<HubPlaylist?> addToMixedPlaylistItems(
  BuildContext context, {
  required int profileId,
  required List<HubItem> items,
  GlobalPlaylistStore? store,
  String? promptTitle,
}) async {
  if (items.isEmpty) {
    return null;
  }
  final uniqueItems = <String, HubItem>{
    for (final item in items) item.key: item,
  }.values.toList();
  final playlists = store ?? GlobalPlaylistStore();
  final library = await playlists.load(profileId);
  final lists = library.playlists.values.where((p) => !p.deleted).toList()
    ..sort((a, b) => b.updatedAtUtc.compareTo(a.updatedAtUtc));
  if (!context.mounted) {
    return null;
  }
  final choice = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
          maxWidth: 560,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                promptTitle ??
                    (uniqueItems.length == 1
                        ? 'Add "${uniqueItems.first.title}" to a playlist'
                        : 'Add ${uniqueItems.length} items to a playlist'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'Playlists can mix songs, YouTube videos, movies, shows, '
                'channels and podcasts.',
              ),
            ),
            ListTile(
              key: const ValueKey('mixed-playlist-new'),
              leading: const Icon(Icons.add),
              title: const Text('New playlist'),
              onTap: () => Navigator.pop(ctx, _newPlaylist),
            ),
            for (final list in lists)
              ListTile(
                key: ValueKey('mixed-playlist-${list.id}'),
                leading: Icon(
                  uniqueItems.any(
                    (candidate) => list.items.any((v) => v.key == candidate.key),
                  )
                      ? Icons.playlist_add_check
                      : Icons.playlist_play,
                ),
                title: Text(
                  list.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${list.items.length} items'),
                onTap: () => Navigator.pop(ctx, list.id),
              ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) {
    return null;
  }
  HubPlaylist? saved;
  try {
    if (choice == _newPlaylist) {
      final name = await _askName(context);
      if (name == null) {
        return null;
      }
      saved = await playlists.savePlaylist(
        profileId,
        name: name,
        items: uniqueItems,
      );
    } else {
      final list = (await playlists.load(profileId)).playlists[choice];
      if (list == null || list.deleted) {
        throw StateError('That playlist no longer exists.');
      }
      final additions = uniqueItems
          .where((candidate) => !list.items.any((value) => value.key == candidate.key))
          .toList();
      if (additions.isEmpty) {
        if (context.mounted) _toast(context, 'Already in ${list.name}');
        return list;
      }
      saved = await playlists.savePlaylist(
        profileId,
        id: list.id,
        name: list.name,
        items: [...list.items, ...additions],
      );
    }
  } catch (error, stack) {
    AppLog.error(
      LogCategory.app,
      'Could not add to playlist',
      error: error,
      stackTrace: stack,
      details: {
        'types': uniqueItems.map((entry) => entry.type.name).toSet().toList(),
      },
    );
    if (context.mounted) {
      _toast(context, 'Could not add to the playlist. $error');
    }
    return null;
  }
  AppLog.event(
    'playlist.add',
    props: {
      'count': uniqueItems.length,
      'types': uniqueItems.map((entry) => entry.type.name).toSet().toList(),
    },
  );
  ProfileSync.schedulePush(profileId);
  if (context.mounted) {
    _toast(
      context,
      uniqueItems.length == 1
          ? 'Added to ${saved.name}'
          : 'Added ${uniqueItems.length} items to ${saved.name}',
    );
  }
  return saved;
}

const _newPlaylist = '__new__';

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

Future<String?> _askName(BuildContext context) =>
    showDialog<String>(context: context, builder: (_) => const _NameDialog());

class _NameDialog extends StatefulWidget {
  const _NameDialog();
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New playlist'),
    content: TextField(
      key: const ValueKey('mixed-playlist-name'),
      controller: controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Playlist name'),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Create')),
    ],
  );
}
