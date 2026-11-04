import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

class ProfileBrowserLease {
  final WebviewController controller;
  final Completer<void> _finished;
  Future<void>? _closing;

  ProfileBrowserLease._(this.controller, this._finished);

  Future<void> close() {
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      await controller.dispose();
    } catch (error) {
      ProfileBrowserSessions._failure = error;
      rethrow;
    } finally {
      if (!_finished.isCompleted) _finished.complete();
    }
  }
}

class ProfileBrowserSessions {
  static Future<void> _previousClosed = Future<void>.value();
  static Object? _failure;

  static Future<ProfileBrowserLease> open(int profileId) async {
    if (profileId <= 0) {
      throw ArgumentError.value(profileId, 'profileId');
    }

    final previous = _previousClosed;
    final finished = Completer<void>();

    // Reserve this browser session before any asynchronous work.
    _previousClosed = finished.future;

    WebviewController? controller;

    try {
      await previous;

      if (_failure != null) {
        throw StateError(
          'The previous browser session did not close cleanly. '
          'Restart MILLITOP TV before opening another profile. '
          'Details: $_failure',
        );
      }

      final support = await getApplicationSupportDirectory();

      final folder = Directory(
        p.join(
          support.path,
          'household',
          'browser-profiles',
          profileId.toString(),
        ),
      );

      await folder.create(recursive: true);

      await WebviewController.initializeEnvironment(userDataPath: folder.path);

      controller = WebviewController();
      await controller.initialize();

      return ProfileBrowserLease._(controller, finished);
    } catch (error) {
      if (controller != null) {
        try {
          await controller.dispose();
        } catch (disposeError) {
          _failure = disposeError;
        }
      }

      if (!finished.isCompleted) finished.complete();
      rethrow;
    }
  }
}
