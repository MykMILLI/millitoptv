import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../library/library_models.dart';
import '../library/library_repository.dart';
import '../library/library_file_service.dart';

class GalleryPreferences {
  final List<String> folderIds;
  final int seconds;
  final bool recursive, videos, shuffle, repeat, sound, limitVideos;
  const GalleryPreferences({
    this.folderIds = const [],
    this.seconds = 10,
    this.recursive = false,
    this.videos = true,
    this.shuffle = false,
    this.repeat = true,
    this.sound = false,
    this.limitVideos = false,
  });
  Map<String, dynamic> toJson() => {
    'folders': folderIds,
    'seconds': seconds,
    'recursive': recursive,
    'videos': videos,
    'shuffle': shuffle,
    'repeat': repeat,
    'sound': sound,
    'limitVideos': limitVideos,
  };
  factory GalleryPreferences.fromJson(Map<String, dynamic> data) {
    final ids = (data['folders'] as List).cast<String>();
    final seconds = data['seconds'] as int;
    if (ids.length > 10 ||
        ids.toSet().length != ids.length ||
        seconds < 3 ||
        seconds > 300) {
      throw const FormatException('Invalid slideshow settings.');
    }
    return GalleryPreferences(
      folderIds: List.unmodifiable(ids),
      seconds: seconds,
      recursive: data['recursive'] == true,
      videos: data['videos'] != false,
      shuffle: data['shuffle'] == true,
      repeat: data['repeat'] != false,
      sound: data['sound'] == true,
      limitVideos: data['limitVideos'] == true,
    );
  }
  GalleryPreferences copy({
    List<String>? folderIds,
    int? seconds,
    bool? recursive,
    bool? videos,
    bool? shuffle,
    bool? repeat,
    bool? sound,
    bool? limitVideos,
  }) => GalleryPreferences(
    folderIds: folderIds ?? this.folderIds,
    seconds: seconds ?? this.seconds,
    recursive: recursive ?? this.recursive,
    videos: videos ?? this.videos,
    shuffle: shuffle ?? this.shuffle,
    repeat: repeat ?? this.repeat,
    sound: sound ?? this.sound,
    limitVideos: limitVideos ?? this.limitVideos,
  );
}

class GalleryEntry {
  final LibraryFolder folder;
  final LibraryItem item;
  const GalleryEntry(this.folder, this.item);
}

class GalleryScan {
  final List<GalleryEntry> entries;
  final List<String> warnings;
  final bool limited;
  const GalleryScan(
    this.entries, {
    this.warnings = const [],
    this.limited = false,
  });
}

class GalleryLibrary {
  final MediaLibraryRepository repository;
  final LibraryFileService files;
  GalleryLibrary({
    MediaLibraryRepository? repository,
    LibraryFileService? files,
  }) : repository = repository ?? MediaLibraryRepository(),
       files = files ?? LibraryFileService();
  Future<GalleryPreferences> preferences(int profile) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'gallery.preferences.v2.$profile',
    );
    return raw == null
        ? const GalleryPreferences()
        : GalleryPreferences.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(int profile, GalleryPreferences value) async {
    final checked = GalleryPreferences.fromJson(value.toJson());
    if (!await (await SharedPreferences.getInstance()).setString(
      'gallery.preferences.v2.$profile',
      jsonEncode(checked.toJson()),
    )) {
      throw StateError('Could not save gallery settings.');
    }
  }

  Future<GalleryScan> scan(int profile, GalleryPreferences settings) async {
    final roots = await repository.load(profile);
    final queue = <(LibraryFolder, String)>[];
    final warnings = <String>[];
    for (final id in settings.folderIds) {
      final matches = roots.where((f) => f.id == id).toList();
      if (matches.isEmpty) {
        warnings.add(
          'A selected folder shortcut was removed. Choose its replacement in Gallery settings.',
        );
      } else {
        queue.add((matches.first, matches.first.path));
      }
    }
    final entries = <GalleryEntry>[], visited = <String>{};
    var dirs = 0;
    var limited = false;
    final watch = Stopwatch()..start();
    while (queue.isNotEmpty) {
      if (dirs >= 200 ||
          entries.length >= 2000 ||
          watch.elapsed > const Duration(seconds: 45)) {
        limited = true;
        break;
      }
      final (folder, path) = queue.removeAt(0);
      final key = '${folder.id}|$path';
      if (!visited.add(key)) {
        continue;
      }
      dirs++;
      try {
        final snap = await files.browse(folder, path);
        limited = limited || snap.limited;
        for (final item in snap.items) {
          if (item.kind == LibraryMediaKind.folder && settings.recursive) {
            queue.add((folder, item.path));
          }
          if (item.kind == LibraryMediaKind.image ||
              (settings.videos && item.kind == LibraryMediaKind.video)) {
            entries.add(GalleryEntry(folder, item));
            if (entries.length >= 2000) {
              limited = true;
              break;
            }
          }
        }
      } catch (_) {
        warnings.add(
          'Could not read ${folder.label}. Check the drive, network connection and Windows access.',
        );
      }
    }
    entries.sort(
      (a, b) => a.item.path.toLowerCase().compareTo(b.item.path.toLowerCase()),
    );
    return GalleryScan(
      List.unmodifiable(entries),
      warnings: List.unmodifiable(warnings.toSet()),
      limited: limited,
    );
  }
}

List<GalleryEntry> galleryOrder(
  List<GalleryEntry> entries,
  bool shuffle, {
  Random? random,
}) {
  final copy = List<GalleryEntry>.of(entries);
  if (shuffle) {
    copy.shuffle(random);
  }
  return copy;
}
