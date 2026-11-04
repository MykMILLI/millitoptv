import 'package:path/path.dart' as p;

enum LibraryMediaKind { folder, video, audio, image, unsupported }

class LibraryProblem implements Exception {
  final String message;
  const LibraryProblem(this.message);
  @override
  String toString() => message;
}

LibraryMediaKind libraryMediaKind(String path) {
  final extension = p.extension(path).toLowerCase();
  if (const {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.m4v',
    '.webm',
    '.ts',
    '.m2ts',
    '.mts',
    '.mpg',
    '.mpeg',
    '.wmv',
    '.vob',
    '.flv',
    '.3gp',
    '.ogv',
    '.wtv',
    '.dvr-ms',
  }.contains(extension)) {
    return LibraryMediaKind.video;
  }
  if (const {
    '.mp3',
    '.flac',
    '.wav',
    '.m4a',
    '.aac',
    '.ogg',
    '.opus',
    '.wma',
    '.aiff',
  }.contains(extension)) {
    return LibraryMediaKind.audio;
  }
  if (const {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.gif',
  }.contains(extension)) {
    return LibraryMediaKind.image;
  }
  return LibraryMediaKind.unsupported;
}

class LibraryFolder {
  final String id, label, path;
  final bool recordings;
  const LibraryFolder({
    required this.id,
    required this.label,
    required this.path,
    this.recordings = false,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'path': path,
    'recordings': recordings,
  };
  factory LibraryFolder.fromJson(Map<String, dynamic> data) {
    final id = data['id'] as String;
    final label = data['label'] as String;
    final path = data['path'] as String;
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id) ||
        label.trim().isEmpty ||
        label.length > 80 ||
        path.isEmpty ||
        !p.isAbsolute(path) ||
        path.contains('\u0000') ||
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(path)) {
      throw const FormatException('Invalid saved folder.');
    }
    return LibraryFolder(
      id: id,
      label: label,
      path: path,
      recordings: data['recordings'] == true,
    );
  }
}

class LibraryItem {
  final String path, name;
  final LibraryMediaKind kind;
  const LibraryItem({
    required this.path,
    required this.name,
    required this.kind,
  });
  bool get playable =>
      kind == LibraryMediaKind.video || kind == LibraryMediaKind.audio;
}

class LibrarySnapshot {
  final String directory;
  final List<LibraryItem> items;
  final bool limited;
  const LibrarySnapshot(this.directory, this.items, {this.limited = false});
}

bool libraryContains(String root, String target, {p.Context? context}) {
  final paths = context ?? p.context;
  return paths.equals(root, target) || paths.isWithin(root, target);
}
