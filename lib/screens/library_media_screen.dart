// ignore_for_file: prefer_collection_literals

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import '../library/library_models.dart';
import '../library/library_file_service.dart';
import '../services/device_connection.dart';
import '../services/home_preferences.dart';
import '../services/video_playback_memory.dart';
import '../theme/millitop_visual_theme.dart';

class LibraryMediaScreen extends StatefulWidget {
  final int profileId;
  final LibraryFolder folder;
  final LibraryItem item;
  final LibraryFileService? files;
  const LibraryMediaScreen({
    super.key,
    required this.profileId,
    required this.folder,
    required this.item,
    this.files,
  });
  @override
  State<LibraryMediaScreen> createState() => _LibraryMediaScreenState();
}

class _LibraryMediaScreenState extends State<LibraryMediaScreen>
    with WidgetsBindingObserver {
  final subscriptions = <StreamSubscription<dynamic>>[];
  final memory = VideoPlaybackMemory();
  final session = 'local-library:${DateTime.now().microsecondsSinceEpoch}';
  Player? player;
  VideoController? video;
  Track selectedTrack = const Track();
  Tracks tracks = const Tracks();
  String? verified;
  String error = '';
  String statusMessage = '';
  bool opening = true,
      closing = false,
      allowPop = false,
      playing = false,
      active = false,
      renderVideo = true,
      buffering = false,
      fullscreen = false,
      muted = false,
      attemptedRecovery = false;
  Duration position = Duration.zero, duration = Duration.zero;
  double volume = 100, preMuteVolume = 100, playbackSpeed = 1.0;
  int seekIncrementSeconds = 10;
  String aspectMode = 'contain';
  List<int> bookmarksMs = const <int>[];
  double? scrub;
  double? scrubPreviewMs;
  int? resumePositionMs;
  late Future<void> initialization;
  Future<void>? closeTask;
  bool get image => widget.item.kind == LibraryMediaKind.image;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initialization = _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (image) {
      return;
    }
    if (state == AppLifecycleState.paused) {
      final current = player;
      if (current != null && playing) {
        unawaited(current.pause());
      }
      unawaited(_saveProgressSnapshot());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(WakelockPlus.enable());
      if (error.isNotEmpty) {
        unawaited(_attemptRecovery());
      }
      return;
    }
    if (state == AppLifecycleState.detached) {
      unawaited(_saveProgressSnapshot());
    }
  }

  void _update(VoidCallback update) {
    if (mounted && !closing) {
      setState(update);
    }
  }

  String get _streamKey => verified == null
      ? 'library:${widget.folder.id}:${widget.item.path}'
      : 'file://${verified!}';

  Future<void> _loadPrefs() async {
    final prefs = await memory.loadPrefs('library-${widget.folder.id}');
    seekIncrementSeconds =
        int.tryParse(prefs['seekIncrementSeconds']?.toString() ?? '') ?? 10;
    seekIncrementSeconds = seekIncrementSeconds.clamp(5, 60);
    aspectMode = prefs['aspectMode']?.toString() ?? 'contain';
    final speed = double.tryParse(prefs['playbackSpeed']?.toString() ?? '');
    if (speed != null && speed >= 0.5 && speed <= 2.0) {
      playbackSpeed = speed;
    }
  }

  Future<void> _savePrefs() async {
    await memory.savePrefs('library-${widget.folder.id}', {
      'seekIncrementSeconds': seekIncrementSeconds,
      'aspectMode': aspectMode,
      'playbackSpeed': playbackSpeed,
    });
  }

  Future<void> _saveProgressSnapshot() async {
    if (image || verified == null) {
      return;
    }
    final durationMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds;
    final complete =
        durationMs > 0 &&
        positionMs >= (durationMs - const Duration(seconds: 6).inMilliseconds);
    await memory.saveProgress(
      _streamKey,
      positionMs: positionMs,
      durationMs: durationMs,
      complete: complete,
    );
    await memory.appendStatsEvent(
      'library-${widget.folder.id}',
      type: 'library_progress',
      payload: {
        'itemPath': widget.item.path,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'buffering': buffering,
      },
    );
    await HomePreferences().saveLibraryPlaybackState(
      widget.profileId,
      itemPath: widget.item.path,
      title: widget.item.name,
      positionMs: positionMs,
      durationMs: durationMs,
      complete: complete,
    );
  }

  Future<void> _initialize() async {
    try {
      await _loadPrefs();
      final path = await (widget.files ?? LibraryFileService()).resolveMedia(
        widget.folder,
        widget.item,
      );
      if (!mounted || closing) {
        return;
      }
      verified = path;
      bookmarksMs = await memory.loadBookmarks(_streamKey);
      final progress = await memory.loadProgress(_streamKey);
      resumePositionMs = int.tryParse(progress['positionMs']?.toString() ?? '');
      if (image) {
        _update(() => opening = false);
        return;
      }
      // Defer native initialization until playback; a missing decoder must not block app startup.
      MediaKit.ensureInitialized();
      final next = Player();
      player = next;
      if (widget.item.kind == LibraryMediaKind.video) {
        video = VideoController(next);
      }
      active = true;
      DeviceConnection.instance.setMediaActive(session, true);
      subscriptions.add(
        next.stream.playing.listen((value) => _update(() => playing = value)),
      );
      subscriptions.add(
        next.stream.duration.listen((value) => _update(() => duration = value)),
      );
      subscriptions.add(
        next.stream.track.listen(
          (value) => _update(() => selectedTrack = value),
        ),
      );
      subscriptions.add(
        next.stream.tracks.listen((value) => _update(() => tracks = value)),
      );
      subscriptions.add(
        next.stream.volume.listen((value) => _update(() => volume = value)),
      );
      subscriptions.add(
        next.stream.buffering.listen(
          (value) => _update(() => buffering = value),
        ),
      );
      subscriptions.add(
        next.stream.error.listen((value) {
          _update(
            () => error =
                'This file could not be played completely. Retrying playback...',
          );
          unawaited(_attemptRecovery());
        }),
      );
      subscriptions.add(
        next.stream.position.listen((value) {
          _update(() => position = value);
          unawaited(_saveProgressSnapshot());
        }),
      );
      subscriptions.add(
        next.stream.completed.listen((done) {
          if (done) {
            unawaited(_saveProgressSnapshot());
          }
        }),
      );
      await next
          .open(
            Media(Uri.file(path, windows: Platform.isWindows).toString()),
            play: true,
          )
          .timeout(const Duration(seconds: 25));
      await next.setRate(playbackSpeed);
      await WakelockPlus.enable();
      if ((resumePositionMs ?? 0) > 15000) {
        await next.seek(Duration(milliseconds: resumePositionMs!));
      }
      _update(() => opening = false);
    } catch (_) {
      _update(() {
        opening = false;
        error =
            'Could not open this media file. Check access and format, or let an active recording finish, then try again.';
      });
    }
  }

  Future<void> _perform(Future<void> Function(Player) action) async {
    final current = player;
    if (current == null || closing || opening) {
      return;
    }
    try {
      await action(current).timeout(const Duration(seconds: 10));
    } catch (_) {
      _update(
        () => error =
            'The player could not complete that action. Try again or return to the folder.',
      );
    }
  }

  Future<void> _attemptRecovery() async {
    if (attemptedRecovery || verified == null) {
      return;
    }
    final current = player;
    if (current == null) {
      return;
    }
    attemptedRecovery = true;
    final resumeMs = position.inMilliseconds;
    try {
      await current.open(
        Media(Uri.file(verified!, windows: Platform.isWindows).toString()),
        play: true,
      );
      if (resumeMs > 0) {
        await current.seek(Duration(milliseconds: resumeMs));
      }
      if (mounted) {
        setState(() => error = '');
      } else {
        error = '';
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Playback could not recover automatically. Please try again.',
        );
      }
    } finally {
      attemptedRecovery = false;
    }
  }

  Future<void> _close() => closeTask ??= _closeImpl();
  Future<void> _closeImpl() async {
    await initialization;
    await _saveProgressSnapshot();
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    subscriptions.clear();
    final current = player;
    player = null;
    if (current != null) {
      await current.dispose().timeout(const Duration(seconds: 15));
    }
    if (active) {
      DeviceConnection.instance.setMediaActive(session, false);
      active = false;
    }
    await WakelockPlus.disable();
  }

  Future<void> _back() async {
    if (closing) {
      return;
    }
    setState(() {
      closing = true;
      renderVideo = false;
    });
    if (fullscreen) {
      await _setFullscreen(false);
    }
    await WidgetsBinding.instance.endOfFrame;
    try {
      await _close();
    } catch (_) {
      // Do not trap the user in this route or falsely clear the playback/update guard.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Player shutdown could not be confirmed. Quit and reopen Millitop before applying an update.',
            ),
          ),
        );
      }
    }
    if (!mounted) {
      return;
    }
    setState(() => allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    closing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(WakelockPlus.disable());
    unawaited(_close().catchError((Object _) {}));
    super.dispose();
  }

  String _time(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  void _seekBy(int seconds) {
    final target = (position.inMilliseconds + seconds * 1000)
        .clamp(0, duration.inMilliseconds)
        .toInt();
    unawaited(_perform((p) => p.seek(Duration(milliseconds: target))));
  }

  Future<void> _seekByConfigured(
    int direction, {
    bool accelerated = false,
  }) async {
    final step = seekIncrementSeconds * (accelerated ? 3 : 1);
    _seekBy(step * direction);
  }

  Future<void> _toggleMute() async {
    final current = player;
    if (current == null) {
      return;
    }
    if (muted || volume <= 0.0001) {
      final target = preMuteVolume <= 0.0001 ? 100.0 : preMuteVolume;
      await current.setVolume(target.clamp(0, 100));
      _update(() {
        muted = false;
        volume = target;
      });
      return;
    }
    preMuteVolume = volume;
    await current.setVolume(0);
    _update(() => muted = true);
  }

  Future<void> _setVolume(double value) async {
    final current = player;
    if (current == null) {
      return;
    }
    await current.setVolume(value);
    _update(() {
      volume = value;
      muted = value <= 0.0001;
    });
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    await _perform((p) => p.setRate(speed));
    _update(() => playbackSpeed = speed);
    await _savePrefs();
  }

  Future<void> _stepFrame(int direction) async {
    if (playing) {
      return;
    }
    await _perform(
      (p) => p.seek(
        Duration(
          milliseconds: max(0, position.inMilliseconds + (33 * direction)),
        ),
      ),
    );
  }

  Future<void> _setAspectMode(String value) async {
    _update(() => aspectMode = value);
    await _savePrefs();
  }

  Future<void> _addBookmark() async {
    final value = position.inMilliseconds.clamp(
      0,
      max(0, duration.inMilliseconds),
    );
    bookmarksMs = [...bookmarksMs, value.toInt()].toSet().toList()..sort();
    await memory.saveBookmarks(_streamKey, bookmarksMs);
    _update(
      () => statusMessage =
          'Bookmark added at ${_time(Duration(milliseconds: value.toInt()))}.',
    );
  }

  Future<void> _openBookmarks() async {
    if (bookmarksMs.isEmpty) {
      return;
    }
    final target = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                'Bookmarks',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final mark in bookmarksMs)
              ListTile(
                title: Text(_time(Duration(milliseconds: mark))),
                onTap: () => Navigator.pop(ctx, mark),
              ),
          ],
        ),
      ),
    );
    if (target != null) {
      await _perform((p) => p.seek(Duration(milliseconds: target)));
    }
  }

  List<int> _chapters() {
    final total = duration.inMilliseconds;
    if (total <= 0) {
      return const <int>[];
    }
    final result = <int>[];
    for (var i = 1; i < 10; i++) {
      result.add((total * (i / 10)).round());
    }
    return result;
  }

  Future<void> _openChapters() async {
    final chapters = _chapters();
    if (chapters.isEmpty) {
      return;
    }
    final target = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                'Chapters',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (var i = 0; i < chapters.length; i++)
              ListTile(
                title: Text('Chapter ${i + 1}'),
                subtitle: Text(_time(Duration(milliseconds: chapters[i]))),
                onTap: () => Navigator.pop(ctx, chapters[i]),
              ),
          ],
        ),
      ),
    );
    if (target != null) {
      await _perform((p) => p.seek(Duration(milliseconds: target)));
    }
  }

  Future<void> _showPlaybackStats() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playback statistics'),
        content: SelectableText(
          'Position: ${_time(position)}\n'
          'Duration: ${_time(duration)}\n'
          'Buffering: ${buffering ? 'yes' : 'no'}\n'
          'Volume: ${volume.toStringAsFixed(0)}%\n'
          'Speed: ${playbackSpeed.toStringAsFixed(2)}x\n'
          'Aspect: $aspectMode\n'
          'Seek step: ${seekIncrementSeconds}s',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _createSessionHandoff() async {
    final code = await memory.createSessionHandoff(
      title: widget.item.name,
      streamUrl: _streamKey,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
    );
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session handoff'),
        content: SelectableText('Use this code on another device: $code'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _consumeSessionHandoff() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Continue from handoff'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Handoff code'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) {
      return;
    }
    final payload = await memory.consumeSessionHandoff(code);
    if (payload == null) {
      _update(() => error = 'Handoff code not found or expired.');
      return;
    }
    final seekMs = int.tryParse(payload['positionMs']?.toString() ?? '') ?? 0;
    if (seekMs > 0) {
      await _perform((p) => p.seek(Duration(milliseconds: seekMs)));
    }
  }

  Future<void> _openExternalPlayer() async {
    if (verified == null) {
      return;
    }
    final uri = Uri.file(verified!, windows: Platform.isWindows).toString();
    await Clipboard.setData(ClipboardData(text: uri));
    _update(
      () => statusMessage = 'Local media path copied for external player.',
    );
  }

  Future<void> _pickSubtitle() async {
    final current = player;
    if (current == null || tracks.subtitle.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            for (final track in tracks.subtitle)
              ListTile(
                leading: Icon(
                  selectedTrack.subtitle == track
                      ? Icons.check_circle
                      : Icons.subtitles_outlined,
                ),
                title: Text(track.title ?? '(Subtitle ${track.id})'),
                subtitle: Text(track.language ?? 'unknown'),
                onTap: () async {
                  await current.setSubtitleTrack(track);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAudioTrack() async {
    final current = player;
    if (current == null || tracks.audio.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            for (final track in tracks.audio)
              ListTile(
                leading: Icon(
                  selectedTrack.audio == track
                      ? Icons.check_circle
                      : Icons.audiotrack_outlined,
                ),
                title: Text(track.title ?? '(Audio ${track.id})'),
                subtitle: Text(track.language ?? 'unknown'),
                onTap: () async {
                  await current.setAudioTrack(track);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickVideoTrack() async {
    final current = player;
    if (current == null || tracks.video.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            for (final track in tracks.video)
              ListTile(
                leading: Icon(
                  selectedTrack.video == track
                      ? Icons.check_circle
                      : Icons.high_quality_outlined,
                ),
                title: Text(track.title ?? '(Quality ${track.id})'),
                subtitle: Text(track.language ?? 'unknown'),
                onTap: () async {
                  await current.setVideoTrack(track);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  BoxFit _aspectFit() {
    switch (aspectMode) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      default:
        return BoxFit.contain;
    }
  }

  Future<void> _setFullscreen(bool value) async {
    try {
      if (value) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(const []);
      }
    } catch (_) {}
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await windowManager.setFullScreen(value);
      }
    } catch (_) {}
    _update(() => fullscreen = value);
  }

  Future<void> _toggleFullscreen() async {
    await _setFullscreen(!fullscreen);
  }

  Future<void> _seekToPreview(double value) async {
    setState(() {
      scrub = null;
      scrubPreviewMs = null;
    });
    await _perform((p) => p.seek(Duration(milliseconds: value.round())));
  }

  Future<void> _restartPlayback() async {
    await _perform((p) => p.seek(Duration.zero));
    _update(() => statusMessage = 'Restarted from beginning.');
  }

  Future<void> _resumeSavedProgress() async {
    final saved = resumePositionMs ?? 0;
    if (saved <= 0) {
      return;
    }
    await _perform((p) => p.seek(Duration(milliseconds: saved)));
    _update(() => statusMessage = 'Resumed saved progress.');
  }

  Widget _seekThumbnailPreview() {
    final preview = scrubPreviewMs;
    if (preview == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: 170,
      height: 96,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withAlpha(210),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: context.millitopTheme.panelColor),
          ),
          const Positioned(
            left: 8,
            top: 8,
            child: Icon(Icons.movie_filter_outlined, color: Colors.white54),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withAlpha(192),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  _time(Duration(milliseconds: preview.round())),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maximum = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final value = (scrub ?? position.inMilliseconds.toDouble())
        .clamp(0.0, maximum)
        .toDouble();
    return PopScope(
      canPop: allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_back());
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(_back()),
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            leading: IconButton(
              onPressed: closing ? null : _back,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to folder',
            ),
            title: Text(
              widget.item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (!image) ...[
                IconButton(
                  tooltip: 'Fullscreen',
                  onPressed: _toggleFullscreen,
                  icon: const Icon(Icons.fullscreen),
                ),
                IconButton(
                  tooltip: 'Subtitles',
                  onPressed: _pickSubtitle,
                  icon: const Icon(Icons.subtitles),
                ),
                IconButton(
                  tooltip: 'Audio track',
                  onPressed: _pickAudioTrack,
                  icon: const Icon(Icons.audiotrack),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Playback options',
                  onSelected: (value) async {
                    switch (value) {
                      case 'quality':
                        await _pickVideoTrack();
                        break;
                      case 'bookmark_add':
                        await _addBookmark();
                        break;
                      case 'bookmark_open':
                        await _openBookmarks();
                        break;
                      case 'chapters':
                        await _openChapters();
                        break;
                      case 'restart':
                        await _restartPlayback();
                        break;
                      case 'resume':
                        await _resumeSavedProgress();
                        break;
                      case 'handoff_create':
                        await _createSessionHandoff();
                        break;
                      case 'handoff_consume':
                        await _consumeSessionHandoff();
                        break;
                      case 'external':
                        await _openExternalPlayer();
                        break;
                      case 'stats':
                        await _showPlaybackStats();
                        break;
                      case 'frame_back':
                        await _stepFrame(-1);
                        break;
                      case 'frame_forward':
                        await _stepFrame(1);
                        break;
                      case 'seek_10':
                        seekIncrementSeconds = 10;
                        await _savePrefs();
                        break;
                      case 'seek_30':
                        seekIncrementSeconds = 30;
                        await _savePrefs();
                        break;
                      case 'seek_45':
                        seekIncrementSeconds = 45;
                        await _savePrefs();
                        break;
                      case 'speed_10':
                        await _setPlaybackSpeed(1.0);
                        break;
                      case 'speed_125':
                        await _setPlaybackSpeed(1.25);
                        break;
                      case 'speed_150':
                        await _setPlaybackSpeed(1.5);
                        break;
                      case 'speed_200':
                        await _setPlaybackSpeed(2.0);
                        break;
                      case 'aspect_contain':
                        await _setAspectMode('contain');
                        break;
                      case 'aspect_cover':
                        await _setAspectMode('cover');
                        break;
                      case 'aspect_fill':
                        await _setAspectMode('fill');
                        break;
                      case 'aspect_fit_width':
                        await _setAspectMode('fitWidth');
                        break;
                      case 'aspect_fit_height':
                        await _setAspectMode('fitHeight');
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'quality',
                      child: Text('Quality'),
                    ),
                    const PopupMenuItem(
                      value: 'chapters',
                      child: Text('Chapters'),
                    ),
                    const PopupMenuItem(
                      value: 'bookmark_add',
                      child: Text('Add bookmark'),
                    ),
                    const PopupMenuItem(
                      value: 'bookmark_open',
                      child: Text('Go to bookmark'),
                    ),
                    const PopupMenuItem(
                      value: 'restart',
                      child: Text('Restart from beginning'),
                    ),
                    if ((resumePositionMs ?? 0) > 0)
                      const PopupMenuItem(
                        value: 'resume',
                        child: Text('Resume saved progress'),
                      ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'frame_back',
                      child: Text('Step frame backward'),
                    ),
                    const PopupMenuItem(
                      value: 'frame_forward',
                      child: Text('Step frame forward'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'seek_10',
                      child: Text('Seek increment: 10s'),
                    ),
                    const PopupMenuItem(
                      value: 'seek_30',
                      child: Text('Seek increment: 30s'),
                    ),
                    const PopupMenuItem(
                      value: 'seek_45',
                      child: Text('Seek increment: 45s'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'speed_10',
                      child: Text('Speed 1.0x'),
                    ),
                    const PopupMenuItem(
                      value: 'speed_125',
                      child: Text('Speed 1.25x'),
                    ),
                    const PopupMenuItem(
                      value: 'speed_150',
                      child: Text('Speed 1.5x'),
                    ),
                    const PopupMenuItem(
                      value: 'speed_200',
                      child: Text('Speed 2.0x'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'aspect_contain',
                      child: Text('Aspect: contain'),
                    ),
                    const PopupMenuItem(
                      value: 'aspect_cover',
                      child: Text('Aspect: cover'),
                    ),
                    const PopupMenuItem(
                      value: 'aspect_fill',
                      child: Text('Aspect: fill'),
                    ),
                    const PopupMenuItem(
                      value: 'aspect_fit_width',
                      child: Text('Aspect: fit width'),
                    ),
                    const PopupMenuItem(
                      value: 'aspect_fit_height',
                      child: Text('Aspect: fit height'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'handoff_create',
                      child: Text('Create session handoff'),
                    ),
                    const PopupMenuItem(
                      value: 'handoff_consume',
                      child: Text('Continue from handoff'),
                    ),
                    const PopupMenuItem(
                      value: 'external',
                      child: Text('Open in external player'),
                    ),
                    const PopupMenuItem(
                      value: 'stats',
                      child: Text('Playback stats'),
                    ),
                  ],
                ),
              ],
            ],
          ),
          body: Column(
            children: [
              if (opening || closing) const LinearProgressIndicator(),
              if (buffering) const LinearProgressIndicator(),
              if (statusMessage.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      statusMessage,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          error,
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => error = ''),
                        child: const Text('Dismiss'),
                      ),
                      FilledButton(
                        onPressed: () => unawaited(_attemptRecovery()),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: image && verified != null
                    ? InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 6,
                        child: Center(
                          child: Image.file(
                            File(verified!),
                            fit: BoxFit.contain,
                            cacheWidth: 1920,
                            errorBuilder: (_, e, stack) =>
                                const Text('This image could not be decoded.'),
                          ),
                        ),
                      )
                    : video != null && renderVideo
                    ? FittedBox(
                        fit: _aspectFit(),
                        child: SizedBox(
                          width: 1920,
                          height: 1080,
                          child: Video(
                            controller: video!,
                            controls: NoVideoControls,
                          ),
                        ),
                      )
                    : Center(
                        child: Icon(
                          image ? Icons.image_outlined : Icons.music_note,
                          size: 96,
                          color: Colors.white54,
                        ),
                      ),
              ),
              if (!image && player != null && !closing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
                    children: [
                      Slider(
                        value: value,
                        max: maximum,
                        onChanged: duration.inMilliseconds <= 0
                            ? null
                            : (v) => setState(() {
                                scrub = v;
                                scrubPreviewMs = v;
                              }),
                        onChangeEnd: duration.inMilliseconds <= 0
                            ? null
                            : (v) => unawaited(_seekToPreview(v)),
                      ),
                      if (scrubPreviewMs != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _seekThumbnailPreview(),
                        ),
                      Wrap(
                        spacing: 14,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.center,
                        children: [
                          IconButton(
                            onPressed: () => unawaited(
                              _seekByConfigured(-1, accelerated: true),
                            ),
                            icon: const Icon(Icons.replay_10),
                            tooltip: 'Rewind',
                          ),
                          FilledButton.icon(
                            onPressed: () =>
                                _perform((p) => playing ? p.pause() : p.play()),
                            icon: Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                            ),
                            label: Text(playing ? 'Pause' : 'Play'),
                          ),
                          IconButton(
                            onPressed: () => unawaited(_seekByConfigured(1)),
                            icon: const Icon(Icons.forward_10),
                            tooltip: 'Forward',
                          ),
                          IconButton(
                            onPressed: () => unawaited(
                              _seekByConfigured(1, accelerated: true),
                            ),
                            icon: const Icon(Icons.forward_30),
                            tooltip: 'Forward fast',
                          ),
                          IconButton(
                            onPressed: () =>
                                _seekBy(const Duration(seconds: 90).inSeconds),
                            icon: const Icon(Icons.skip_next_outlined),
                            tooltip: 'Skip intro',
                          ),
                          IconButton(
                            onPressed: () =>
                                _seekBy(const Duration(seconds: 30).inSeconds),
                            icon: const Icon(Icons.fast_forward_outlined),
                            tooltip: 'Skip recap',
                          ),
                          Text('${_time(position)} / ${_time(duration)}'),
                          IconButton(
                            onPressed: () => unawaited(_toggleMute()),
                            icon: Icon(
                              muted ? Icons.volume_off : Icons.volume_up,
                            ),
                            tooltip: muted ? 'Unmute' : 'Mute',
                          ),
                          SizedBox(
                            width: 150,
                            child: Slider(
                              value: volume.clamp(0, 100).toDouble(),
                              max: 100,
                              onChanged: (v) => unawaited(_setVolume(v)),
                            ),
                          ),
                          Text('Step ${seekIncrementSeconds}s'),
                          Text('Speed ${playbackSpeed.toStringAsFixed(2)}x'),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
