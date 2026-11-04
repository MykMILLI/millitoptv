import 'package:window_manager/window_manager.dart';
import '../services/viewing_sessions.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/gallery_library.dart';
import '../library/library_models.dart';
import '../library/library_file_service.dart';
import '../services/device_connection.dart';

class GallerySlideshow extends StatefulWidget {
  final List<GalleryEntry> entries;
  final GalleryPreferences preferences;
  final int initialIndex;
  const GallerySlideshow({
    super.key,
    required this.entries,
    required this.preferences,
    this.initialIndex = 0,
  });
  @override
  State<GallerySlideshow> createState() => _GallerySlideshowState();
}

class _GallerySlideshowState extends State<GallerySlideshow> {
  late List<GalleryEntry> order;
  late int index;
  GlobalKey<_GallerySlideState> slide = GlobalKey<_GallerySlideState>();
  Future<void> Function()? closeSlide;
  Timer? timer;
  bool paused = false,
      changing = false,
      allowPop = false,
      stopped = false,
      ready = false;
  int failures = 0, epoch = 0;
  String error = '';
  late int intervalSeconds;
  late bool sound, limitVideos;
  double volume = 100;
  bool? originalFullscreen;
  bool fullscreen = true;
  final session = 'gallery:${DateTime.now().microsecondsSinceEpoch}';
  @override
  void initState() {
    super.initState();
    intervalSeconds = widget.preferences.seconds;
    sound = widget.preferences.sound;
    limitVideos = widget.preferences.limitVideos;
    ViewingSessions.instance.register(session, _stopForSleep);
    unawaited(_captureWindow());
    order = galleryOrder(widget.entries, widget.preferences.shuffle);
    index = widget.initialIndex
        .clamp(0, order.isEmpty ? 0 : order.length - 1)
        .toInt();
    DeviceConnection.instance.setMediaActive(session, true);
  }

  void _arm() {
    timer?.cancel();
    if (!paused &&
        !stopped &&
        ready &&
        order.isNotEmpty &&
        (order[index].item.kind == LibraryMediaKind.image || limitVideos)) {
      timer = Timer(Duration(seconds: intervalSeconds), () {
        failures = 0;
        unawaited(_advance(1, automatic: true));
      });
    }
  }

  void _ready(int token) {
    if (!mounted || token != epoch) {
      return;
    }
    setState(() {
      ready = true;
      error = '';
    });
    _arm();
  }

  void _failed(int token) {
    if (!mounted || token != epoch || changing) {
      return;
    }
    timer?.cancel();
    failures++;
    setState(
      () => error =
          'This item is unavailable, unfinished, protected or unsupported.',
    );
    if (failures >= order.length) {
      setState(() => stopped = true);
      return;
    }
    if (!paused) {
      timer = Timer(
        const Duration(seconds: 1),
        () => unawaited(_advance(1, automatic: true)),
      );
    }
  }

  Future<void> _advance(int direction, {bool automatic = false}) async {
    if (changing || order.isEmpty) {
      return;
    }
    timer?.cancel();
    final next = index + direction;
    if (automatic &&
        !widget.preferences.repeat &&
        (next < 0 || next >= order.length)) {
      setState(() => stopped = true);
      return;
    }
    setState(() => changing = true);
    try {
      await closeSlide?.call();
    } catch (_) {
      if (mounted) {
        setState(() {
          error =
              'Player shutdown was not confirmed. Quit and reopen Millitop before updating.';
          stopped = true;
          changing = false;
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      index = (next % order.length + order.length) % order.length;
      epoch++;
      closeSlide = null;
      slide = GlobalKey<_GallerySlideState>();
      ready = false;
      stopped = false;
      changing = false;
    });
  }

  Future<void> _pause() async {
    if (changing) {
      return;
    }
    timer?.cancel();
    setState(() => paused = !paused);
    await slide.currentState?.pause(paused);
    if (!paused) {
      _arm();
    }
  }

  Future<void> _captureWindow() async {
    try {
      originalFullscreen = await windowManager.isFullScreen();
      if (mounted) {
        setState(() => fullscreen = originalFullscreen!);
      }
    } catch (_) {}
  }

  Future<void> _toggleFullscreen() async {
    try {
      final next = !await windowManager.isFullScreen();
      await windowManager.setFullScreen(next);
      await windowManager.setTitleBarStyle(
        next ? TitleBarStyle.hidden : TitleBarStyle.normal,
        windowButtonVisibility: !next,
      );
      if (mounted) {
        setState(() => fullscreen = next);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not change window mode.');
      }
    }
  }

  Future<void> _minimize() async {
    try {
      await windowManager.minimize();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not minimize the gallery.');
      }
    }
  }

  Future<void> _stopForSleep() async {
    if (changing) {
      throw StateError('Gallery is changing media. Try the timer again.');
    }
    timer?.cancel();
    if (mounted) {
      setState(() {
        paused = true;
        changing = true;
      });
    }
    try {
      await closeSlide?.call();
      DeviceConnection.instance.setMediaActive(session, false);
      if (mounted) {
        setState(() => stopped = true);
      }
    } finally {
      if (mounted) {
        setState(() => changing = false);
      }
    }
  }

  Future<void> _back() async {
    if (changing) {
      return;
    }
    timer?.cancel();
    setState(() => changing = true);
    var safe = true;
    try {
      await closeSlide?.call();
    } catch (_) {
      safe = false;
    }
    if (safe) {
      DeviceConnection.instance.setMediaActive(session, false);
      ViewingSessions.instance.remove(session);
    }
    try {
      if (originalFullscreen != null) {
        await windowManager.setFullScreen(originalFullscreen!);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
      }
    } catch (_) {}
    if (!mounted) {
      return;
    }
    setState(() => allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      if (!safe) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Quit and reopen Millitop before updating; player shutdown was not confirmed.',
            ),
          ),
        );
      }
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    unawaited(
      (closeSlide?.call() ?? Future<void>.value())
          .then((_) {
            DeviceConnection.instance.setMediaActive(session, false);
            ViewingSessions.instance.remove(session);
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final token = epoch;
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
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              unawaited(_advance(1)),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              unawaited(_advance(-1)),
          const SingleActivator(LogicalKeyboardKey.space): () =>
              unawaited(_pause()),
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            leading: IconButton(
              onPressed: changing ? null : _back,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to gallery',
            ),
            title: Text(
              order.isEmpty
                  ? 'Gallery'
                  : '${index + 1} / ${order.length} · ${order[index].item.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                onPressed: changing ? null : _toggleFullscreen,
                icon: Icon(
                  fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
                tooltip: fullscreen ? 'Windowed view' : 'Fullscreen',
              ),
              IconButton(
                onPressed: changing ? null : _minimize,
                icon: const Icon(Icons.minimize),
                tooltip: 'Minimize gallery; restore from the taskbar',
              ),
              IconButton(
                onPressed: changing ? null : () => _advance(-1),
                icon: const Icon(Icons.skip_previous),
                tooltip: 'Previous',
              ),
              IconButton(
                onPressed: changing ? null : _pause,
                icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                tooltip: paused ? 'Resume' : 'Pause',
              ),
              IconButton(
                onPressed: changing ? null : () => _advance(1),
                icon: const Icon(Icons.skip_next),
                tooltip: 'Next',
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Advance after'),
                    DropdownButton<int>(
                      value: intervalSeconds,
                      items:
                          ({
                                ...[3, 5, 10, 15, 30, 60, 120, 300],
                                intervalSeconds,
                              }.toList()..sort())
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s,
                                  child: Text('$s seconds'),
                                ),
                              )
                              .toList(),
                      onChanged: changing
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => intervalSeconds = v);
                                _arm();
                              }
                            },
                    ),
                    FilterChip(
                      label: const Text('Limit videos to interval'),
                      selected: limitVideos,
                      onSelected: changing
                          ? null
                          : (v) {
                              setState(() => limitVideos = v);
                              _arm();
                            },
                    ),
                    IconButton(
                      tooltip: sound
                          ? 'Mute video sound'
                          : 'Enable video sound',
                      icon: Icon(sound ? Icons.volume_up : Icons.volume_off),
                      onPressed: changing
                          ? null
                          : () {
                              setState(() => sound = !sound);
                            },
                    ),
                    SizedBox(
                      width: 150,
                      child: Slider(
                        value: volume,
                        max: 100,
                        onChanged: changing
                            ? null
                            : (v) {
                                setState(() => volume = v);
                              },
                      ),
                    ),
                  ],
                ),
              ),
              if (changing) const LinearProgressIndicator(),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              if (stopped)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Slideshow stopped. Use Next/Previous or return to Gallery.',
                  ),
                ),
              Expanded(
                child: order.isEmpty
                    ? const Center(child: Text('No media selected.'))
                    : KeyedSubtree(
                        key: ValueKey(epoch),
                        child: _GallerySlide(
                          key: slide,
                          entry: order[index],
                          paused: paused,
                          sound: sound,
                          volume: volume,
                          onHandle: (handle) {
                            closeSlide = handle;
                          },
                          onReady: () => _ready(token),
                          onError: () => _failed(token),
                          onCompleted: () {
                            if (!paused) {
                              failures = 0;
                              unawaited(_advance(1, automatic: true));
                            }
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GallerySlide extends StatefulWidget {
  final GalleryEntry entry;
  final bool paused, sound;
  final double volume;
  final VoidCallback onReady, onError, onCompleted;
  final void Function(Future<void> Function()) onHandle;
  const _GallerySlide({
    super.key,
    required this.entry,
    required this.paused,
    required this.sound,
    required this.volume,
    required this.onReady,
    required this.onError,
    required this.onCompleted,
    required this.onHandle,
  });
  @override
  State<_GallerySlide> createState() => _GallerySlideState();
}

class _GallerySlideState extends State<_GallerySlide> {
  Player? player;
  VideoController? video;
  String? path;
  bool render = true,
      readyReported = false,
      errorReported = false,
      closing = false,
      disposing = false;
  final subscriptions = <StreamSubscription<dynamic>>[];
  late Future<void> initialization;
  Future<void>? closingFuture;
  @override
  void initState() {
    super.initState();
    initialization = _initialize();
    widget.onHandle(close);
  }

  void _report(bool success) {
    if (!mounted ||
        closing ||
        (success ? (readyReported || errorReported) : errorReported)) {
      return;
    }
    if (success) {
      readyReported = true;
    } else {
      errorReported = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !closing) {
        setState(() {});
        if (success) {
          widget.onReady();
        } else {
          widget.onError();
        }
      }
    });
  }

  Future<void> _initialize() async {
    try {
      path = await LibraryFileService().resolveMedia(
        widget.entry.folder,
        widget.entry.item,
      );
      if (!mounted || closing) {
        return;
      }
      if (widget.entry.item.kind == LibraryMediaKind.image) {
        setState(() {});
        return;
      }
      MediaKit.ensureInitialized();
      final next = Player();
      player = next;
      video = VideoController(next);
      subscriptions.add(next.stream.error.listen((_) => _report(false)));
      subscriptions.add(
        next.stream.completed.listen((done) {
          if (done && mounted && !closing) {
            widget.onCompleted();
          }
        }),
      );
      await next.setVolume(widget.sound ? widget.volume : 0);
      await next
          .open(
            Media(Uri.file(path!, windows: Platform.isWindows).toString()),
            play: !widget.paused,
          )
          .timeout(const Duration(seconds: 25));
      if (mounted && !closing) {
        setState(() {});
        _report(true);
      }
    } catch (_) {
      _report(false);
    }
  }

  @override
  void didUpdateWidget(covariant _GallerySlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sound != widget.sound || oldWidget.volume != widget.volume) {
      unawaited(_setVolume());
    }
  }

  Future<void> _setVolume() async {
    try {
      await player?.setVolume(widget.sound ? widget.volume : 0);
    } catch (_) {
      _report(false);
    }
  }

  Future<void> pause(bool value) async {
    try {
      final p = player;
      if (p != null) {
        if (value) {
          await p.pause();
        } else {
          await p.play();
        }
      }
    } catch (_) {
      _report(false);
    }
  }

  Future<void> close() => closingFuture ??= _close();
  Future<void> _close() async {
    closing = true;
    if (mounted && !disposing) {
      setState(() => render = false);
      await WidgetsBinding.instance.endOfFrame;
    }
    await initialization;
    for (final s in subscriptions) {
      try {
        await s.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    final p = player;
    player = null;
    if (p != null) {
      await p.dispose().timeout(const Duration(seconds: 15));
    }
  }

  @override
  void dispose() {
    disposing = true;
    closing = true;
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!render) {
      return const SizedBox.shrink();
    }
    if (errorReported) {
      return const Center(child: Text('Media unavailable. Use Next or Back.'));
    }
    if (path == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.entry.item.kind == LibraryMediaKind.image) {
      return Center(
        child: Image.file(
          File(path!),
          cacheWidth: 1920,
          fit: BoxFit.contain,
          frameBuilder: (ctx, child, frame, sync) {
            if (sync || frame != null) {
              _report(true);
            }
            return child;
          },
          errorBuilder: (ctx, error, stack) {
            _report(false);
            return const Text('Image unavailable.');
          },
        ),
      );
    }
    return video == null
        ? const Center(child: CircularProgressIndicator())
        : Video(controller: video!, controls: NoVideoControls);
  }
}
