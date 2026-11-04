import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'device_connection.dart';

class RemoteNotice {
  final Map<String, Object?> row;
  final Map<String, dynamic> content;
  RemoteNotice(this.row)
    : content = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
  String get id => row['delivery_id'] as String;
  String get title => content['title'] as String;
  String get body => content['body'] as String;
  bool get requiresAck => content['requiresAck'] == true;
  bool get opened => row['opened_at'] != null;
  bool get acknowledged => row['ack_at'] != null;
  bool get ackSynced => row['ack_synced'] == 1;
  String get published => content['publishedAt'] as String;
}

class RemoteInbox {
  RemoteInbox._();
  static final instance = RemoteInbox._();
  final notices = ValueNotifier<List<RemoteNotice>>([]);
  final syncState = ValueNotifier<String>('Messages not connected');
  final _notifications = <LocalNotification>[];
  Database? _db;
  Future<void>? _starting;
  Timer? _timer;
  bool _busy = false;
  bool _notificationsReady = false;
  String _visibleKey = '';
  DeviceConnection get link => DeviceConnection.instance;

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    sqfliteFfiInit();
    final support = await getApplicationSupportDirectory();
    _db = await databaseFactoryFfi.openDatabase(
      p.join(support.path, 'device-messages.sqlite'),
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE inbox (connection_key TEXT NOT NULL, delivery_id TEXT NOT NULL, payload TEXT NOT NULL, published TEXT NOT NULL, opened_at TEXT, ack_at TEXT, ack_synced INTEGER NOT NULL DEFAULT 0, notified INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(connection_key, delivery_id))',
          );
          await db.execute(
            'CREATE TABLE outbox (id TEXT PRIMARY KEY, connection_key TEXT NOT NULL, delivery_id TEXT NOT NULL, kind TEXT NOT NULL, event_json TEXT NOT NULL)',
          );
        },
      ),
    );
    try {
      await localNotifier.setup(
        appName: 'MILLITOP TV',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _notificationsReady = true;
    } catch (_) {
      syncState.value =
          'Windows notifications unavailable; messages still saved';
    }
    link.status.addListener(_connectionChanged);
    await _load();
    unawaited(sync());
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(sync()),
    );
  }

  void _connectionChanged() {
    if (_db == null) return;
    if (_visibleKey != link.connectionKey) {
      notices.value = [];
      unawaited(_load().catchError((Object _) {}));
    }
    if (link.isConnected) unawaited(sync());
  }

  Future<void> _load() async {
    final db = _db;
    if (db == null) return;
    final key = link.connectionKey;
    _visibleKey = key;
    if (key.isEmpty) {
      notices.value = [];
      return;
    }
    final rows = await db.query(
      'inbox',
      where: 'connection_key = ?',
      whereArgs: [key],
      orderBy: 'published DESC, delivery_id DESC',
    );
    if (link.connectionKey == key) {
      notices.value = rows.map(RemoteNotice.new).toList();
    }
  }

  Future<void> _queue(
    DatabaseExecutor db,
    String key,
    String id,
    String kind,
    String? profile,
  ) async {
    final eventId = const Uuid().v4();
    final event = {
      'id': eventId,
      'deliveryId': id,
      'kind': kind,
      'profileId': profile,
    };
    await db.insert('outbox', {
      'id': eventId,
      'connection_key': key,
      'delivery_id': id,
      'kind': kind,
      'event_json': jsonEncode(event),
    });
  }

  Future<void> recordAction(String id, String kind, int profileId) async {
    final db = _db;
    final key = link.connectionKey;
    if (db == null || key.isEmpty) {
      throw StateError('No device inbox is available.');
    }
    if (kind != 'opened' && kind != 'acknowledged') {
      throw ArgumentError('Invalid receipt kind.');
    }
    await db.transaction((tx) async {
      final rows = await tx.query(
        'inbox',
        where: 'connection_key = ? AND delivery_id = ?',
        whereArgs: [key, id],
      );
      if (rows.isEmpty) {
        throw StateError('Message is not cached for this device.');
      }
      final row = rows.first;
      final content =
          jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (kind == 'acknowledged' && content['requiresAck'] != true) {
        throw StateError('Acknowledgement is not requested.');
      }
      final field = kind == 'opened' ? 'opened_at' : 'ack_at';
      if (row[field] != null) return;
      await tx.update(
        'inbox',
        {field: DateTime.now().toUtc().toIso8601String()},
        where: 'connection_key = ? AND delivery_id = ?',
        whereArgs: [key, id],
      );
      await _queue(tx, key, id, kind, profileId.toString());
    });
    await _load();
    unawaited(sync());
  }

  Future<void> _flush(String key) async {
    final db = _db!;
    while (true) {
      final pending = await db.query(
        'outbox',
        where: 'connection_key = ?',
        whereArgs: [key],
        limit: 50,
      );
      if (pending.isEmpty) return;
      final response = await link.postDevice('/api/device/receipts', {
        'events': pending
            .map((r) => jsonDecode(r['event_json'] as String))
            .toList(),
      }, expectedConnection: key);
      final accepted = Set<String>.from(response['accepted'] as List);
      if (pending.any((r) => !accepted.contains(r['id']))) {
        throw StateError('Some receipts remain unconfirmed.');
      }
      await db.transaction((tx) async {
        for (final event in pending) {
          if (event['kind'] == 'acknowledged') {
            await tx.update(
              'inbox',
              {'ack_synced': 1},
              where: 'connection_key = ? AND delivery_id = ?',
              whereArgs: [key, event['delivery_id']],
            );
          }
          await tx.delete(
            'outbox',
            where: 'id = ? AND connection_key = ?',
            whereArgs: [event['id'], key],
          );
        }
      });
    }
  }

  Future<void> sync() async {
    if (_busy || _db == null) return;
    _busy = true;
    final key = link.connectionKey;
    try {
      await _load();
      if (key.isEmpty || !link.isConnected) {
        syncState.value = 'Offline cache; receipts will retry when connected';
        return;
      }
      syncState.value = 'Checking for messages';
      await _flush(key);
      String? cursor;
      do {
        final response = await link.postDevice('/api/device/messages', {
          'cursor': cursor,
        }, expectedConnection: key);
        final messages = response['messages'] as List;
        for (final item in messages) {
          final message = Map<String, dynamic>.from(item as Map);
          final id = message['deliveryId'] as String;
          if (message['title'] is! String ||
              message['body'] is! String ||
              message['publishedAt'] is! String ||
              message['requiresAck'] is! bool) {
            throw const FormatException('Invalid message.');
          }
          await _db!.transaction((tx) async {
            final existing = await tx.query(
              'inbox',
              columns: ['delivery_id'],
              where: 'connection_key = ? AND delivery_id = ?',
              whereArgs: [key, id],
            );
            if (existing.isNotEmpty) return;
            await tx.insert('inbox', {
              'connection_key': key,
              'delivery_id': id,
              'payload': jsonEncode(message),
              'published': message['publishedAt'],
            });
            // A delivery receipt is queued only after the durable cache write.
            await _queue(tx, key, id, 'delivered', null);
          });
        }
        cursor = response['nextCursor'] as String?;
      } while (cursor != null);
      await _flush(key);
      await _load();
      if (link.connectionKey != key) return;
      if (_notificationsReady) {
        final unnotified = await _db!.query(
          'inbox',
          where: 'connection_key = ? AND notified = 0',
          whereArgs: [key],
          orderBy: 'published',
        );
        for (final row in unnotified) {
          if (link.connectionKey != key) return;
          final notice = RemoteNotice(row);
          try {
            final notification = LocalNotification(
              title: notice.title,
              body: notice.body.length > 250
                  ? '${notice.body.substring(0, 250)}…'
                  : notice.body,
            );
            _notifications.add(notification);
            await notification.show();
            await _db!.update(
              'inbox',
              {'notified': 1},
              where: 'connection_key = ? AND delivery_id = ?',
              whereArgs: [key, notice.id],
            );
            if (_notifications.length > 30) _notifications.removeAt(0);
          } catch (_) {
            /* The message remains available in Updates. */
          }
        }
      }
      syncState.value = 'Messages synced';
    } catch (_) {
      syncState.value =
          'Message sync pending; cached messages remain available';
    } finally {
      _busy = false;
      await _load().catchError((Object _) {});
    }
  }

  void stop() {
    _timer?.cancel();
  }
}
