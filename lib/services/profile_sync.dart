import 'dart:async';

import 'app_log.dart';
import 'device_connection.dart';
import 'home_preferences.dart';
import 'live_tv_control.dart';

/// Small helpers for keeping a profile's library in step across paired
/// devices. Uploads go through [LiveTvControlService.pushConfig], which
/// merges the server copy of per-item collections first.
class ProfileSync {
  ProfileSync._();

  static final Map<int, Timer> _debounce = {};
  static final Map<int, Future<void>> _pushes = {};

  static bool get _connected =>
      DeviceConnection.instance.connectionKey.isNotEmpty &&
      DeviceConnection.instance.isConnected;

  /// Pulls the server's YouTube library and mixed playlists/favorites and
  /// merges them into this device. Returns true when the merge ran.
  static Future<bool> pullCollections(
    int profileId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_connected) {
      return false;
    }
    try {
      final remote = await LiveTvControlService()
          .pullConfig(
            expectedConnection: DeviceConnection.instance.connectionKey,
            profileId: profileId,
          )
          .timeout(timeout);
      final state = remote['profileState'];
      if (state is! Map) {
        return false;
      }
      await HomePreferences().mergeCollectionSyncState(
        profileId,
        Map<String, dynamic>.from(state),
      );
      AppLog.debug(
        LogCategory.sync,
        'Pulled library collections',
        details: {'profileId': profileId},
      );
      return true;
    } catch (error, stack) {
      AppLog.warn(
        LogCategory.sync,
        'Could not pull your library from the server; showing this '
        'device\'s copy',
        error: error,
        stackTrace: stack,
        details: {'profileId': profileId},
      );
      return false;
    }
  }

  /// Uploads this profile now. Concurrent calls share one upload.
  static Future<void> push(int profileId) {
    if (!_connected) {
      return Future<void>.value();
    }
    return _pushes[profileId] ??= _push(profileId).whenComplete(() {
      _pushes.remove(profileId);
    });
  }

  static Future<void> _push(int profileId) async {
    final prefs = HomePreferences();
    await LiveTvControlService().pushConfig(
      expectedConnection: DeviceConnection.instance.connectionKey,
      profileId: profileId,
      sources: await prefs.liveTvSources(profileId),
      tmdbApiKey: await prefs.tmdbApiKey(profileId),
      profileState: await prefs.liveTvProfileSyncState(profileId),
    );
  }

  /// Debounced background upload; failures are logged, not thrown.
  static void schedulePush(
    int profileId, {
    Duration delay = const Duration(milliseconds: 800),
  }) {
    if (!_connected) {
      return;
    }
    _debounce[profileId]?.cancel();
    _debounce[profileId] = Timer(delay, () {
      _debounce.remove(profileId);
      unawaited(
        push(profileId).catchError((Object error, StackTrace stack) {
          AppLog.warn(
            LogCategory.sync,
            'Profile upload failed; it will retry on the next change',
            error: error,
            stackTrace: stack,
            details: {'profileId': profileId},
          );
        }),
      );
    });
  }
}
