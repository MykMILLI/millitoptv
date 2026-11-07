import 'app_log.dart';
import 'device_connection.dart';
import 'home_preferences.dart';
import 'live_tv_source.dart';

class LiveTvControlService {
  final DeviceConnection connection;
  LiveTvControlService({DeviceConnection? connection})
    : connection = connection ?? DeviceConnection.instance;

  Future<void> pushConfig({
    required String expectedConnection,
    required int profileId,
    required List<LiveTvSource> sources,
    required String tmdbApiKey,
    Map<String, dynamic>? profileState,
  }) async {
    final state = profileState == null
        ? null
        : await _withRemoteCollections(
            expectedConnection: expectedConnection,
            profileId: profileId,
            profileState: profileState,
          );
    await connection.postDevice('/api/device/live-tv/config', {
      'action': 'set',
      'profileId': profileId,
      'tmdbApiKey': tmdbApiKey,
      'sources': sources.map((item) => item.toJson()).toList(),
      if (state != null) 'profileState': state,
    }, expectedConnection: expectedConnection);
  }

  /// The server keeps one profile snapshot and each push replaces it. Before
  /// uploading, fold in the server's copy of the per-item collections
  /// (YouTube subscriptions/likes/history, mixed playlists and favorites)
  /// so a device never erases what another device added since its
  /// last pull. Those collections merge per item by timestamp, so this is
  /// safe to run on every push.
  Future<Map<String, dynamic>> _withRemoteCollections({
    required String expectedConnection,
    required int profileId,
    required Map<String, dynamic> profileState,
  }) async {
    try {
      final remote = await pullConfig(
        expectedConnection: expectedConnection,
        profileId: profileId,
      );
      final remoteState = remote['profileState'];
      if (remoteState is! Map) {
        return profileState;
      }
      final prefs = HomePreferences();
      await prefs.mergeCollectionSyncState(
        profileId,
        Map<String, dynamic>.from(remoteState),
      );
      return {...profileState, ...await prefs.collectionSyncState(profileId)};
    } catch (error, stack) {
      AppLog.warn(
        LogCategory.sync,
        'Could not merge the server profile before uploading; '
        'uploading this device\'s copy',
        error: error,
        stackTrace: stack,
        details: {'profileId': profileId},
      );
      return profileState;
    }
  }

  Future<Map<String, dynamic>> pullConfig({
    required String expectedConnection,
    required int profileId,
  }) async {
    return connection.postDevice('/api/device/live-tv/config', {
      'action': 'get',
      'profileId': profileId,
    }, expectedConnection: expectedConnection);
  }

  Future<Map<String, dynamic>> pullHouseholdProfiles({
    required String expectedConnection,
  }) async {
    return connection.postDevice('/api/device/household/profiles', {
      'action': 'get',
    }, expectedConnection: expectedConnection);
  }

  Future<void> upsertHouseholdProfile({
    required String expectedConnection,
    required int profileId,
    required String name,
    String? avatarBase64,
    String? avatarExtension,
  }) async {
    await connection.postDevice('/api/device/household/profiles', {
      'action': 'upsert',
      'profileId': profileId,
      'name': name,
      if (avatarBase64 != null && avatarBase64.trim().isNotEmpty)
        'avatarBase64': avatarBase64.trim(),
      if (avatarExtension != null && avatarExtension.trim().isNotEmpty)
        'avatarExtension': avatarExtension.trim(),
    }, expectedConnection: expectedConnection);
  }

  Future<void> removeHouseholdProfile({
    required String expectedConnection,
    required int profileId,
  }) async {
    await connection.postDevice('/api/device/household/profiles', {
      'action': 'remove',
      'profileId': profileId,
    }, expectedConnection: expectedConnection);
  }

  Future<void> reportPlayback({
    required String expectedConnection,
    required int profileId,
    required String sourceId,
    required String sourceName,
    required String mediaType,
    required String mediaId,
    required String title,
    required bool active,
  }) async {
    await connection.postDevice('/api/device/live-tv/playback', {
      'action': 'status',
      'profileId': profileId,
      'sourceId': sourceId,
      'sourceName': sourceName,
      'mediaType': mediaType,
      'mediaId': mediaId,
      'title': title,
      'active': active,
    }, expectedConnection: expectedConnection);
  }

  Future<void> queuePlayback({
    required String expectedConnection,
    required int profileId,
    required LiveTvLibraryItem item,
  }) async {
    await connection.postDevice('/api/device/live-tv/queue', {
      'action': 'enqueue',
      'profileId': profileId,
      'item': item.toJson(),
    }, expectedConnection: expectedConnection);
  }

  Future<Map<String, dynamic>> dvrSchedules({
    required String expectedConnection,
    required int profileId,
  }) async {
    return connection.postDevice('/api/device/live-tv/dvr/schedule', {
      'action': 'list',
      'profileId': profileId,
    }, expectedConnection: expectedConnection);
  }

  Future<void> scheduleDvr({
    required String expectedConnection,
    required int profileId,
    required String sourceId,
    required String channelId,
    required String channelName,
    required DateTime startUtc,
    required DateTime endUtc,
    required String title,
    String streamUrl = '',
  }) async {
    await connection.postDevice('/api/device/live-tv/dvr/schedule', {
      'action': 'upsert',
      'streamUrl': streamUrl,
      'profileId': profileId,
      'sourceId': sourceId,
      'channelId': channelId,
      'channelName': channelName,
      'title': title,
      'startUtc': startUtc.toUtc().toIso8601String(),
      'endUtc': endUtc.toUtc().toIso8601String(),
    }, expectedConnection: expectedConnection);
  }

  Future<void> cancelScheduledDvr({
    required String expectedConnection,
    required int profileId,
    required String scheduleId,
  }) async {
    await connection.postDevice('/api/device/live-tv/dvr/schedule', {
      'action': 'remove',
      'profileId': profileId,
      'scheduleId': scheduleId,
    }, expectedConnection: expectedConnection);
  }

  Future<Map<String, dynamic>> dvrRecordings({
    required String expectedConnection,
    required int profileId,
  }) async {
    return connection.postDevice('/api/device/live-tv/dvr/recordings', {
      'action': 'list',
      'profileId': profileId,
    }, expectedConnection: expectedConnection);
  }

  Future<void> deleteDvrRecording({
    required String expectedConnection,
    required String recordingId,
  }) async {
    await connection.postDevice('/api/device/live-tv/dvr/recordings', {
      'action': 'delete',
      'recordingId': recordingId,
    }, expectedConnection: expectedConnection);
  }

  Future<Map<String, dynamic>> stopDvrRecording({
    required String expectedConnection,
    required String recordingId,
  }) {
    return connection.postDevice('/api/device/live-tv/dvr', {
      'action': 'stop',
      'recordingId': recordingId,
    }, expectedConnection: expectedConnection);
  }

  Future<Map<String, dynamic>> serviceAccess({
    required String expectedConnection,
    required int profileId,
  }) async {
    return connection.postDevice('/api/device/service/access', {
      'action': 'get',
      'profileId': profileId,
    }, expectedConnection: expectedConnection);
  }

  Future<Map<String, dynamic>> mediaLibraryCatalog({
    required String expectedConnection,
    required int profileId,
    String? catalogVersion,
  }) async {
    return connection.postDevice('/api/device/media-library/catalog', {
      'profileId': profileId,
      if (catalogVersion != null && catalogVersion.isNotEmpty)
        'catalogVersion': catalogVersion,
    }, expectedConnection: expectedConnection);
  }
}
