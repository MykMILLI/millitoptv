import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:uuid/uuid.dart';

import '../services/device_connection.dart';
import '../services/home_preferences.dart';
import '../services/live_tv_control.dart';
import '../services/music_service.dart';

class MusicScreen extends StatefulWidget {
  final int profileId;
  const MusicScreen({super.key, required this.profileId});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  final music = MusicService();
  final liveTvControl = LiveTvControlService();
  final query = TextEditingController();
  final stationName = TextEditingController();
  final setupServer = TextEditingController();
  final setupUser = TextEditingController();
  final setupPass = TextEditingController();
  Player? player;
  final subs = <StreamSubscription<dynamic>>[];

  MusicServerConfig? config;
  NavidromeClient? client;
  List<MusicTrack> picks = [];
  List<MusicTrack> recent = [];
  List<MusicTrack> searchResults = [];
  List<MusicStation> stations = [];
  List<MusicTrack> activeQueue = [];
  MusicTrack? activeTrack;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool loading = true;
  bool playing = false;
  String error = '';
  String status = '';

  @override
  void initState() {
    super.initState();
    query.addListener(_onSearchChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    query.removeListener(_onSearchChanged);
    query.dispose();
    stationName.dispose();
    setupServer.dispose();
    setupUser.dispose();
    setupPass.dispose();
    for (final sub in subs) {
      unawaited(sub.cancel());
    }
    final activePlayer = player;
    if (activePlayer != null) {
      unawaited(activePlayer.dispose());
    }
    super.dispose();
  }

  Future<Player> _ensurePlayer() async {
    final existing = player;
    if (existing != null) {
      return existing;
    }
    try {
      MediaKit.ensureInitialized();
      final created = Player();
      subs.add(
        created.stream.position.listen((value) {
          if (mounted) {
            setState(() => position = value);
          }
        }),
      );
      subs.add(
        created.stream.duration.listen((value) {
          if (mounted) {
            setState(() => duration = value);
          }
        }),
      );
      subs.add(
        created.stream.playing.listen((value) {
          if (mounted) {
            setState(() => playing = value);
          }
        }),
      );
      player = created;
      return created;
    } catch (_) {
      throw StateError(
        'Music playback could not start on this device. Please restart the app and try again.',
      );
    }
  }

  void _onSearchChanged() {
    if (query.text.trim().length < 2 || client == null) {
      if (searchResults.isNotEmpty && mounted) {
        setState(() => searchResults = []);
      }
      return;
    }
    unawaited(_search(query.text.trim()));
  }

  Future<void> _syncProfileState() async {
    final key = DeviceConnection.instance.connectionKey;
    if (key.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      await liveTvControl.pushConfig(
        expectedConnection: key,
        profileId: widget.profileId,
        sources: await HomePreferences().liveTvSources(widget.profileId),
        tmdbApiKey: await HomePreferences().tmdbApiKey(widget.profileId),
        profileState: await HomePreferences().liveTvProfileSyncState(
          widget.profileId,
        ),
      );
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      config = await music.config(widget.profileId);
      stations = await music.stations(widget.profileId);
      recent = await music.recentlyPlayed(widget.profileId);
      if (config != null) {
        client = NavidromeClient(config!);
        await client!.ping();
        picks = await client!.randomSongs(limit: 18);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        loading = false;
        error = '';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        loading = false;
        error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _saveSetup(
    String server,
    String username,
    String password,
  ) async {
    final next = MusicServerConfig(
      baseUrl: validateMusicServerUrl(server),
      username: username.trim(),
      password: password,
    );
    if (next.username.isEmpty || next.password.trim().isEmpty) {
      throw const FormatException('Username and password are required.');
    }
    final nav = NavidromeClient(next);
    await nav.ping();
    await music.saveConfig(widget.profileId, next);
    await _syncProfileState();
    if (!mounted) {
      return;
    }
    setState(() {
      config = next;
      client = nav;
      error = '';
      status = 'Connected to Navidrome.';
      loading = true;
    });
    await _load();
  }

  Future<void> _search(String text) async {
    final nav = client;
    if (nav == null) {
      return;
    }
    try {
      final results = await nav.searchSongs(text, limit: 24);
      if (!mounted || query.text.trim() != text) {
        return;
      }
      setState(() => searchResults = results);
    } catch (_) {}
  }

  Future<void> _playTrack(MusicTrack track, {List<MusicTrack>? queue}) async {
    final url = track.streamUrl;
    if (url == null || url.trim().isEmpty) {
      throw StateError('Track stream URL is missing.');
    }
    final nextQueue = queue ?? [track];
    final activePlayer = await _ensurePlayer();
    await activePlayer.open(Media(url));
    await activePlayer.play();
    await music.upsertRecentlyPlayed(widget.profileId, track);
    recent = await music.recentlyPlayed(widget.profileId);
    await _syncProfileState();
    if (!mounted) {
      return;
    }
    setState(() {
      activeTrack = track;
      activeQueue = nextQueue;
      status = 'Now playing ${track.title}';
    });
  }

  Future<void> _createStation(MusicTrack seed) async {
    final nav = client;
    if (nav == null) {
      return;
    }
    final custom = stationName.text.trim();
    final label = custom.isEmpty ? 'Song Radio · ${seed.title}' : custom;
    setState(() => status = 'Building station from ${seed.title}...');
    final queue = await nav.stationFromSeed(seed, limit: 30);
    final station = MusicStation(
      id: const Uuid().v4(),
      name: label,
      seedTrackId: seed.id,
      seedTitle: seed.title,
      createdAtUtc: DateTime.now().toUtc(),
      queue: queue,
    );
    await music.upsertStation(widget.profileId, station);
    await _syncProfileState();
    stations = await music.stations(widget.profileId);
    if (!mounted) {
      return;
    }
    setState(() {
      stationName.clear();
      status = 'Station created: ${station.name}';
    });
  }

  Future<void> _openStation(MusicStation station) async {
    if (station.queue.isEmpty) {
      return;
    }
    await _playTrack(station.queue.first, queue: station.queue);
  }

  Future<void> _removeStation(MusicStation station) async {
    await music.removeStation(widget.profileId, station.id);
    await _syncProfileState();
    stations = await music.stations(widget.profileId);
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _seekRelative(int seconds) async {
    final activePlayer = player;
    if (activePlayer == null) {
      return;
    }
    if (duration <= Duration.zero) {
      return;
    }
    final target = (position + Duration(seconds: seconds)).inMilliseconds.clamp(
      0,
      duration.inMilliseconds,
    );
    await activePlayer.seek(Duration(milliseconds: target));
  }

  Future<void> _togglePlayPause() async {
    final activePlayer = player;
    if (activePlayer == null) {
      return;
    }
    if (playing) {
      await activePlayer.pause();
    } else {
      await activePlayer.play();
    }
  }

  String _clock(Duration value) {
    final total = value.inSeconds.clamp(0, 359999);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _setupView() {
    if (setupServer.text.trim().isEmpty) {
      setupServer.text = config?.baseUrl ?? 'https://';
    }
    if (setupUser.text.trim().isEmpty) {
      setupUser.text = config?.username ?? '';
    }
    if (setupPass.text.trim().isEmpty) {
      setupPass.text = config?.password ?? '';
    }
    bool busy = false;
    String localError = '';
    return StatefulBuilder(
      builder: (context, setLocal) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Connect Navidrome',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Sign in once and MILLITOP will sync music setup + stations across household devices.',
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: setupServer,
                    autocorrect: false,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'Navidrome server origin',
                      hintText: 'https://music.yourdomain.com',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: setupUser,
                    autocorrect: false,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: setupPass,
                    enabled: !busy,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  if (localError.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      localError,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ],
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            setLocal(() {
                              busy = true;
                              localError = '';
                            });
                            try {
                              await _saveSetup(
                                setupServer.text,
                                setupUser.text,
                                setupPass.text,
                              );
                            } catch (e) {
                              setLocal(() {
                                localError = e.toString().replaceFirst(
                                  'FormatException: ',
                                  '',
                                );
                              });
                            } finally {
                              setLocal(() => busy = false);
                            }
                          },
                    icon: const Icon(Icons.link),
                    label: Text(busy ? 'Connecting...' : 'Connect music'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _trackCard(MusicTrack track, {VoidCallback? onSecondaryAction}) {
    return Card(
      child: InkWell(
        onTap: () => unawaited(_playTrack(track)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF3B2F7A), Color(0xFF131926)],
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.music_note,
                      size: 42,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70),
              ),
              if (onSecondaryAction != null)
                TextButton.icon(
                  onPressed: onSecondaryAction,
                  icon: const Icon(Icons.radio),
                  label: const Text('Start song radio'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _playerBar() {
    final track = activeTrack;
    if (track == null) {
      return const SizedBox.shrink();
    }
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.album),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${track.artist} • ${track.album}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                if (activeQueue.length > 1)
                  Text(
                    '${activeQueue.length} in station',
                    style: const TextStyle(color: Colors.white54),
                  ),
              ],
            ),
            Slider(
              value: duration.inMilliseconds <= 0
                  ? 0
                  : position.inMilliseconds
                        .clamp(0, duration.inMilliseconds)
                        .toDouble(),
              min: 0,
              max: duration.inMilliseconds <= 0
                  ? 1
                  : duration.inMilliseconds.toDouble(),
              onChanged: duration.inMilliseconds <= 0 || player == null
                  ? null
                  : (value) => unawaited(
                      player!.seek(Duration(milliseconds: value.toInt())),
                    ),
            ),
            Row(
              children: [
                Text(_clock(position), style: const TextStyle(fontSize: 12)),
                const Spacer(),
                Text(_clock(duration), style: const TextStyle(fontSize: 12)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => unawaited(_seekRelative(-30)),
                  icon: const Icon(Icons.replay_30),
                ),
                IconButton(
                  onPressed: () => unawaited(_seekRelative(-10)),
                  icon: const Icon(Icons.replay_10),
                ),
                FilledButton.tonal(
                  onPressed: () => unawaited(_togglePlayPause()),
                  child: Icon(playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  onPressed: () => unawaited(_seekRelative(10)),
                  icon: const Icon(Icons.forward_10),
                ),
                IconButton(
                  onPressed: () => unawaited(_seekRelative(30)),
                  icon: const Icon(Icons.forward_30),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 980;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Music'),
        actions: [
          if (config != null)
            IconButton(
              tooltip: 'Reconnect / change server',
              onPressed: () {
                setState(() {
                  config = null;
                  client = null;
                  error = '';
                });
              },
              icon: const Icon(Icons.settings_ethernet),
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  error,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            )
          : config == null
          ? _setupView()
          : Padding(
              padding: EdgeInsets.all(compact ? 12 : 18),
              child: Column(
                children: [
                  TextField(
                    controller: query,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search your music',
                    ),
                  ),
                  if (status.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        status,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your music. Rediscovered.',
                            style: TextStyle(
                              fontSize: compact ? 30 : 42,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Start with a favorite.',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const Text(
                                    'Build a station from any song in your Navidrome library.',
                                  ),
                                  const SizedBox(height: 10),
                                  TextField(
                                    controller: stationName,
                                    decoration: const InputDecoration(
                                      hintText:
                                          'Optional station name (for example: Late Night Rotation)',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (searchResults.isNotEmpty) ...[
                            const Text(
                              'Search results',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 240,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: searchResults.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 10),
                                itemBuilder: (context, index) => SizedBox(
                                  width: 240,
                                  child: _trackCard(
                                    searchResults[index],
                                    onSecondaryAction: () => unawaited(
                                      _createStation(searchResults[index]),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          const Text(
                            'Made from your library',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: picks.length,
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: compact ? 220 : 260,
                                  childAspectRatio: 0.78,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                            itemBuilder: (context, index) => _trackCard(
                              picks[index],
                              onSecondaryAction: () =>
                                  unawaited(_createStation(picks[index])),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Your stations',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (stations.isEmpty)
                            const Text(
                              'No stations yet. Start song radio to create one.',
                            )
                          else
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final station in stations.take(12))
                                  SizedBox(
                                    width: compact ? double.infinity : 320,
                                    child: Card(
                                      child: ListTile(
                                        title: Text(
                                          station.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          '${station.seedTitle} • ${station.queue.length} tracks',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        leading: const Icon(Icons.radio),
                                        trailing: IconButton(
                                          tooltip: 'Remove station',
                                          onPressed: () => unawaited(
                                            _removeStation(station),
                                          ),
                                          icon: const Icon(
                                            Icons.delete_outline,
                                          ),
                                        ),
                                        onTap: () =>
                                            unawaited(_openStation(station)),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          const SizedBox(height: 16),
                          const Text(
                            'Recently played',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (recent.isEmpty)
                            const Text('Nothing played yet on this profile.')
                          else
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final track in recent.take(10))
                                  SizedBox(
                                    width: compact ? double.infinity : 320,
                                    child: Card(
                                      child: ListTile(
                                        leading: const Icon(Icons.history),
                                        title: Text(
                                          track.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          '${track.artist} • ${track.album}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        onTap: () =>
                                            unawaited(_playTrack(track)),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                  _playerBar(),
                ],
              ),
            ),
    );
  }
}
