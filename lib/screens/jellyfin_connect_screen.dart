import '../services/app_log.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/jellyfin_client.dart';
import '../services/profile_sync.dart';

/// Signs a Millitop profile into Jellyfin (Quick Connect or password) and
/// picks which libraries appear in Movies & Series. Pops `true` when the
/// saved connection changed.
class JellyfinConnectScreen extends StatefulWidget {
  final int profileId;
  final JellyfinAccountStore? store;
  final JellyfinTransport? transport;
  const JellyfinConnectScreen({
    super.key,
    required this.profileId,
    this.store,
    this.transport,
  });

  @override
  State<JellyfinConnectScreen> createState() => _JellyfinConnectScreenState();
}

class _JellyfinConnectScreenState extends State<JellyfinConnectScreen> {
  static const _accent = Color(0xFF63DFCB);
  static const _jellyfin = Color(0xFF7C3AED);

  late final JellyfinAccountStore store =
      widget.store ?? JellyfinAccountStore.instance();
  final serverController = TextEditingController();
  final userController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = true;
  bool busy = false;
  bool changed = false;
  String error = '';
  String? serverName;
  String? serverVersion;
  bool quickConnectAvailable = false;
  String? quickConnectCode;
  Timer? quickConnectPoll;
  JellyfinAccount? account;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    quickConnectPoll?.cancel();
    serverController.dispose();
    userController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await store.load(widget.profileId);
    if (!mounted) {
      return;
    }
    setState(() {
      account = saved;
      serverController.text = saved?.serverUrl ?? '';
      serverName = saved?.serverName;
      loading = false;
    });
  }

  Future<JellyfinApi> _api({String? token}) async => JellyfinApi(
    serverUrl: serverController.text,
    deviceId: await store.deviceId(),
    accessToken: token,
    transport: widget.transport,
  );

  String _message(Object e) => e is FormatException
      ? e.message
      : e.toString().replaceFirst('Bad state: ', '');

  Future<void> _checkServer() async {
    setState(() {
      busy = true;
      error = '';
      serverName = null;
      quickConnectCode = null;
    });
    quickConnectPoll?.cancel();
    try {
      final api = await _api();
      final info = await api.publicInfo();
      final quick = await api.quickConnectEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        serverController.text = api.serverUrl;
        serverName = info['ServerName']?.toString() ?? 'Jellyfin';
        serverVersion = info['Version']?.toString();
        quickConnectAvailable = quick;
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = _message(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _startQuickConnect() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final api = await _api();
      final started = await api.initiateQuickConnect();
      if (!mounted) {
        return;
      }
      setState(() => quickConnectCode = started.code);
      quickConnectPoll?.cancel();
      quickConnectPoll = Timer.periodic(const Duration(seconds: 5), (timer) {
        unawaited(_pollQuickConnect(api, started.secret, timer));
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = _message(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _pollQuickConnect(
    JellyfinApi api,
    String secret,
    Timer timer,
  ) async {
    try {
      final state = await api.quickConnectStatus(secret);
      if (!state.authenticated || !timer.isActive) {
        return;
      }
      timer.cancel();
      final auth = await api.authenticateWithQuickConnect(secret);
      await _finishSignIn(auth);
    } catch (e) {
      timer.cancel();
      if (mounted) {
        setState(() {
          quickConnectCode = null;
          error = 'Quick Connect expired. ${_message(e)}';
        });
      }
    }
  }

  Future<void> _signInWithPassword() async {
    final user = userController.text.trim();
    if (user.isEmpty) {
      setState(() => error = 'Enter your Jellyfin username.');
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final api = await _api();
      final auth = await api.authenticateByName(user, passwordController.text);
      passwordController.clear();
      await _finishSignIn(auth);
    } catch (e) {
      if (mounted) {
        setState(() => error = _message(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _finishSignIn(JellyfinAuthResult auth) async {
    final api = await _api(token: auth.accessToken);
    final libraries = (await api.libraries(
      auth.userId,
    )).where((library) => library.isVideo).toList();
    final next = JellyfinAccount(
      serverUrl: api.serverUrl,
      serverName: serverName ?? 'Jellyfin',
      userId: auth.userId,
      userName: auth.userName,
      accessToken: auth.accessToken,
      deviceId: api.deviceId,
      libraries: libraries,
      selectedLibraryIds: {for (final library in libraries) library.id},
    );
    await store.save(widget.profileId, next);
    AppLog.audit(
      'Jellyfin signed in',
      details: {
        'server': api.serverUrl,
        'user': auth.userName,
        'libraries': libraries.length,
      },
    );
    if (!mounted) {
      return;
    }
    setState(() {
      account = next;
      quickConnectCode = null;
      changed = true;
    });
  }

  Future<void> _refreshLibraries() async {
    final current = account;
    if (current == null) {
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final api = JellyfinApi.forAccount(current, transport: widget.transport);
      final libraries = (await api.libraries(
        current.userId,
      )).where((library) => library.isVideo).toList();
      final known = {for (final library in current.libraries) library.id};
      final selected = {
        ...current.selectedLibraryIds.where(
          (id) => libraries.any((library) => library.id == id),
        ),
        // Newly created libraries start switched on.
        for (final library in libraries)
          if (!known.contains(library.id)) library.id,
      };
      await _save(
        current.copyWith(libraries: libraries, selectedLibraryIds: selected),
      );
    } catch (e) {
      if (mounted) {
        setState(() => error = _message(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _save(JellyfinAccount next) async {
    await store.save(widget.profileId, next);
    ProfileSync.schedulePush(widget.profileId);
    if (mounted) {
      setState(() {
        account = next;
        changed = true;
      });
    }
  }

  Future<void> _signOut() async {
    await store.clear(widget.profileId);
    ProfileSync.schedulePush(widget.profileId);
    AppLog.audit(
      'Jellyfin signed out',
      details: {'profileId': widget.profileId},
    );
    if (mounted) {
      setState(() {
        account = null;
        changed = true;
        serverName = null;
      });
    }
  }

  Widget _panel({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: const Color(0xFF16243A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: Color(0xFF8FA3BF)),
                ),
              ],
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      ),
    );
  }

  Widget _serverPanel() {
    return _panel(
      title: 'Server',
      subtitle: 'Your Jellyfin address, for example http://192.168.1.20:8096',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('jellyfin-server-url'),
                  controller: serverController,
                  enabled: account == null && !busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Server address',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                  onSubmitted: (_) => _checkServer(),
                ),
              ),
              if (account == null) ...[
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: busy ? null : _checkServer,
                  child: const Text('Connect'),
                ),
              ],
            ],
          ),
          if (serverName != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.check_circle, color: _accent, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    serverVersion == null
                        ? serverName!
                        : '$serverName · Jellyfin $serverVersion',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _signInPanel() {
    return _panel(
      title: 'Sign in',
      subtitle:
          'Each Millitop profile signs in with its own Jellyfin user, so watch progress stays separate.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (quickConnectAvailable) ...[
            const Text(
              'Quick Connect',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            if (quickConnectCode == null)
              OutlinedButton.icon(
                onPressed: busy ? null : _startQuickConnect,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Get a Quick Connect code'),
              )
            else ...[
              const Text(
                'In Jellyfin on your phone or computer open Settings > Quick Connect and enter:',
                style: TextStyle(color: Color(0xFF8FA3BF)),
              ),
              const SizedBox(height: 10),
              SelectableText(
                quickConnectCode!,
                key: const ValueKey('jellyfin-quick-code'),
                style: const TextStyle(
                  fontSize: 40,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w800,
                  color: _accent,
                ),
              ),
              const SizedBox(height: 6),
              const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Waiting for approval...'),
                ],
              ),
            ],
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(),
            ),
          ],
          const Text(
            'Username and password',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('jellyfin-username'),
            controller: userController,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('jellyfin-password'),
            controller: passwordController,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              helperText: 'Used once to get a sign-in token. Never saved.',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _signInWithPassword(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : _signInWithPassword,
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
  }

  Widget _accountPanels(JellyfinAccount current) {
    return Column(
      children: [
        _panel(
          title: 'Signed in',
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: _jellyfin,
                child: Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      current.userName.isEmpty
                          ? 'Jellyfin user'
                          : current.userName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${current.serverName} · ${current.serverUrl}',
                      style: const TextStyle(color: Color(0xFF8FA3BF)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: busy ? null : _signOut,
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
        _panel(
          title: 'Libraries',
          subtitle: 'Checked libraries appear in Movies & Series.',
          child: Column(
            children: [
              if (current.libraries.isEmpty)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No movie or TV libraries were found.'),
                ),
              ...current.libraries.map(
                (library) => CheckboxListTile(
                  key: ValueKey('jellyfin-library-${library.id}'),
                  contentPadding: EdgeInsets.zero,
                  value: current.selectedLibraryIds.contains(library.id),
                  title: Text(library.name),
                  subtitle: Text(_collectionLabel(library.collectionType)),
                  onChanged: busy
                      ? null
                      : (value) {
                          final next = {...current.selectedLibraryIds};
                          if (value == true) {
                            next.add(library.id);
                          } else {
                            next.remove(library.id);
                          }
                          unawaited(
                            _save(current.copyWith(selectedLibraryIds: next)),
                          );
                        },
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: busy ? null : _refreshLibraries,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh library list'),
                ),
              ),
            ],
          ),
        ),
        _panel(
          title: 'Sync',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: current.syncProgress,
                title: const Text('Sync watch progress with Jellyfin'),
                subtitle: const Text(
                  'Resume points and watched state follow you to other Jellyfin apps.',
                ),
                onChanged: (value) =>
                    unawaited(_save(current.copyWith(syncProgress: value))),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: current.showContinueWatching,
                title: const Text('Show Jellyfin Continue Watching on Home'),
                onChanged: (value) => unawaited(
                  _save(current.copyWith(showContinueWatching: value)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _collectionLabel(String type) => switch (type) {
    'movies' => 'Movies',
    'tvshows' => 'TV shows',
    'homevideos' => 'Home videos',
    _ => 'Mixed content',
  };

  @override
  Widget build(BuildContext context) {
    final current = account;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pop(changed);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Connect Jellyfin'),
          bottom: busy
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(3),
                  child: LinearProgressIndicator(minHeight: 3),
                )
              : null,
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      if (error.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withAlpha(40),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(error),
                        ),
                      _serverPanel(),
                      if (current != null)
                        _accountPanels(current)
                      else if (serverName != null)
                        _signInPanel(),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
