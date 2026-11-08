import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_log.dart';
import 'global_playlists.dart';
import 'music_mini_player.dart';

enum PlaylistPlaybackSessionState {
  idle,
  opening,
  playing,
  transitioning,
  failed,
  stopped,
}

enum PlaylistPlaybackExitKind {
  completed,
  explicitStop,
  explicitBack,
  failed,
  switched,
}

class PlaylistPlaybackExit {
  final PlaylistPlaybackExitKind kind;
  final String? targetEntryId;
  final Object? error;
  final StackTrace? stackTrace;

  const PlaylistPlaybackExit._(
    this.kind, {
    this.targetEntryId,
    this.error,
    this.stackTrace,
  });

  const PlaylistPlaybackExit.completed()
    : this._(PlaylistPlaybackExitKind.completed);
  const PlaylistPlaybackExit.explicitStop()
    : this._(PlaylistPlaybackExitKind.explicitStop);
  const PlaylistPlaybackExit.explicitBack()
    : this._(PlaylistPlaybackExitKind.explicitBack);
  const PlaylistPlaybackExit.failed(Object error, {StackTrace? stackTrace})
    : this._(
        PlaylistPlaybackExitKind.failed,
        error: error,
        stackTrace: stackTrace,
      );
  const PlaylistPlaybackExit.switched(String targetEntryId)
    : this._(PlaylistPlaybackExitKind.switched, targetEntryId: targetEntryId);
}

class PlaylistPlaybackEntry {
  final String entryId;
  final HubItem item;
  const PlaylistPlaybackEntry({required this.entryId, required this.item});
}

/// One step of playlist playback. Consecutive songs are grouped so they can
/// play as one Music queue; every other item is its own step.
class PlaylistSegment {
  final List<PlaylistPlaybackEntry> entries;
  const PlaylistSegment(this.entries);
  List<HubItem> get items => entries.map((entry) => entry.item).toList();
  bool get isMusic =>
      entries.isNotEmpty && entries.first.item.type == HubMediaType.song;
  PlaylistPlaybackEntry get first => entries.first;
  String get title => isMusic && entries.length > 1
      ? '${entries.first.item.title} + ${entries.length - 1} more songs'
      : entries.first.item.title;
}

class PlaylistPlaybackSession extends ChangeNotifier {
  final int profileId;
  final String playlistId;
  final String playlistName;
  final bool shuffled;
  final List<PlaylistPlaybackEntry> _entries;
  int _currentIndex;
  bool _autoplay;
  PlaylistPlaybackSessionState _state = PlaylistPlaybackSessionState.idle;
  String? _errorMessage;
  int _generation = 0;

  PlaylistPlaybackSession({
    required this.profileId,
    required this.playlistId,
    required this.playlistName,
    required List<PlaylistPlaybackEntry> entries,
    required int startIndex,
    required this.shuffled,
    bool autoplay = true,
  }) : _entries = List<PlaylistPlaybackEntry>.from(entries),
       _currentIndex = startIndex,
       _autoplay = autoplay;

  List<PlaylistPlaybackEntry> get entries =>
      List<PlaylistPlaybackEntry>.unmodifiable(_entries);
  int get currentIndex => _currentIndex;
  PlaylistPlaybackEntry? get current =>
      _entries.isEmpty || _currentIndex < 0 || _currentIndex >= _entries.length
      ? null
      : _entries[_currentIndex];
  bool get autoplay => _autoplay;
  PlaylistPlaybackSessionState get state => _state;
  String? get errorMessage => _errorMessage;
  int get generation => _generation;
  bool get hasPrevious => _currentIndex > 0 && _entries.isNotEmpty;
  bool get hasNext =>
      _entries.isNotEmpty &&
      _currentIndex >= 0 &&
      _currentIndex < _entries.length - 1;

  void setAutoplay(bool value) {
    if (_autoplay == value) {
      return;
    }
    _autoplay = value;
    notifyListeners();
  }

  void markOpening() {
    _state = PlaylistPlaybackSessionState.opening;
    _errorMessage = null;
    notifyListeners();
  }

  void markPlaying() {
    _state = PlaylistPlaybackSessionState.playing;
    _errorMessage = null;
    notifyListeners();
  }

  void markTransitioning() {
    _state = PlaylistPlaybackSessionState.transitioning;
    notifyListeners();
  }

  void markFailure(String message) {
    _state = PlaylistPlaybackSessionState.failed;
    _errorMessage = message;
    notifyListeners();
  }

  void stop() {
    _state = PlaylistPlaybackSessionState.stopped;
    notifyListeners();
  }

  bool playEntry(String entryId) {
    final index = _entries.indexWhere((entry) => entry.entryId == entryId);
    if (index < 0 || index == _currentIndex) {
      return false;
    }
    _currentIndex = index;
    _generation += 1;
    _state = PlaylistPlaybackSessionState.transitioning;
    notifyListeners();
    return true;
  }

  bool next() {
    if (!hasNext) {
      return false;
    }
    _currentIndex += 1;
    _generation += 1;
    _state = PlaylistPlaybackSessionState.transitioning;
    notifyListeners();
    return true;
  }

  bool previous() {
    if (!hasPrevious) {
      return false;
    }
    _currentIndex -= 1;
    _generation += 1;
    _state = PlaylistPlaybackSessionState.transitioning;
    notifyListeners();
    return true;
  }

  bool removePending(String entryId) {
    final index = _entries.indexWhere((entry) => entry.entryId == entryId);
    if (index < 0 || index <= _currentIndex) {
      return false;
    }
    _entries.removeAt(index);
    if (_currentIndex >= _entries.length) {
      _currentIndex = (_entries.length - 1).clamp(0, _entries.length).toInt();
    }
    notifyListeners();
    return true;
  }

  bool reorderPending(int oldIndex, int newIndex) {
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _entries.length ||
        newIndex >= _entries.length ||
        oldIndex <= _currentIndex ||
        newIndex <= _currentIndex) {
      return false;
    }
    final moved = _entries.removeAt(oldIndex);
    _entries.insert(newIndex, moved);
    notifyListeners();
    return true;
  }
}

class PlaylistPlaybackRegistry extends ChangeNotifier {
  PlaylistPlaybackRegistry._();
  static final instance = PlaylistPlaybackRegistry._();

  PlaylistPlaybackSession? _active;
  PlaylistPlaybackSession? get active => _active;

  void activate(PlaylistPlaybackSession session) {
    _active?.removeListener(notifyListeners);
    _active = session;
    _active?.addListener(notifyListeners);
    notifyListeners();
  }

  void clear(PlaylistPlaybackSession session) {
    if (!identical(_active, session)) {
      return;
    }
    _active?.removeListener(notifyListeners);
    _active = null;
    notifyListeners();
  }
}

/// Opens one playlist step and returns why playback left that provider.
typedef PlaylistSegmentOpener =
    Future<PlaylistPlaybackExit?> Function(
      BuildContext context,
      PlaylistPlaybackSession session,
      PlaylistSegment segment,
    );

/// Plays a mixed playlist in order or shuffled with one shared, observable
/// queue session that all providers can control.
class PlaylistPlayback {
  final int profileId;
  final PlaylistSegmentOpener open;
  final math.Random random;

  PlaylistPlayback({
    required this.profileId,
    required this.open,
    math.Random? random,
  }) : random = random ?? math.Random();

  /// Order used for playback; shuffled copies never change the saved list.
  List<HubItem> order(List<HubItem> items, {required bool shuffle}) {
    final values = List<HubItem>.from(items);
    if (shuffle) {
      values.shuffle(random);
    }
    return values;
  }

  static List<PlaylistSegment> segments(List<HubItem> items) {
    final entries = <PlaylistPlaybackEntry>[
      for (var index = 0; index < items.length; index++)
        PlaylistPlaybackEntry(
          entryId: 'entry-$index-${items[index].key.hashCode}',
          item: items[index],
        ),
    ];
    return segmentsFromEntries(entries, startIndex: 0);
  }

  static List<PlaylistSegment> segmentsFromEntries(
    List<PlaylistPlaybackEntry> entries, {
    required int startIndex,
  }) {
    if (entries.isEmpty || startIndex >= entries.length) {
      return const <PlaylistSegment>[];
    }
    final result = <PlaylistSegment>[];
    var songs = <PlaylistPlaybackEntry>[];
    for (var index = startIndex; index < entries.length; index++) {
      final entry = entries[index];
      if (entry.item.type == HubMediaType.song) {
        songs.add(entry);
        continue;
      }
      if (songs.isNotEmpty) {
        result.add(PlaylistSegment(List<PlaylistPlaybackEntry>.from(songs)));
        songs = <PlaylistPlaybackEntry>[];
      }
      result.add(PlaylistSegment(<PlaylistPlaybackEntry>[entry]));
    }
    if (songs.isNotEmpty) {
      result.add(PlaylistSegment(List<PlaylistPlaybackEntry>.from(songs)));
    }
    return result;
  }

  List<PlaylistPlaybackEntry> _buildEntries(List<HubItem> ordered) => [
    for (var index = 0; index < ordered.length; index++)
      PlaylistPlaybackEntry(
        entryId: 'entry-$index-${ordered[index].key.hashCode}',
        item: ordered[index],
      ),
  ];

  Future<void> play(
    BuildContext context, {
    required String playlistId,
    required String name,
    required List<HubItem> items,
    bool shuffle = false,
  }) async {
    if (items.isEmpty) {
      return;
    }
    final ordered = order(items, shuffle: shuffle);
    final entries = _buildEntries(ordered);
    final session = PlaylistPlaybackSession(
      profileId: profileId,
      playlistId: playlistId,
      playlistName: name,
      entries: entries,
      startIndex: 0,
      shuffled: shuffle,
      autoplay: true,
    );
    PlaylistPlaybackRegistry.instance.activate(session);
    AppLog.event(
      'playlist.play',
      props: {
        'playlistId': playlistId,
        'items': items.length,
        'shuffle': shuffle,
        'types': {for (final item in items) item.type.name}.toList(),
      },
    );
    try {
      while (context.mounted &&
          session.state != PlaylistPlaybackSessionState.stopped) {
        final current = session.current;
        if (current == null) {
          session.stop();
          break;
        }
        final plan = segmentsFromEntries(
          session.entries,
          startIndex: session.currentIndex,
        );
        if (plan.isEmpty) {
          session.stop();
          break;
        }
        final segment = plan.first;
        session.markOpening();
        if (!segment.isMusic &&
            session.currentIndex > 0 &&
            session.entries[session.currentIndex - 1].item.type ==
                HubMediaType.song) {
          await MusicMiniPlayerService.instance.closeMini();
        }
        PlaylistPlaybackExit? exit;
        try {
          // ignore: use_build_context_synchronously
          exit = await open(context, session, segment);
        } catch (error, stack) {
          AppLog.error(
            LogCategory.playback,
            'Playlist item could not open',
            error: error,
            stackTrace: stack,
            details: {
              'type': segment.first.item.type.name,
              'position': session.currentIndex + 1,
            },
          );
          exit = PlaylistPlaybackExit.failed(error, stackTrace: stack);
        }
        if (!context.mounted ||
            session.state == PlaylistPlaybackSessionState.stopped) {
          break;
        }
        if (exit == null) {
          session.stop();
          break;
        }
        switch (exit.kind) {
          case PlaylistPlaybackExitKind.switched:
            final target = exit.targetEntryId;
            if (target == null || !session.playEntry(target)) {
              session.stop();
            }
            break;
          case PlaylistPlaybackExitKind.completed:
            if (!session.autoplay) {
              session.markPlaying();
              break;
            }
            session.markTransitioning();
            if (segment.isMusic) {
              final nextIndex = session.currentIndex + segment.entries.length;
              if (nextIndex >= session.entries.length) {
                session.stop();
              } else {
                session.playEntry(session.entries[nextIndex].entryId);
              }
            } else if (!session.next()) {
              session.stop();
            }
            break;
          case PlaylistPlaybackExitKind.failed:
            session.markFailure('${exit.error ?? 'Playback failed.'}');
            if (!context.mounted) {
              session.stop();
              break;
            }
            final action = await _showFailureAction(
              context,
              segment.first.item,
            );
            if (action == _FailureAction.retry) {
              session.markTransitioning();
              break;
            }
            if (action == _FailureAction.skip && session.next()) {
              break;
            }
            session.stop();
            break;
          case PlaylistPlaybackExitKind.explicitStop:
          case PlaylistPlaybackExitKind.explicitBack:
            session.stop();
            break;
        }
      }
    } finally {
      PlaylistPlaybackRegistry.instance.clear(session);
    }
  }

  Future<_FailureAction> _showFailureAction(
    BuildContext context,
    HubItem item,
  ) async {
    if (!context.mounted) {
      return _FailureAction.stop;
    }
    final result = await showDialog<_FailureAction>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Playback failed'),
        content: Text('Could not open "${item.title}".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _FailureAction.stop),
            child: const Text('Stop'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _FailureAction.skip),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _FailureAction.retry),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
    return result ?? _FailureAction.stop;
  }
}

enum _FailureAction { retry, skip, stop }
