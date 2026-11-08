import '../services/home_preferences.dart';
import 'sleep_mode_panel.dart';
import 'diagnostics_screen.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/firefox_browser.dart';
import '../services/web_app_catalog.dart';
import '../services/web_app_definition.dart';
import '../services/device_connection.dart';
import '../services/live_tv_control.dart';
import '../services/live_tv_source.dart';
import '../services/playback_performance.dart';
import '../services/shared_family_album_service.dart';
import '../theme/millitop_visual_theme.dart';
import 'music_screen.dart';
import 'media_library_home.dart';

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

enum _SettingsSection { general, tvMovies, music, websites }

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  static const bool _sharedFamilyAlbumEnabled = false;
  final catalog = WebAppCatalog.instance;
  final liveTvControl = LiveTvControlService();
  List<WebAppDefinition> apps = [];
  String error = '', exe = 'Not checked';
  bool busy = false;
  int sleepQuickMinutes = 45;
  _SettingsSection section = _SettingsSection.general;
  String tmdbApiKey = '';
  SharedFamilyAlbumSettings sharedFamilyAlbumSettings =
      const SharedFamilyAlbumSettings();
  MillitopThemeId visualTheme = MillitopThemeId.auroraGlass;
  Map<String, dynamic> subtitleProviderSettings = const {};
  Map<String, dynamic> liveTvPlayerDefaults = const {};
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
      final key = await HomePreferences().tmdbApiKey(widget.profileId);
      final themeId = MillitopThemeController.fromStorage(
        await HomePreferences().visualTheme(widget.profileId),
      );
      final subtitleProviders = await HomePreferences()
          .subtitleProviderSettings(widget.profileId);
      final playerDefaults = await HomePreferences().liveTvPlayerDefaults(
        widget.profileId,
      );
      final performance = await HomePreferences().playbackPerformance(
        widget.profileId,
      );
      final sharedFamilyAlbum = await HomePreferences()
          .sharedFamilyAlbumSettings(widget.profileId);
      if (mounted) {
        setState(() {
          apps = values;
          tmdbApiKey = key;
          sharedFamilyAlbumSettings = sharedFamilyAlbum;
          visualTheme = themeId;
          subtitleProviderSettings = subtitleProviders;
          liveTvPlayerDefaults = playerDefaults;
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

  Future<void> _editSharedFamilyAlbum() async {
    var draft = sharedFamilyAlbumSettings;
    final proxy = TextEditingController(text: draft.proxyUrl);
    final host = TextEditingController(text: draft.serverUrl);
    final key = TextEditingController(text: draft.apiKey);
    final seconds = TextEditingController(text: draft.seconds.toString());
    final manualAlbumIds = TextEditingController(
      text: draft.albumIds.join(','),
    );
    var loadingAlbums = false;
    var albums = <SharedFamilyAlbumInfo>[];
    var localError = '';
    Future<void> loadAlbums(StateSetter setLocal) async {
      final currentHost = host.text.trim();
      final currentKey = key.text.trim();
      if (currentHost.isEmpty || currentKey.isEmpty) {
        setLocal(() => localError = 'Enter host and API key first.');
        return;
      }
      setLocal(() {
        loadingAlbums = true;
        localError = '';
      });
      try {
        albums = await const SharedFamilyAlbumService().albums(
          proxyUrl: proxy.text.trim(),
          host: currentHost,
          apiKey: currentKey,
        );
        if (albums.isEmpty) {
          setLocal(
            () => localError = proxy.text.trim().isEmpty
                ? 'No albums found. Check credentials, permissions, or add Proxy URL.'
                : 'No albums found. Check proxy, credentials, and album permissions.',
          );
        }
      } catch (e) {
        setLocal(
          () => localError = e.toString().replaceFirst('FormatException: ', ''),
        );
      } finally {
        setLocal(() => loadingAlbums = false);
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Shared Family Album'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Set up Immich to show a Home slideshow. If these settings are empty, nothing appears on Home.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: proxy,
                    autocorrect: false,
                    onChanged: (_) => setLocal(() => localError = ''),
                    decoration: const InputDecoration(
                      labelText: 'Proxy URL (Flask backend)',
                      hintText: 'https://dashboard.example.com',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: host,
                    autocorrect: false,
                    onChanged: (_) => setLocal(() => localError = ''),
                    decoration: const InputDecoration(
                      labelText: 'Immich host (external URL)',
                      hintText: 'https://immich.example.com',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: key,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (_) => setLocal(() => localError = ''),
                    decoration: const InputDecoration(
                      labelText: 'Immich API key',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: seconds,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Slide duration (seconds)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: draft.shuffle,
                          onChanged: (value) {
                            setLocal(() => draft = draft.copy(shuffle: value));
                          },
                          title: const Text('Shuffle'),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: draft.enabled,
                    onChanged: (value) {
                      setLocal(() => draft = draft.copy(enabled: value));
                    },
                    title: const Text('Enable on Home'),
                  ),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: loadingAlbums
                            ? null
                            : () => unawaited(loadAlbums(setLocal)),
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          loadingAlbums ? 'Loading albums...' : 'Load albums',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          draft.albumIds.isEmpty
                              ? 'No album selected.'
                              : 'Selected: ${draft.albumIds.length} album(s)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                  if (albums.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Albums to show on Home',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final album in albums)
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              value: draft.albumIds.contains(album.id),
                              onChanged: (selected) {
                                final ids = List<String>.from(draft.albumIds);
                                final names = List<String>.from(
                                  draft.albumNames,
                                );
                                if (selected == true) {
                                  if (!ids.contains(album.id)) {
                                    ids.add(album.id);
                                    names.add(album.name);
                                  }
                                } else {
                                  final removeIndex = ids.indexOf(album.id);
                                  if (removeIndex >= 0) {
                                    ids.removeAt(removeIndex);
                                    if (removeIndex < names.length) {
                                      names.removeAt(removeIndex);
                                    } else {
                                      names.remove(album.name);
                                    }
                                  }
                                }
                                setLocal(
                                  () => draft = draft.copy(
                                    albumIds: ids,
                                    albumNames: names,
                                  ),
                                );
                              },
                              title: Text(
                                '${album.name} (${album.assetCount})',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: manualAlbumIds,
                    minLines: 1,
                    maxLines: 3,
                    onChanged: (_) => setLocal(() => localError = ''),
                    decoration: const InputDecoration(
                      labelText: 'Album IDs (manual fallback)',
                      hintText: 'comma or newline separated album IDs',
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'If album loading times out, paste album IDs manually and save.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
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
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                await HomePreferences().saveSharedFamilyAlbumSettings(
                  widget.profileId,
                  const SharedFamilyAlbumSettings(),
                );
                if (!mounted) {
                  return;
                }
                setState(
                  () => sharedFamilyAlbumSettings =
                      const SharedFamilyAlbumSettings(),
                );
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Clear'),
            ),
            FilledButton(
              onPressed: () async {
                final parsedSeconds =
                    int.tryParse(seconds.text.trim()) ?? draft.seconds;
                final parsedAlbumIds = manualAlbumIds.text
                    .split(RegExp(r'[,\n]'))
                    .map((entry) => entry.trim())
                    .where((entry) => entry.isNotEmpty)
                    .toList();
                final resolvedIds = parsedAlbumIds.isEmpty
                    ? draft.albumIds
                    : parsedAlbumIds;
                if (resolvedIds.isEmpty) {
                  setLocal(
                    () => localError =
                        'Select at least one album or paste album IDs manually.',
                  );
                  return;
                }
                final nameById = <String, String>{
                  for (final album in albums) album.id: album.name,
                };
                final resolvedNames = <String>[];
                for (final id in resolvedIds) {
                  final loadedName = nameById[id];
                  if (loadedName != null && loadedName.isNotEmpty) {
                    resolvedNames.add(loadedName);
                    continue;
                  }
                  final previousIndex = draft.albumIds.indexOf(id);
                  if (previousIndex >= 0 &&
                      previousIndex < draft.albumNames.length) {
                    resolvedNames.add(draft.albumNames[previousIndex]);
                    continue;
                  }
                  resolvedNames.add(id);
                }
                final next = draft.copy(
                  proxyUrl: proxy.text.trim(),
                  serverUrl: host.text.trim(),
                  apiKey: key.text.trim(),
                  albumIds: resolvedIds,
                  albumNames: resolvedNames,
                  seconds: parsedSeconds.clamp(3, 60),
                );
                try {
                  await HomePreferences().saveSharedFamilyAlbumSettings(
                    widget.profileId,
                    next,
                  );
                  if (!mounted) {
                    return;
                  }
                  setState(() => sharedFamilyAlbumSettings = next);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                } catch (e) {
                  setLocal(
                    () => localError = e.toString().replaceFirst(
                      'FormatException: ',
                      '',
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    host.dispose();
    proxy.dispose();
    key.dispose();
    seconds.dispose();
    manualAlbumIds.dispose();
  }

  Future<void> _editVisualTheme() async {
    MillitopThemeId draft = visualTheme;
    String localError = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Visual theme'),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Themes restyle and re-layout MILLITOP TV across screens.',
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final spec in MillitopThemeController.themes)
                        ListTile(
                          leading: Icon(
                            draft == spec.id
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                          ),
                          title: Text(spec.label),
                          subtitle: Text(spec.summary),
                          onTap: () => setLocal(() => draft = spec.id),
                        ),
                    ],
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
            FilledButton(
              onPressed: () async {
                try {
                  await HomePreferences().setVisualTheme(
                    widget.profileId,
                    MillitopThemeController.toStorage(draft),
                  );
                  MillitopThemeController.instance.setTheme(draft);
                  if (!mounted) {
                    return;
                  }
                  setState(() => visualTheme = draft);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                } catch (error) {
                  if (ctx.mounted) {
                    setLocal(() => localError = '$error');
                  }
                }
              },
              child: const Text('Apply theme'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editSubtitleProviders() async {
    final opensubsApi = TextEditingController(
      text: subtitleProviderSettings['openSubtitlesApiKey']?.toString() ?? '',
    );
    final opensubsUser = TextEditingController(
      text: subtitleProviderSettings['openSubtitlesUsername']?.toString() ?? '',
    );
    final opensubsPass = TextEditingController(
      text: subtitleProviderSettings['openSubtitlesPassword']?.toString() ?? '',
    );
    final subdlApi = TextEditingController(
      text: subtitleProviderSettings['subdlApiKey']?.toString() ?? '',
    );
    final translateEndpoint = TextEditingController(
      text:
          subtitleProviderSettings['translateEndpoint']?.toString() ??
          'https://libretranslate.com/translate',
    );
    final translateApi = TextEditingController(
      text: subtitleProviderSettings['translateApiKey']?.toString() ?? '',
    );
    String localError = '';
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Subtitle providers'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Configure OpenSubtitles (primary), SubDL (secondary), and LibreTranslate translation endpoint.',
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: opensubsApi,
                      decoration: const InputDecoration(
                        labelText: 'OpenSubtitles API key',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: opensubsUser,
                      decoration: const InputDecoration(
                        labelText: 'OpenSubtitles username',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: opensubsPass,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'OpenSubtitles password',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: subdlApi,
                      decoration: const InputDecoration(
                        labelText: 'SubDL API key (optional)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: translateEndpoint,
                      decoration: const InputDecoration(
                        labelText: 'LibreTranslate endpoint',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: translateApi,
                      decoration: const InputDecoration(
                        labelText: 'LibreTranslate API key (optional)',
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
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await HomePreferences().saveSubtitleProviderSettings(
                      widget.profileId,
                      const {},
                    );
                    await _syncLiveTvConfig();
                    if (!mounted) {
                      return;
                    }
                    setState(() => subtitleProviderSettings = const {});
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                    }
                  } catch (e) {
                    if (ctx.mounted) {
                      setLocal(() => localError = e.toString());
                    }
                  }
                },
                child: const Text('Clear'),
              ),
              FilledButton(
                onPressed: () async {
                  final next = <String, dynamic>{
                    'openSubtitlesApiKey': opensubsApi.text.trim(),
                    'openSubtitlesUsername': opensubsUser.text.trim(),
                    'openSubtitlesPassword': opensubsPass.text.trim(),
                    'subdlApiKey': subdlApi.text.trim(),
                    'translateEndpoint': translateEndpoint.text.trim(),
                    'translateApiKey': translateApi.text.trim(),
                  };
                  try {
                    await HomePreferences().saveSubtitleProviderSettings(
                      widget.profileId,
                      next,
                    );
                    await _syncLiveTvConfig();
                    if (!mounted) {
                      return;
                    }
                    setState(() => subtitleProviderSettings = next);
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                    }
                  } catch (e) {
                    if (ctx.mounted) {
                      setLocal(() => localError = e.toString());
                    }
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
    } finally {
      opensubsApi.dispose();
      opensubsUser.dispose();
      opensubsPass.dispose();
      subdlApi.dispose();
      translateEndpoint.dispose();
      translateApi.dispose();
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

  Future<void> _editLiveTvPlayerDefaults() async {
    final defaults = Map<String, dynamic>.from(liveTvPlayerDefaults);
    double subtitleFontSize =
        double.tryParse(defaults['subtitleFontSize']?.toString() ?? '') ?? 46;
    double subtitleOpacity =
        double.tryParse(defaults['subtitleOpacity']?.toString() ?? '') ?? 1.0;
    double subtitlePosition =
        double.tryParse(defaults['subtitlePosition']?.toString() ?? '') ?? 92;
    double subtitleDelaySeconds =
        double.tryParse(defaults['subtitleDelaySeconds']?.toString() ?? '') ??
        0.0;
    String subtitleFontFamily =
        defaults['subtitleFontFamily']?.toString().trim().isNotEmpty == true
        ? defaults['subtitleFontFamily'].toString().trim()
        : 'Default';
    int maxBandwidthKbpsRemote =
        int.tryParse(defaults['maxBandwidthKbpsRemote']?.toString() ?? '') ??
        4500;
    int maxBandwidthKbpsLocal =
        int.tryParse(defaults['maxBandwidthKbpsLocal']?.toString() ?? '') ??
        18000;
    Color subtitleForeground = Color(
      int.tryParse(defaults['subtitleForeground']?.toString() ?? '') ??
          Colors.white.toARGB32(),
    );
    Color subtitleBackground = Color(
      int.tryParse(defaults['subtitleBackground']?.toString() ?? '') ??
          Colors.black87.toARGB32(),
    );
    Color subtitleOutline = Color(
      int.tryParse(defaults['subtitleOutline']?.toString() ?? '') ??
          Colors.black.toARGB32(),
    );
    String localError = '';
    final colorOptions = <MapEntry<String, Color>>[
      const MapEntry('White', Colors.white),
      const MapEntry('Black', Colors.black),
      const MapEntry('Amber', Colors.amber),
      const MapEntry('Cyan', Colors.cyanAccent),
      const MapEntry('Green', Colors.lightGreenAccent),
      const MapEntry('Pink', Colors.pinkAccent),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Live TV subtitle & quality defaults'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'These defaults apply to Movies & Series playback. They can still be adjusted during playback.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Remote max quality: $maxBandwidthKbpsRemote kbps',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Slider(
                    value: maxBandwidthKbpsRemote.clamp(1200, 20000).toDouble(),
                    min: 1200,
                    max: 20000,
                    divisions: 188,
                    onChanged: (value) =>
                        setLocal(() => maxBandwidthKbpsRemote = value.round()),
                  ),
                  Text(
                    'Local max quality: $maxBandwidthKbpsLocal kbps',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Slider(
                    value: maxBandwidthKbpsLocal
                        .clamp(maxBandwidthKbpsRemote, 50000)
                        .toDouble(),
                    min: maxBandwidthKbpsRemote.toDouble(),
                    max: 50000,
                    divisions: 244,
                    onChanged: (value) =>
                        setLocal(() => maxBandwidthKbpsLocal = value.round()),
                  ),
                  const Divider(height: 24),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Subtitle font family'),
                    subtitle: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final family in const [
                          'Default',
                          'Arial',
                          'Roboto',
                          'Noto Sans',
                          'Open Sans',
                          'Verdana',
                        ])
                          ChoiceChip(
                            label: Text(family),
                            selected: subtitleFontFamily == family,
                            onSelected: (_) =>
                                setLocal(() => subtitleFontFamily = family),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Subtitle font size: ${subtitleFontSize.toStringAsFixed(0)}',
                    ),
                    subtitle: Slider(
                      value: subtitleFontSize.clamp(26, 82),
                      min: 26,
                      max: 82,
                      onChanged: (value) =>
                          setLocal(() => subtitleFontSize = value),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Subtitle opacity: ${(subtitleOpacity * 100).round()}%',
                    ),
                    subtitle: Slider(
                      value: subtitleOpacity.clamp(0.2, 1.0),
                      min: 0.2,
                      max: 1.0,
                      onChanged: (value) =>
                          setLocal(() => subtitleOpacity = value),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Subtitle position: ${subtitlePosition.toStringAsFixed(0)}',
                    ),
                    subtitle: Slider(
                      value: subtitlePosition.clamp(10, 100),
                      min: 10,
                      max: 100,
                      onChanged: (value) =>
                          setLocal(() => subtitlePosition = value),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Subtitle timing offset: ${subtitleDelaySeconds.toStringAsFixed(2)}s',
                    ),
                    subtitle: Slider(
                      value: subtitleDelaySeconds.clamp(-10, 10),
                      min: -10,
                      max: 10,
                      onChanged: (value) =>
                          setLocal(() => subtitleDelaySeconds = value),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Subtitle foreground color'),
                    subtitle: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in colorOptions)
                          ChoiceChip(
                            label: Text(option.key),
                            selected:
                                subtitleForeground.toARGB32() ==
                                option.value.toARGB32(),
                            onSelected: (_) => setLocal(
                              () => subtitleForeground = option.value,
                            ),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Subtitle background color'),
                    subtitle: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in colorOptions)
                          ChoiceChip(
                            label: Text(option.key),
                            selected:
                                subtitleBackground.toARGB32() ==
                                option.value.toARGB32(),
                            onSelected: (_) => setLocal(
                              () => subtitleBackground = option.value,
                            ),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Subtitle outline/shadow color'),
                    subtitle: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in colorOptions)
                          ChoiceChip(
                            label: Text(option.key),
                            selected:
                                subtitleOutline.toARGB32() ==
                                option.value.toARGB32(),
                            onSelected: (_) =>
                                setLocal(() => subtitleOutline = option.value),
                          ),
                      ],
                    ),
                  ),
                  if (localError.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        localError,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                await HomePreferences().saveLiveTvPlayerDefaults(
                  widget.profileId,
                  const {},
                );
                await _syncLiveTvConfig();
                if (!mounted) {
                  return;
                }
                setState(() => liveTvPlayerDefaults = const {});
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Reset defaults'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  if (maxBandwidthKbpsRemote < 1200 ||
                      maxBandwidthKbpsLocal < maxBandwidthKbpsRemote) {
                    throw const FormatException(
                      'Bandwidth limits must be at least 1200 kbps and local must be >= remote.',
                    );
                  }
                  final next = <String, dynamic>{
                    'maxBandwidthKbpsRemote': maxBandwidthKbpsRemote,
                    'maxBandwidthKbpsLocal': maxBandwidthKbpsLocal,
                    'subtitleFontFamily': subtitleFontFamily,
                    'subtitleFontSize': subtitleFontSize,
                    'subtitleOpacity': subtitleOpacity,
                    'subtitlePosition': subtitlePosition,
                    'subtitleDelaySeconds': subtitleDelaySeconds,
                    'subtitleForeground': subtitleForeground.toARGB32(),
                    'subtitleBackground': subtitleBackground.toARGB32(),
                    'subtitleOutline': subtitleOutline.toARGB32(),
                  };
                  await HomePreferences().saveLiveTvPlayerDefaults(
                    widget.profileId,
                    next,
                  );
                  await _syncLiveTvConfig();
                  if (!mounted) {
                    return;
                  }
                  setState(() => liveTvPlayerDefaults = next);
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
              child: const Text('Save defaults'),
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

  Future<void> _openSleepPanel() async {
    final tokens = context.millitopTheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: tokens.panelColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(tokens.cardRadius + 2),
        ),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SleepModePanel(profileId: widget.profileId),
        ),
      ),
    );
  }

  Widget _settingsCard({required Widget child}) {
    final tokens = context.millitopTheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: tokens.panelColor.withAlpha(130),
        borderRadius: BorderRadius.circular(tokens.cardRadius),
        border: Border.all(color: tokens.panelBorder.withAlpha(128)),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }

  Widget _sectionButton({
    required _SettingsSection value,
    required String label,
    required IconData icon,
  }) {
    final tokens = context.millitopTheme;
    final selected = section == value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextButton.icon(
        onPressed: () => setState(() => section = value),
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          backgroundColor: selected ? tokens.accentColor : null,
          foregroundColor: selected
              ? Theme.of(context).colorScheme.onPrimary
              : tokens.mutedColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }

  Widget _generalSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'General',
        style: TextStyle(fontSize: 38, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      const Text(
        'Make Millitop feel right for you.',
        style: TextStyle(color: Colors.white70),
      ),
      const SizedBox(height: 18),
      _settingsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.nightlight_round,
                  color: context.millitopTheme.accentColor,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Sleep timer',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Stop watching after a set time. Keep your sleep sounds playing.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final minutes in [15, 30, 45, 60])
                  ChoiceChip(
                    label: Text('$minutes min'),
                    selected: sleepQuickMinutes == minutes,
                    onSelected: (_) =>
                        setState(() => sleepQuickMinutes = minutes),
                  ),
                OutlinedButton(
                  onPressed: _openSleepPanel,
                  child: const Text('Custom'),
                ),
                FilledButton(
                  onPressed: _openSleepPanel,
                  child: const Text('Start timer'),
                ),
              ],
            ),
            const Divider(height: 26),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note_outlined),
              title: const Text('Sleep sounds'),
              subtitle: const Text('Choose something relaxing for bedtime.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openSleepPanel,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _settingsCard(
        child: ListTile(
          key: const ValueKey('settings-diagnostics'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Diagnostics & logs'),
          subtitle: const Text(
            'Errors with suggested fixes, activity log, and usage sharing.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'diagnostics'),
              builder: (_) => const DiagnosticsScreen(),
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      _settingsCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Interface theme'),
          subtitle: Text(
            MillitopThemeController.themes
                .firstWhere(
                  (theme) => theme.id == visualTheme,
                  orElse: () => MillitopThemeController.themes.first,
                )
                .label,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editVisualTheme,
        ),
      ),
      const SizedBox(height: 14),
      _settingsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your entertainment',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Manage the services you use in Millitop.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Files'),
              subtitle: const Text(
                'Manage your folders and browse local or network media',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Files')),
                    body: SingleChildScrollView(
                      child: MediaLibraryHome(profileId: widget.profileId),
                    ),
                  ),
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tv_outlined),
              title: const Text('TV & movies'),
              subtitle: const Text('Live channels, movies, and subtitles'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => section = _SettingsSection.tvMovies),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note_outlined),
              title: const Text('Music'),
              subtitle: const Text('Your library and music connection'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => section = _SettingsSection.music),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.public_outlined),
              title: const Text('Websites'),
              subtitle: const Text('Add and organize your website shortcuts'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => section = _SettingsSection.websites),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _tvMoviesSection() => _settingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'TV & movies',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
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
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('TMDB metadata key'),
          subtitle: Text(
            tmdbApiKey.isEmpty
                ? 'Not configured.'
                : 'Configured (${tmdbApiKey.length} chars).',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editTmdbApiKey,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Subtitle provider settings'),
          subtitle: Text(
            subtitleProviderSettings.isEmpty
                ? 'Not configured.'
                : 'Configured (${subtitleProviderSettings.keys.length} values).',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editSubtitleProviders,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Subtitle display & quality defaults'),
          subtitle: Text(
            liveTvPlayerDefaults.isEmpty
                ? 'Using built-in defaults.'
                : 'Configured (${liveTvPlayerDefaults.keys.length} values).',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editLiveTvPlayerDefaults,
        ),
        // Shared Family Album temporarily disabled.
        if (_sharedFamilyAlbumEnabled)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Shared Family Album slideshow'),
            subtitle: Text(
              !sharedFamilyAlbumSettings.isConfigured
                  ? 'Disabled until host, API key, and album are set.'
                  : 'Enabled for ${sharedFamilyAlbumSettings.albumIds.length} album(s).',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editSharedFamilyAlbum,
          ),
      ],
    ),
  );

  Widget _musicSection() => _settingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Music',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Connect your Navidrome server for native music playback and profile sync.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => MusicScreen(profileId: widget.profileId),
            ),
          ),
          child: const Text('Open Music'),
        ),
      ],
    ),
  );

  Widget _websitesSection() => _settingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Websites',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        SelectableText(exe),
        const SizedBox(height: 8),
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
          ],
        ),
        const Divider(height: 24),
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
          ListTile(
            contentPadding: EdgeInsets.zero,
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
      ],
    ),
  );

  Widget _sectionContent() {
    switch (section) {
      case _SettingsSection.general:
        return _generalSection();
      case _SettingsSection.tvMovies:
        return _tvMoviesSection();
      case _SettingsSection.music:
        return _musicSection();
      case _SettingsSection.websites:
        return _websitesSection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.millitopTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 700) {
            return SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: DropdownButtonFormField<_SettingsSection>(
                      initialValue: section,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Settings category',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: _SettingsSection.general,
                          child: Text('General'),
                        ),
                        DropdownMenuItem(
                          value: _SettingsSection.tvMovies,
                          child: Text('TV & movies'),
                        ),
                        DropdownMenuItem(
                          value: _SettingsSection.music,
                          child: Text('Music'),
                        ),
                        DropdownMenuItem(
                          value: _SettingsSection.websites,
                          child: Text('Websites'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => section = value);
                        }
                      },
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [_sectionContent()],
                    ),
                  ),
                ],
              ),
            );
          }
          return Row(
            children: [
              Container(
                width: 220,
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: tokens.panelBorder)),
                ),
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    Text(
                      'MILLITOP',
                      style: TextStyle(
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                        color: tokens.accentColor,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _sectionButton(
                      value: _SettingsSection.general,
                      label: 'General',
                      icon: Icons.settings_outlined,
                    ),
                    _sectionButton(
                      value: _SettingsSection.tvMovies,
                      label: 'TV & movies',
                      icon: Icons.tv_outlined,
                    ),
                    _sectionButton(
                      value: _SettingsSection.music,
                      label: 'Music',
                      icon: Icons.music_note_outlined,
                    ),
                    _sectionButton(
                      value: _SettingsSection.websites,
                      label: 'Websites',
                      icon: Icons.public_outlined,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(22),
                  children: [_sectionContent()],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
