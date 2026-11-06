import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class GroupSessionMember {
  final String deviceId;
  final String label;
  const GroupSessionMember({required this.deviceId, required this.label});

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'label': label,
  };

  static GroupSessionMember fromJson(Map<String, dynamic> json) {
    return GroupSessionMember(
      deviceId: json['deviceId']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
    );
  }
}

class GroupListeningSession {
  final String id;
  final String name;
  final String trackId;
  final int positionMs;
  final List<GroupSessionMember> members;
  final DateTime updatedAtUtc;

  const GroupListeningSession({
    required this.id,
    required this.name,
    required this.trackId,
    required this.positionMs,
    required this.members,
    required this.updatedAtUtc,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trackId': trackId,
    'positionMs': positionMs,
    'members': members.map((e) => e.toJson()).toList(),
    'updatedAtUtc': updatedAtUtc.toIso8601String(),
  };

  static GroupListeningSession fromJson(Map<String, dynamic> json) {
    final membersRaw = json['members'];
    final members = <GroupSessionMember>[];
    if (membersRaw is List) {
      for (final item in membersRaw) {
        if (item is Map) {
          members.add(GroupSessionMember.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return GroupListeningSession(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      trackId: json['trackId']?.toString() ?? '',
      positionMs: int.tryParse(json['positionMs']?.toString() ?? '') ?? 0,
      members: members,
      updatedAtUtc: DateTime.tryParse(json['updatedAtUtc']?.toString() ?? '')?.toUtc() ?? DateTime.now().toUtc(),
    );
  }
}

class GroupListeningService {
  static const _keyPrefix = 'group.listening.sessions.v1.';

  Future<List<GroupListeningSession>> sessions(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString('$_keyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return const <GroupListeningSession>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <GroupListeningSession>[];
    }
    final values = <GroupListeningSession>[];
    for (final item in decoded) {
      if (item is Map) {
        values.add(GroupListeningSession.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    return values;
  }

  Future<void> saveSessions(int profileId, List<GroupListeningSession> values) async {
    await (await SharedPreferences.getInstance()).setString(
      '$_keyPrefix$profileId',
      jsonEncode(values.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> upsertSession(int profileId, GroupListeningSession session) async {
    final current = await sessions(profileId);
    final next = <GroupListeningSession>[
      session,
      ...current.where((item) => item.id != session.id),
    ];
    await saveSessions(profileId, next.take(100).toList());
  }
}
