import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pstube_engine/pstube_engine.dart';
import '../services/app_log.dart';
import '../services/device_connection.dart';
import '../services/global_playlists.dart';
import '../services/home_preferences.dart';
import '../services/pip_playback.dart';
import '../services/playlist_playback.dart';
import '../services/profile_sync.dart';
import '../services/tube_downloads.dart';
import '../services/tube_library.dart';
import '../theme/millitop_visual_theme.dart';
import '../widgets/mixed_playlist_picker.dart';
import '../widgets/redesign/media_side_panels.dart';
import 'playlists_screen.dart';

String tubeTime(int seconds) {
  if (seconds >= 3600) {
    return '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class YouTubeScreen extends StatefulWidget {
  final int profileId;
  final TubeEngine? engine;
  final TubeDownloads? downloads;
  final TubeVideo? initialVideo;
  final PlaylistPlaybackSession? mixedSession;
  final String? mixedSessionEntryId;

  /// Legacy route behavior retained for non-session callers.
  final bool exitWhenFinished;
  const YouTubeScreen({
    super.key,
    required this.profileId,
    this.engine,
    this.downloads,
    this.initialVideo,
    this.mixedSession,
    this.mixedSessionEntryId,
    this.exitWhenFinished = false,
  });
  @override
  State<YouTubeScreen> createState() => _YouTubeScreenState();
}

class _YouTubeScreenState extends State<YouTubeScreen> {
  static bool licenseRegistered = false;
  late final TubeEngine engine =
      widget.engine ?? PsTubeEngine(onFallback: debugPrint);
  late final TubeDownloads downloads = widget.downloads ?? TubeDownloads();
  final store = TubeStore();
  final search = TextEditingController();
  final scaffold = GlobalKey<ScaffoldState>();
  TubeLibrary library = const TubeLibrary();
  List<TubeVideo> videos = [];
  TubePage? page;
  String section = 'Home', category = 'All', error = '', status = '';
  bool loading = true, more = false, sidebar = true;
  int generation = 0, playbackGeneration = 0;
  Future<void> writes = Future.value();
  Player? player;
  VideoController? controller;
  TubeDetails? details;
  TubeVideo? active;
  Duration position = Duration.zero, duration = Duration.zero;
  bool playing = false, opening = false, buffering = false;
  String playbackError = '', quality = '';
  List<TubeSubtitle> captions = [];
  Timer? progressTimer;
  final subscriptions = <StreamSubscription<dynamic>>[];
  String? downloading;
  final downloadedIds = <String>{};
  bool handedOffToMiniPlayer = false;
  bool _mixedExitSent = false;
  PlaylistPlaybackSession? get _mixedSession => widget.mixedSession;
  bool get _hasMixedSession =>
      _mixedSession != null && widget.mixedSessionEntryId != null;

  void _exitMixed(PlaylistPlaybackExit exit) {
    if (!mounted || _mixedExitSent) {
      return;
    }
    _mixedExitSent = true;
    Navigator.of(context).pop<Object?>(exit);
  }

  @override
  void initState() {
    super.initState();
    if (!licenseRegistered) {
      licenseRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks([
          'PsTube engine',
        ], await rootBundle.loadString('third_party/pstube_engine/LICENSE'));
      });
    }
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      library = await store.load(widget.profileId);
      // Pick up subscriptions, favorites and history saved on other paired
      // devices. Runs alongside the first page so opening is not blocked.
      unawaited(_pullRemote());
      final prefs = await HomePreferences().tubePipedUrl(widget.profileId);
      if (engine is PsTubeEngine) (engine as PsTubeEngine).pipedUrl = prefs;
      final saved = await downloads.list(widget.profileId);
      downloadedIds.addAll(saved.map((video) => video.id));
      if (!mounted) return;
      final initial = widget.initialVideo;
      if (initial != null) {
        setState(() {
          videos = [initial];
          loading = false;
        });
        await _play(initial);
      } else {
        await _load();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'Could not load YouTube: $e';
        });
      }
    }
  }

  static const _librarySections = {
    'Subscriptions',
    'Favorites',
    'Watch later',
    'History',
    'Playlists',
  };

  /// Merges the server copy of this profile's YouTube library and refreshes
  /// the screen if anything changed.
  Future<void> _pullRemote() async {
    final pulled = await ProfileSync.pullCollections(widget.profileId);
    if (!pulled || !mounted) return;
    await writes;
    final merged = await store.load(widget.profileId);
    if (!mounted) return;
    final changed = jsonEncode(merged.entries) != jsonEncode(library.entries);
    setState(() => library = merged);
    if (changed &&
        (_librarySections.contains(section) ||
            section.startsWith('Playlist:'))) {
      await _load();
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('YouTube action failed: $e');
      if (mounted) setState(() => error = 'YouTube action failed: $e');
    }
  }

  Future<void> _persist({bool sync = true}) async {
    final snapshot = library;
    // Merge rather than overwrite so entries that arrived from another
    // device in the background are kept.
    final pending = writes.then(
      (_) => store.applySync(widget.profileId, snapshot.toJson()),
    );
    writes = pending.catchError((Object e) {
      debugPrint('Could not save YouTube profile: $e');
      if (mounted) setState(() => error = 'Could not save YouTube profile: $e');
    });
    await pending;
    if (!sync || !DeviceConnection.instance.isConnected) return;
    try {
      await ProfileSync.push(widget.profileId);
      final merged = await store.load(widget.profileId);
      if (mounted) setState(() => library = merged);
    } catch (e, st) {
      AppLog.warn(
        LogCategory.sync,
        'YouTube library sync failed; saved on this device',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        setState(
          () => error = 'Saved on this device; sync failed and will retry. $e',
        );
      }
    }
  }

  Future<void> _toggle(String collection, TubeVideo video) async {
    setState(() => library = library.toggle(collection, video));
    await _persist();
    if ([
      'Favorites',
      'Watch later',
      'Subscriptions',
      'Playlists',
    ].contains(section)) {
      await _load();
    }
  }

  void _saveProgress({bool sync = false}) {
    final video = active;
    if (video == null) return;
    library = library.progress(video, position, duration);
    unawaited(_action(() => _persist(sync: sync)));
  }

  Future<void> _load() async {
    final request = ++generation;
    final targetSection = section;
    final targetCategory = category;
    setState(() {
      loading = true;
      error = '';
      page = null;
      videos = [];
    });
    try {
      TubePage result;
      switch (targetSection) {
        case 'History':
          result = TubePage(library.watched);
        case 'Favorites':
          result = TubePage(library.list('liked'));
        case 'Watch later':
          result = TubePage(library.list('later'));
        case 'Downloads':
          result = TubePage(await downloads.list(widget.profileId));
        case 'Playlists':
          result = TubePage(library.playlists.expand(library.list).toList());
        case 'Subscriptions':
          // Make sure channels subscribed on another device are included.
          if (await ProfileSync.pullCollections(widget.profileId)) {
            await writes;
            library = await store.load(widget.profileId);
          }
          if (!mounted || request != generation) return;
          final channels = library.list('subscriptions');
          final results = <TubePage>[];
          for (var index = 0; index < channels.length; index += 4) {
            results.addAll(
              await Future.wait(
                channels
                    .skip(index)
                    .take(4)
                    .map((channel) => engine.channel(channel.channelId)),
              ),
            );
            if (!mounted || request != generation) return;
          }
          result = TubePage(results.expand((value) => value.videos).toList());
        case 'Search':
          result = await engine.search(search.text.trim());
        case 'Shorts':
          result = await engine.search('#shorts');
        default:
          if (targetSection.startsWith('Channel:')) {
            result = await engine.channel(targetSection.substring(8));
          } else if (targetSection.startsWith('Playlist:')) {
            result = TubePage(
              library.list('playlist/${targetSection.substring(9)}'),
            );
          } else if (targetSection.startsWith('Public playlist:')) {
            result = await engine.playlist(targetSection.substring(16));
          } else if (targetCategory == 'Watched') {
            result = TubePage(library.watched);
          } else {
            result = targetCategory == 'All' || targetCategory == 'New to you'
                ? await engine.trending()
                : await engine.search(switch (targetCategory) {
                    'Live' => 'live stream',
                    'Recently uploaded' => 'latest videos today',
                    _ => targetCategory,
                  });
          }
      }
      if (!mounted || request != generation) return;
      final filtered = result.videos.where((video) {
        if (targetSection == 'Shorts') {
          return video.seconds > 0 && video.seconds <= 60;
        }
        if (targetCategory == 'Live' && targetSection == 'Home') {
          return video.live;
        }
        if (targetCategory == 'New to you') {
          return !library.history.containsKey(video.id);
        }
        return true;
      }).toList();
      final ids = <String>{};
      setState(() {
        page = result;
        videos = filtered.where((video) => ids.add(video.id)).toList();
        loading = false;
      });
    } catch (e) {
      debugPrint('YouTube content load failed: $e');
      if (mounted && request == generation) {
        setState(() {
          loading = false;
          error = 'Could not load $targetSection. $e';
        });
      }
    }
  }

  Future<void> _more() async {
    final next = page?.next;
    if (next == null || more) return;
    final request = generation;
    setState(() => more = true);
    try {
      final result = await next();
      if (!mounted || request != generation) return;
      final ids = videos.map((video) => video.id).toSet();
      setState(() {
        page = result;
        videos.addAll(
          (result?.videos ?? []).where(
            (video) =>
                ids.add(video.id) &&
                (section != 'Shorts' ||
                    video.seconds > 0 && video.seconds <= 60) &&
                (category != 'Live' || section != 'Home' || video.live) &&
                (category != 'New to you' ||
                    !library.history.containsKey(video.id)),
          ),
        );
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Could not load more videos: $e');
    } finally {
      if (mounted) setState(() => more = false);
    }
  }

  void _select(String value) {
    if (value == 'Settings') {
      unawaited(_settings());
      return;
    }
    setState(() {
      section = value;
      category = 'All';
    });
    unawaited(_load());
  }

  Future<void> _play(TubeVideo video) async {
    _saveProgress();
    final request = ++playbackGeneration;
    progressTimer?.cancel();
    setState(() {
      active = video;
      opening = true;
      playbackError = '';
      details = null;
      captions = [];
      position = Duration.zero;
      duration = Duration(seconds: video.seconds);
      quality = '';
    });
    try {
      if (player == null) {
        MediaKit.ensureInitialized();
        final created = Player();
        player = created;
        controller = VideoController(created);
        subscriptions.addAll([
          created.stream.playing.listen((value) {
            DeviceConnection.instance.setMediaActive('youtube', value);
            if (mounted) setState(() => playing = value);
          }),
          created.stream.position.listen((value) {
            if (mounted) position = value;
          }),
          created.stream.duration.listen((value) {
            if (mounted) duration = value;
          }),
          created.stream.buffering.listen((value) {
            if (mounted) setState(() => buffering = value);
          }),
          created.stream.error.listen((value) {
            debugPrint('YouTube playback failed: $value');
            DeviceConnection.instance.setMediaActive('youtube', false);
            if (mounted) {
              setState(() {
                playbackError = value;
                playing = false;
                buffering = false;
              });
            }
            if (!opening) {
              unawaited(
                _action(() async {
                  await created.stop();
                }),
              );
            }
          }),
          created.stream.completed.listen((value) {
            if (!value) return;
            _saveProgress(sync: true);
            final session = _mixedSession;
            if (session != null) {
              final current = session.current;
              if (current != null &&
                  current.entryId == widget.mixedSessionEntryId &&
                  session.autoplay &&
                  mounted) {
                _exitMixed(const PlaylistPlaybackExit.completed());
              }
              return;
            }
            if (widget.exitWhenFinished && mounted) {
              unawaited(Navigator.maybePop(context));
            }
          }),
        ]);
      }
      await player!.stop();
      final local = await downloads.local(widget.profileId, video.id);
      if (!mounted || request != playbackGeneration) return;
      if (local != null) {
        quality = 'Downloaded';
        await player!.open(
          Media(Uri.file(local, windows: Platform.isWindows).toString()),
          play: false,
        );
      } else {
        final value = await engine.details(video.id);
        if (!mounted || request != playbackGeneration) return;
        setState(() {
          details = value;
          active = value.video;
          captions = value.subtitles;
        });
        final preferred = value.videoStreams.firstWhere(
          (stream) => !stream.videoOnly,
          orElse: () => value.videoStreams.first,
        );
        await _openStream(preferred, resume: Duration.zero);
      }
      if (!mounted || request != playbackGeneration) return;
      final saved = library.history[video.id];
      if (saved is Map) {
        final resume = Duration(milliseconds: saved['positionMs'] as int? ?? 0);
        final length = saved['durationMs'] as int? ?? 0;
        if (length > 0 && resume.inMilliseconds < length - 5000) {
          await player!.seek(resume);
        }
      }
      await player!.play();
      if (playbackError.isNotEmpty) throw StateError(playbackError);
      _saveProgress(sync: true);
      progressTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _saveProgress(),
      );
    } catch (e) {
      debugPrint('YouTube playback failed: $e');
      if (mounted && request == playbackGeneration) {
        await player?.stop();
        setState(() {
          playbackError = 'Could not play this video: $e';
          playing = false;
          buffering = false;
        });
      }
    } finally {
      if (mounted && request == playbackGeneration) {
        setState(() => opening = false);
      }
    }
  }

  Future<void> _openStream(
    TubeStream stream, {
    required Duration resume,
  }) async {
    if (stream.videoOnly && (details?.audioStreams.isEmpty ?? true)) {
      throw StateError(
        'No companion audio stream is available for this quality.',
      );
    }
    await player!.open(Media(webUrl(stream.url)), play: false);
    if (stream.videoOnly) {
      await player!.setAudioTrack(
        AudioTrack.uri(webUrl(details!.audioStreams.first.url)),
      );
    }
    if (resume > Duration.zero) await player!.seek(resume);
    setState(() => quality = stream.quality);
  }

  Future<void> _quality(TubeStream stream) async {
    final resume = position;
    final wasPlaying = playing;
    await _openStream(stream, resume: resume);
    if (wasPlaying) await player!.play();
  }

  Future<void> _stop() async {
    playbackGeneration++;
    _saveProgress(sync: true);
    progressTimer?.cancel();
    await player?.stop();
    DeviceConnection.instance.setMediaActive('youtube', false);
    if (mounted) {
      setState(() {
        active = null;
        details = null;
        playing = false;
        opening = false;
      });
    }
  }

  Future<void> _switchMixedEntry(String entryId) async {
    final session = _mixedSession;
    if (session == null ||
        session.entryById(entryId) == null ||
        session.current?.entryId == entryId) {
      return;
    }
    _saveProgress(sync: true);
    await player?.stop();
    _exitMixed(PlaylistPlaybackExit.switched(entryId));
  }

  Future<void> _mixedNext() async {
    final session = _mixedSession;
    final target = session?.nextEntry;
    if (target == null) {
      return;
    }
    _saveProgress(sync: true);
    await player?.stop();
    _exitMixed(PlaylistPlaybackExit.switched(target.entryId));
  }

  Future<void> _mixedPrevious() async {
    final session = _mixedSession;
    final target = session?.previousEntry;
    if (target == null) {
      return;
    }
    _saveProgress(sync: true);
    await player?.stop();
    _exitMixed(PlaylistPlaybackExit.switched(target.entryId));
  }

  Future<void> _mixedStop() async {
    final session = _mixedSession;
    if (session == null) {
      await _stop();
      return;
    }
    session.stop();
    _saveProgress(sync: true);
    await player?.stop();
    _exitMixed(const PlaylistPlaybackExit.explicitStop());
  }

  Future<void> _openMixedQueue() async {
    final session = _mixedSession;
    if (session == null || !mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.75,
          child: AnimatedBuilder(
            animation: session,
            builder: (_, __) {
              final rows = [
                for (var index = 0; index < session.entries.length; index++)
                  MediaQueueRow(
                    id: session.entries[index].entryId,
                    title: session.entries[index].item.title,
                    subtitle:
                        session.entries[index].item.subtitle.trim().isEmpty
                        ? session.entries[index].item.sourceName
                        : '${session.entries[index].item.sourceName} · ${session.entries[index].item.subtitle}',
                    nowPlaying: index == session.currentIndex,
                    canMoveUp: index > session.currentIndex + 1,
                    canMoveDown:
                        index > session.currentIndex &&
                        index < session.entries.length - 1,
                    canRemove: index > session.currentIndex,
                  ),
              ];
              return Column(
                children: [
                  ListTile(
                    title: Text(session.playlistName),
                    subtitle: Text(
                      session.shuffled
                          ? 'Mixed playlist queue · shuffled'
                          : 'Mixed playlist queue',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Autoplay'),
                        Switch(
                          value: session.autoplay,
                          onChanged: session.setAutoplay,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: MovieQueuePanel(
                      items: rows,
                      autoplay: session.autoplay,
                      onAutoplayChanged: session.setAutoplay,
                      onPlay: (entryId) {
                        Navigator.of(sheetContext).pop();
                        unawaited(_switchMixedEntry(entryId));
                      },
                      onRemove: session.removePending,
                      onMoveUp: (entryId) {
                        final oldIndex = session.entries.indexWhere(
                          (entry) => entry.entryId == entryId,
                        );
                        if (oldIndex > 0) {
                          session.reorderPending(oldIndex, oldIndex - 1);
                        }
                      },
                      onMoveDown: (entryId) {
                        final oldIndex = session.entries.indexWhere(
                          (entry) => entry.entryId == entryId,
                        );
                        if (oldIndex >= 0) {
                          session.reorderPending(oldIndex, oldIndex + 1);
                        }
                      },
                      onReorder: session.reorderPending,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _goHomeWithMiniPlayer() async {
    final currentPlayer = player;
    final currentController = controller;
    final currentVideo = active;
    if (currentPlayer == null ||
        currentController == null ||
        currentVideo == null) {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return;
    }
    handedOffToMiniPlayer = true;
    progressTimer?.cancel();
    progressTimer = null;
    _saveProgress(sync: true);
    for (final sub in subscriptions) {
      unawaited(sub.cancel());
    }
    subscriptions.clear();
    player = null;
    controller = null;
    await PipPlaybackController.instance.minimize(
      PipPlaybackSession(
        player: currentPlayer,
        video: currentController,
        title: currentVideo.title,
        subtitle: currentVideo.author,
        seekable: true,
        onClose: () async {
          try {
            await currentPlayer.dispose();
          } catch (_) {}
          DeviceConnection.instance.setMediaActive('youtube', false);
        },
      ),
    );
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _download(TubeVideo video) async {
    if (downloading != null) {
      throw StateError('Wait for the current video download to finish.');
    }
    setState(() {
      downloading = video.id;
      status = 'Preparing download...';
    });
    try {
      final value = await engine.details(video.id);
      final combined = value.videoStreams
          .where((stream) => !stream.videoOnly && !stream.url.contains('.m3u8'))
          .firstOrNull;
      if (combined == null) {
        throw StateError(
          'This video has no combined downloadable stream. Adaptive/live downloads are not supported.',
        );
      }
      await downloads.save(widget.profileId, video, combined, (bytes, total) {
        if (mounted) {
          setState(
            () => status = total == null
                ? 'Downloading ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
                : 'Downloading ${(bytes / total * 100).round()}%',
          );
        }
      });
      if (mounted) {
        setState(() {
          downloadedIds.add(video.id);
          status = 'Video downloaded for offline playback.';
        });
      }
    } finally {
      if (mounted) setState(() => downloading = null);
    }
  }

  Future<String?> _input(
    String title,
    String hint, {
    String initial = '',
  }) async {
    final text = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: text,
            autofocus: true,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, text.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      text.dispose();
    }
  }

  /// Adds the video to one of the profile's mixed playlists, where it sits
  /// alongside songs, movies, shows and podcasts.
  Future<void> _playlist(TubeVideo video) async {
    await addToMixedPlaylist(
      context,
      profileId: widget.profileId,
      item: HubItem.youtube(video),
    );
  }

  Future<void> _openMixedPlaylists() async {
    scaffold.currentState?.closeDrawer();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PlaylistsScreen(profileId: widget.profileId),
      ),
    );
    if (!mounted) return;
    final latest = await store.load(widget.profileId);
    if (mounted) setState(() => library = latest);
  }

  Future<void> _settings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('YouTube / PsTube'),
        content: const Text(
          'Powered by the GPLv3 PsTube engine (YouTubeExplode + Piped). '
          'Subscriptions, favorites, history and playlists belong to this MILLITOPTV profile and sync to every device paired with your account. They are not read from your Google account. '
          'Piped receives public search/video requests when used. Public server availability varies. '
          'Uploads, purchases and posting comments require the official YouTube app.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _action(() async {
                final url = await _input(
                  'Piped API server',
                  'https://your-piped-server',
                  initial: await HomePreferences().tubePipedUrl(
                    widget.profileId,
                  ),
                );
                if (url == null) return;
                webUrl(url);
                await HomePreferences().setTubePipedUrl(widget.profileId, url);
                if (engine is PsTubeEngine) {
                  (engine as PsTubeEngine).pipedUrl = url;
                }
                await _load();
              });
            },
            child: const Text('Piped server'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              showLicensePage(
                context: this.context,
                applicationName: 'MILLITOPTV / PsTube',
              );
            },
            child: const Text('Licenses'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _comments() async {
    final video = active;
    if (video == null) return;
    final future = engine.comments(video.id);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: FutureBuilder<TubeComments>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Could not load comments: ${snapshot.error}'),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return _CommentsList(initial: snapshot.data!);
          },
        ),
      ),
    );
  }

  Future<void> _captionMenu() async {
    if (active == null || player == null) return;
    if (captions.isEmpty && engine is PsTubeEngine) {
      final values = await (engine as PsTubeEngine).captions(active!.id);
      if (!mounted) return;
      setState(() => captions = values);
    }
    if (!mounted) return;
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Subtitles'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, -1),
            child: const Text('Off'),
          ),
          if (captions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No captions available.'),
            ),
          for (var i = 0; i < captions.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Text(captions[i].label),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await player!.setSubtitleTrack(
      choice == -1
          ? SubtitleTrack.no()
          : SubtitleTrack.uri(captions[choice].url),
    );
  }

  @override
  void dispose() {
    generation++;
    playbackGeneration++;
    progressTimer?.cancel();
    _saveProgress();
    final departing = player;
    for (final sub in subscriptions) {
      unawaited(sub.cancel());
    }
    if (!handedOffToMiniPlayer) {
      unawaited(
        departing?.dispose().catchError((Object e) {
              debugPrint('Could not dispose YouTube player: $e');
            }) ??
            Future.value(),
      );
      DeviceConnection.instance.setMediaActive('youtube', false);
    }
    engine.close();
    search.dispose();
    super.dispose();
  }

  Widget _avatar(String url, String name, {double size = 32}) => ClipOval(
    child: SizedBox(
      width: size,
      height: size,
      child: url.isEmpty
          ? ColoredBox(
              color: context.millitopTheme.accentColor.withAlpha(60),
              child: Center(
                child: Text(
                  name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
                ),
              ),
            )
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.person_outline),
            ),
    ),
  );

  Widget _nav(String label, IconData icon, {String? destination}) => ListTile(
    dense: true,
    selected: section == (destination ?? label),
    selectedTileColor: Colors.white.withAlpha(24),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    leading: Icon(icon, size: 21),
    title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: () {
      scaffold.currentState?.closeDrawer();
      _select(destination ?? label);
    },
  );

  Widget _rail() => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _nav('Home', Icons.home_outlined),
      _nav('Shorts', Icons.bolt_outlined),
      _nav('Subscriptions', Icons.subscriptions_outlined),
      const Divider(height: 28),
      const Padding(
        padding: EdgeInsets.all(8),
        child: Text('You', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      _nav('History', Icons.history),
      ListTile(
        key: const ValueKey('youtube-mixed-playlists'),
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: const Icon(Icons.queue_play_next, size: 21),
        title: const Text(
          'My playlists',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: const Text('Mixed with music, movies & more'),
        onTap: () => unawaited(_openMixedPlaylists()),
      ),
      _nav('Watch later', Icons.schedule),
      _nav('Favorites', Icons.favorite_border),
      _nav('Downloads', Icons.download_outlined),
      const Divider(height: 28),
      const Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'Subscriptions',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      for (final channel in library.list('subscriptions'))
        ListTile(
          dense: true,
          leading: _avatar(channel.avatar, channel.author, size: 24),
          title: Text(
            channel.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _select('Channel:${channel.channelId}'),
        ),
      if (library.list('subscriptions').isEmpty)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('Subscribe from a video to build your feed.'),
        ),
      if (library.playlists.isNotEmpty) ...[
        const Divider(),
        _nav(
          'Older YouTube playlists',
          Icons.playlist_play,
          destination: 'Playlists',
        ),
      ],
      for (final name in library.playlists)
        _nav(
          name.substring(9),
          Icons.playlist_play,
          destination: 'Playlist:${name.substring(9)}',
        ),
      _nav('Engine settings', Icons.settings_outlined, destination: 'Settings'),
    ],
  );

  Widget _videoCard(TubeVideo video) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: () => unawaited(_play(video)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: context.millitopTheme.panelColor,
                  child: video.thumbnail.isEmpty
                      ? const Icon(Icons.video_library_outlined, size: 40)
                      : Image.network(
                          video.thumbnail,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.video_library_outlined,
                            size: 40,
                          ),
                        ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(210),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      child: Text(
                        video.live ? 'LIVE' : tubeTime(video.seconds),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                if (library.history[video.id] is Map)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      value:
                          ((library.history[video.id] as Map)['durationMs']
                                      as int? ??
                                  0) >
                              0
                          ? (((library.history[video.id] as Map)['positionMs']
                                        as int) /
                                    ((library.history[video.id]
                                            as Map)['durationMs']
                                        as int))
                                .clamp(0, 1)
                          : 0,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _avatar(video.avatar, video.author),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.millitopTheme.mutedColor,
                    ),
                  ),
                  Text(
                    '${_views(video.views)} views${video.published.isEmpty ? '' : ' · ${video.published.split('T').first}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.millitopTheme.mutedColor,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Video actions',
              onSelected: (value) => unawaited(
                _action(() async {
                  switch (value) {
                    case 'later':
                      await _toggle('later', video);
                    case 'liked':
                      await _toggle('liked', video);
                    case 'playlist':
                      await _playlist(video);
                    case 'download':
                      await _download(video);
                    case 'remove':
                      await downloads.remove(widget.profileId, video.id);
                      downloadedIds.remove(video.id);
                      await _load();
                  }
                }),
              ),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'later',
                  child: Text(
                    library.contains('later', video)
                        ? 'Remove from Watch later'
                        : 'Watch later',
                  ),
                ),
                PopupMenuItem(
                  value: 'liked',
                  child: Text(
                    library.contains('liked', video)
                        ? 'Remove from Favorites'
                        : 'Add to Favorites',
                  ),
                ),
                const PopupMenuItem(
                  value: 'playlist',
                  child: Text('Add to playlist'),
                ),
                if (downloadedIds.contains(video.id))
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove download'),
                  )
                else
                  PopupMenuItem(
                    value: 'download',
                    enabled: downloading == null,
                    child: const Text('Download video'),
                  ),
              ],
              icon: const Icon(Icons.more_vert, size: 20),
            ),
          ],
        ),
      ],
    ),
  );

  String _views(int count) => count >= 1000000
      ? '${(count / 1000000).toStringAsFixed(1)}M'
      : count >= 1000
      ? '${(count / 1000).toStringAsFixed(0)}K'
      : '$count';

  Widget _player() {
    final video = active!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: Colors.black,
            constraints: const BoxConstraints(maxHeight: 480),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: controller == null
                  ? const Center(child: CircularProgressIndicator())
                  : Video(controller: controller!),
            ),
          ),
          if (opening || buffering) const LinearProgressIndicator(),
          if (playbackError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                playbackError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              video.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: video.channelId.isEmpty
                    ? null
                    : () => _select('Channel:${video.channelId}'),
                icon: _avatar(video.avatar, video.author),
                label: Text(video.author),
              ),
              FilledButton(
                onPressed: video.channelId.isEmpty
                    ? null
                    : () => unawaited(
                        _action(() => _toggle('subscriptions', video)),
                      ),
                child: Text(
                  library.contains('subscriptions', video)
                      ? 'Unsubscribe'
                      : 'Subscribe',
                ),
              ),
              IconButton(
                key: const ValueKey('youtube-favorite'),
                tooltip: library.contains('liked', video)
                    ? 'Remove from Favorites'
                    : 'Add to Favorites',
                icon: Icon(
                  library.contains('liked', video)
                      ? Icons.favorite
                      : Icons.favorite_border,
                ),
                onPressed: () =>
                    unawaited(_action(() => _toggle('liked', video))),
              ),
              IconButton(
                tooltip: 'Watch later',
                icon: const Icon(Icons.schedule),
                onPressed: () =>
                    unawaited(_action(() => _toggle('later', video))),
              ),
              IconButton(
                tooltip: 'Add to playlist',
                icon: const Icon(Icons.playlist_add),
                onPressed: () => unawaited(_action(() => _playlist(video))),
              ),
              TextButton.icon(
                onPressed: () => unawaited(_action(_comments)),
                icon: const Icon(Icons.comment_outlined),
                label: const Text('Comments'),
              ),
              PopupMenuButton<TubeStream>(
                tooltip: 'Video quality',
                onSelected: (stream) =>
                    unawaited(_action(() => _quality(stream))),
                itemBuilder: (_) => [
                  for (final stream in details?.videoStreams ?? <TubeStream>[])
                    PopupMenuItem(value: stream, child: Text(stream.quality)),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(quality.isEmpty ? 'Quality' : quality),
                ),
              ),
              IconButton(
                tooltip: 'Subtitles',
                icon: const Icon(Icons.closed_caption_outlined),
                onPressed: () => unawaited(_action(_captionMenu)),
              ),
              PopupMenuButton<double>(
                tooltip: 'Playback speed',
                onSelected: (speed) => unawaited(
                  _action(() async {
                    await player?.setRate(speed);
                  }),
                ),
                itemBuilder: (_) => [
                  for (final speed in [.5, .75, 1.0, 1.25, 1.5, 2.0])
                    PopupMenuItem(value: speed, child: Text('${speed}x')),
                ],
                icon: const Icon(Icons.speed),
              ),
              if (_hasMixedSession)
                IconButton(
                  tooltip: 'Previous item',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () => unawaited(_mixedPrevious()),
                ),
              if (_hasMixedSession)
                IconButton(
                  tooltip: 'Next item',
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => unawaited(_mixedNext()),
                ),
              if (_hasMixedSession)
                IconButton(
                  tooltip: 'Queue',
                  icon: const Icon(Icons.queue_music),
                  onPressed: () => unawaited(_openMixedQueue()),
                ),
              IconButton(
                tooltip: _hasMixedSession ? 'Stop session' : 'Close player',
                icon: const Icon(Icons.close),
                onPressed: () =>
                    unawaited(_action(_hasMixedSession ? _mixedStop : _stop)),
              ),
            ],
          ),
          if (video.description.isNotEmpty)
            ExpansionTile(
              title: const Text('Description'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(video.description),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _content() => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1250
          ? 4
          : constraints.maxWidth >= 900
          ? 3
          : constraints.maxWidth >= 560
          ? 2
          : 1;
      final cardWidth =
          (constraints.maxWidth - 40 - (columns - 1) * 18) / columns;
      final cardHeight = cardWidth * 9 / 16 + 118;
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            sliver: SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final value in [
                      'All',
                      'Music',
                      'Technology',
                      'Gaming',
                      'Live',
                      'Podcasts',
                      'Mixes',
                      'Recently uploaded',
                      'Watched',
                      'New to you',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(value),
                          selected: section == 'Home' && category == value,
                          onSelected: (_) {
                            setState(() {
                              section = 'Home';
                              category = value;
                            });
                            unawaited(_load());
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (active != null)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverToBoxAdapter(child: _player()),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (section != 'Home')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        section.startsWith('Channel:')
                            ? 'Channel videos'
                            : section,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (error.isNotEmpty)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SelectableText(
                            error,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  if (status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(status),
                    ),
                  if (loading) const LinearProgressIndicator(),
                  if (!loading && videos.isEmpty && error.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No videos here yet. Search or save videos to your library.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 18,
                mainAxisSpacing: 22,
                mainAxisExtent: cardHeight,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _videoCard(videos[index]),
                childCount: videos.length,
              ),
            ),
          ),
          if (page?.next != null)
            SliverToBoxAdapter(
              child: Center(
                child: TextButton(
                  onPressed: more ? null : _more,
                  child: Text(more ? 'Loading...' : 'Load more'),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 30)),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 850;
      return PopScope(
        canPop: !_hasMixedSession,
        onPopInvokedWithResult: (didPop, __) {
          if (!didPop && _hasMixedSession) {
            _mixedSession?.stop();
            _exitMixed(const PlaylistPlaybackExit.explicitBack());
          }
        },
        child: Scaffold(
          key: scaffold,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          drawer: desktop
              ? null
              : Drawer(
                  child: SafeArea(child: Builder(builder: (_) => _rail())),
                ),
          appBar: AppBar(
            automaticallyImplyLeading: false,
            toolbarHeight: 64,
            titleSpacing: 12,
            title: Row(
              children: [
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Navigation',
                    icon: const Icon(Icons.menu),
                    onPressed: () {
                      if (desktop) {
                        setState(() => sidebar = !sidebar);
                      } else {
                        Scaffold.of(context).openDrawer();
                      }
                    },
                  ),
                ),
                const Icon(Icons.smart_display, color: Color(0xFFFF3030)),
                if (constraints.maxWidth >= 650) ...[
                  const SizedBox(width: 7),
                  const Text(
                    'YouTube',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 30),
                ],
                Expanded(
                  child: TextField(
                    controller: search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _select('Search'),
                    decoration: InputDecoration(
                      hintText: 'Search',
                      isDense: true,
                      filled: true,
                      fillColor: context.millitopTheme.panelColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        tooltip: 'Search YouTube',
                        icon: const Icon(Icons.search),
                        onPressed: () => _select('Search'),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'YouTube / PsTube settings',
                  onPressed: _settings,
                  icon: const Icon(Icons.settings_outlined),
                ),
                IconButton(
                  tooltip: _hasMixedSession
                      ? 'Leave playlist playback'
                      : 'Back to MILLITOPTV',
                  onPressed: () => unawaited(
                    _hasMixedSession
                        ? () async {
                            _mixedSession?.stop();
                            _exitMixed(
                              const PlaylistPlaybackExit.explicitBack(),
                            );
                          }()
                        : _goHomeWithMiniPlayer(),
                  ),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          body: Row(
            children: [
              if (desktop && sidebar)
                SizedBox(width: 218, child: Builder(builder: (_) => _rail())),
              Expanded(child: _content()),
            ],
          ),
          floatingActionButton: section == 'Playlists'
              ? FloatingActionButton.extended(
                  onPressed: () => unawaited(
                    _action(() async {
                      final url = await _input(
                        'Open public YouTube playlist',
                        'Playlist URL or ID',
                      );
                      if (url == null) return;
                      final id =
                          Uri.tryParse(url)?.queryParameters['list'] ?? url;
                      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
                        throw const FormatException('Invalid playlist ID.');
                      }
                      _select('Public playlist:$id');
                    }),
                  ),
                  icon: const Icon(Icons.playlist_play),
                  label: const Text('Open public playlist'),
                )
              : null,
        ),
      );
    },
  );
}

class _CommentsList extends StatefulWidget {
  final TubeComments initial;
  const _CommentsList({required this.initial});
  @override
  State<_CommentsList> createState() => _CommentsListState();
}

class _CommentsListState extends State<_CommentsList> {
  late TubeComments page = widget.initial;
  late final values = [...page.comments];
  bool loading = false;
  String error = '';
  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const ListTile(
        title: Text('Comments'),
        subtitle: Text('Read-only. Posting requires the official YouTube app.'),
      ),
      if (values.isEmpty) const ListTile(title: Text('No comments available.')),
      for (final value in values)
        ListTile(
          title: Text(value.author),
          subtitle: Text(
            '${value.text}\n${value.published} · ${value.likes} likes',
          ),
          isThreeLine: true,
        ),
      if (error.isNotEmpty)
        Padding(padding: const EdgeInsets.all(16), child: Text(error)),
      if (page.next != null)
        TextButton(
          onPressed: loading
              ? null
              : () async {
                  setState(() => loading = true);
                  try {
                    final next = await page.next!();
                    if (mounted && next != null) {
                      setState(() {
                        page = next;
                        values.addAll(next.comments);
                      });
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(
                        () => error = 'Could not load more comments: $e',
                      );
                    }
                  } finally {
                    if (mounted) setState(() => loading = false);
                  }
                },
          child: Text(loading ? 'Loading...' : 'More comments'),
        ),
    ],
  );
}
