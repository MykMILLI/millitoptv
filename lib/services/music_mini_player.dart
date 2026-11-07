import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'music_service.dart';

class MusicMiniPlayerService extends ChangeNotifier {
  MusicMiniPlayerService._();
  static final instance = MusicMiniPlayerService._();

  Player? _player;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  bool _visible = false;
  bool _playing = false;
  List<MusicTrack> _queue = const <MusicTrack>[];
  int _queueIndex = 0;
  List<MusicTrack> _librarySongs = const <MusicTrack>[];
  MusicServerConfig? _config;

  /// Track currently opened in [player].
  String? loadedTrackId;

  Player? get player => _player;
  bool get visible => _visible && _queue.isNotEmpty;
  bool get playing => _playing;
  List<MusicTrack> get queue => _queue;
  int get queueIndex => _queueIndex;
  List<MusicTrack> get librarySongs => _librarySongs;
  MusicTrack? get activeTrack =>
      _queue.isEmpty || _queueIndex < 0 || _queueIndex >= _queue.length
      ? null
      : _queue[_queueIndex];

  void syncFromMusicScreen({
    required Player player,
    required List<MusicTrack> queue,
    required int queueIndex,
    required List<MusicTrack> librarySongs,
    required bool playing,
    required Duration position,
    required Duration duration,
    required MusicServerConfig? config,
    String? loadedTrackId,
  }) {
    if (loadedTrackId != null) {
      this.loadedTrackId = loadedTrackId;
    }
    if (!identical(_player, player)) {
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      _subs.clear();
      _player = player;
      _subs.add(
        player.stream.playing.listen((value) {
          _playing = value;
          notifyListeners();
        }),
      );
      _subs.add(
        player.stream.completed.listen((done) {
          if (done) {
            unawaited(playNext());
          }
        }),
      );
    }
    _queue = List<MusicTrack>.from(queue);
    _queueIndex = queueIndex.clamp(0, queue.isEmpty ? 0 : queue.length - 1);
    _librarySongs = List<MusicTrack>.from(librarySongs);
    _playing = playing;
    _config = config;
    notifyListeners();
  }

  void showMini() {
    _visible = _queue.isNotEmpty;
    notifyListeners();
  }

  void hideMini() {
    _visible = false;
    notifyListeners();
  }

  Future<void> closeMini() async {
    final current = _player;
    if (current != null) {
      try {
        await current.pause();
        await current.seek(Duration.zero);
      } catch (_) {}
    }
    _visible = false;
    _playing = false;
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    final current = _player;
    if (current == null) {
      return;
    }
    if (_playing) {
      await current.pause();
    } else {
      final index = _queueIndex.clamp(0, _queue.length - 1);
      if (_queue.isNotEmpty && loadedTrackId != _queue[index].id) {
        await playAt(index);
      } else {
        await current.play();
      }
    }
  }

  Future<void> playAt(int index) async {
    if (_queue.isEmpty || index < 0 || index >= _queue.length) {
      return;
    }
    final current = _player;
    if (current == null) {
      return;
    }
    final track = _queue[index];
    var streamUrl = track.streamUrl?.trim() ?? '';
    if (streamUrl.isEmpty && _config != null) {
      streamUrl = NavidromeClient(_config!).streamUri(track.id).toString();
    }
    if (streamUrl.isEmpty) {
      return;
    }
    await current.open(Media(streamUrl));
    await current.play();
    loadedTrackId = track.id;
    _queueIndex = index;
    notifyListeners();
  }

  Future<void> playNext() async {
    if (_queue.isEmpty) {
      return;
    }
    final next = (_queueIndex + 1).clamp(0, _queue.length - 1);
    if (next == _queueIndex) {
      return;
    }
    await playAt(next);
  }

  Future<void> playPrevious() async {
    if (_queue.isEmpty) {
      return;
    }
    final prev = (_queueIndex - 1).clamp(0, _queue.length - 1);
    if (prev == _queueIndex) {
      return;
    }
    await playAt(prev);
  }

  void addToQueue(MusicTrack track) {
    _queue = [..._queue, track];
    notifyListeners();
  }

  List<MusicTrack> searchSongs(String text, {int limit = 24}) {
    final query = text.trim().toLowerCase();
    if (query.isEmpty) {
      return const <MusicTrack>[];
    }
    final matches = _librarySongs.where((track) {
      return track.title.toLowerCase().contains(query) ||
          track.artist.toLowerCase().contains(query) ||
          track.album.toLowerCase().contains(query);
    });
    return matches.take(limit).toList();
  }

  String? coverArtUrl(MusicTrack track) {
    final coverId = track.coverArtId?.trim() ?? '';
    final config = _config;
    if (coverId.isEmpty || config == null) {
      return null;
    }
    return NavidromeClient(config).coverArtUri(coverId).toString();
  }
}
