import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pstube_engine/pstube_engine.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/watch_party/watch_party_service.dart';
import 'watch_party_panel.dart';

/// Plays the host's stream (through the tvadmin relay) and keeps it in sync.
class WatchPartyGuestScreen extends StatefulWidget {
  const WatchPartyGuestScreen({super.key});

  @override
  State<WatchPartyGuestScreen> createState() => _WatchPartyGuestScreenState();
}

class _WatchPartyGuestScreenState extends State<WatchPartyGuestScreen> {
  final WatchPartyService _party = WatchPartyService.instance;
  final Player _player = Player(
    configuration: const PlayerConfiguration(title: 'MILLITOP TV watch party'),
  );
  late final VideoController _video = VideoController(_player);
  Timer? _syncTimer;
  int? _openedRev;
  int _openGeneration = 0;
  String? _error;
  bool _opening = false;
  bool _showChat = true;
  double _volume = 100;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((_) {});
    _party.addListener(_onParty);
    _player.stream.error.listen((message) {
      if (mounted && message.isNotEmpty) setState(() => _error = message);
    });
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sync(),
    );
    _onParty();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _party.removeListener(_onParty);
    WakelockPlus.disable().catchError((_) {});
    unawaited(_player.dispose());
    super.dispose();
  }

  void _onParty() {
    if (!_party.active) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    final media = _party.media;
    if (media != null && media.rev != _openedRev) unawaited(_open(media));
    if (mounted) setState(() {});
  }

  Future<void> _open(WatchPartyRemoteMedia media) async {
    final generation = ++_openGeneration;
    _openedRev = media.rev;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      String? url;
      String? audioUrl;
      if (media.youtubeId != null) {
        // YouTube streams are tied to the viewer's address, so each guest
        // resolves the video itself instead of using the relay.
        final details = await PsTubeEngine().details(media.youtubeId!);
        final muxed = details.videoStreams.where((s) => !s.videoOnly).toList()
          ..sort((a, b) => b.height.compareTo(a.height));
        if (muxed.isNotEmpty) {
          url = webUrl(muxed.first.url);
        } else if (details.videoStreams.isNotEmpty &&
            details.audioStreams.isNotEmpty) {
          url = webUrl(details.videoStreams.first.url);
          audioUrl = webUrl(details.audioStreams.first.url);
        }
      } else {
        url = _party.relayUrl;
      }
      if (generation != _openGeneration) return;
      if (url == null) throw StateError('The host’s stream is not available.');
      await _player.open(Media(url), play: false);
      if (audioUrl != null) {
        await _player.setAudioTrack(AudioTrack.uri(audioUrl));
      }
      await _player.setVolume(_volume);
      _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);
      _sync(force: true);
    } catch (error) {
      if (generation == _openGeneration && mounted) {
        setState(() => _error = 'Could not play: $error');
      }
    } finally {
      if (generation == _openGeneration && mounted) {
        setState(() => _opening = false);
      }
    }
  }

  /// Follows the host: pause/play, and seek or nudge speed to close drift.
  void _sync({bool force = false}) {
    final playback = _party.playback;
    final media = _party.media;
    if (playback == null ||
        media == null ||
        playback.mediaRev != _openedRev ||
        _opening) {
      return;
    }
    final state = _player.state;
    final shouldPlay = playback.playing && !playback.buffering;
    if (shouldPlay && !state.playing) unawaited(_player.play());
    if (!shouldPlay && state.playing) unawaited(_player.pause());
    if (media.live) return;
    final target = playback.targetPositionMs(_party.serverNowMs);
    final drift = state.position.inMilliseconds - target;
    final now = DateTime.now();
    if ((force || drift.abs() > 2500) &&
        now.difference(_lastSeek) > const Duration(seconds: 3)) {
      _lastSeek = now;
      unawaited(_player.seek(Duration(milliseconds: target.clamp(0, 1 << 40))));
      unawaited(_player.setRate(playback.rate));
      return;
    }
    if (!shouldPlay) return;
    final desired = drift.abs() > 200
        ? playback.rate * (drift > 0 ? 0.95 : 1.05)
        : playback.rate;
    if ((state.rate - desired).abs() > 0.001) {
      unawaited(_player.setRate(desired));
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = _party.media;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: media?.audioOnly == true
                        ? _AudioOnly(media: media!)
                        : Video(controller: _video, controls: NoVideoControls),
                  ),
                  if (media == null)
                    Center(
                      child: Text(
                        'Waiting for ${_party.hostName} to play something…',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  if (_opening)
                    const Center(child: CircularProgressIndicator()),
                  if (_party.playback?.buffering == true && !_opening)
                    const Positioned(
                      left: 16,
                      bottom: 70,
                      child: Text(
                        'Host is buffering…',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  if (_error != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 70,
                      child: Material(
                        color: const Color(0xCC7F1D1D),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _controls(media, wide),
                  ),
                ],
              ),
            ),
            if (wide && _showChat)
              const SizedBox(
                width: 360,
                child: WatchPartyPanel(embedded: true),
              ),
          ],
        ),
      ),
    );
  }

  Widget _controls(WatchPartyRemoteMedia? media, bool wide) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back (stay in the party)',
            color: Colors.white,
            autofocus: true,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  media?.title ?? _party.partyTitle ?? 'Watch party',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  [
                    'Hosted by ${_party.hostName}',
                    if (media?.queueLabel != null) media!.queueLabel!,
                    if (!_party.hostOnline) 'host offline',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: _volume == 0 ? 'Unmute' : 'Mute',
            color: Colors.white,
            onPressed: () {
              setState(() => _volume = _volume == 0 ? 100 : 0);
              unawaited(_player.setVolume(_volume));
            },
            icon: Icon(_volume == 0 ? Icons.volume_off : Icons.volume_up),
          ),
          IconButton(
            tooltip: 'Resync with host',
            color: Colors.white,
            onPressed: () {
              _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);
              final current = _party.media;
              if (_error != null && current != null) {
                unawaited(_open(current));
              } else {
                _sync(force: true);
              }
            },
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'Chat and people',
            color: Colors.white,
            onPressed: () => wide
                ? setState(() => _showChat = !_showChat)
                : _party.setPanelOpen(true),
            icon: Badge(
              isLabelVisible: _party.unreadChat > 0,
              label: Text('${_party.unreadChat}'),
              child: const Icon(Icons.forum_outlined),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioOnly extends StatelessWidget {
  final WatchPartyRemoteMedia media;
  const _AudioOnly({required this.media});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0E1018),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (media.posterUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                media.posterUrl!,
                width: 240,
                height: 240,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.music_note,
                  size: 120,
                  color: Colors.white24,
                ),
              ),
            )
          else
            const Icon(Icons.graphic_eq, size: 120, color: Colors.white24),
          const SizedBox(height: 16),
          Text(
            media.title,
            style: const TextStyle(color: Colors.white, fontSize: 20),
          ),
          if (media.subtitle != null)
            Text(
              media.subtitle!,
              style: const TextStyle(color: Colors.white60),
            ),
        ],
      ),
    );
  }
}
