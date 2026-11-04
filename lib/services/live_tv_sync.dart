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
    final response = await connection.postDevice('/api/device/live-tv/favorites', {
      'action': 'get',
      'profileId': profileId,
      'sourceId': sourceId,
    }, expectedConnection: expectedConnection);
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

  Future<void> dvr({
    required String expectedConnection,
    required int profileId,
    required String sourceId,
    required String channelId,
    required String channelName,
    required bool start,
  }) async {
    await connection.postDevice('/api/device/live-tv/dvr', {
      'action': start ? 'start' : 'stop',
      'profileId': profileId,
      'sourceId': sourceId,
      'channelId': channelId,
      'channelName': channelName,
    }, expectedConnection: expectedConnection);
  }
}
