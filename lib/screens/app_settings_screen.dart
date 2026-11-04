import '../services/home_preferences.dart';
import 'sleep_mode_panel.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/firefox_browser.dart';
import '../services/web_app_catalog.dart';
import '../services/web_app_definition.dart';
import '../services/native_app_launcher.dart';
import '../services/device_connection.dart';
import '../services/live_tv_control.dart';
import '../services/live_tv_source.dart';
import '../services/playback_performance.dart';
import 'gallery_panel.dart';
import 'live_tv_screen.dart';
import 'music_screen.dart';

Future<void> editWebApp(
  BuildContext context,
  int profile,
  WebAppDefinition? app, {
  WebAppCatalog? catalog,
}) async {
  final service = catalog ?? WebAppCatalog.instance;
  if (app?.managed == true) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(app!.title),
        content: Text(
          'Managed by your administrator. Edit its name, URL or device assignment in the dashboard.\n\n${app.url}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    return;
  }
  final name = TextEditingController(text: app?.title ?? ''),
      url = TextEditingController(text: app?.url ?? 'https://');
  final form = GlobalKey<FormState>();
  var icon = app?.icon ?? 'web', enabled = app?.enabled ?? true, busy = false;
  String error = '';
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(app == null ? 'Add website app' : 'Edit ${app.title}'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      maxLength: 80,
                      enabled: !busy,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'App name'),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Enter a name' : null,
                    ),
                    TextFormField(
                      controller: url,
                      maxLength: 2048,
                      enabled: !busy,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Website URL',
                      ),
                      validator: (v) {
                        try {
                          validateAppUrl(v ?? '');
                          return null;
                        } catch (e) {
                          return e.toString().replaceFirst(
                            'FormatException: ',
                            '',
                          );
                        }
                      },
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: icon,
                      decoration: const InputDecoration(labelText: 'Icon'),
                      items: const [
                        DropdownMenuItem(value: 'web', child: Text('Website')),
                        DropdownMenuItem(value: 'emby', child: Text('Emby')),
                        DropdownMenuItem(
                          value: 'jellyfin',
                          child: Text('Jellyfin'),
                        ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => setLocal(() => icon = v ?? 'web'),
                    ),
                    CheckboxListTile(
                      value: enabled,
                      onChanged: busy
                          ? null
                          : (v) => setLocal(() => enabled = v ?? true),
                      title: const Text('Show on Home'),
                    ),
                    const Text(
                      'Web apps use this household profile’s Firefox data and extensions. Do not put passwords in the URL; sign in within Firefox.',
                    ),
                    if (error.isNotEmpty)
                      Text(
                        error,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) {
                        return;
                      }
                      setLocal(() => busy = true);
                      try {
                        await service.save(
                          profile,
                          id: app?.id,
                          title: name.text,
                          url: url.text,
                          icon: icon,
                          enabled: enabled,
                        );
                        if (ctx.mounted &&
                            ModalRoute.of(ctx)?.isCurrent == true) {
                          Navigator.pop(ctx);
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          setLocal(() {
                            busy = false;
                            error = e.toString().replaceFirst(
                              'Bad state: ',
                              '',
                            );
                          });
                        }
                      }
                    },
              child: Text(busy ? 'Saving...' : 'Save app'),
            ),
          ],
        ),
      ),
    );
  } finally {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    url.dispose();
  }
}

class AppSettingsScreen extends StatefulWidget {
  final int profileId;
  const AppSettingsScreen({super.key, required this.profileId});
  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  final catalog = WebAppCatalog.instance;
  final liveTvControl = LiveTvControlService();
  List<WebAppDefinition> apps = [];
  String error = '', exe = 'Not checked';
  bool busy = false;
  bool familyMoments = true;
  String tmdbApiKey = '';
  PlaybackPerformanceSettings playbackPerformance =
      const PlaybackPerformanceSettings();
  @override
  void initState() {
    super.initState();
    catalog.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    unawaited(_load());
  }

  Future<void> _pullRemoteLiveTvConfig() async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      final remote = await liveTvControl.pullConfig(
        expectedConnection: connection,
        profileId: widget.profileId,
      );
      final sourcesRaw = remote['sources'];
      if (sourcesRaw is List) {
        final parsed = <LiveTvSource>[];
        for (final entry in sourcesRaw) {
          if (entry is! Map) {
            continue;
          }
          try {
            parsed.add(LiveTvSource.fromJson(Map<String, dynamic>.from(entry)));
          } catch (_) {}
        }
        if (parsed.isNotEmpty) {
          await HomePreferences().saveLiveTvSources(widget.profileId, parsed);
        }
      }
      final tmdbApiKey = remote['tmdbApiKey']?.toString().trim() ?? '';
      if (tmdbApiKey.isNotEmpty) {
        await HomePreferences().setTmdbApiKey(widget.profileId, tmdbApiKey);
      }
      final profileState = remote['profileState'];
      if (profileState is Map) {
        await HomePreferences().applyLiveTvProfileSyncState(
          widget.profileId,
          Map<String, dynamic>.from(profileState),
        );
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      await _pullRemoteLiveTvConfig();
      final values = await catalog.load(widget.profileId, includeHidden: true);
      final visible = await HomePreferences().familyMoments(widget.profileId);
      final key = await HomePreferences().tmdbApiKey(widget.profileId);
      final performance = await HomePreferences().playbackPerformance(
        widget.profileId,
      );
      if (mounted) {
        setState(() {
          apps = values;
          familyMoments = visible;
          tmdbApiKey = key;
          playbackPerformance = performance;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not read app settings. Existing settings were not erased.',
        );
      }
    }
  }

  Future<void> _editTmdbApiKey() async {
    final input = TextEditingController(text: tmdbApiKey);
    String localError = '';
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('TMDB API key'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Used to enrich Movies/Series metadata for M3U sources (posters, backdrops, and descriptions).',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: input,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'TMDB API key',
                      hintText: 'Paste your TMDB v3 API key',
                    ),
                  ),
                  if (localError.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      localError,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await HomePreferences().setTmdbApiKey(widget.profileId, '');
                    await _syncLiveTvConfig();
                    if (!mounted) {
                      return;
                    }
                    setState(() => tmdbApiKey = '');
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                    }
                  } catch (e) {
                    if (ctx.mounted) {
                      setLocal(
                        () => localError = e.toString().replaceFirst(
                          'FormatException: ',
                          '',
                        ),
                      );
                    }
                  }
                },
                child: const Text('Clear key'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    await HomePreferences().setTmdbApiKey(
                      widget.profileId,
                      input.text,
                    );
                    await _syncLiveTvConfig();
                    if (!mounted) {
                      return;
                    }
                    setState(() => tmdbApiKey = input.text.trim());
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                    }
                  } catch (e) {
                    if (ctx.mounted) {
                      setLocal(
                        () => localError = e.toString().replaceFirst(
                          'FormatException: ',
                          '',
                        ),
                      );
                    }
                  }
                },
                child: const Text('Save key'),
              ),
            ],
          ),
        ),
      );
    } finally {
      input.dispose();
    }
  }

  Future<void> _editPlaybackPerformance() async {
    var value = playbackPerformance;
    String localError = '';
    final canTuneHardware =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.android;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Playback performance'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tune video playback performance for compatible devices. '
                  'Hardware decoding uses the GPU when available.',
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<HardwareDecodingMode>(
                  initialValue: value.hardwareDecoding,
                  items: const [
                    DropdownMenuItem(
                      value: HardwareDecodingMode.auto,
                      child: Text('GPU decode: Auto (recommended)'),
                    ),
                    DropdownMenuItem(
                      value: HardwareDecodingMode.enabled,
                      child: Text('GPU decode: Force on'),
                    ),
                    DropdownMenuItem(
                      value: HardwareDecodingMode.disabled,
                      child: Text('GPU decode: Force off (CPU only)'),
                    ),
                  ],
                  onChanged: canTuneHardware
                      ? (next) {
                          if (next == null) {
                            return;
                          }
                          setLocal(
                            () =>
                                value = value.copyWith(hardwareDecoding: next),
                          );
                        }
                      : null,
                ),
                if (!canTuneHardware)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'GPU decode overrides are available on Windows and Android.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Android aggressive tuning'),
                  subtitle: const Text(
                    'Improves smoothness on many Android devices by favoring speed over heavy filtering.',
                  ),
                  value: value.androidAggressiveMode,
                  onChanged: defaultTargetPlatform == TargetPlatform.android
                      ? (enabled) => setLocal(
                          () => value = value.copyWith(
                            androidAggressiveMode: enabled,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: value.desktopBufferMb.toString(),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Desktop network buffer (MB)',
                  ),
                  onChanged: (input) {
                    final parsed = int.tryParse(input.trim());
                    if (parsed == null) {
                      return;
                    }
                    setLocal(
                      () => value = value.copyWith(desktopBufferMb: parsed),
                    );
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: value.androidBufferMb.toString(),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Android network buffer (MB)',
                  ),
                  onChanged: (input) {
                    final parsed = int.tryParse(input.trim());
                    if (parsed == null) {
                      return;
                    }
                    setLocal(
                      () => value = value.copyWith(androidBufferMb: parsed),
                    );
                  },
                ),
                if (localError.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    localError,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  if (value.desktopBufferMb < 16 ||
                      value.desktopBufferMb > 512 ||
                      value.androidBufferMb < 16 ||
                      value.androidBufferMb > 512) {
                    throw const FormatException(
                      'Buffer sizes must be between 16 and 512 MB.',
                    );
                  }
                  await HomePreferences().savePlaybackPerformance(
                    widget.profileId,
                    value,
                  );
                  await _syncLiveTvConfig();
                  if (!mounted) {
                    return;
                  }
                  setState(() => playbackPerformance = value);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                } catch (e) {
                  if (ctx.mounted) {
                    setLocal(
                      () => localError = e.toString().replaceFirst(
                        'FormatException: ',
                        '',
                      ),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncLiveTvConfig() async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      return;
    }
    try {
      await liveTvControl.pushConfig(
        expectedConnection: connection,
        profileId: widget.profileId,
        sources: await HomePreferences().liveTvSources(widget.profileId),
        tmdbApiKey: await HomePreferences().tmdbApiKey(widget.profileId),
        profileState: await HomePreferences().liveTvProfileSyncState(
          widget.profileId,
        ),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    catalog.removeListener(_changed);
    super.dispose();
  }

  Future<void> _detect() async {
    setState(() => busy = true);
    try {
      final found = await FirefoxBrowser.detect(profileId: widget.profileId);
      if (mounted) {
        setState(
          () => exe =
              found ??
              'Managed Firefox is not prepared yet. Open a website app to install and prepare it automatically.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => exe = 'Could not verify Firefox.');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _remove(WebAppDefinition app) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          app.builtin
              ? 'Restore ${app.title} defaults?'
              : 'Remove ${app.title}?',
        ),
        content: const Text(
          'Firefox cookies, logins and extensions are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (yes == true) {
      try {
        await catalog.removeOrReset(widget.profileId, app);
      } catch (_) {
        if (mounted) {
          setState(() => error = 'Could not save the change.');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.all(28),
      children: [
        SleepModePanel(profileId: widget.profileId),
        SwitchListTile(
          title: const Text('Show Family Moments on Home'),
          subtitle: const Text(
            'Hiding the card does not remove gallery folders or slideshow settings.',
          ),
          value: familyMoments,
          onChanged: (value) async {
            try {
              await HomePreferences().setFamilyMoments(widget.profileId, value);
              await _syncLiveTvConfig();
              if (mounted) {
                setState(() => familyMoments = value);
              }
            } catch (_) {
              if (mounted) {
                setState(
                  () => error = 'Could not save Family Moments preference.',
                );
              }
            }
          },
        ),
        const SizedBox(height: 28),
        const Text('Live TV', style: TextStyle(fontSize: 28)),
        const SizedBox(height: 10),
        const Text(
          'Live TV opens inside Millitop with managed M3U or Xtream sources, channel groups, and search. Keep IPTVnator as a temporary fallback while testing.',
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Playback performance'),
          subtitle: Text(switch (playbackPerformance.hardwareDecoding) {
            HardwareDecodingMode.enabled => 'GPU decode forced on',
            HardwareDecodingMode.disabled => 'GPU decode forced off',
            HardwareDecodingMode.auto => 'GPU decode auto (recommended)',
          }),
          trailing: const Icon(Icons.tune),
          onTap: _editPlaybackPerformance,
        ),
        const SizedBox(height: 6),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('TMDB metadata key'),
          subtitle: Text(
            tmdbApiKey.isEmpty
                ? 'Not configured. Add your key to enrich M3U Movies/Series metadata.'
                : 'Configured (${tmdbApiKey.length} chars).',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editTmdbApiKey,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => LiveTvScreen(profileId: widget.profileId),
                ),
              ),
              child: const Text('Open native Live TV'),
            ),
            OutlinedButton(
              onPressed: () => NativeAppLauncher.open(
                context,
                appKey: 'iptvnator',
                title: 'IPTVnator',
              ),
              child: const Text('Open IPTVnator (legacy)'),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text('Music', style: TextStyle(fontSize: 28)),
        const SizedBox(height: 10),
        const Text(
          'Connect your Navidrome server for native music playback, stations, and profile parity sync.',
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => MusicScreen(profileId: widget.profileId),
            ),
          ),
          child: const Text('Open Music'),
        ),
        const SizedBox(height: 28),
        const Text('Browser', style: TextStyle(fontSize: 28)),
        const SizedBox(height: 10),
        const Text(
          'Website apps open in their own Firefox fullscreen app-style window. Closing that Millitop browser session returns here. This does not change the Windows default browser. Firefox, AdBlocker Ultimate and SponsorBlock are prepared automatically on first use. Browsing data is reused per profile. Personal Firefox is not changed.',
        ),
        const SizedBox(height: 10),
        SelectableText(exe),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : _detect,
              child: const Text('Check Firefox'),
            ),
            FilledButton(
              onPressed: () => FirefoxBrowser.open(
                context,
                profileId: widget.profileId,
                addons: true,
              ),
              child: const Text('Manage Firefox extensions'),
            ),
            TextButton(
              onPressed: () => FirefoxBrowser.open(
                context,
                profileId: widget.profileId,
                url:
                    'https://addons.mozilla.org/firefox/addon/adblocker-ultimate/',
              ),
              child: const Text('AdBlocker Ultimate listing'),
            ),
            TextButton(
              onPressed: () => FirefoxBrowser.open(
                context,
                profileId: widget.profileId,
                url: 'https://addons.mozilla.org/firefox/addon/sponsorblock/',
              ),
              child: const Text('SponsorBlock listing'),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text('Web apps', style: TextStyle(fontSize: 28)),
        const Text(
          'Local names and URLs are per profile. Managed apps are read-only here and controlled by the dashboard.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () => editWebApp(context, widget.profileId, null),
              icon: const Icon(Icons.add),
              label: const Text('Add URL app'),
            ),
            OutlinedButton(
              onPressed: () => catalog.sync(),
              child: const Text('Sync managed apps'),
            ),
          ],
        ),
        Text(catalog.syncStatus),
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(color: Colors.orangeAccent)),
        for (final app in apps)
          Card(
            child: ListTile(
              leading: Icon(
                app.managed
                    ? Icons.admin_panel_settings_outlined
                    : Icons.language,
              ),
              title: Text(
                '${app.title}${app.enabled ? '' : ' (hidden)'}${app.managed ? ' · Managed' : ''}',
              ),
              subtitle: Text(app.url),
              trailing: Wrap(
                children: [
                  IconButton(
                    onPressed: () => editWebApp(context, widget.profileId, app),
                    icon: const Icon(Icons.settings),
                    tooltip: app.managed ? 'Managed app details' : 'Edit app',
                  ),
                  if (!app.managed)
                    IconButton(
                      onPressed: () => _remove(app),
                      icon: Icon(
                        app.builtin ? Icons.restore : Icons.delete_outline,
                      ),
                      tooltip: app.builtin ? 'Restore defaults' : 'Remove app',
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 28),
        const Text('Gallery', style: TextStyle(fontSize: 28)),
        ListTile(
          title: const Text('Family folders and slideshow'),
          subtitle: const Text(
            'Choose folders, photo interval, videos, sound, shuffle and repeat.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => editGallerySettings(context, widget.profileId),
        ),
      ],
    ),
  );
}
