import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../library/library_models.dart';
import '../library/library_file_service.dart';
import '../services/device_connection.dart';

class LibraryMediaScreen extends StatefulWidget {
  final LibraryFolder folder;
  final LibraryItem item;
  final LibraryFileService? files;
  const LibraryMediaScreen({
    super.key,
    required this.folder,
    required this.item,
    this.files,
  });
  @override
  State<LibraryMediaScreen> createState() => _LibraryMediaScreenState();
}

class _LibraryMediaScreenState extends State<LibraryMediaScreen> {
  final subscriptions = <StreamSubscription<dynamic>>[];
  final session = 'local-library:${DateTime.now().microsecondsSinceEpoch}';
  Player? player;
  VideoController? video;
  String? verified;
  String error = '';
  bool opening = true,
      closing = false,
      allowPop = false,
      playing = false,
      active = false,
      renderVideo = true;
  Duration position = Duration.zero, duration = Duration.zero;
  double volume = 100;
  double? scrub;
  late Future<void> initialization;
  Future<void>? closeTask;
  bool get image => widget.item.kind == LibraryMediaKind.image;
  @override
  void initState() {
    super.initState();
    initialization = _initialize();
  }

  void _update(VoidCallback update) {
    if (mounted && !closing) {
      setState(update);
    }
  }

  Future<void> _initialize() async {
    try {
      final path = await (widget.files ?? LibraryFileService()).resolveMedia(
        widget.folder,
        widget.item,
      );
      if (!mounted || closing) {
        return;
      }
      verified = path;
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
        next.stream.position.listen((value) => _update(() => position = value)),
      );
      subscriptions.add(
        next.stream.duration.listen((value) => _update(() => duration = value)),
      );
      subscriptions.add(
        next.stream.volume.listen((value) => _update(() => volume = value)),
      );
      subscriptions.add(
        next.stream.error.listen(
          (value) => _update(
            () => error =
                'This file could not be played completely. It may be unfinished, protected or unsupported by the bundled decoder.',
          ),
        ),
      );
      await next
          .open(
            Media(Uri.file(path, windows: Platform.isWindows).toString()),
            play: true,
          )
          .timeout(const Duration(seconds: 25));
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

  Future<void> _close() => closeTask ??= _closeImpl();
  Future<void> _closeImpl() async {
    await initialization;
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
  }

  Future<void> _back() async {
    if (closing) {
      return;
    }
    setState(() {
      closing = true;
      renderVideo = false;
    });
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
          ),
          body: Column(
            children: [
              if (opening || closing) const LinearProgressIndicator(),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error,
                    style: const TextStyle(color: Colors.orangeAccent),
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
                    ? Video(controller: video!, controls: NoVideoControls)
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
                            : (v) => setState(() => scrub = v),
                        onChangeEnd: duration.inMilliseconds <= 0
                            ? null
                            : (v) {
                                setState(() => scrub = null);
                                unawaited(
                                  _perform(
                                    (p) => p.seek(
                                      Duration(milliseconds: v.round()),
                                    ),
                                  ),
                                );
                              },
                      ),
                      Wrap(
                        spacing: 14,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.center,
                        children: [
                          IconButton(
                            onPressed: () => _seekBy(-10),
                            icon: const Icon(Icons.replay_10),
                            tooltip: 'Back 10 seconds',
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
                            onPressed: () => _seekBy(10),
                            icon: const Icon(Icons.forward_10),
                            tooltip: 'Forward 10 seconds',
                          ),
                          Text('${_time(position)} / ${_time(duration)}'),
                          const Icon(Icons.volume_up),
                          SizedBox(
                            width: 150,
                            child: Slider(
                              value: volume.clamp(0, 100).toDouble(),
                              max: 100,
                              onChanged: (v) =>
                                  unawaited(_perform((p) => p.setVolume(v))),
                            ),
                          ),
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
