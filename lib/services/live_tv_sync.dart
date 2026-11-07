import 'device_connection.dart';

class LiveTvSyncSnapshot {
  final Set<String> favorites;
  final List<String> history;
  const LiveTvSyncSnapshot({required this.favorites, required this.history});
}

class LiveTvSyncService {
  final DeviceConnection connection;
  LiveTvSyncService({DeviceConnection? connection})
    : connection = connection ?? DeviceConnection.instance;

  Future<LiveTvSyncSnapshot> load({
    required String expectedConnection,
    required int profileId,
    required String sourceId,
  }) async {
    final response = await connection.postDevice(
      '/api/device/live-tv/favorites',
      {'action': 'get', 'profileId': profileId, 'sourceId': sourceId},
      expectedConnection: expectedConnection,
    );
    final favoritesRaw = response['favorites'];
    final historyRaw = response['history'];
    final favorites = <String>{};
    if (favoritesRaw is List) {
      for (final value in favoritesRaw) {
        final next = value.toString().trim();
        if (next.isNotEmpty) {
          favorites.add(next);
        }
      }
    }
    final history = <String>[];
    if (historyRaw is List) {
      for (final value in historyRaw) {
        final next = value.toString().trim();
        if (next.isNotEmpty) {
          history.add(next);
        }
      }
    }
    return LiveTvSyncSnapshot(favorites: favorites, history: history);
  }

  Future<void> syncFavorites({
    required String expectedConnection,
    required int profileId,
    required String sourceId,
    required Set<String> favorites,
  }) async {
    await connection.postDevice('/api/device/live-tv/favorites', {
      'action': 'set',
      'profileId': profileId,
      'sourceId': sourceId,
      'favorites': favorites.toList(),
    }, expectedConnection: expectedConnection);
  }

  Future<void> appendHistory({
    required String expectedConnection,
    required int profileId,
    required String sourceId,
    required String channelId,
    required String channelName,
  }) async {
    await connection.postDevice('/api/device/live-tv/history', {
      'action': 'append',
      'profileId': profileId,
      'sourceId': sourceId,
      'channelId': channelId,
      'channelName': channelName,
    }, expectedConnection: expectedConnection);
  }

  /// Starts or stops a cloud DVR recording on the paired Millitop server.
  /// Returns the server's recording record (`recording`).
  Future<Map<String, dynamic>> dvr({
    required String expectedConnection,
    required int profileId,
    required String sourceId,
    required String channelId,
    required String channelName,
    required bool start,
    String streamUrl = '',
    String title = '',
    String? recordingId,
  }) {
    return connection.postDevice('/api/device/live-tv/dvr', {
      'action': start ? 'start' : 'stop',
      'profileId': profileId,
      'sourceId': sourceId,
      'channelId': channelId,
      'channelName': channelName,
      if (start) 'streamUrl': streamUrl,
      if (start && title.trim().isNotEmpty) 'title': title.trim(),
      if (!start && recordingId != null) 'recordingId': recordingId,
    }, expectedConnection: expectedConnection);
  }

  /// Recordings currently running anywhere in the household.
  Future<List<Map<String, dynamic>>> dvrActive({
    required String expectedConnection,
  }) async {
    final response = await connection.postDevice('/api/device/live-tv/dvr', {
      'action': 'status',
    }, expectedConnection: expectedConnection);
    return [
      ...(response['recordings'] as List? ?? const []),
    ].whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
  }
}
