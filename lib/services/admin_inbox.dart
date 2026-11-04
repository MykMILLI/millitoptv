import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

class AdminNotice {
  final String id;
  final String title;
  final String body;

  const AdminNotice({
    required this.id,
    required this.title,
    required this.body,
  });

  factory AdminNotice.fromJson(Map<String, dynamic> json) {
    return AdminNotice(
      id: json['id'] as String,
      title: json['title'] as String,
      body: json['body'] as String,
    );
  }
}

class AdminInbox {
  AdminInbox._();
  static final instance = AdminInbox._();

  final notices = ValueNotifier<List<AdminNotice>>([]);
  final Set<String> seen = {};
  final List<LocalNotification> activeNotifications = [];

  Timer? timer;
  bool busy = false;
  bool notificationReady = false;

  Directory get directory {
    final root = Platform.environment['LOCALAPPDATA'];
    if (root == null) {
      throw StateError('LOCALAPPDATA is unavailable.');
    }
    return Directory('$root\\MILLITOPTV');
  }

  File get inboxFile => File('${directory.path}\\admin-inbox.json');
  File get seenFile => File('${directory.path}\\admin-seen.json');

  Future<void> start() async {
    await directory.create(recursive: true);

    if (await seenFile.exists()) {
      try {
        final values = jsonDecode(await seenFile.readAsString()) as List;
        seen.addAll(values.cast<String>());
      } catch (error) {
        debugPrint('Could not read notification history: $error');
      }
    }

    if (!await inboxFile.exists()) {
      await inboxFile.writeAsString('[]');
    }

    try {
      await localNotifier.setup(
        appName: 'MILLITOP TV',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      notificationReady = true;
    } catch (error) {
      debugPrint('Windows notification setup failed: $error');
    }

    await refresh();
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  Future<void> refresh() async {
    if (busy) return;
    busy = true;

    try {
      final raw = jsonDecode(await inboxFile.readAsString()) as List;

      final incoming = raw.map((item) {
        return AdminNotice.fromJson(Map<String, dynamic>.from(item as Map));
      }).toList();

      notices.value = List.unmodifiable(incoming);

      for (final notice in incoming) {
        if (seen.contains(notice.id) || !notificationReady) continue;

        final notification = LocalNotification(
          title: notice.title,
          body: notice.body,
        );

        activeNotifications.add(notification);

        try {
          await notification.show();
          seen.add(notice.id);

          await seenFile.writeAsString(jsonEncode(seen.toList()), flush: true);

          if (activeNotifications.length > 30) {
            activeNotifications.removeAt(0);
          }
        } catch (error) {
          debugPrint('Could not show admin notification: $error');
          activeNotifications.remove(notification);
        }
      }
    } catch (error) {
      debugPrint('Admin inbox read failed: $error');
    } finally {
      busy = false;
    }
  }
}
