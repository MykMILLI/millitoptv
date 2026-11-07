import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../library/library_models.dart';
import '../library/library_repository.dart';
import '../library/library_file_service.dart';
import '../services/home_preferences.dart';
import '../services/library_metadata_service.dart';
import '../services/native_app_launcher.dart';
import '../services/device_connection.dart';
import '../services/live_tv_control.dart';
import '../theme/millitop_visual_theme.dart';
import 'live_tv_screen.dart';
import 'live_tv_media_screen.dart' show DvrRecordingPlayerScreen;
import '../widgets/live_tv_osd.dart' show DvrRecordingBadge, dvrRecordRed;
import 'library_browser_screen.dart';

class MediaLibraryHome extends StatefulWidget {
  final int profileId;
  final bool recordings;
  final MediaLibraryRepository? repository;
  final LibraryFileService? files;
  final Future<String?> Function()? pickDirectory;
  const MediaLibraryHome({
    super.key,
    required this.profileId,
    this.recordings = false,
    this.repository,
    this.files,
    this.pickDirectory,
  });
  @override
  State<MediaLibraryHome> createState() => _MediaLibraryHomeState();
}

class _MediaLibraryHomeState extends State<MediaLibraryHome> {
  late MediaLibraryRepository repository;
  late LibraryFileService files;
  final liveTvControl = LiveTvControlService();
  final metadata = const LibraryMetadataService();
  List<LibraryFolder> folders = [];
  List<LiveTvRecentChannel> recentLiveTv = [];
  List<Map<String, dynamic>> remoteSchedules = [];
  List<Map<String, dynamic>> remoteRecordings = [];
  bool cloudDvrConnected = false, cloudDvrLoaded = false;
  String cloudDvrError = '';
  Timer? cloudDvrRefresh;
  bool busy = false, loading = true;
  bool metadataScanning = false;
  String error = '';
  String metadataStatus = '';
  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void dispose() {
    cloudDvrRefresh?.cancel();
    super.dispose();
  }

  void _attach() {
    repository = widget.repository ?? MediaLibraryRepository();
    files = widget.files ?? LibraryFileService();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant MediaLibraryHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileId != widget.profileId ||
        oldWidget.recordings != widget.recordings ||
        oldWidget.repository != widget.repository) {
      _attach();
    }
  }

  Future<void> _load() async {
    final profile = widget.profileId;
    try {
      final values = await repository.load(profile);
      if (!mounted || widget.profileId != profile) {
        return;
      }
      setState(() {
        folders = values;
        recentLiveTv = [];
        loading = false;
        error = '';
      });
      try {
        final recents = await HomePreferences().liveTvRecentChannels(profile);
        if (mounted && widget.profileId == profile) {
          setState(() {
            recentLiveTv = recents.take(8).toList();
          });
        }
      } catch (_) {}
      if (widget.recordings) {
        await _loadRemoteDvr(profile);
      }
    } catch (e) {
      if (mounted && widget.profileId == profile) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> _loadRemoteDvr(int profile) async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      cloudDvrRefresh?.cancel();
      if (mounted) {
        setState(() {
          cloudDvrConnected = false;
          cloudDvrLoaded = true;
          remoteSchedules = [];
          remoteRecordings = [];
        });
      }
      return;
    }
    List<Map<String, dynamic>> rows(Map<String, dynamic> data, String key) => [
      ...(data[key] as List? ?? const []),
    ].whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    try {
      final recordings = await liveTvControl.dvrRecordings(
        expectedConnection: connection,
        profileId: profile,
      );
      var schedules = <Map<String, dynamic>>[];
      try {
        schedules = rows(
          await liveTvControl.dvrSchedules(
            expectedConnection: connection,
            profileId: profile,
          ),
          'schedules',
        );
      } catch (_) {}
      if (!mounted || widget.profileId != profile) {
        return;
      }
      final next = rows(recordings, 'recordings');
      setState(() {
        cloudDvrConnected = true;
        cloudDvrLoaded = true;
        cloudDvrError = '';
        remoteSchedules = schedules;
        remoteRecordings = next;
      });
      // Keep "Recording now" entries fresh while something is recording.
      cloudDvrRefresh?.cancel();
      if (next.any((item) => item['status'] == 'recording') ||
          schedules.isNotEmpty) {
        cloudDvrRefresh = Timer(
          const Duration(seconds: 15),
          () => unawaited(_loadRemoteDvr(profile)),
        );
      }
    } catch (e) {
      if (!mounted || widget.profileId != profile) {
        return;
      }
      setState(() {
        cloudDvrConnected = true;
        cloudDvrLoaded = true;
        cloudDvrError = e is DeviceRequestFailure && e.statusCode == 404
            ? 'Your Millitop server does not support DVR yet. Update the dashboard server to enable recordings.'
            : 'Recordings could not load. ${e is DeviceRequestFailure && e.message.isNotEmpty ? e.message : 'Check your connection and refresh.'}';
      });
    }
  }

  Uri? _playbackUri(Map<String, dynamic> item) {
    final path = item['playbackPath']?.toString() ?? '';
    final server = DeviceConnection.instance.serverUri;
    if (path.isEmpty || server == null) {
      return null;
    }
    return server.resolve(path);
  }

  Future<void> _playRecording(Map<String, dynamic> item) async {
    final uri = _playbackUri(item);
    if (uri == null) {
      setState(
        () => cloudDvrError = 'This recording is not available to play.',
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DvrRecordingPlayerScreen(
          profileId: widget.profileId,
          title: item['title']?.toString() ?? 'Recording',
          subtitle: item['channelName']?.toString(),
          streamUrl: uri.toString(),
        ),
      ),
    );
  }

  Future<void> _stopRecording(Map<String, dynamic> item) async {
    final connection = DeviceConnection.instance.connectionKey;
    final id = item['id']?.toString() ?? '';
    if (connection.isEmpty || id.isEmpty) {
      return;
    }
    setState(() => busy = true);
    try {
      await liveTvControl.stopDvrRecording(
        expectedConnection: connection,
        recordingId: id,
      );
    } catch (e) {
      if (mounted && !(e is DeviceRequestFailure && e.statusCode == 404)) {
        setState(() => cloudDvrError = 'Could not stop the recording. $e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
      await _loadRemoteDvr(widget.profileId);
    }
  }

  Future<void> _deleteRecording(Map<String, dynamic> item) async {
    final connection = DeviceConnection.instance.connectionKey;
    final id = item['id']?.toString() ?? '';
    if (connection.isEmpty || id.isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(
          '"${item['title'] ?? 'Recording'}" will be removed from DVR on all paired devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await liveTvControl.deleteDvrRecording(
        expectedConnection: connection,
        recordingId: id,
      );
    } catch (e) {
      if (mounted) {
        setState(() => cloudDvrError = 'Could not delete the recording. $e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
      await _loadRemoteDvr(widget.profileId);
    }
  }

  static String _durationText(int seconds) {
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }

  static String _sizeText(num bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String _whenText(String? iso) {
    final value = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (value == null) return '';
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    return '${value.month}/${value.day} $hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  Widget _cloudDvrPanel() {
    final active = remoteRecordings
        .where((item) => item['status'] == 'recording')
        .toList();
    final saved = remoteRecordings
        .where((item) => item['status'] != 'recording')
        .toList();
    final upcoming = remoteSchedules
        .where((item) => item['status'] == 'scheduled')
        .toList();
    return _premiumPanel(
      child: Column(
        key: const ValueKey('cloud-dvr-panel'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Your recordings',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => unawaited(_loadRemoteDvr(widget.profileId)),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (cloudDvrLoaded && !cloudDvrConnected)
            const Text(
              'Pair this device with your Millitop server to see recordings saved from any of your devices.',
            )
          else if (!cloudDvrLoaded)
            const LinearProgressIndicator()
          else ...[
            if (cloudDvrError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  cloudDvrError,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            if (active.isNotEmpty) ...[
              const Text(
                'Recording now',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final item in active)
                ListTile(
                  key: ValueKey('dvr-active-${item['id']}'),
                  leading: const DvrRecordingBadge(),
                  title: Text(item['title']?.toString() ?? 'Recording'),
                  subtitle: Text(
                    '${item['channelName'] ?? ''} · started ${_whenText(item['startedAtUtc']?.toString())}',
                  ),
                  trailing: Wrap(
                    spacing: 6,
                    children: [
                      if (_playbackUri(item) != null)
                        IconButton(
                          tooltip: 'Watch from the beginning',
                          onPressed: busy ? null : () => _playRecording(item),
                          icon: const Icon(Icons.play_arrow),
                        ),
                      OutlinedButton.icon(
                        onPressed: busy ? null : () => _stopRecording(item),
                        icon: const Icon(Icons.stop, color: dvrRecordRed),
                        label: const Text('Stop'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
            if (upcoming.isNotEmpty) ...[
              const Text(
                'Scheduled',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final item in upcoming.take(10))
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.event_note),
                  title: Text(item['title']?.toString() ?? 'Scheduled item'),
                  subtitle: Text(
                    '${item['channelName'] ?? ''} · ${_whenText(item['startUtc']?.toString())}',
                  ),
                  trailing: (item['scheduleId'] ?? item['id']) == null
                      ? null
                      : IconButton(
                          tooltip: 'Cancel schedule',
                          onPressed: busy
                              ? null
                              : () => unawaited(
                                  _cancelRemoteSchedule(
                                    (item['scheduleId'] ?? item['id'])
                                        .toString(),
                                  ),
                                ),
                          icon: const Icon(Icons.delete_outline),
                        ),
                ),
              const SizedBox(height: 8),
            ],
            if (saved.isEmpty && active.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No recordings yet. In Live TV, press the record button and choose Record now, or schedule a program from the guide.',
                ),
              ),
            for (final item in saved)
              ListTile(
                key: ValueKey('dvr-recording-${item['id']}'),
                leading: Icon(
                  item['status'] == 'failed'
                      ? Icons.error_outline
                      : Icons.fiber_smart_record,
                  color: item['status'] == 'failed'
                      ? Colors.orangeAccent
                      : null,
                ),
                title: Text(item['title']?.toString() ?? 'Recording'),
                subtitle: Text(
                  [
                    item['channelName']?.toString() ?? '',
                    _whenText(item['startedAtUtc']?.toString()),
                    if (item['status'] != 'failed') ...[
                      _durationText(
                        (item['durationSeconds'] as num?)?.toInt() ?? 0,
                      ),
                      _sizeText((item['sizeBytes'] as num?) ?? 0),
                    ],
                    if (item['status'] == 'failed')
                      item['note']?.toString() ?? 'Recording failed',
                  ].where((part) => part.isNotEmpty).join(' · '),
                ),
                onTap: busy || _playbackUri(item) == null
                    ? null
                    : () => _playRecording(item),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    if (_playbackUri(item) != null)
                      IconButton(
                        tooltip: 'Play',
                        onPressed: busy ? null : () => _playRecording(item),
                        icon: const Icon(Icons.play_arrow),
                      ),
                    IconButton(
                      tooltip: 'Delete recording',
                      onPressed: busy ? null : () => _deleteRecording(item),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _scanMetadata() async {
    if (metadataScanning || busy || loading) {
      return;
    }
    final profile = widget.profileId;
    final tmdbApiKey = await HomePreferences().tmdbApiKey(profile);
    if (tmdbApiKey.trim().isEmpty) {
      if (mounted) {
        setState(
          () => metadataStatus =
              'TMDB key missing. Add it in Settings → TV & movies.',
        );
      }
      return;
    }
    final targets = folders.where((entry) => !entry.recordings).toList();
    if (targets.isEmpty) {
      if (mounted) {
        setState(() => metadataStatus = 'Add at least one media folder first.');
      }
      return;
    }
    if (mounted) {
      setState(() {
        metadataScanning = true;
        metadataStatus = 'Scanning folders and matching TMDB metadata...';
      });
    }
    try {
      final report = await metadata.scanFolders(
        profileId: profile,
        folders: targets,
        tmdbApiKey: tmdbApiKey,
      );
      if (!mounted) {
        return;
      }
      setState(
        () => metadataStatus =
            'TMDB scan complete: ${report.updated} updated, ${report.matched} matched, ${report.scanned} scanned.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => metadataStatus = 'TMDB scan failed: $error');
    } finally {
      if (mounted) {
        setState(() => metadataScanning = false);
      }
    }
  }

  Future<void> _cancelRemoteSchedule(String scheduleId) async {
    final connection = DeviceConnection.instance.connectionKey;
    if (connection.isEmpty || !DeviceConnection.instance.isConnected) {
      if (mounted) {
        setState(() => error = 'Connect device to cancel scheduled DVR jobs.');
      }
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await liveTvControl.cancelScheduledDvr(
        expectedConnection: connection,
        profileId: widget.profileId,
        scheduleId: scheduleId,
      );
      await _loadRemoteDvr(widget.profileId);
    } catch (exception) {
      if (mounted) {
        setState(() => error = 'Could not cancel schedule: $exception');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _add([String? suggested]) async {
    if (busy || loading) {
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    TextEditingController? label;
    try {
      final path = await _pickFolderPath();
      if (path == null || !mounted) {
        return;
      }
      final resolved = await files.validateFolder(path);
      if (!mounted) {
        return;
      }
      label = TextEditingController(
        text:
            suggested ??
            (widget.recordings ? 'Recordings' : p.basename(resolved)),
      );
      final editor = label;
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            widget.recordings ? 'Add recordings folder' : 'Add folder shortcut',
          ),
          content: SizedBox(
            width: 450,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: editor,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Folder label'),
                  onSubmitted: (value) {
                    if (value.trim().isNotEmpty) {
                      Navigator.pop(ctx, value.trim());
                    }
                  },
                ),
                const SizedBox(height: 8),
                SelectableText(resolved),
                const SizedBox(height: 8),
                const Text(
                  'Millitop browses this folder using your Windows account. No network password is stored by this feature.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = editor.text.trim();
                if (value.isNotEmpty && value.length <= 80) {
                  Navigator.pop(ctx, value);
                }
              },
              child: const Text('Save folder'),
            ),
          ],
        ),
      );
      if (name == null || !mounted) {
        return;
      }
      await repository.add(
        widget.profileId,
        path: resolved,
        label: name,
        recordings: widget.recordings,
      );
      await _load();
      await _syncLibraryFolders();
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (label != null) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        label.dispose();
      }
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _remove(LibraryFolder folder) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${folder.label}?'),
        content: const Text(
          'This removes only the saved shortcut for this profile. No folders, recordings or files will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove shortcut'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await repository.remove(widget.profileId, folder.id);
      await _load();
      await _syncLibraryFolders();
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<String?> _pickFolderPath() async {
    final picked =
        await (widget.pickDirectory?.call() ??
            getDirectoryPath(confirmButtonText: 'Use this folder'));
    if (picked != null && picked.trim().isNotEmpty) {
      return picked.trim();
    }
    if (!mounted) {
      return null;
    }
    final input = TextEditingController();
    final manual = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add network share path'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste an SMB/UNC path like \\\\SERVER\\Movies or map it to a drive first.',
              ),
              const SizedBox(height: 10),
              TextField(
                controller: input,
                autofocus: true,
                maxLength: 280,
                decoration: const InputDecoration(
                  labelText: 'Network path',
                  hintText: r'\\SERVER\Share\Folder',
                ),
                onSubmitted: (value) {
                  final next = value.trim();
                  if (next.isNotEmpty) {
                    Navigator.pop(ctx, next);
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final next = input.text.trim();
              if (next.isNotEmpty) {
                Navigator.pop(ctx, next);
              }
            },
            child: const Text('Use path'),
          ),
        ],
      ),
    );
    input.dispose();
    return manual;
  }

  Future<void> _syncLibraryFolders() async {
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

  Widget _premiumPanel({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    EdgeInsetsGeometry margin = const EdgeInsets.only(bottom: 14),
  }) => Container(
    margin: margin,
    padding: padding,
    decoration: BoxDecoration(
      color: context.millitopTheme.panelColor.withAlpha(130),
      borderRadius: BorderRadius.circular(context.millitopTheme.cardRadius),
      border: Border.all(color: context.millitopTheme.panelBorder),
    ),
    child: child,
  );

  ButtonStyle _tvButtonStyle({required bool prominent}) {
    return ButtonStyle(
      minimumSize: WidgetStateProperty.all(
        Size(prominent ? 188 : 172, prominent ? 56 : 52),
      ),
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
      textStyle: WidgetStateProperty.all(
        const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      ),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return BorderSide(color: context.millitopTheme.accentColor, width: 2);
        }
        if (states.contains(WidgetState.hovered)) {
          return BorderSide(
            color: context.millitopTheme.accentColor.withAlpha(180),
            width: 1.4,
          );
        }
        return BorderSide(color: context.millitopTheme.panelBorder, width: 1);
      }),
    );
  }

  Widget _recordingsHome(List<LibraryFolder> visible) => Theme(
    data: Theme.of(context).copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: _tvButtonStyle(prominent: true),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _tvButtonStyle(prominent: false),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _tvButtonStyle(prominent: false),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _premiumPanel(
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DVR recordings',
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 8),
              Text(
                'Recordings from Live TV are saved to your Millitop server and appear on every paired device.',
                style: TextStyle(
                  fontSize: 20,
                  color: Colors.white70,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        if (busy || loading) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(color: Colors.orangeAccent)),
        _cloudDvrPanel(),
        if (visible.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Recording folders on this device',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
        ],
        for (final folder in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SizedBox(
              width: 450,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(20),
                ),
                onPressed: busy
                    ? null
                    : () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => LibraryBrowserScreen(
                            profileId: widget.profileId,
                            folder: folder,
                            files: files,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.video_library_outlined, size: 30),
                label: Text(folder.label, style: const TextStyle(fontSize: 20)),
              ),
            ),
          ),
        const SizedBox(height: 8),
        ExpansionTile(
          title: const Text('Recording settings'),
          initiallyExpanded: false,
          childrenPadding: const EdgeInsets.all(16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Record now and Schedule from the Live TV guide save to your Millitop server. You can also add folders from another recorder on this device.',
              style: TextStyle(height: 1.35),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const ValueKey('add-dvr-folder'),
                  onPressed: busy || loading ? null : () => _add(),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Add recordings folder'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh folders'),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => LiveTvScreen(
                              profileId: widget.profileId,
                              openGuideOnStart: true,
                            ),
                          ),
                        ),
                  child: const Text('Schedule from EPG guide'),
                ),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => unawaited(_loadRemoteDvr(widget.profileId)),
                  icon: const Icon(Icons.event_note),
                  label: const Text('Refresh schedules'),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => NativeAppLauncher.open(
                          context,
                          appKey: 'iptvnator',
                          title: 'IPTVnator',
                        ),
                  child: const Text('Open IPTVnator (legacy)'),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => NativeAppLauncher.open(
                          context,
                          appKey: 'vlc',
                          title: 'VLC player',
                        ),
                  child: const Text('Open VLC'),
                ),
              ],
            ),
            for (final folder in visible)
              ListTile(
                title: Text(folder.label),
                subtitle: SelectableText(folder.path),
                trailing: TextButton(
                  onPressed: busy ? null : () => _remove(folder),
                  child: const Text('Remove shortcut'),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final visible = folders
        .where((f) => f.recordings == widget.recordings)
        .toList();
    if (widget.recordings) return _recordingsHome(visible);
    return Theme(
      data: Theme.of(context).copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: _tvButtonStyle(prominent: true),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: _tvButtonStyle(prominent: false),
        ),
        textButtonTheme: TextButtonThemeData(
          style: _tvButtonStyle(prominent: false),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _premiumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.recordings ? 'DVR recordings' : 'Your files',
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.recordings
                      ? 'Browse and play recordings saved to your selected folders, inside Millitop.'
                      : 'Browse local or Windows network folders. Supported video, audio and photos open inside Millitop.',
                  style: const TextStyle(
                    fontSize: 20,
                    color: Colors.white70,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          _premiumPanel(
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: ValueKey(
                    widget.recordings ? 'add-dvr-folder' : 'add-library-folder',
                  ),
                  onPressed: busy || loading ? null : () => _add(),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: Text(
                    widget.recordings ? 'Add recordings folder' : 'Add folder',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh folders'),
                ),
                OutlinedButton.icon(
                  onPressed: metadataScanning
                      ? null
                      : () => unawaited(_scanMetadata()),
                  icon: Icon(
                    metadataScanning ? Icons.sync : Icons.movie_filter_outlined,
                  ),
                  label: Text(
                    metadataScanning
                        ? 'Scanning TMDB...'
                        : 'Scan TMDB metadata',
                  ),
                ),
              ],
            ),
          ),
          if (busy || loading) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (error.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(error, style: const TextStyle(color: Colors.orangeAccent)),
          ],
          if (metadataStatus.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              metadataStatus,
              style: TextStyle(
                color: context.millitopTheme.mutedColor,
                fontSize: 14,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (!loading && visible.isEmpty)
            Text(
              widget.recordings
                  ? 'No recordings folder selected yet. Choose the folder where your recorder saves its files.'
                  : 'No folders selected for this profile. Add a folder to get started.',
            ),
          _premiumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Library folders',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 18,
                  runSpacing: 18,
                  children: [
                    for (final folder in visible)
                      SizedBox(
                        width: 300,
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  widget.recordings
                                      ? Icons.video_library_outlined
                                      : Icons.folder_outlined,
                                  size: 44,
                                  color: context.millitopTheme.accentColor,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  folder.label,
                                  style: const TextStyle(fontSize: 24),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  folder.path,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(height: 1.35),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    FilledButton(
                                      onPressed: busy
                                          ? null
                                          : () => Navigator.of(context)
                                                .push<void>(
                                                  MaterialPageRoute<void>(
                                                    builder: (_) =>
                                                        LibraryBrowserScreen(
                                                          profileId:
                                                              widget.profileId,
                                                          folder: folder,
                                                          files: files,
                                                        ),
                                                  ),
                                                ),
                                      child: const Text('Browse'),
                                    ),
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => _remove(folder),
                                      child: const Text('Remove shortcut'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (!widget.recordings) ...[
            if (recentLiveTv.isNotEmpty) ...[
              _premiumPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Continue watching',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final item in recentLiveTv.take(4))
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder: (_) => LiveTvScreen(
                                        profileId: widget.profileId,
                                        initialSourceId: item.sourceId,
                                        initialChannelId: item.channelId,
                                      ),
                                    ),
                                  ),
                            icon: const Icon(Icons.play_arrow),
                            label: Text(
                              '${item.channelName} · ${item.sourceName}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(height: 1.3),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            _premiumPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick add',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final label in [
                        'Movies',
                        'TV Shows',
                        'Music',
                        'Family Photos',
                      ])
                        OutlinedButton(
                          onPressed: busy || loading ? null : () => _add(label),
                          child: Text('Add $label'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (widget.recordings) ...[
            _premiumPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Recording apps',
                    style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Set your recorder’s output folder to a folder added above. This page reads existing recordings; it does not schedule, start or stop a recording. Files still being written may not play completely.',
                    style: TextStyle(height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      LiveTvScreen(profileId: widget.profileId),
                                ),
                              ),
                        child: const Text('Open Live TV'),
                      ),
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => NativeAppLauncher.open(
                                context,
                                appKey: 'iptvnator',
                                title: 'IPTVnator',
                              ),
                        child: const Text('Open IPTVnator (legacy)'),
                      ),
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => NativeAppLauncher.open(
                                context,
                                appKey: 'vlc',
                                title: 'VLC player',
                              ),
                        child: const Text('Open VLC'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
