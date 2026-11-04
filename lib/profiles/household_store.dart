import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class HouseholdProfile {
  final int id;
  final String name;
  final String? avatarPath;

  const HouseholdProfile({
    required this.id,
    required this.name,
    this.avatarPath,
  });

  factory HouseholdProfile.fromRow(Map<String, Object?> row) {
    return HouseholdProfile(
      id: row['id'] as int,
      name: row['name'] as String,
      avatarPath: row['avatar_path'] as String?,
    );
  }
}

class HouseholdStore {
  HouseholdStore._();
  static final instance = HouseholdStore._();

  Database? _database;
  Future<void>? _initializing;
  late Directory dataDirectory;

  bool get isReady => _database != null;

  Future<void> initialize() {
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    sqfliteFfiInit();

    final support = await getApplicationSupportDirectory();
    dataDirectory = Directory(p.join(support.path, 'household'));
    await dataDirectory.create(recursive: true);

    _database = await databaseFactoryFfi.openDatabase(
      p.join(dataDirectory.path, 'household.sqlite'),
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE profiles (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              avatar_path TEXT,
              created_at TEXT NOT NULL
            )
          ''');

          await db.execute('''
            CREATE TABLE profile_settings (
              profile_id INTEGER NOT NULL,
              setting_key TEXT NOT NULL,
              value_json TEXT NOT NULL,
              PRIMARY KEY (profile_id, setting_key),
              FOREIGN KEY (profile_id) REFERENCES profiles(id)
                ON DELETE CASCADE
            )
          ''');

          await db.execute('''
            CREATE TABLE shortcuts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              profile_id INTEGER NOT NULL,
              label TEXT NOT NULL,
              kind TEXT NOT NULL,
              target TEXT NOT NULL,
              arguments_json TEXT NOT NULL DEFAULT '[]',
              sort_order INTEGER NOT NULL DEFAULT 0,
              FOREIGN KEY (profile_id) REFERENCES profiles(id)
                ON DELETE CASCADE
            )
          ''');

          await db.execute('''
            CREATE TABLE credential_references (
              profile_id INTEGER NOT NULL,
              service TEXT NOT NULL,
              secure_storage_key TEXT NOT NULL,
              PRIMARY KEY (profile_id, service),
              FOREIGN KEY (profile_id) REFERENCES profiles(id)
                ON DELETE CASCADE
            )
          ''');
        },
      ),
    );
  }

  Database get database {
    final db = _database;
    if (db == null) throw StateError('Household database is not initialized.');
    return db;
  }

  Future<List<HouseholdProfile>> profiles() async {
    final rows = await database.query('profiles', orderBy: 'id');
    return rows.map(HouseholdProfile.fromRow).toList();
  }

  Future<HouseholdProfile?> profileById(int id) async {
    final rows = await database.query(
      'profiles',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return HouseholdProfile.fromRow(rows.first);
  }

  Future<int> createProfile(String name) async {
    return database.insert('profiles', {
      'name': name.trim(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<int> upsertProfile(int id, String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty) {
      throw StateError('Profile name cannot be empty.');
    }
    final existing = await profileById(id);
    if (existing == null) {
      await database.insert('profiles', {
        'id': id,
        'name': cleaned,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      return id;
    }
    if (existing.name != cleaned) {
      await rename(id, cleaned);
    }
    return id;
  }

  Future<void> rename(int id, String name) async {
    await database.update(
      'profiles',
      {'name': name.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setAvatar(int id, String sourcePath) async {
    final avatars = Directory(p.join(dataDirectory.path, 'avatars'));
    await avatars.create(recursive: true);

    final extension = p.extension(sourcePath).toLowerCase();
    final destination = p.join(
      avatars.path,
      '$id-${DateTime.now().microsecondsSinceEpoch}$extension',
    );

    await File(sourcePath).copy(destination);

    final old = await database.query(
      'profiles',
      columns: ['avatar_path'],
      where: 'id = ?',
      whereArgs: [id],
    );

    await database.update(
      'profiles',
      {'avatar_path': destination},
      where: 'id = ?',
      whereArgs: [id],
    );

    final oldPath = old.isEmpty ? null : old.first['avatar_path'] as String?;
    if (oldPath != null && p.isWithin(avatars.path, oldPath)) {
      final file = File(oldPath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> setAvatarBytes(
    int id,
    List<int> bytes, {
    String extension = '.png',
  }) async {
    final avatars = Directory(p.join(dataDirectory.path, 'avatars'));
    await avatars.create(recursive: true);
    final normalizedExtension = extension.trim().isEmpty
        ? '.png'
        : extension.trim().toLowerCase();
    final safeExtension = normalizedExtension.startsWith('.')
        ? normalizedExtension
        : '.$normalizedExtension';
    final destination = p.join(
      avatars.path,
      '$id-${DateTime.now().microsecondsSinceEpoch}$safeExtension',
    );
    final file = File(destination);
    await file.writeAsBytes(bytes, flush: true);
    final old = await database.query(
      'profiles',
      columns: ['avatar_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (old.isEmpty) {
      if (await file.exists()) {
        await file.delete();
      }
      throw StateError('Profile was not found.');
    }
    await database.update(
      'profiles',
      {'avatar_path': destination},
      where: 'id = ?',
      whereArgs: [id],
    );
    final oldPath = old.first['avatar_path'] as String?;
    if (oldPath != null && p.isWithin(avatars.path, oldPath)) {
      final stale = File(oldPath);
      if (await stale.exists()) {
        await stale.delete();
      }
    }
  }

  Future<void> deleteProfile(int id) async {
    final rows = await database.query(
      'profiles',
      columns: ['avatar_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Profile was not found.');
    }

    final avatarPath = rows.first['avatar_path'] as String?;
    final removed = await database.delete(
      'profiles',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (removed != 1) {
      throw StateError('Profile could not be deleted.');
    }
    if (avatarPath != null && avatarPath.trim().isNotEmpty) {
      final avatars = Directory(p.join(dataDirectory.path, 'avatars'));
      if (p.isWithin(avatars.path, avatarPath)) {
        final file = File(avatarPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  Future<T?> setting<T>(int profileId, String key) async {
    final rows = await database.query(
      'profile_settings',
      where: 'profile_id = ? AND setting_key = ?',
      whereArgs: [profileId, key],
    );

    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['value_json'] as String) as T?;
  }

  Future<void> saveSetting(int profileId, String key, Object value) async {
    await database.insert('profile_settings', {
      'profile_id': profileId,
      'setting_key': key,
      'value_json': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
