import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../library/library_models.dart';
import '../library/library_file_service.dart';
import 'library_media_screen.dart';
import '../library/recording_label.dart';
import '../services/library_metadata_service.dart';
import '../services/native_app_launcher.dart';
import '../theme/millitop_visual_theme.dart';

class LibraryBrowserScreen extends StatefulWidget {
  final int profileId;
  final LibraryFolder folder;
  final LibraryFileService? files;
  final Future<void> Function(BuildContext, String)? playRecording;
  const LibraryBrowserScreen({
    super.key,
    required this.profileId,
    required this.folder,
    this.files,
    this.playRecording,
  });
  @override
  State<LibraryBrowserScreen> createState() => _LibraryBrowserScreenState();
}

class _LibraryBrowserScreenState extends State<LibraryBrowserScreen> {
  late LibraryFileService files;
  late String directory;
  final history = <String>[];
  final search = TextEditingController();
  LibrarySnapshot? snapshot;
  final metadata = const LibraryMetadataService();
  Map<String, LibraryMetadataEntry> metadataCache =
      const <String, LibraryMetadataEntry>{};
  bool busy = true;
  String error = '';
  int generation = 0;
  @override
  void initState() {
    super.initState();
    files = widget.files ?? LibraryFileService();
    directory = widget.folder.path;
    unawaited(_load());
  }

  @override
  void dispose() {
    generation++;
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = ++generation;
    setState(() {
      busy = true;
      error = '';
      snapshot = null;
    });
    try {
      final result = await files.browse(widget.folder, directory);
      if (!mounted || token != generation) {
        return;
      }
      setState(() {
        snapshot = result;
        directory = result.directory;
      });
      final cache = await metadata.loadCache(widget.profileId);
      if (!mounted || token != generation) {
        return;
      }
      setState(() => metadataCache = cache);
    } catch (e) {
      if (mounted && token == generation) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && token == generation) {
        setState(() => busy = false);
      }
    }
  }

  void _back() {
    if (search.text.isNotEmpty) {
      setState(search.clear);
      return;
    }
    if (history.isNotEmpty) {
      directory = history.removeLast();
      unawaited(_load());
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _open(LibraryItem item) async {
    if (busy) {
      return;
    }
    if (item.kind == LibraryMediaKind.folder) {
      history.add(directory);
      directory = item.path;
      search.clear();
      await _load();
      return;
    }
    if (!item.playable && item.kind != LibraryMediaKind.image) {
      return;
    }
    setState(() => busy = true);
    try {
      final verified = await files.resolveMedia(widget.folder, item);
      if (!mounted) {
        return;
      }
      if (widget.folder.recordings) {
        final play = widget.playRecording;
        if (play != null) {
          await play(context, verified);
        } else {
          await NativeAppLauncher.open(
            context,
            appKey: 'vlc',
            title: 'VLC player',
            mediaPath: verified,
          );
        }
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => LibraryMediaScreen(
            profileId: widget.profileId,
            folder: widget.folder,
            item: LibraryItem(path: verified, name: item.name, kind: item.kind),
            files: files,
          ),
        ),
      );
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

  IconData icon(LibraryMediaKind kind) => switch (kind) {
    LibraryMediaKind.folder => Icons.folder_outlined,
    LibraryMediaKind.video => Icons.movie_outlined,
    LibraryMediaKind.audio => Icons.music_note,
    LibraryMediaKind.image => Icons.image_outlined,
    LibraryMediaKind.unsupported => Icons.insert_drive_file_outlined,
  };
  @override
  Widget build(BuildContext context) {
    final accent = context.millitopTheme.accentColor;
    final query = search.text.toLowerCase();
    final items = (snapshot?.items ?? <LibraryItem>[])
        .where(
          (item) =>
              (widget.folder.recordings
                      ? '${RecordingLabel.fromFilename(item.name).channel} ${RecordingLabel.fromFilename(item.name).subtitle}'
                      : item.name)
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    if (widget.folder.recordings) {
      items.sort((a, b) {
        if (a.kind == LibraryMediaKind.folder &&
            b.kind != LibraryMediaKind.folder) {
          return -1;
        }
        if (b.kind == LibraryMediaKind.folder &&
            a.kind != LibraryMediaKind.folder) {
          return 1;
        }
        final ad = RecordingLabel.fromFilename(a.name).recordedAt;
        final bd = RecordingLabel.fromFilename(b.name).recordedAt;
        if (ad != null && bd != null) return bd.compareTo(ad);
        if (ad != null) return -1;
        if (bd != null) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    }
    return PopScope(
      canPop: history.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _back();
        }
      },
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _back},
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back',
            ),
            title: Text(widget.folder.label),
            actions: [
              IconButton(
                onPressed: busy ? null : _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh folder',
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.folder.recordings)
                      SelectableText(
                        directory,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    if (widget.folder.recordings)
                      const Text(
                        'Choose a recording to watch in VLC.',
                        style: TextStyle(fontSize: 20),
                      ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: widget.folder.recordings
                            ? 'Find a channel or recording date'
                            : 'Search loaded items in this folder',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (snapshot?.limited == true)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Showing the first 2,000 directory entries. More entries may exist. Search filters only this loaded list.',
                        ),
                      ),
                    if (error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error,
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                  ],
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              Expanded(
                child: !busy && items.isEmpty
                    ? Center(
                        child: Text(
                          error.isEmpty
                              ? 'No matching files or folders.'
                              : 'Folder contents unavailable. Use Back or Refresh.',
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final supported =
                              item.kind != LibraryMediaKind.unsupported;
                          final recording =
                              widget.folder.recordings &&
                              item.kind != LibraryMediaKind.folder;
                          final label = RecordingLabel.fromFilename(item.name);
                          final enriched = metadataCache[item.path];
                          final title = enriched?.title.trim() ?? '';
                          final overview = enriched?.overview?.trim() ?? '';
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            leading:
                                enriched?.posterUrl != null &&
                                    item.kind != LibraryMediaKind.folder
                                ? CircleAvatar(
                                    backgroundImage: NetworkImage(
                                      enriched!.posterUrl!,
                                    ),
                                  )
                                : Icon(
                                    icon(item.kind),
                                    color: supported ? accent : Colors.white38,
                                  ),
                            title: Text(
                              title.isNotEmpty
                                  ? title
                                  : (recording ? label.channel : item.name),
                              style: recording
                                  ? const TextStyle(
                                      fontSize: 23,
                                      fontWeight: FontWeight.w600,
                                    )
                                  : null,
                            ),
                            subtitle: Text(
                              recording
                                  ? label.subtitle
                                  : overview.isNotEmpty
                                  ? overview
                                  : item.kind == LibraryMediaKind.folder
                                  ? 'Folder'
                                  : supported
                                  ? '${item.kind.name} · ${p.extension(item.name).replaceFirst('.', '').toUpperCase()}'
                                  : 'Not supported in Millitop; not launched externally',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: recording
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.play_circle_fill,
                                        color: accent,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Play',
                                        style: TextStyle(fontSize: 18),
                                      ),
                                    ],
                                  )
                                : supported
                                ? const Icon(Icons.chevron_right)
                                : null,
                            enabled: !busy && supported,
                            onTap: () => _open(item),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
