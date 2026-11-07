import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/podcast_playback.dart';
import '../services/global_playlists.dart';
import '../services/podcast_service.dart';
import '../services/podcast_downloads.dart';
import '../theme/millitop_visual_theme.dart';
import '../widgets/podcast_player_bar.dart';

enum _PodcastFilter { all, audio, video, following }

class PodcastsScreen extends StatefulWidget {
  final int profileId;
  final PodcastCatalog? catalog;
  final PodcastPlayback? playback;
  final PodcastDownloads? downloads;
  final PodcastEpisode? initialEpisode;
  const PodcastsScreen({
    super.key,
    required this.profileId,
    this.catalog,
    this.playback,
    this.downloads,
    this.initialEpisode,
  });
  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  late final playback = widget.playback ?? PodcastPlayback.instance;
  late final downloadService = widget.downloads ?? PodcastDownloads();
  final search = TextEditingController();
  late final PodcastCatalog catalog = widget.catalog ?? PodcastCatalog();
  List<PodcastShow> shows = [];
  List<PodcastEpisode> episodes = [];
  List<PodcastEpisode> downloads = [];
  _PodcastFilter filter = _PodcastFilter.all;
  bool loading = true;
  String error = '', query = '';
  int generation = 0;
  String? downloading;
  String downloadStatus = '';
  Set<String> favoriteEpisodeKeys = {};

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await playback.initialize(widget.profileId);
      final favorites = await GlobalPlaylistStore().load(widget.profileId);
      final saved = await downloadService.list(widget.profileId);
      if (!mounted) return;
      setState(() {
        downloads = saved;
        favoriteEpisodeKeys = favorites.favorites.values
            .where((v) => !v.deleted).map((v) => v.item.key).toSet();
      });
      final initial = widget.initialEpisode;
      if (initial != null) {
        setState(() {
          shows = [initial.show];
          episodes = [initial];
          loading = false;
        });
        await playback.play(initial);
        return;
      }
      await _discover();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Could not load podcasts: $e';
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    generation++;
    search.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final results = filter == _PodcastFilter.following
          ? playback.library.following
          : await catalog.search(query.isEmpty ? 'popular podcasts' : query);
      if (!mounted || request != generation) return;
      setState(() {
        shows = results;
        episodes = [];
      });
      // Keep discovery responsive: show directory cards before publisher feeds finish.
      final feeds = await Future.wait(
        results.take(6).map((show) async {
          try {
            return await catalog.episodes(show);
          } catch (e) {
            if (mounted && request == generation) {
              setState(() => error = 'Could not refresh "${show.title}": $e');
            }
            return <PodcastEpisode>[];
          }
        }),
      );
      if (!mounted || request != generation) return;
      final latest = feeds.expand((list) => list).toList()
        ..sort(
          (a, b) => (b.published ?? DateTime(1970)).compareTo(
            a.published ?? DateTime(1970),
          ),
        );
      setState(() {
        episodes = latest;
        loading = false;
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          error =
              'Podcast discovery failed. Check your connection and retry. $e';
          loading = false;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Podcast action failed: $e')));
      }
    }
  }

  bool _matches(PodcastEpisode episode) => switch (filter) {
    _PodcastFilter.audio => !episode.video,
    _PodcastFilter.video => episode.video,
    _PodcastFilter.following => playback.library.following.any(
      (show) => show.id == episode.show.id,
    ),
    _PodcastFilter.all => true,
  };

  Future<void> _openShow(PodcastShow show) async {
    final feed = catalog.episodes(show);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(
            children: [
              AnimatedBuilder(
                animation: playback,
                builder: (context, _) => ListTile(
                  leading: _art(show.artwork, 56),
                  title: Text(
                    show.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    show.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: TextButton(
                    onPressed: () =>
                        unawaited(_run(() => playback.follow(show))),
                    child: Text(
                      playback.library.following.any((e) => e.id == show.id)
                          ? 'Unfollow'
                          : 'Follow',
                    ),
                  ),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<PodcastEpisode>>(
                  future: feed,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Could not load this feed: ${snapshot.error}',
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final values = snapshot.data!.where(_matches).toList();
                    if (values.isEmpty) {
                      return const Center(
                        child: Text(
                          'No matching audio/video episodes in this feed.',
                        ),
                      );
                    }
                    return ListView(
                      children: [
                        for (final episode in values) _episodeRow(episode),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _art(String url, double size) => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: SizedBox(
      width: size,
      height: size,
      child: url.isEmpty
          ? const Icon(Icons.podcasts, size: 36)
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.podcasts, size: 36),
            ),
    ),
  );

  Widget _badge(bool video) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        video ? Icons.videocam : Icons.headphones,
        size: 14,
        color: context.millitopTheme.accentColor,
      ),
      const SizedBox(width: 5),
      Text(
        video ? 'VIDEO' : 'AUDIO',
        style: TextStyle(
          fontSize: 11,
          color: context.millitopTheme.accentColor,
        ),
      ),
    ],
  );

  Widget _panel(Widget child) => Card(
    color: context.millitopTheme.panelColor,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(context.millitopTheme.cardRadius),
      side: BorderSide(color: context.millitopTheme.panelBorder),
    ),
    child: child,
  );

  Widget _episodeRow(PodcastEpisode episode) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 600;
      final actions = [
        IconButton(
          tooltip: favoriteEpisodeKeys.contains(HubItem.podcast(episode).key)
              ? 'Remove podcast favorite' : 'Favorite episode',
          icon: Icon(favoriteEpisodeKeys.contains(HubItem.podcast(episode).key)
              ? Icons.favorite : Icons.favorite_border),
          onPressed: () => unawaited(_run(() async {
            final key = HubItem.podcast(episode).key;
            final value = !favoriteEpisodeKeys.contains(key);
            await playback.setFavorite(episode, value);
            if (mounted) {
              setState(() {
                if (value) {
                  favoriteEpisodeKeys.add(key);
                } else {
                  favoriteEpisodeKeys.remove(key);
                }
              });
            }
          })),
        ),
        IconButton(
          tooltip: 'Add episode to queue',
          icon: const Icon(Icons.playlist_add),
          onPressed: () => unawaited(_run(() => playback.enqueue(episode))),
        ),
        IconButton.filled(
          tooltip: episode.video ? 'Watch episode' : 'Listen to episode',
          icon: const Icon(Icons.play_arrow),
          onPressed: () => unawaited(_run(() => playback.play(episode))),
        ),
      ];
      return _panel(
        ListTile(
          leading: _art(episode.artwork, compact ? 36 : 52),
          title: Text(
            episode.show.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(episode.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _badge(episode.video),
                  Text(
                    podcastTime(episode.duration),
                    style: TextStyle(color: context.millitopTheme.mutedColor),
                  ),
                  if (episode.published != null)
                    Text(
                      '${episode.published!.toLocal()}'.split(' ').first,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
              if (compact) Wrap(children: actions),
            ],
          ),
          onTap: () => _episodeDetails(episode),
          trailing: compact
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
      );
    },
  );

  Future<void> _episodeDetails(PodcastEpisode episode) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(episode.title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Text(
            episode.description.isEmpty
                ? 'No episode description provided.'
                : episode.description,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: downloading != null
              ? null
              : () {
                  Navigator.pop(context);
                  unawaited(_download(episode));
                },
          child: const Text('Download for offline'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(
              _run(() async {
                await downloadService.remove(widget.profileId, episode);
                if (mounted) {
                  setState(
                    () => downloads.removeWhere((e) => e.key == episode.key),
                  );
                }
              }),
            );
          },
          child: const Text('Remove download'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(_run(() => playback.enqueue(episode)));
          },
          child: const Text('Add to queue'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(_run(() => playback.play(episode, restart: true)));
          },
          child: const Text('Play from beginning'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(_run(() => playback.play(episode)));
          },
          child: Text(episode.video ? 'Watch / resume' : 'Listen / resume'),
        ),
      ],
    ),
  );

  Future<void> _download(PodcastEpisode episode) async {
    setState(() {
      downloading = episode.key;
      downloadStatus = 'Downloading ${episode.title}...';
    });
    try {
      await downloadService.download(widget.profileId, episode, (bytes, total) {
        if (mounted) {
          setState(
            () => downloadStatus = total != null && total > 0
                ? 'Downloading: ${(bytes / total * 100).round()}%'
                : 'Downloading: ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
          );
        }
      });
      if (mounted) {
        setState(() {
          if (!downloads.any((e) => e.key == episode.key)) {
            downloads.add(episode);
          }
          downloadStatus = 'Download saved. This episode can now play offline.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => downloadStatus = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => downloading = null);
    }
  }

  Future<void> _fullscreenVideo() => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(child: Video(controller: playback.videoController!)),
          Positioned(
            top: 12,
            right: 12,
            child: IconButton.filled(
              tooltip: 'Exit podcast full screen',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) {
      final tokens = context.millitopTheme;
      final matching = episodes.where(_matches).take(40).toList();
      final resumed =
          playback.library.progress.values
              .whereType<Map>()
              .where(
                (e) =>
                    e['completed'] != true &&
                    (e['positionMs'] as int? ?? 0) > 0,
              )
              .toList()
            ..sort(
              (a, b) => b['updatedAtUtc'].toString().compareTo(
                a['updatedAtUtc'].toString(),
              ),
            );
      return Scaffold(
        appBar: AppBar(
          title: const Text('Podcasts'),
          actions: [
            IconButton(
              tooltip: 'Podcast queue',
              icon: const Icon(Icons.queue_music),
              onPressed: () =>
                  unawaited(showPodcastQueue(context, controller: playback)),
            ),
            IconButton(
              tooltip: 'Refresh podcasts',
              icon: const Icon(Icons.refresh),
              onPressed: _discover,
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: PodcastPlayerBar(
            playback: playback,
            onOpenQueue: () =>
                unawaited(showPodcastQueue(context, controller: playback)),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Listen. Watch. Pick up where you left off.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search Apple Podcasts',
                suffixIcon: IconButton(
                  tooltip: 'Search podcasts',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () {
                    query = search.text.trim();
                    unawaited(_discover());
                  },
                ),
              ),
              onSubmitted: (value) {
                query = value.trim();
                unawaited(_discover());
              },
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              children: [
                for (final value in _PodcastFilter.values)
                  ChoiceChip(
                    label: Text(switch (value) {
                      _PodcastFilter.all => 'All',
                      _PodcastFilter.audio => 'Audio',
                      _PodcastFilter.video => 'Video',
                      _PodcastFilter.following => 'Following',
                    }),
                    selected: filter == value,
                    onSelected: (_) {
                      final previous = filter;
                      setState(() => filter = value);
                      if (value == _PodcastFilter.following ||
                          shows.isEmpty ||
                          previous == _PodcastFilter.following) {
                        unawaited(_discover());
                      }
                    },
                  ),
              ],
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
            if (error.isNotEmpty)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (downloadStatus.isNotEmpty) Text(downloadStatus),
            if (downloads.where(_matches).isNotEmpty) ...[
              _heading('Downloaded episodes'),
              for (final episode in downloads.where(_matches))
                _episodeRow(episode),
            ],
            if (playback.active?.video == true &&
                playback.videoController != null) ...[
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Video(
                    controller: playback.videoController!,
                    controls: NoVideoControls,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _fullscreenVideo,
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('Full screen'),
                ),
              ),
            ],
            if (resumed.isNotEmpty) ...[
              _heading('Continue listening & watching'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in resumed.take(6))
                    if (_matches(
                      PodcastEpisode.fromJson(
                        Map<String, dynamic>.from(item['episode'] as Map),
                      ),
                    ))
                      SizedBox(
                        width: MediaQuery.sizeOf(context).width < 700
                            ? double.infinity
                            : 480,
                        child: _panel(
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _episodeRow(
                                  PodcastEpisode.fromJson(
                                    Map<String, dynamic>.from(
                                      item['episode'] as Map,
                                    ),
                                  ),
                                ),
                                LinearProgressIndicator(
                                  value: (item['durationMs'] as int? ?? 0) > 0
                                      ? ((item['positionMs'] as int) /
                                                (item['durationMs'] as int))
                                            .clamp(0.0, 1.0)
                                      : 0,
                                ),
                                Text(
                                  '${podcastTime(Duration(milliseconds: item['positionMs'] as int))} / '
                                  '${podcastTime(Duration(milliseconds: item['durationMs'] as int? ?? 0))}',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ],
            _heading(
              filter == _PodcastFilter.following
                  ? 'Following'
                  : query.isEmpty
                  ? 'Discover on Apple Podcasts'
                  : 'Search results',
            ),
            SizedBox(
              height: 180,
              child: shows.isEmpty && !loading
                  ? Center(
                      child: Text(
                        filter == _PodcastFilter.following
                            ? 'Follow a show to see it here.'
                            : 'No podcasts found.',
                      ),
                    )
                  : ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final show in shows)
                          SizedBox(
                            width: 280,
                            child: _panel(
                              InkWell(
                                borderRadius: BorderRadius.circular(
                                  tokens.cardRadius,
                                ),
                                onTap: () => unawaited(_openShow(show)),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    children: [
                                      _art(show.artwork, 88),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              show.title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            Text(
                                              show.author,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: tokens.mutedColor,
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: () => unawaited(
                                                _run(
                                                  () => playback.follow(show),
                                                ),
                                              ),
                                              child: Text(
                                                playback.library.following.any(
                                                      (e) => e.id == show.id,
                                                    )
                                                    ? 'Following'
                                                    : 'Follow',
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
            ),
            _heading('Latest episodes'),
            if (matching.isEmpty && !loading)
              const Text(
                'No matching episodes. Open a show or search for another podcast.',
              ),
            for (final episode in matching) _episodeRow(episode),
          ],
        ),
      );
    },
  );

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10),
    child: Text(
      title,
      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
    ),
  );
}
