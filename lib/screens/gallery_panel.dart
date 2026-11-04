import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../library/library_models.dart';
import '../library/library_file_service.dart';
import '../services/gallery_library.dart';
import 'gallery_slideshow.dart';

Future<void> editGallerySettings(
  BuildContext context,
  int profile, {
  GalleryLibrary? library,
}) async {
  final service = library ?? GalleryLibrary();
  GalleryPreferences value;
  List<LibraryFolder> roots;
  try {
    value = await service.preferences(profile);
    roots = await service.repository.load(profile);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Gallery settings could not be loaded. Existing settings were not cleared.',
          ),
        ),
      );
    }
    return;
  }
  if (!context.mounted) {
    return;
  }
  var saving = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> save() async {
          if (saving) {
            return;
          }
          setLocal(() => saving = true);
          try {
            await service.save(profile, value);
            if (ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
              Navigator.pop(ctx);
            }
          } catch (_) {
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text('Could not save gallery settings.'),
                ),
              );
              setLocal(() => saving = false);
            }
          }
        }

        Future<void> add() async {
          if (saving || value.folderIds.length >= 10) {
            return;
          }
          try {
            final path = await getDirectoryPath(
              confirmButtonText: 'Use family folder',
            );
            if (path == null) {
              return;
            }
            final resolved = await service.files.validateFolder(path);
            await service.repository.add(
              profile,
              path: resolved,
              label: 'Family moments',
            );
            final updated = await service.repository.load(profile);
            final selected = updated.firstWhere(
              (r) => !r.recordings && p.equals(r.path, resolved),
            );
            if (ctx.mounted) {
              setLocal(() {
                roots = updated;
                value = value.copy(
                  folderIds: {...value.folderIds, selected.id}.toList(),
                );
              });
            }
          } catch (_) {
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Could not add that folder. Check Windows access or the network connection.',
                  ),
                ),
              );
            }
          }
        }

        final intervals = <int>{
          3,
          5,
          10,
          15,
          30,
          60,
          120,
          300,
          value.seconds,
        }.toList()..sort();
        return AlertDialog(
          title: const Text('Gallery settings'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select up to 10 existing library folders or add a family folder. Network folders use your Windows account.',
                  ),
                  for (final root in roots.where((r) => !r.recordings))
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(root.label),
                      subtitle: Text(
                        root.path,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: value.folderIds.contains(root.id),
                      onChanged: (checked) {
                        if (checked == true && value.folderIds.length >= 10) {
                          return;
                        }
                        setLocal(
                          () => value = value.copy(
                            folderIds: checked == true
                                ? [...value.folderIds, root.id]
                                : value.folderIds
                                      .where((id) => id != root.id)
                                      .toList(),
                          ),
                        );
                      },
                    ),
                  TextButton.icon(
                    onPressed: add,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Add family folder'),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: value.seconds,
                    decoration: const InputDecoration(
                      labelText: 'Photo display time',
                    ),
                    items: intervals
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text('$s seconds'),
                          ),
                        )
                        .toList(),
                    onChanged: (s) {
                      if (s != null) {
                        setLocal(() => value = value.copy(seconds: s));
                      }
                    },
                  ),
                  CheckboxListTile(
                    title: const Text('Include subfolders'),
                    value: value.recursive,
                    onChanged: (v) =>
                        setLocal(() => value = value.copy(recursive: v)),
                  ),
                  CheckboxListTile(
                    title: const Text('Include videos'),
                    value: value.videos,
                    onChanged: (v) =>
                        setLocal(() => value = value.copy(videos: v)),
                  ),
                  CheckboxListTile(
                    title: const Text(
                      'Advance videos after the selected interval',
                    ),
                    subtitle: const Text(
                      'Off: let each video finish. On: limit videos to the photo interval.',
                    ),
                    value: value.limitVideos,
                    onChanged: (v) =>
                        setLocal(() => value = value.copy(limitVideos: v)),
                  ),
                  CheckboxListTile(
                    title: const Text('Play video sound'),
                    value: value.sound,
                    onChanged: (v) =>
                        setLocal(() => value = value.copy(sound: v)),
                  ),
                  CheckboxListTile(
                    title: const Text('Shuffle slideshow'),
                    value: value.shuffle,
                    onChanged: (v) =>
                        setLocal(() => value = value.copy(shuffle: v)),
                  ),
                  CheckboxListTile(
                    title: const Text('Repeat slideshow'),
                    value: value.repeat,
                    onChanged: (v) =>
                        setLocal(() => value = value.copy(repeat: v)),
                  ),
                  const Text(
                    'Scanning is bounded to 2,000 media items, 200 folders and a time budget. Folder and slideshow preferences are saved for this profile.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving ? 'Saving...' : 'Save gallery'),
            ),
          ],
        );
      },
    ),
  );
}

class GalleryPanel extends StatefulWidget {
  final int profileId;
  final GalleryLibrary? library;
  const GalleryPanel({super.key, required this.profileId, this.library});
  @override
  State<GalleryPanel> createState() => _GalleryPanelState();
}

class _GalleryPanelState extends State<GalleryPanel> {
  late GalleryLibrary library;
  GalleryPreferences? settings;
  GalleryScan? scan;
  bool loading = true;
  String error = '';
  int generation = 0;
  @override
  void initState() {
    super.initState();
    library = widget.library ?? GalleryLibrary();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant GalleryPanel old) {
    super.didUpdateWidget(old);
    if (old.profileId != widget.profileId || old.library != widget.library) {
      library = widget.library ?? GalleryLibrary();
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final token = ++generation;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final preferences = await library.preferences(widget.profileId);
      final result = await library.scan(widget.profileId, preferences);
      if (mounted && token == generation) {
        setState(() {
          settings = preferences;
          scan = result;
        });
      }
    } catch (_) {
      if (mounted && token == generation) {
        setState(
          () => error =
              'Gallery could not be loaded. Check its settings and folder access.',
        );
      }
    } finally {
      if (mounted && token == generation) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _settings() async {
    await editGallerySettings(context, widget.profileId, library: library);
    if (mounted) {
      await _load();
    }
  }

  Future<void> _open([int? index]) async {
    final entries = scan?.entries ?? [];
    if (entries.isEmpty || settings == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GallerySlideshow(
          entries: entries,
          preferences: index == null
              ? settings!
              : settings!.copy(shuffle: false),
          initialIndex: index ?? 0,
        ),
      ),
    );
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = scan?.entries ?? <GalleryEntry>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Family moments',
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        const Text(
          'Your family photos and videos, inside Millitop. Settings and selected folders are saved separately for each profile.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: loading || entries.isEmpty ? null : () => _open(),
              icon: const Icon(Icons.slideshow),
              label: const Text('Start slideshow'),
            ),
            OutlinedButton.icon(
              onPressed: loading ? null : _settings,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folders / settings'),
            ),
            TextButton(
              onPressed: loading ? null : _load,
              child: const Text('Refresh gallery'),
            ),
            if (entries.length > 24)
              TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        _GalleryGrid(entries: entries, onOpen: (i) => _open(i)),
                  ),
                ),
                child: const Text('Browse all media'),
              ),
          ],
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(color: Colors.orangeAccent)),
        if (!loading && entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'No photos or videos available. Choose a family folder, enable video inclusion if needed, then Refresh.',
            ),
          ),
        if (scan?.limited == true)
          const Text(
            'Scan limit reached. Choose a more specific folder to include a different selection.',
          ),
        for (final warning in scan?.warnings ?? <String>[])
          Text(warning, style: const TextStyle(color: Colors.orangeAccent)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var i = 0; i < entries.length && i < 24; i++)
              SizedBox(
                width: 220,
                height: 180,
                child: _GalleryTile(entry: entries[i], onTap: () => _open(i)),
              ),
          ],
        ),
      ],
    );
  }
}

class _GalleryGrid extends StatelessWidget {
  final List<GalleryEntry> entries;
  final Future<void> Function(int) onOpen;
  const _GalleryGrid({required this.entries, required this.onOpen});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Gallery')),
    body: GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        childAspectRatio: 1.3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: entries.length,
      itemBuilder: (_, i) =>
          _GalleryTile(entry: entries[i], onTap: () => onOpen(i)),
    ),
  );
}

class _GalleryTile extends StatefulWidget {
  final GalleryEntry entry;
  final VoidCallback onTap;
  const _GalleryTile({required this.entry, required this.onTap});
  @override
  State<_GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<_GalleryTile> {
  Future<String>? path;
  void _prepare() {
    path = widget.entry.item.kind == LibraryMediaKind.image
        ? LibraryFileService().resolveMedia(
            widget.entry.folder,
            widget.entry.item,
          )
        : null;
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant _GalleryTile old) {
    super.didUpdateWidget(old);
    if (old.entry.item.path != widget.entry.item.path ||
        old.entry.folder.id != widget.entry.folder.id) {
      _prepare();
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Expanded(
              child: path == null
                  ? const Icon(Icons.movie_outlined, size: 60)
                  : FutureBuilder<String>(
                      future: path,
                      builder: (ctx, snapshot) => snapshot.hasData
                          ? Image.file(
                              File(snapshot.data!),
                              cacheWidth: 256,
                              fit: BoxFit.contain,
                              errorBuilder: (_, e, s) =>
                                  const Icon(Icons.broken_image_outlined),
                            )
                          : const Icon(Icons.image_outlined, size: 50),
                    ),
            ),
            Text(
              widget.entry.item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ),
  );
}
