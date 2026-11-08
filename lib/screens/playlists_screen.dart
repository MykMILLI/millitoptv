import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pstube_engine/pstube_engine.dart';

import '../services/device_connection.dart';
import '../services/global_playlists.dart';
import '../services/home_preferences.dart';
import '../services/live_tv_control.dart';
import '../services/live_tv_sync.dart';
import '../services/music_service.dart';
import '../services/playlist_hub.dart';
import '../services/playlist_playback.dart';
import '../services/podcast_service.dart';
import '../services/profile_sync.dart';
import '../theme/millitop_visual_theme.dart';
import 'live_tv_media_screen.dart';
import 'live_tv_screen.dart';
import 'music_screen.dart';
import 'podcasts_screen.dart';
import 'youtube_screen.dart';

Widget hubDestination(
  int profile,
  HubItem item, {
  PlaylistPlaybackSession? mixedSession,
  String? mixedSessionEntryId,
}) => switch (item.type) {
  HubMediaType.channel => LiveTvScreen(
    profileId: profile,
    initialSourceId: item.sourceId,
    initialChannelId: item.id,
  ),
  HubMediaType.movie ||
  HubMediaType.series ||
  HubMediaType.episode => LiveTvMediaScreen(
    profileId: profile,
    initialSourceId: item.sourceId,
    initialLibraryItem: LiveTvLibraryItem.fromJson(item.payload),
    mixedSession: mixedSession,
    mixedSessionEntryId: mixedSessionEntryId,
  ),
  HubMediaType.song => MusicScreen(
    profileId: profile,
    initialTrack: MusicTrack.fromJson(item.payload),
  ),
  HubMediaType.podcast => PodcastsScreen(
    profileId: profile,
    initialEpisode: PodcastEpisode.fromJson(item.payload),
  ),
  HubMediaType.youtube => YouTubeScreen(
    profileId: profile,
    initialVideo: TubeVideo.fromJson(item.payload),
  ),
};

/// Opens one playlist step for the shared mixed-playlist session.
Future<PlaylistPlaybackExit?> openPlaylistSegment(
  BuildContext context,
  PlaylistPlaybackSession session,
  PlaylistSegment segment,
) async {
  final entry = segment.first;
  final item = entry.item;
  final Widget page = switch (item.type) {
    HubMediaType.song => MusicScreen(
      profileId: session.profileId,
      initialQueue: [
        for (final song in segment.items) MusicTrack.fromJson(song.payload),
      ],
    ),
    HubMediaType.youtube => YouTubeScreen(
      profileId: session.profileId,
      initialVideo: TubeVideo.fromJson(item.payload),
      mixedSession: session,
      mixedSessionEntryId: entry.entryId,
    ),
    _ => hubDestination(
      session.profileId,
      item,
      mixedSession: session,
      mixedSessionEntryId: entry.entryId,
    ),
  };
  final result = await Navigator.of(
    context,
  ).push<Object?>(MaterialPageRoute(builder: (_) => page));
  if (result is PlaylistPlaybackExit) {
    return result;
  }
  return const PlaylistPlaybackExit.explicitBack();
}

IconData _mediaIcon(HubMediaType type) => switch (type) {
  HubMediaType.channel => Icons.live_tv,
  HubMediaType.movie => Icons.movie_outlined,
  HubMediaType.series => Icons.video_library_outlined,
  HubMediaType.episode => Icons.smart_display_outlined,
  HubMediaType.song => Icons.music_note,
  HubMediaType.podcast => Icons.podcasts,
  HubMediaType.youtube => Icons.play_circle_outline,
};

class PlaylistsScreen extends StatefulWidget {
  final int profileId;
  final bool embedded;
  final PlaylistHubRepository? repository;
  final Future<void> Function(int profile, HubItem item)? onOpenItem;
  const PlaylistsScreen({
    super.key,
    required this.profileId,
    this.embedded = false,
    this.repository,
    this.onOpenItem,
  });
  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  late final repository = widget.repository ?? PlaylistHubRepository();
  final search = TextEditingController();
  HubSnapshot data = const HubSnapshot();
  HubMediaType? type;
  String? sourceId;
  String error = '', syncWarning = '';
  bool loading = true, busy = false;
  int tab = 0, generation = 0;
  final pendingChannelSync = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_pullRemote());
  }

  /// Picks up playlists and favorites saved on the user's other devices.
  Future<void> _pullRemote() async {
    final profile = widget.profileId;
    final changed = await ProfileSync.pullCollections(profile);
    if (changed && mounted && widget.profileId == profile) await _load();
  }

  Future<void> _play(HubPlaylist list, {bool shuffle = false}) async {
    if (list.items.isEmpty) return;
    await PlaylistPlayback(
      profileId: widget.profileId,
      open: openPlaylistSegment,
    ).play(
      context,
      playlistId: list.id,
      name: list.name,
      items: list.items,
      shuffle: shuffle,
    );
    if (mounted) await _load();
  }

  @override
  void didUpdateWidget(covariant PlaylistsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileId != widget.profileId) {
      search.clear();
      type = null;
      sourceId = null;
      data = const HubSnapshot();
      error = '';
      syncWarning = '';
      pendingChannelSync.clear();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    generation++;
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++generation;
    setState(() => loading = true);
    try {
      final next = await repository.load(widget.profileId);
      if (!mounted || request != generation) return;
      setState(() {
        data = next;
        loading = false;
        if (!next.available.any((v) => v.sourceId == sourceId)) sourceId = null;
      });
    } catch (e) {
      if (!mounted || request != generation) return;
      setState(() {
        loading = false;
        error = 'Could not load your playlists. $e';
      });
    }
  }

  Future<void> _sync(int profile) async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      if (mounted && widget.profileId == profile) {
        setState(
          () => syncWarning =
              'Saved on this device. Connect and refresh to sync across your devices.',
        );
      }
      return;
    }
    final sourcesToSync = pendingChannelSync.toList();
    try {
      final prefs = repository.preferences;
      await LiveTvControlService().pushConfig(
        expectedConnection: connection,
        profileId: profile,
        sources: await prefs.liveTvSources(profile),
        tmdbApiKey: await prefs.tmdbApiKey(profile),
        profileState: await prefs.liveTvProfileSyncState(profile),
      );
      final channelKeys = await channelFavoriteKeys(profile);
      for (final source in sourcesToSync) {
        await LiveTvSyncService().syncFavorites(
          expectedConnection: connection,
          profileId: profile,
          sourceId: source,
          favorites: channelKeys
              .where((key) => key.startsWith('$source|'))
              .toSet(),
        );
        if (widget.profileId == profile) {
          pendingChannelSync.remove(source);
        }
      }
      if (mounted && widget.profileId == profile) {
        setState(() => syncWarning = '');
      }
    } catch (e) {
      debugPrint('Global playlists profile sync failed: $e');
      if (mounted && widget.profileId == profile) {
        setState(
          () => syncWarning =
              'Saved on this device. Profile sync failed; reconnect and refresh. $e',
        );
      }
    }
  }

  Future<void> _run(
    Future<void> Function(int profile) action, {
    HubItem? favoriteChange,
    int? ownerProfile,
  }) async {
    if (!mounted || busy) return;
    if (ownerProfile != null && ownerProfile != widget.profileId) {
      debugPrint('Playlist edit ignored because the active profile changed.');
      return;
    }
    final profile = widget.profileId;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action(profile);
      if (favoriteChange?.type == HubMediaType.channel &&
          widget.profileId == profile) {
        pendingChannelSync.add(favoriteChange!.sourceId);
      }
      await _sync(profile);
      if (mounted && widget.profileId == profile) await _load();
    } catch (e) {
      debugPrint('Playlist action failed: $e');
      if (mounted && widget.profileId == profile) {
        setState(() => error = 'Could not update your library. $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refresh() => _run((profile) async {
    final library = await repository.store.load(profile);
    if (!mounted || widget.profileId != profile) return;
    pendingChannelSync.addAll(
      library.favorites.values
          .where((v) => v.item.type == HubMediaType.channel)
          .map((v) => v.item.sourceId),
    );
  });

  bool _favorite(HubItem item) => data.favorites.any((v) => v.key == item.key);

  Future<void> _open(HubItem item, {int? ownerProfile}) async {
    if (!mounted) return;
    if (ownerProfile != null && ownerProfile != widget.profileId) {
      debugPrint('Saved media ignored because the active profile changed.');
      return;
    }
    final profile = widget.profileId;
    try {
      if (widget.onOpenItem != null) {
        await widget.onOpenItem!(profile, item);
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => hubDestination(profile, item)),
        );
      }
      if (mounted) await _load();
    } catch (e) {
      debugPrint('Saved media could not open: $e');
      if (mounted && widget.profileId == profile) {
        setState(() => error = 'Could not open "${item.title}". $e');
      }
    }
  }

  Future<String?> _name(String title, [String initial = '']) =>
      showDialog<String>(
        context: context,
        builder: (_) => _PlaylistNameDialog(title: title, initial: initial),
      );

  Future<void> _create([List<HubItem> items = const []]) async {
    final owner = widget.profileId;
    final name = await _name('New playlist');
    if (name == null || !mounted || widget.profileId != owner) return;
    await _run((profile) async {
      await repository.store.savePlaylist(profile, name: name, items: items);
    });
  }

  Future<void> _add(HubItem item, {int? ownerProfile}) async {
    if (!mounted) return;
    if (ownerProfile != null && ownerProfile != widget.profileId) {
      debugPrint(
        'Saved media selection ignored because the active profile changed.',
      );
      return;
    }
    final owner = widget.profileId;
    final lists = data.playlists.where((p) => p.editable).toList();
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add to playlist'),
        content: SizedBox(
          width: math.min(480, MediaQuery.sizeOf(ctx).width - 48),
          height: math.min(300, MediaQuery.sizeOf(ctx).height * .5),
          child: ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New playlist'),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
              for (final list in lists)
                ListTile(
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted || widget.profileId != owner) return;
    if (selected == 'new') {
      await _create([item]);
      return;
    }
    await _run((profile) async {
      final list = (await repository.store.load(profile)).playlists[selected];
      if (list == null || list.deleted) {
        throw StateError('That playlist no longer exists.');
      }
      await repository.store.savePlaylist(
        profile,
        id: list.id,
        name: list.name,
        items: [...list.items, item],
      );
    });
  }

  Future<void> _collectionAction(HubPlaylist list, String action) async {
    final owner = widget.profileId;
    switch (action) {
      case 'play':
        await _play(list);
      case 'shuffle':
        await _play(list, shuffle: true);
      case 'copy':
        final name = await _name(
          'Copy to global playlist',
          '${list.name} copy',
        );
        if (name == null || !mounted || widget.profileId != owner) return;
        await _run((profile) async {
          await repository.store.savePlaylist(
            profile,
            name: name,
            items: list.items,
          );
        });
      case 'rename':
        final name = await _name('Rename playlist', list.name);
        if (name == null || !mounted || widget.profileId != owner) return;
        await _run((profile) async {
          await repository.store.savePlaylist(
            profile,
            id: list.id,
            name: name,
            items: list.items,
          );
        });
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete playlist?'),
            content: Text(
              'Delete "${list.name}"? This will not remove your favorites.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted || widget.profileId != owner) return;
        await _run(
          (profile) => repository.store.deletePlaylist(profile, list.id),
        );
    }
  }

  Future<void> _view(HubPlaylist list) async {
    final owner = widget.profileId;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _PlaylistContents(
          playlist: list,
          available: data.available,
          isFavorite: _favorite,
          onOpen: (item) => _open(item, ownerProfile: owner),
          onFavorite: (item) => _run(
            (profile) =>
                repository.setFavorite(profile, item, !_favorite(item)),
            favoriteChange: item,
            ownerProfile: owner,
          ),
          onAdd: (item) => _add(item, ownerProfile: owner),
          onPlay: (current, shuffle) => _play(current, shuffle: shuffle),
          onSave: list.editable
              ? (items) async {
                  HubPlaylist? saved;
                  await _run((profile) async {
                    saved = await repository.store.savePlaylist(
                      profile,
                      id: list.id,
                      name: list.name,
                      items: items,
                    );
                  }, ownerProfile: owner);
                  return saved;
                }
              : null,
        ),
      ),
    );
    if (mounted) await _load();
  }

  bool _matches(HubItem item) {
    final query = search.text.trim().toLowerCase();
    return (type == null || item.type == type) &&
        (sourceId == null || item.sourceId == sourceId) &&
        (query.isEmpty ||
            '${item.title} ${item.subtitle} ${item.sourceName}'
                .toLowerCase()
                .contains(query));
  }

  Widget _row(HubItem item) => _HubItemTile(
    item: item,
    favorite: _favorite(item),
    onOpen: () => unawaited(_open(item)),
    onFavorite: busy
        ? null
        : () => unawaited(
            _run(
              (profile) =>
                  repository.setFavorite(profile, item, !_favorite(item)),
              favoriteChange: item,
            ),
          ),
    onAdd: busy ? null : () => unawaited(_add(item)),
  );

  @override
  Widget build(BuildContext context) {
    final personal = data.forYou;
    final personalKeys = personal.map((v) => v.key).toSet();
    final remaining =
        data.favorites.where((v) => !personalKeys.contains(v.key)).toList()
          ..sort((a, b) => a.title.compareTo(b.title));
    final favorites = [...personal, ...remaining].where(_matches).toList();
    final collections = data.playlists
        .where(
          (p) =>
              (type == null &&
                  sourceId == null &&
                  p.name.toLowerCase().contains(
                    search.text.trim().toLowerCase(),
                  )) ||
              p.items.any(_matches),
        )
        .toList();
    final sources = {
      for (final item in data.available)
        item.sourceId: item.type == HubMediaType.podcast
            ? 'Podcasts · ${item.subtitle}'
            : item.sourceName,
    };
    final body = DefaultTabController(
      length: 2,
      child: SafeArea(
        child: Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height < 500
                    ? 100
                    : (widget.embedded ? 190 : 260),
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Text(
                            'Your Playlists',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          FilledButton.icon(
                            onPressed: loading || busy
                                ? null
                                : () => unawaited(_create()),
                            icon: const Icon(Icons.playlist_add),
                            label: const Text('New playlist'),
                          ),
                          IconButton(
                            tooltip: 'Refresh collections',
                            onPressed: busy
                                ? null
                                : () => unawaited(_refresh()),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your saved media, across your connected apps. Suggestions learn from your existing favorites and history; saved playlists only change when you choose.',
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: search,
                        decoration: const InputDecoration(
                          labelText: 'Search playlists and favorites',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      if (sources.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          key: ValueKey(sourceId),
                          isExpanded: true,
                          initialValue: sourceId,
                          hint: const Text('All sources'),
                          decoration: const InputDecoration(
                            labelText: 'Source',
                          ),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('All sources'),
                            ),
                            for (final entry in sources.entries)
                              DropdownMenuItem(
                                value: entry.key,
                                child: Text(
                                  entry.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => sourceId = value),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: type == null,
                    onSelected: (_) => setState(() => type = null),
                  ),
                  for (final kind in HubMediaType.values)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text(switch (kind) {
                          HubMediaType.channel => 'Channels',
                          HubMediaType.movie => 'Movies',
                          HubMediaType.series => 'Series',
                          HubMediaType.episode => 'Episodes',
                          HubMediaType.song => 'Songs',
                          HubMediaType.podcast => 'Podcasts',
                          HubMediaType.youtube => 'YouTube',
                        }),
                        selected: type == kind,
                        onSelected: (_) => setState(() => type = kind),
                      ),
                    ),
                ],
              ),
            ),
            TabBar(
              onTap: (value) => setState(() => tab = value),
              tabs: [
                Tab(text: 'Playlists (${data.playlists.length})'),
                Tab(text: 'Favorites (${data.favorites.length})'),
              ],
            ),
            if (loading || busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (error.isNotEmpty ||
                      syncWarning.isNotEmpty ||
                      data.warnings.isNotEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          [
                            error,
                            syncWarning,
                            ...data.warnings,
                          ].where((v) => v.isNotEmpty).join('\n'),
                        ),
                      ),
                    ),
                  if (tab == 1) ...[
                    const Text(
                      'Favorites · sorted for you',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!loading && favorites.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No matching favorites. Save channels, movies, series, episodes, songs, podcasts or YouTube videos in their apps to find them here.',
                        ),
                      ),
                    ...favorites.map(_row),
                  ] else ...[
                    if (personal.any(_matches)) ...[
                      const Text(
                        'For you',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      ...personal.where(_matches).take(4).map(_row),
                      const SizedBox(height: 16),
                    ],
                    if (data.recent.any(_matches)) ...[
                      const Text(
                        'Recently enjoyed',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      ...data.recent.where(_matches).take(6).map(_row),
                      const SizedBox(height: 16),
                    ],
                    const Text(
                      'Saved playlists',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!loading && collections.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No matching playlists. Create a mixed-media playlist or save one in Music, Movies & TV, Podcasts or YouTube.',
                        ),
                      ),
                    for (final list in collections)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.playlist_play),
                          title: Text(
                            list.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${list.items.length} items · ${list.editable ? 'Your global playlist' : list.origin}',
                          ),
                          onTap: () => unawaited(_view(list)),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Playlist actions',
                            onSelected: (value) =>
                                unawaited(_collectionAction(list, value)),
                            itemBuilder: (_) => [
                              if (list.items.isNotEmpty) ...[
                                const PopupMenuItem(
                                  value: 'play',
                                  child: Text('Play all'),
                                ),
                                const PopupMenuItem(
                                  value: 'shuffle',
                                  child: Text('Shuffle'),
                                ),
                              ],
                              const PopupMenuItem(
                                value: 'copy',
                                child: Text('Copy to global playlist'),
                              ),
                              if (list.editable) ...[
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Text('Rename'),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('Playlists')),
            body: body,
          );
  }
}

class _PlaylistNameDialog extends StatefulWidget {
  final String title, initial;
  const _PlaylistNameDialog({required this.title, required this.initial});
  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final input = TextEditingController(text: widget.initial);
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void _save() {
    if (form.currentState!.validate()) {
      Navigator.pop(context, input.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: form,
      child: TextFormField(
        controller: input,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Playlist name'),
        validator: (value) =>
            value?.trim().isNotEmpty == true ? null : 'Enter a playlist name.',
        onFieldSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

class _HubItemTile extends StatelessWidget {
  final HubItem item;
  final bool favorite;
  final VoidCallback onOpen;
  final VoidCallback? onFavorite, onAdd;
  const _HubItemTile({
    required this.item,
    required this.favorite,
    required this.onOpen,
    required this.onFavorite,
    required this.onAdd,
  });
  @override
  Widget build(BuildContext context) => Card(
    color: context.millitopTheme.panelColor,
    child: ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: item.artwork.isEmpty
            ? Icon(_mediaIcon(item.type))
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  item.artwork,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(_mediaIcon(item.type)),
                ),
              ),
      ),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${item.label} · ${item.sourceName}${item.subtitle.isEmpty ? '' : ' · ${item.subtitle}'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onOpen,
      trailing: PopupMenuButton<String>(
        tooltip: 'Actions for ${item.title}',
        onSelected: (value) {
          if (value == 'favorite') onFavorite?.call();
          if (value == 'add') onAdd?.call();
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'favorite',
            enabled: onFavorite != null,
            child: Text(favorite ? 'Remove favorite' : 'Add favorite'),
          ),
          PopupMenuItem(
            value: 'add',
            enabled: onAdd != null,
            child: const Text('Add to playlist'),
          ),
        ],
      ),
    ),
  );
}

class _PlaylistContents extends StatefulWidget {
  final HubPlaylist playlist;
  final List<HubItem> available;
  final bool Function(HubItem) isFavorite;
  final Future<void> Function(HubItem) onOpen, onFavorite, onAdd;
  final Future<HubPlaylist?> Function(List<HubItem>)? onSave;
  final Future<void> Function(HubPlaylist playlist, bool shuffle)? onPlay;
  const _PlaylistContents({
    this.onPlay,
    required this.playlist,
    required this.available,
    required this.isFavorite,
    required this.onOpen,
    required this.onFavorite,
    required this.onAdd,
    this.onSave,
  });
  @override
  State<_PlaylistContents> createState() => _PlaylistContentsState();
}

class _PlaylistContentsState extends State<_PlaylistContents> {
  late HubPlaylist playlist = widget.playlist;
  bool busy = false;
  String error = '';

  Future<void> _change(List<HubItem> items) async {
    if (busy || widget.onSave == null) return;
    setState(() => busy = true);
    final saved = await widget.onSave!(items);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (saved != null) playlist = saved;
      error = saved == null
          ? 'The playlist could not be saved. Go back to review the error and retry.'
          : '';
    });
  }

  Future<void> _pick() async {
    final selected = playlist.items.map((v) => v.key).toSet();
    final choices = widget.available
        .where((v) => !selected.contains(v.key))
        .toList();
    final item = await showDialog<HubItem>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add saved media'),
        content: SizedBox(
          width: math.min(520, MediaQuery.sizeOf(ctx).width - 48),
          height: math.min(360, MediaQuery.sizeOf(ctx).height * .55),
          child: choices.isEmpty
              ? const Text(
                  'Favorite media in your apps first, then add it to this playlist.',
                )
              : ListView(
                  children: [
                    for (final item in choices)
                      ListTile(
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${item.label} · ${item.sourceName}'),
                        onTap: () => Navigator.pop(ctx, item),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (item != null && mounted) await _change([...playlist.items, item]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (widget.onSave != null)
          IconButton(
            tooltip: 'Add saved media',
            onPressed: busy ? null : () => unawaited(_pick()),
            icon: const Icon(Icons.playlist_add),
          ),
      ],
    ),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (widget.onPlay != null && playlist.items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('playlist-play'),
                  autofocus: true,
                  onPressed: busy
                      ? null
                      : () => unawaited(widget.onPlay!(playlist, false)),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play all'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('playlist-shuffle'),
                  onPressed: busy
                      ? null
                      : () => unawaited(widget.onPlay!(playlist, true)),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle'),
                ),
                Text(
                  '${playlist.items.length} items · '
                  '${{for (final item in playlist.items) item.label}.join(', ')}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (error.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(error)),
        if (!playlist.editable)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Saved in ${playlist.origin}. Copy it to a global playlist to edit a mixed-media version here.',
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: playlist.items.isEmpty ? 1 : playlist.items.length,
            itemBuilder: (context, index) {
              if (playlist.items.isEmpty) {
                return const Text(
                  'This playlist is empty. Add saved media using the button above.',
                );
              }
              final item = playlist.items[index];
              return Column(
                children: [
                  _HubItemTile(
                    item: item,
                    favorite: widget.isFavorite(item),
                    onOpen: () => unawaited(widget.onOpen(item)),
                    onFavorite: () => unawaited(
                      widget.onFavorite(item).then((_) {
                        if (mounted) setState(() {});
                      }),
                    ),
                    onAdd: () => unawaited(widget.onAdd(item)),
                  ),
                  if (widget.onSave != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: 'Move up',
                          onPressed: busy || index == 0
                              ? null
                              : () {
                                  final items = List<HubItem>.from(
                                    playlist.items,
                                  );
                                  items.insert(
                                    index - 1,
                                    items.removeAt(index),
                                  );
                                  unawaited(_change(items));
                                },
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: 'Move down',
                          onPressed: busy || index == playlist.items.length - 1
                              ? null
                              : () {
                                  final items = List<HubItem>.from(
                                    playlist.items,
                                  );
                                  items.insert(
                                    index + 1,
                                    items.removeAt(index),
                                  );
                                  unawaited(_change(items));
                                },
                          icon: const Icon(Icons.arrow_downward),
                        ),
                        IconButton(
                          tooltip: 'Remove from playlist',
                          onPressed: busy
                              ? null
                              : () => unawaited(
                                  _change(
                                    playlist.items
                                        .where((v) => v.key != item.key)
                                        .toList(),
                                  ),
                                ),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
