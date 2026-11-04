import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../services/device_connection.dart';
import '../services/home_preferences.dart';
import '../services/live_tv_control.dart';
import '../services/live_tv_source.dart';
import '../services/music_playback.dart';
import 'household_store.dart';

class ProfileGate extends StatefulWidget {
  final Widget Function(HouseholdProfile profile) builder;

  const ProfileGate({super.key, required this.builder});

  @override
  State<ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<ProfileGate> {
  final liveTvControl = LiveTvControlService();
  final address = TextEditingController(text: 'http://192.168.1.36:8185');
  final code = TextEditingController();

  late Future<void> initialization;
  HouseholdProfile? selected;
  List<HouseholdProfile> profiles = [];
  String? error;
  String? syncError;
  bool pairing = false;
  String? pairingError;

  DeviceConnection get connection => DeviceConnection.instance;

  @override
  void initState() {
    super.initState();
    initialization = load();
  }

  @override
  void dispose() {
    address.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      await HouseholdStore.instance.initialize();
      await connection.start();
      if (connection.isEnrolled && !connection.isSuspended) {
        await connection.checkNow();
      }
      await _pullHouseholdProfiles();
      final values = await HouseholdStore.instance.profiles();

      if (mounted) {
        setState(() {
          profiles = values;
          error = null;
        });
      }
      if (connection.isConnected) {
        await _pullProfileConfig(values);
        final refreshed = await HouseholdStore.instance.profiles();
        if (mounted) {
          setState(() => profiles = refreshed);
        }
      }
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }

  Future<void> _pullHouseholdProfiles() async {
    if (!connection.isConnected || connection.connectionKey.isEmpty) {
      return;
    }
    try {
      final payload = await liveTvControl.pullHouseholdProfiles(
        expectedConnection: connection.connectionKey,
      );
      final rawProfiles = payload['profiles'];
      if (rawProfiles is! List) {
        return;
      }

      for (final entry in rawProfiles) {
        if (entry is! Map) {
          continue;
        }
        final value = Map<String, dynamic>.from(entry);
        final idRaw = value['id'];
        final profileId = idRaw is int ? idRaw : int.tryParse('$idRaw');
        if (profileId == null || profileId < 1) {
          continue;
        }
        final deleted = value['deleted'] == true;
        if (deleted) {
          final existing = await HouseholdStore.instance.profileById(profileId);
          if (existing != null) {
            await HouseholdStore.instance.deleteProfile(profileId);
            await HomePreferences().clearProfileData(profileId);
          }
          continue;
        }
        final name = value['name']?.toString().trim() ?? '';
        if (name.isEmpty) {
          continue;
        }
        await HouseholdStore.instance.upsertProfile(profileId, name);
        final avatarBase64 = value['avatarBase64']?.toString().trim() ?? '';
        if (avatarBase64.isNotEmpty) {
          final bytes = base64Decode(avatarBase64);
          if (bytes.length <= 262144) {
            final avatarExtension =
                value['avatarExtension']?.toString().trim() ?? '.png';
            await HouseholdStore.instance.setAvatarBytes(
              profileId,
              bytes,
              extension: avatarExtension,
            );
          }
        }
      }
      if (mounted) {
        setState(() => syncError = null);
      }
    } catch (exception) {
      if (mounted) {
        setState(() => syncError = 'Household sync failed: $exception');
      }
    }
  }

  Future<void> _pullProfileConfig(List<HouseholdProfile> values) async {
    final connectionKey = connection.connectionKey;
    if (connectionKey.isEmpty || !connection.isConnected) {
      return;
    }
    for (final profile in values) {
      final remote = await liveTvControl.pullConfig(
        expectedConnection: connectionKey,
        profileId: profile.id,
      );
      final sourcesRaw = remote['sources'];
      if (sourcesRaw is List) {
        final parsed = <Map<String, dynamic>>[];
        for (final entry in sourcesRaw) {
          if (entry is Map) {
            parsed.add(Map<String, dynamic>.from(entry));
          }
        }
        if (parsed.isNotEmpty) {
          await HomePreferences().saveLiveTvSources(
            profile.id,
            parsed.map((entry) => LiveTvSource.fromJson(entry)).toList(),
          );
        }
      }
      final tmdbApiKey = remote['tmdbApiKey']?.toString().trim() ?? '';
      if (tmdbApiKey.isNotEmpty) {
        await HomePreferences().setTmdbApiKey(profile.id, tmdbApiKey);
      }
      final profileState = remote['profileState'];
      if (profileState is Map) {
        await HomePreferences().applyLiveTvProfileSyncState(
          profile.id,
          Map<String, dynamic>.from(profileState),
        );
      }
    }
  }

  Future<void> _syncRemoteProfile(int profileId) async {
    final connectionKey = connection.connectionKey;
    if (connectionKey.isEmpty || !connection.isConnected) {
      return;
    }
    final profileState = await HomePreferences().liveTvProfileSyncState(
      profileId,
    );
    await liveTvControl.pushConfig(
      expectedConnection: connectionKey,
      profileId: profileId,
      sources: await HomePreferences().liveTvSources(profileId),
      tmdbApiKey: await HomePreferences().tmdbApiKey(profileId),
      profileState: profileState,
    );
    final identityRaw = profileState['profileIdentity'];
    if (identityRaw is Map) {
      final identity = Map<String, dynamic>.from(identityRaw);
      await liveTvControl.upsertHouseholdProfile(
        expectedConnection: connectionKey,
        profileId: profileId,
        name: identity['name']?.toString().trim() ?? '',
        avatarBase64: identity['avatarBase64']?.toString(),
        avatarExtension: identity['avatarExtension']?.toString(),
      );
    }
  }

  Future<void> editName([HouseholdProfile? profile]) async {
    final controller = TextEditingController(text: profile?.name ?? '');

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(profile == null ? 'Add a profile' : 'Rename profile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                Navigator.pop(dialogContext, value);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();

    if (name == null || !mounted) return;

    try {
      if (profile == null) {
        final id = await HouseholdStore.instance.createProfile(name);
        await _syncRemoteProfile(id);
      } else {
        await HouseholdStore.instance.rename(profile.id, name);
        await _syncRemoteProfile(profile.id);
      }
      await load();
    } catch (exception) {
      showError(exception);
    }
  }

  Future<void> chooseAvatar(HouseholdProfile profile) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Profile picture',
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
          ),
        ],
      );

      if (file == null) return;

      await HouseholdStore.instance.setAvatar(profile.id, file.path);
      await _syncRemoteProfile(profile.id);
      await load();
    } catch (exception) {
      showError(exception);
    }
  }

  Future<void> removeProfile(HouseholdProfile profile) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${profile.name}?'),
        content: const Text(
          'This removes the profile, picture, and its local settings/history on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) {
      return;
    }
    try {
      if (connection.isConnected && connection.connectionKey.isNotEmpty) {
        await liveTvControl.removeHouseholdProfile(
          expectedConnection: connection.connectionKey,
          profileId: profile.id,
        );
      }
      await HouseholdStore.instance.deleteProfile(profile.id);
      await HomePreferences().clearProfileData(profile.id);
      await load();
    } catch (exception) {
      showError(exception);
    }
  }

  Future<void> pair() async {
    setState(() {
      pairing = true;
      pairingError = null;
    });
    try {
      await connection.enroll(address.text, code.text);
      code.clear();
      initialization = load();
      await initialization;
    } catch (exception) {
      if (mounted) {
        setState(() => pairingError = exception.toString());
      }
    } finally {
      if (mounted) {
        setState(() => pairing = false);
      }
    }
  }

  Future<void> disconnect() async {
    await MusicPlayback.instance.deactivateProfile();
    await connection.disconnect();
    if (mounted) {
      setState(() {
        selected = null;
        profiles = [];
      });
    }
  }

  void showError(Object exception) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(exception.toString())));
  }

  Widget avatar(HouseholdProfile profile) {
    final path = profile.avatarPath;

    return ClipOval(
      child: SizedBox(
        width: 110,
        height: 110,
        child: path == null
            ? const ColoredBox(
                color: Color(0xFF28445A),
                child: Icon(Icons.person, size: 70),
              )
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, error, stack) => const ColoredBox(
                  color: Color(0xFF28445A),
                  child: Icon(Icons.person, size: 70),
                ),
              ),
      ),
    );
  }

  Widget _pairingView() {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 700;

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 16 : 36),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: compact ? 560 : 760),
          child: ValueListenableBuilder<String>(
            valueListenable: connection.status,
            builder: (context, status, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pair this device first',
                    style: TextStyle(
                      fontSize: compact ? 30 : 44,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    status,
                    style: TextStyle(
                      fontSize: compact ? 18 : 23,
                      color: Color(0xFF63DFCB),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Generate a pairing code in the admin dashboard, then connect this device. Profiles will sync automatically before login.',
                    style: TextStyle(fontSize: compact ? 16 : 21, height: 1.5),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: address,
                    enabled: !pairing,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Dashboard server',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: code,
                    enabled: !pairing,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Pairing code',
                      hintText: 'ABCD-1234-EF56',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) {
                      if (!pairing) {
                        pair();
                      }
                    },
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      FilledButton.icon(
                        onPressed: pairing ? null : pair,
                        icon: const Icon(Icons.link),
                        label: Text(
                          pairing ? 'Pairing…' : 'Connect this device',
                        ),
                      ),
                      if (connection.isEnrolled)
                        OutlinedButton(
                          onPressed: pairing ? null : disconnect,
                          child: const Text('Disconnect and pair again'),
                        ),
                    ],
                  ),
                  if (pairingError != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      pairingError!,
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: compact ? 15 : 19,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 900;
    final tileWidth = compact ? ((width - 64) / 2).clamp(150.0, 210.0) : 210.0;
    final current = selected;

    if (current != null) {
      return SelectedProfileScope(
        profile: current,
        switchProfile: () {
          MusicPlayback.instance.deactivateProfile();
          setState(() => selected = null);
        },
        child: widget.builder(current),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B1425),
      body: FutureBuilder<void>(
        future: initialization,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (error != null) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(compact ? 16 : 36),
                child: SelectableText(
                  'Could not load household profiles.\n\n$error',
                ),
              ),
            );
          }

          if (!connection.isEnrolled || connection.isSuspended) {
            return _pairingView();
          }

          return Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(compact ? 16 : 40),
              child: Column(
                children: [
                  const Text(
                    'MILLITOP TV',
                    style: TextStyle(
                      fontSize: 20,
                      letterSpacing: 3,
                      color: Color(0xFF63DFCB),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ValueListenableBuilder<String>(
                    valueListenable: connection.status,
                    builder: (context, status, _) => Text(
                      status,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  if (syncError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      syncError!,
                      style: const TextStyle(color: Colors.orangeAccent),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 28),
                  Text(
                    "Who's watching?",
                    style: TextStyle(
                      fontSize: compact ? 34 : 46,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Choose your space',
                    style: TextStyle(
                      fontSize: compact ? 18 : 22,
                      color: Colors.white60,
                    ),
                  ),
                  SizedBox(height: compact ? 24 : 42),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: compact ? 12 : 28,
                    runSpacing: compact ? 12 : 28,
                    children: [
                      for (final profile in profiles)
                        SizedBox(
                          width: tileWidth,
                          child: Column(
                            children: [
                              OutlinedButton(
                                autofocus: profile == profiles.first,
                                style: OutlinedButton.styleFrom(
                                  padding: EdgeInsets.all(compact ? 14 : 22),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                ),
                                onPressed: () {
                                  MusicPlayback.instance.activateProfile(
                                    profile.id,
                                  );
                                  setState(() => selected = profile);
                                },
                                child: Column(
                                  children: [
                                    avatar(profile),
                                    const SizedBox(height: 18),
                                    Text(
                                      profile.name,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: compact ? 18 : 24,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextButton.icon(
                                onPressed: () => chooseAvatar(profile),
                                icon: const Icon(Icons.add_a_photo_outlined),
                                label: const Text('Change picture'),
                              ),
                              TextButton(
                                onPressed: () => editName(profile),
                                child: const Text('Rename'),
                              ),
                              TextButton(
                                onPressed: () => removeProfile(profile),
                                child: const Text('Remove'),
                              ),
                            ],
                          ),
                        ),
                      SizedBox(
                        width: tileWidth,
                        height: compact ? 170 : 220,
                        child: OutlinedButton(
                          autofocus: profiles.isEmpty,
                          onPressed: () => editName(),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.add_circle_outline,
                                size: compact ? 46 : 65,
                              ),
                              SizedBox(height: compact ? 12 : 20),
                              Text(
                                'Add profile',
                                style: TextStyle(fontSize: compact ? 18 : 23),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class SelectedProfileScope extends InheritedWidget {
  final HouseholdProfile profile;
  final VoidCallback switchProfile;
  const SelectedProfileScope({
    super.key,
    required this.profile,
    required this.switchProfile,
    required super.child,
  });
  static SelectedProfileScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SelectedProfileScope>();
  @override
  bool updateShouldNotify(SelectedProfileScope oldWidget) =>
      oldWidget.profile.id != profile.id ||
      oldWidget.profile.name != profile.name ||
      oldWidget.profile.avatarPath != profile.avatarPath ||
      oldWidget.switchProfile != switchProfile;
}
