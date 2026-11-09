import 'dart:async';
import 'global_playlists.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'device_connection.dart';
import 'home_preferences.dart';
import 'live_tv_control.dart';
import 'podcast_service.dart';
import 'podcast_downloads.dart';
import 'watch_party/watch_party_service.dart';

class PodcastPlayback extends ChangeNotifier {
  PodcastPlayback();
  static final instance = PodcastPlayback();
  final store = PodcastStore();
  Player? player;
  VideoController? videoController;
  final subscriptions = <StreamSubscription<dynamic>>[];
  int? profileId;
  PodcastLibrary library = const PodcastLibrary();
  PodcastEpisode? active;
  Duration position = Duration.zero, duration = Duration.zero;
  bool playing = false, opening = false, buffering = false;
  String error = '';
  String? _mediaError;
  double volume = 100;
  Timer? sleepTimer;
  DateTime? sleepUntil;
  Timer? saveTimer;
  Future<void> _writes = Future<void>.value();
  Future<void> _lifecycle = Future<void>.value();
  int _session = 0;

  Future<void> _serializeLifecycle(Future<void> Function() action) {
    final pending = _lifecycle.then((_) => action());
    _lifecycle = pending.catchError((Object e) {
      error = 'Podcast session update failed: $e';
      debugPrint(error);
      notifyListeners();
    });
    return pending;
  }

  Future<void> initialize(int profile) => _serializeLifecycle(() async {
    if (profileId != null && profileId != profile) {
      await _stop();
    }
    profileId = profile;
    library = await store.load(profile);
    notifyListeners();
  });

  Future<void> _persist({bool sync = true}) async {
    final profile = profileId;
    if (profile == null) return;
    final snapshot = library;
    final pending = _writes.then((_) => store.save(profile, snapshot));
    _writes = pending.catchError((Object e) {
      error = 'Could not save podcast progress: $e';
      debugPrint(error);
      notifyListeners();
    });
    await pending;
    if (!sync || !DeviceConnection.instance.isConnected) return;
    final connection = DeviceConnection.instance.connectionKey;
    try {
      final prefs = HomePreferences();
      await LiveTvControlService().pushConfig(
        expectedConnection: connection,
        profileId: profile,
        sources: await prefs.liveTvSources(profile),
        tmdbApiKey: await prefs.tmdbApiKey(profile),
        profileState: await prefs.liveTvProfileSyncState(profile),
      );
    } catch (e) {
      error = 'Podcasts saved on this device; profile sync failed. $e';
      debugPrint(error);
      notifyListeners();
    }
  }

  Future<void> follow(PodcastShow show) async {
    final followed = library.following.any((e) => e.id == show.id);
    library = PodcastLibrary(
      following: followed
          ? library.following.where((e) => e.id != show.id).toList()
          : [...library.following, show],
      queue: library.queue,
      progress: library.progress,
      speed: library.speed,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> enqueue(PodcastEpisode episode) async {
    if (library.queue.any((e) => e.key == episode.key)) return;
    library = PodcastLibrary(
      following: library.following,
      queue: [...library.queue, episode],
      progress: library.progress,
      speed: library.speed,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> setFavorite(PodcastEpisode episode, bool value) async {
    final profile = profileId;
    if (profile == null) {
      throw StateError('Select a profile before saving podcast favorites.');
    }
    await GlobalPlaylistStore().setFavorite(
      profile,
      HubItem.podcast(episode),
      value,
    );
    await _persist();
  }

  Future<void> removeQueued(PodcastEpisode episode) async {
    library = PodcastLibrary(
      following: library.following,
      queue: library.queue.where((e) => e.key != episode.key).toList(),
      progress: library.progress,
      speed: library.speed,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> _saveProgress({bool completed = false, bool sync = true}) async {
    final episode = active;
    if (episode == null) return;
    final progress = Map<String, dynamic>.from(library.progress);
    final previous = progress[episode.key];
    progress[episode.key] = {
      'episode': episode.toJson(),
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'completed':
          completed ||
          (previous is Map &&
              previous['completed'] == true &&
              duration > Duration.zero &&
              position >= duration - const Duration(seconds: 2)),
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    };
    final ordered = progress.entries.toList()
      ..sort(
        (a, b) => (b.value as Map)['updatedAtUtc'].toString().compareTo(
          (a.value as Map)['updatedAtUtc'].toString(),
        ),
      );
    library = PodcastLibrary(
      following: library.following,
      queue: library.queue,
      progress: Map.fromEntries(ordered.take(100)),
      speed: library.speed,
    );
    await _persist(sync: sync);
  }

  Future<void> play(PodcastEpisode episode, {bool restart = false}) async {
    if (opening) return;
    final session = _session;
    opening = true;
    saveTimer?.cancel();
    error = '';
    _mediaError = null;
    notifyListeners();
    try {
      await _saveProgress();
      if (session != _session) return;
      if (player == null) {
        MediaKit.ensureInitialized();
        final created = Player();
        player = created;
        videoController = VideoController(created);
        subscriptions.addAll([
          created.stream.playing.listen((value) {
            playing = value;
            DeviceConnection.instance.setMediaActive('podcasts', value);
            notifyListeners();
          }),
          created.stream.position.listen((value) {
            position = value;
            notifyListeners();
          }),
          created.stream.duration.listen((value) {
            duration = value;
            notifyListeners();
          }),
          created.stream.buffering.listen((value) {
            buffering = value;
            notifyListeners();
          }),
          created.stream.error.listen((value) {
            _mediaError = value;
            error = 'Podcast playback failed: $value';
            playing = false;
            buffering = false;
            if (!opening) {
              unawaited(
                created.stop().catchError((Object e) {
                  error =
                      'Podcast playback failed: $value. Could not stop the player: $e';
                  notifyListeners();
                }),
              );
            }
            notifyListeners();
          }),
          created.stream.completed.listen((value) {
            if (value) unawaited(_complete());
          }),
        ]);
      }
      active = episode;
      position = Duration.zero;
      duration = episode.duration;
      final local = profileId == null
          ? null
          : await PodcastDownloads().localPath(profileId!, episode);
      if (session != _session) return;
      await player!
          .open(
            Media(
              local == null
                  ? episode.mediaUrl
                  : Uri.file(local, windows: Platform.isWindows).toString(),
            ),
            play: false,
          )
          .timeout(const Duration(seconds: 25));
      if (session != _session) return;
      if (_mediaError != null) throw HttpException(_mediaError!);
      await player!.setRate(library.speed);
      await player!.setVolume(volume);
      WatchPartyService.instance.registerLocalPlayback(
        player!,
        WatchPartyMedia(
          kind: 'podcast',
          title: episode.title,
          subtitle: episode.show.title,
          posterUrl: episode.artwork.isEmpty ? null : episode.artwork,
          durationMs: episode.duration.inMilliseconds,
          audioOnly: !episode.video,
          // Guests always stream from the publisher, even when the host
          // plays a downloaded copy.
          upstreamUrl: episode.mediaUrl,
        ),
      );
      final previous = library.progress[episode.key];
      if (!restart && previous is Map && previous['completed'] != true) {
        final saved = previous['positionMs'] as int? ?? 0;
        if (saved > 0) await player!.seek(Duration(milliseconds: saved));
      }
      await player!.play();
      if (_mediaError != null) throw HttpException(_mediaError!);
      await removeQueued(episode);
      saveTimer?.cancel();
      saveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(
          _saveProgress().catchError((Object e) {
            error = 'Could not save podcast progress: $e';
            notifyListeners();
          }),
        );
      });
    } catch (e) {
      await player?.stop();
      playing = false;
      buffering = false;
      error =
          'Could not play this episode. Check your connection and try again. $e';
      debugPrint(error);
    } finally {
      opening = false;
      notifyListeners();
    }
  }

  Future<void> _complete() async {
    try {
      saveTimer?.cancel();
      await _saveProgress(completed: true);
      if (library.queue.isNotEmpty) await play(library.queue.first);
    } catch (e) {
      error = 'Could not advance the podcast queue: $e';
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    if (player == null) return;
    if (playing) {
      await player!.pause();
      await _saveProgress();
    } else {
      await player!.play();
    }
  }

  Future<void> seek(Duration target) async {
    if (player == null) return;
    final milliseconds = target.inMilliseconds.clamp(
      0,
      duration.inMilliseconds > 0
          ? duration.inMilliseconds
          : target.inMilliseconds.clamp(0, 1 << 40),
    );
    await player!.seek(Duration(milliseconds: milliseconds));
  }

  Future<void> setSpeed(double speed) async {
    await player?.setRate(speed);
    library = PodcastLibrary(
      following: library.following,
      queue: library.queue,
      progress: library.progress,
      speed: speed,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> setVolume(double value) async {
    volume = value;
    await player?.setVolume(value);
    notifyListeners();
  }

  void setSleep(Duration? delay) {
    sleepTimer?.cancel();
    sleepUntil = delay == null ? null : DateTime.now().add(delay);
    if (delay != null) {
      sleepTimer = Timer(delay, () {
        sleepUntil = null;
        unawaited(
          stop().catchError((Object e) {
            error = 'Podcast sleep timer failed: $e';
            notifyListeners();
          }),
        );
      });
    }
    notifyListeners();
  }

  Future<void> stop() => _serializeLifecycle(_stop);

  Future<void> _stop() async {
    _session++;
    try {
      await _saveProgress();
    } finally {
      saveTimer?.cancel();
      sleepTimer?.cancel();
      sleepUntil = null;
      await player?.stop();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
      final departing = player;
      if (departing != null) {
        WatchPartyService.instance.unregisterLocalPlayback(departing);
      }
      await player?.dispose();
      player = null;
      videoController = null;
      active = null;
      playing = false;
      DeviceConnection.instance.setMediaActive('podcasts', false);
      notifyListeners();
    }
  }
}
