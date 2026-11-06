import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PlaybackDestination {
  final String id;
  final String name;
  final String type;
  final String host;
  final int port;
  final bool selected;
  const PlaybackDestination({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    this.selected = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'host': host,
    'port': port,
    'selected': selected,
  };

  static PlaybackDestination fromJson(Map<String, dynamic> json) {
    return PlaybackDestination(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      host: json['host']?.toString() ?? '',
      port: int.tryParse(json['port']?.toString() ?? '') ?? 0,
      selected: json['selected'] == true,
    );
  }
}

class PlaybackDestinationsService {
  static const _keyPrefix = 'playback.destinations.v1.';

  Future<List<PlaybackDestination>> list(int profileId) async {
    final raw = (await SharedPreferences.getInstance()).getString('$_keyPrefix$profileId');
    if (raw == null || raw.trim().isEmpty) {
      return const <PlaybackDestination>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <PlaybackDestination>[];
    }
    final values = <PlaybackDestination>[];
    for (final item in decoded) {
      if (item is! Map) {
        continue;
      }
      values.add(PlaybackDestination.fromJson(Map<String, dynamic>.from(item)));
    }
    return values;
  }

  Future<void> save(int profileId, List<PlaybackDestination> values) async {
    await (await SharedPreferences.getInstance()).setString(
      '$_keyPrefix$profileId',
      jsonEncode(values.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> upsert(int profileId, PlaybackDestination destination) async {
    final current = await list(profileId);
    final next = <PlaybackDestination>[
      destination,
      ...current.where((item) => item.id != destination.id),
    ];
    await save(profileId, next.take(200).toList());
  }

  Future<void> select(int profileId, String destinationId) async {
    final current = await list(profileId);
    final next = current
        .map(
          (item) => PlaybackDestination(
            id: item.id,
            name: item.name,
            type: item.type,
            host: item.host,
            port: item.port,
            selected: item.id == destinationId,
          ),
        )
        .toList();
    await save(profileId, next);
  }
}
