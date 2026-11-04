import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'library_models.dart';

class MediaLibraryRepository {
  static final Map<int, Future<void>> _writes = {};
  String _key(int profileId) => 'library.folders.v1.$profileId';
  Future<List<LibraryFolder>> load(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(profileId));
    if (raw == null) {
      return [];
    }
    try {
      final values = (jsonDecode(raw) as List)
          .map(
            (value) =>
                LibraryFolder.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
      if (values.map((value) => value.id).toSet().length != values.length) {
        throw const FormatException('Duplicate folder IDs.');
      }
      return values;
    } catch (_) {
      throw const LibraryProblem(
        'Saved folders could not be read. They have not been cleared or overwritten.',
      );
    }
  }

  Future<void> _update(
    int profileId,
    List<LibraryFolder> Function(List<LibraryFolder>) change,
  ) async {
    final previous = _writes[profileId] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then<void>((_) async {
      final folders = change(await load(profileId));
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        _key(profileId),
        jsonEncode(folders.map((f) => f.toJson()).toList()),
      )) {
        throw const LibraryProblem(
          'Windows could not save the folder shortcut.',
        );
      }
    });
    _writes[profileId] = next;
    try {
      await next;
    } finally {
      if (identical(_writes[profileId], next)) {
        _writes.remove(profileId);
      }
    }
  }

  Future<void> add(
    int profileId, {
    required String path,
    required String label,
    bool recordings = false,
  }) async {
    final clean = label.trim();
    if (clean.isEmpty || clean.length > 80 || !p.isAbsolute(path)) {
      throw const LibraryProblem(
        'Choose a folder and a label of 1–80 characters.',
      );
    }
    await _update(profileId, (folders) {
      final existing = folders.indexWhere(
        (f) => p.equals(f.path, path) && f.recordings == recordings,
      );
      if (existing >= 0) {
        folders[existing] = LibraryFolder(
          id: folders[existing].id,
          label: clean,
          path: path,
          recordings: recordings,
        );
      } else {
        if (folders.length >= 100) {
          throw const LibraryProblem(
            'This profile already has 100 folder shortcuts. Remove a shortcut before adding another.',
          );
        }
        folders.add(
          LibraryFolder(
            id: const Uuid().v4(),
            label: clean,
            path: path,
            recordings: recordings,
          ),
        );
      }
      return folders;
    });
  }

  Future<void> remove(int profileId, String id) => _update(
    profileId,
    (folders) => folders.where((f) => f.id != id).toList(),
  );
}
