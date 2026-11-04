import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../services/device_connection.dart';
import '../services/home_preferences.dart';
import '../services/live_tv_control.dart';
import '../services/music_playback.dart';
import '../services/music_service.dart';
import '../widgets/music_player.dart';

class MusicScreen extends StatefulWidget {
  final int profileId;
  final MusicPlayback? playback;
  final MusicService? service;
  final NavidromeClient Function(MusicServerConfig)? clientFactory;
  const MusicScreen({
    super.key,
    required this.profileId,
    this.playback,
    this.service,
    this.clientFactory,
  });

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  late final MusicService _music = widget.service ?? MusicService();
  late final MusicPlayback _playback = widget.playback ?? MusicPlayback.instance;
  final _query = TextEditingController();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  MusicServerConfig? _config;
  NavidromeClient? _client;
  List<MusicTrack> _picks = [], _recent = [], _results = [];
  List<MusicStation> _stations = [];
  Timer? _debounce;
  int _searchGeneration = 0, _loadGeneration = 0, _actionGeneration = 0;
  int _recentGeneration = 0;
  late int _lastHistoryRevision;
  String? _error, _searchError;
  String _section = 'Home';
  bool _loading = true, _searching = false, _setup = false, _saving = false;
  bool _buildingRadio = false;
  List<MusicTrack>? _radioQueue;
  MusicTrack? _radioSeed;
  String? _radioDescription;

  @override
  void initState() {
    super.initState();
    _lastHistoryRevision = _playback.historyRevision;
    _query.addListener(_searchChanged);
    _playback.addListener(_trackChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchGeneration++;
    _actionGeneration++;
    _loadGeneration++;
    _debounce?.cancel();
    _playback.removeListener(_trackChanged);
    _query.dispose();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _trackChanged() {
    if (_radioQueue != null &&
        (_playback.profileId != widget.profileId ||
            !_sameQueue(_radioQueue!, _playback.queue))) {
      if (mounted) {
        setState(() {
          _radioQueue = null;
          _radioSeed = null;
          _radioDescription = null;
        });
      }
    }
    final revision = _playback.historyRevision;
    if (revision == _lastHistoryRevision) return;
    _lastHistoryRevision = revision;
    if (_playback.profileId == widget.profileId) {
      unawaited(_refreshRecent());
    }
  }

  Future<void> _refreshRecent() async {
    final generation = ++_recentGeneration;
    try {
      final recent = await _music.recentlyPlayed(widget.profileId);
      if (!mounted || generation != _recentGeneration) return;
      setState(() => _recent = recent);
      await _syncProfileState();
    } catch (_) {}
  }

  Future<void> _syncProfileState() async {
    final connection = DeviceConnection.instance;
    final key = connection.connectionKey;
    if (key.isEmpty || !connection.isConnected) return;
    try {
      final preferences = HomePreferences();
      await LiveTvControlService().pushConfig(
        expectedConnection: key,
        profileId: widget.profileId,
        sources: await preferences.liveTvSources(widget.profileId),
        tmdbApiKey: await preferences.tmdbApiKey(widget.profileId),
        profileState: await preferences.liveTvProfileSyncState(widget.profileId),
      );
    } catch (_) {}
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final recentGeneration = ++_recentGeneration;
    ++_searchGeneration;
    _debounce?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
      _searching = false;
      _searchError = null;
    });
    try {
      await _playback.activateProfile(widget.profileId);
      final config = await _music.config(widget.profileId);
      final stations = await _music.stations(widget.profileId);
      final recent = await _music.recentlyPlayed(widget.profileId);
      final client = config == null
          ? null
          : (widget.clientFactory?.call(config) ?? NavidromeClient(config));
      if (!mounted || generation != _loadGeneration) return;
      _config = config;
      _stations = stations;
      if (recentGeneration == _recentGeneration) _recent = recent;
      if (client != null) await client.ping();
      final picks = client == null ? <MusicTrack>[] : await client.randomSongs(limit: 18);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _config = config;
        _client = client;
        _stations = stations;
        if (recentGeneration == _recentGeneration) _recent = recent;
        _picks = picks;
        _loading = false;
        _setup = config == null;
      });
      if (_query.text.trim().isNotEmpty) _searchChanged();
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = 'Could not connect to your music library. Check your connection or server settings.';
      });
    }
  }

  void _searchChanged() {
    _debounce?.cancel();
    final generation = ++_searchGeneration;
    final text = _query.text.trim();
    setState(() {
      _results = [];
      _searchError = null;
      _searching = text.isNotEmpty && _client != null;
    });
    if (!_searching) return;
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_search(text, generation));
    });
  }

  Future<void> _search(String text, int generation) async {
    final client = _client;
    if (client == null) return;
    try {
      final tracks = await client.searchSongs(text, limit: 30);
      if (!mounted || generation != _searchGeneration || client != _client) return;
      setState(() {
        _results = tracks;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searching = false;
        _searchError = 'Search unavailable. Please try again.';
      });
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _play(List<MusicTrack> tracks, {int index = 0}) async {
    ++_actionGeneration;
    setState(() {
      _buildingRadio = false;
      _radioQueue = null;
      _radioSeed = null;
      _radioDescription = null;
    });
    try {
      await _playback.playQueue(widget.profileId, tracks, index: index);
    } catch (_) {
      _notice('Could not play this selection. Please retry or check setup.');
    }
  }

  bool _sameQueue(List<MusicTrack> a, List<MusicTrack> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i].id == b[i].id);

  Future<void> _startRadio() async {
    final client = _client;
    final seed = _playback.current ?? (_picks.isEmpty ? null : _picks.first);
    if (client == null || seed == null) return;
    final generation = ++_actionGeneration;
    setState(() {
      _buildingRadio = true;
      _radioQueue = null;
      _radioSeed = null;
      _radioDescription = null;
    });
    try {
      // Start immediately; recommendation latency must not delay the seed.
      final started = _playback.playQueue(widget.profileId, [seed]);
      final queueRevision = _playback.queueRevision;
      await started;
      if (!mounted ||
          generation != _actionGeneration ||
          _playback.profileId != widget.profileId ||
          queueRevision != _playback.queueRevision) return;
      if (_playback.error != null) {
        _notice('Could not start radio. Check your connection or server setup.');
        return;
      }
      final tracks = await client.stationFromSeed(seed, limit: 30);
      if (!mounted ||
          generation != _actionGeneration ||
          client != _client ||
          _playback.profileId != widget.profileId ||
          queueRevision != _playback.queueRevision) return;
      final upcoming = tracks.where((track) => track.id != seed.id).toList();
      final description = client.radioDescription;
      await _playback.replaceUpcoming(upcoming, expectedRevision: queueRevision);
      if (!mounted || generation != _actionGeneration) return;
      setState(() {
        _radioQueue = List.of(_playback.queue);
        _radioSeed = seed;
        _radioDescription = description;
      });
    } catch (_) {
      if (generation == _actionGeneration) {
        _notice('Radio could not be built. Your seed is still available to play.');
      }
    } finally {
      if (mounted && generation == _actionGeneration) {
        setState(() => _buildingRadio = false);
      }
    }
  }

  Future<void> _saveStation() async {
    final seed = _radioSeed;
    final queue = _radioQueue;
    if (seed == null || queue == null || !_sameQueue(queue, _playback.queue)) return;
    final generation = _actionGeneration;
    final name = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save station'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Name (optional)', hintText: '${seed.title} Radio'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, name.text), child: const Text('Save')),
        ],
      ),
    );
    // The route may still be animating with its TextField attached.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    if (!mounted || value == null || generation != _actionGeneration ||
        !_sameQueue(queue, _playback.queue)) return;
    try {
      await _music.upsertStation(widget.profileId, MusicStation(
        id: const Uuid().v4(),
        name: value.trim().isEmpty ? '${seed.title} Radio' : value.trim(),
        seedTrackId: seed.id,
        seedTitle: seed.title,
        createdAtUtc: DateTime.now().toUtc(),
        queue: List.of(queue),
      ));
      final stations = await _music.stations(widget.profileId);
      if (!mounted) return;
      setState(() => _stations = stations);
      _notice('Station saved.');
      await _syncProfileState();
    } catch (_) {
      _notice('Station could not be saved. Please try again.');
    }
  }

  void _openPlayer() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => StatefulBuilder(
        builder: (context, updateRoute) => ListenableBuilder(
          listenable: _playback,
          builder: (context, _) => Theme(
            data: _theme(),
            child: Scaffold(
              appBar: AppBar(title: const Text('Now playing')),
              body: SafeArea(
                child: MusicNowPlaying(
                  playback: _playback,
                  client: _client,
                  fullScreen: true,
                  buildingRadio: _buildingRadio,
                  radioDescription: _radioDescription,
                  onRadio: _client == null
                      ? null
                      : () async {
                          final pending = _startRadio();
                          updateRoute(() {});
                          await pending;
                          if (context.mounted) updateRoute(() {});
                        },
                  onSaveStation: _radioQueue == null
                      ? null
                      : () => unawaited(_saveStation()),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  ThemeData _theme() => ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(seedColor: musicAccent, brightness: Brightness.dark,
        surface: musicSurface),
    scaffoldBackgroundColor: const Color(0xFF19191F),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: musicSurface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    ),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF19191F)),
  );

  void _showSetup() {
    setState(() {
      _setup = true;
      _server.text = _config?.baseUrl ?? '';
      _username.text = _config?.username ?? '';
      _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme(),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('MILLITOP / MUSIC', maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, letterSpacing: 2)),
        actions: [
          IconButton(
            tooltip: 'Music server setup',
            onPressed: _setup && _client != null
                ? () => setState(() => _setup = false)
                : _showSetup,
            icon: const Icon(Icons.tune),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final desktop = constraints.maxWidth >= 1100;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (desktop) SizedBox(width: 174, child: _navigation(vertical: true)),
                    Expanded(
                      child: Column(
                        children: [
                          if (!desktop && !_setup) _navigation(),
                          Expanded(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                key: const ValueKey('music-library-content'),
                                constraints: const BoxConstraints(maxWidth: 1100),
                                child: _body(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (desktop && !_setup && _client != null)
                      Container(
                        width: 310,
                        decoration: const BoxDecoration(
                          color: Color(0xFF202027),
                          border: Border(left: BorderSide(color: Colors.white10)),
                        ),
                        child: MusicNowPlaying(
                          playback: _playback,
                          client: _client,
                          buildingRadio: _buildingRadio,
                          radioDescription: _radioDescription,
                          onRadio: () => unawaited(_startRadio()),
                          onSaveStation: _radioQueue == null ? null : () => unawaited(_saveStation()),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          MusicPlayerBar(playback: _playback, client: _client, onOpen: _openPlayer),
        ],
      ),
    ),
  );

  Widget _navigation({bool vertical = false}) {
    final items = [
      for (final entry in [
        ('Home', Icons.home_outlined),
        ('Library', Icons.library_music_outlined),
        ('Stations', Icons.sensors),
      ])
        Padding(
          padding: const EdgeInsets.all(4),
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: _section == entry.$1 ? musicAccent : Colors.white60,
              backgroundColor: _section == entry.$1 ? musicAccent.withValues(alpha: .1) : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            ),
            onPressed: () => setState(() => _section = entry.$1),
            icon: Icon(entry.$2, size: 18),
            label: Text(entry.$1),
          ),
        ),
    ];
    return vertical
        ? Padding(padding: const EdgeInsets.only(top: 24), child: Column(children: items))
        : SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: items));
  }

  Widget _body() {
    if (_setup) return _setupView();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined, size: 48, color: musicAccent),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Wrap(spacing: 12, children: [
            FilledButton(onPressed: () => unawaited(_load()), child: const Text('Retry')),
            OutlinedButton(onPressed: _showSetup, child: const Text('Server setup')),
          ]),
        ]),
      ));
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(_section == 'Home' ? 'Your music. Your moment.' : _section,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(_section == 'Library' ? 'Random picks from your Navidrome library. Search to find a favorite.'
            : _section == 'Stations' ? 'Saved queues, made from the songs you love.'
            : 'A little discovery, a lot of you.',
            style: const TextStyle(color: Colors.white54)),
        const SizedBox(height: 24),
        TextField(
          controller: _query,
          decoration: InputDecoration(
            hintText: 'Search your music',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.text.isEmpty ? null : IconButton(
              tooltip: 'Clear search', onPressed: _query.clear, icon: const Icon(Icons.close)),
          ),
        ),
        const SizedBox(height: 24),
        if (_query.text.trim().isNotEmpty)
          ..._searchContent()
        else if (_section == 'Stations')
          ..._stationContent()
        else ...[
          if (_section == 'Home') ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(colors: [Color(0xFF44335D), Color(0xFF292433)]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('SONG RADIO', style: TextStyle(color: musicAccent, letterSpacing: 2, fontSize: 11)),
                const SizedBox(height: 8),
                const Text('Follow the feeling.', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('Start with your current song, or the first library pick.',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: _buildingRadio || (_picks.isEmpty && _playback.current == null)
                        ? null : () => unawaited(_startRadio()),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_buildingRadio ? 'Building radio…' : 'Start radio'),
                  ),
                  if (_radioQueue != null)
                    OutlinedButton(onPressed: () => unawaited(_saveStation()), child: const Text('Save station')),
                ]),
                if (_radioDescription != null) ...[
                  const SizedBox(height: 16),
                  const Text('RADIO SOURCE', style: TextStyle(
                      letterSpacing: 2, color: musicAccent, fontSize: 11)),
                  const SizedBox(height: 6),
                  Text(_radioDescription!,
                      style: const TextStyle(color: Colors.white70)),
                ],
              ]),
            ),
            const SizedBox(height: 28),
            if (_recent.isNotEmpty) ...[
              _heading('Recently played'),
              _trackGrid(_recent),
              const SizedBox(height: 28),
            ],
          ],
          _heading('Random library picks', onRefresh: () => unawaited(_load())),
          if (_picks.isEmpty)
            const Text('No songs found. Add music to your Navidrome library.')
          else
            _trackGrid(_picks),
        ],
      ],
    );
  }

  List<Widget> _searchContent() => [
    _heading('Search results'),
    if (_searching)
      const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
    else if (_searchError != null)
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_searchError!),
        TextButton(onPressed: _searchChanged, child: const Text('Retry search')),
      ])
    else if (_results.isEmpty)
      const Text('No songs match your search.')
    else
      _trackGrid(_results),
  ];

  List<Widget> _stationContent() => [
    if (_stations.isEmpty)
      const Text('No stations yet. Start song radio, then save its queue here.'),
    for (final station in _stations)
      Card(
        child: ListTile(
          leading: const Icon(Icons.sensors, color: musicAccent),
          title: Text(station.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text('${station.queue.length} songs · ${station.seedTitle}', maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: station.queue.isEmpty ? null : () => unawaited(_play(station.queue)),
          trailing: IconButton(
            tooltip: 'Delete station',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              try {
                await _music.removeStation(widget.profileId, station.id);
                final stations = await _music.stations(widget.profileId);
                if (!mounted) return;
                setState(() => _stations = stations);
                await _syncProfileState();
              } catch (_) { _notice('Could not remove station. Please retry.'); }
            },
          ),
        ),
      ),
  ];

  Widget _heading(String label, {VoidCallback? onRefresh}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600))),
      if (onRefresh != null) IconButton(tooltip: 'Refresh random picks', onPressed: onRefresh, icon: const Icon(Icons.refresh)),
    ]),
  );

  Widget _trackGrid(List<MusicTrack> tracks) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 170).floor().clamp(1, 6).toInt();
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: tracks.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          mainAxisExtent: ((constraints.maxWidth - (columns - 1) * 14) / columns).clamp(0, 210).toDouble() + 77,
        ),
        itemBuilder: (context, i) {
          final track = tracks[i];
          return Material(
            color: musicSurface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => unawaited(_play(tracks, index: i)),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 210, maxHeight: 210),
                        child: AspectRatio(aspectRatio: 1, child: MusicCover(track: track, client: _client)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ),
            ),
          );
        },
      );
    },
  );

  Widget _setupView() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: AutofillGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.graphic_eq, size: 48, color: musicAccent),
            const SizedBox(height: 20),
            const Text('Connect Navidrome', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            const Text('Your library, stations and recent listening belong to this profile. Sign in on each device to keep your password private.',
                style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 24),
            TextField(
              controller: _server, enabled: !_saving, autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Server origin', hintText: 'https://music.example.com'),
            ),
            const SizedBox(height: 14),
            TextField(controller: _username, enabled: !_saving, autocorrect: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Username')),
            const SizedBox(height: 14),
            TextField(controller: _password, enabled: !_saving, obscureText: true,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) { if (!_saving) unawaited(_saveSetup()); },
                decoration: const InputDecoration(labelText: 'Password')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, style: const TextStyle(color: musicAccent))),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : () => unawaited(_saveSetup()),
              icon: const Icon(Icons.link),
              label: Text(_saving ? 'Connecting…' : 'Connect music'),
            ),
          ]),
        ),
      ),
    ),
  );

  Future<void> _saveSetup() async {
    setState(() { _saving = true; _error = null; });
    try {
      final config = MusicServerConfig(
        baseUrl: validateMusicServerUrl(_server.text),
        username: _username.text.trim(),
        password: _password.text,
      );
      if (config.username.isEmpty || config.password.trim().isEmpty) {
        throw const FormatException();
      }
      await NavidromeClient(config).ping();
      await _music.saveConfig(widget.profileId, config);
      if (!mounted) return;
      _password.clear();
      setState(() { _setup = false; _saving = false; });
      await _syncProfileState();
      if (mounted) await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not connect. Check the HTTP(S) server origin, username and password.';
      });
    }
  }
}
