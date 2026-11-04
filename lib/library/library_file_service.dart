import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'library_models.dart';

class LibraryFileService {
  static const maximumEntries = 2000;
  static const maximumImageBytes = 104857600;

  Future<String> validateFolder(String path) async {
    try {
      if (!p.isAbsolute(path) ||
          path.contains('\u0000') ||
          path.startsWith('\\\\.\\') ||
          path.toUpperCase().startsWith(r'\\?\GLOBALROOT')) {
        throw const LibraryProblem('Choose a normal local or network folder.');
      }
      final resolved = await Directory(
        path,
      ).resolveSymbolicLinks().timeout(const Duration(seconds: 12));
      if (!await Directory(
        resolved,
      ).exists().timeout(const Duration(seconds: 8))) {
        throw const LibraryProblem('The selected folder is unavailable.');
      }
      return resolved;
    } on LibraryProblem {
      rethrow;
    } on TimeoutException {
      throw const LibraryProblem(
        'Windows did not respond to the folder request in time. Check the drive or network and try again.',
      );
    } catch (_) {
      throw const LibraryProblem(
        'The folder is unavailable or Windows denied access. Check the drive/network connection and your Windows permissions.',
      );
    }
  }

  Future<LibrarySnapshot> browse(LibraryFolder folder, String path) async {
    try {
      final root = await validateFolder(folder.path);
      final directory = await validateFolder(path);
      if (!libraryContains(root, directory)) {
        throw const LibraryProblem(
          'This folder is outside the selected library root.',
        );
      }
      return await _list(
        directory,
        folder.recordings,
      ).timeout(const Duration(seconds: 20));
    } on LibraryProblem {
      rethrow;
    } catch (_) {
      throw const LibraryProblem(
        'Could not read this folder. Check access or network availability, then try Refresh.',
      );
    }
  }

  Future<LibrarySnapshot> _list(String directory, bool recordings) async {
    final items = <LibraryItem>[];
    var seen = 0;
    var limited = false;
    await for (final entity in Directory(
      directory,
    ).list(followLinks: false).timeout(const Duration(seconds: 12))) {
      seen++;
      if (seen > maximumEntries) {
        limited = true;
        break;
      }
      if (entity is Link) {
        continue;
      }
      final kind = entity is Directory
          ? LibraryMediaKind.folder
          : libraryMediaKind(entity.path);
      if (recordings &&
          kind != LibraryMediaKind.folder &&
          kind != LibraryMediaKind.video &&
          kind != LibraryMediaKind.audio) {
        continue;
      }
      items.add(
        LibraryItem(
          path: entity.path,
          name: p.basename(entity.path),
          kind: kind,
        ),
      );
    }
    items.sort((a, b) {
      if (a.kind == LibraryMediaKind.folder &&
          b.kind != LibraryMediaKind.folder) {
        return -1;
      }
      if (b.kind == LibraryMediaKind.folder &&
          a.kind != LibraryMediaKind.folder) {
        return 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return LibrarySnapshot(
      directory,
      List.unmodifiable(items),
      limited: limited,
    );
  }

  Future<String> resolveMedia(LibraryFolder folder, LibraryItem item) async {
    if (!item.playable && item.kind != LibraryMediaKind.image) {
      throw const LibraryProblem(
        'This file type cannot be opened inside Millitop.',
      );
    }
    try {
      final root = await validateFolder(folder.path);
      if (await FileSystemEntity.type(
            item.path,
            followLinks: false,
          ).timeout(const Duration(seconds: 8)) !=
          FileSystemEntityType.file) {
        throw const LibraryProblem(
          'Links and non-file entries are not opened.',
        );
      }
      final resolved = await File(
        item.path,
      ).resolveSymbolicLinks().timeout(const Duration(seconds: 12));
      if (!libraryContains(root, resolved) ||
          libraryMediaKind(resolved) != item.kind) {
        throw const LibraryProblem(
          'The file is outside this library or its type changed.',
        );
      }
      if (item.kind == LibraryMediaKind.image &&
          await File(resolved).length().timeout(const Duration(seconds: 8)) >
              maximumImageBytes) {
        throw const LibraryProblem(
          'This image is too large for the built-in preview (100 MB limit).',
        );
      }
      return resolved;
    } on LibraryProblem {
      rethrow;
    } catch (_) {
      throw const LibraryProblem(
        'The file is missing, still being written, or Windows denied access. Refresh the folder and try again.',
      );
    }
  }
}
