import 'dart:async';
import 'viewing_sessions.dart';
import 'device_connection.dart';
import 'opening_indicator.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../screens/native_app_screen.dart';

class NativeAppLauncher {
  static final Set<String> _opening = {};

  static Future<String> _helperPath() async {
    final root = Platform.environment['LOCALAPPDATA'];

    if (root == null) {
      throw StateError('LOCALAPPDATA is unavailable.');
    }

    final folder = Directory('$root\\MILLITOPTV\\helpers');
    await folder.create(recursive: true);

    final script = await rootBundle.loadString(
      'assets/native/windows_apps.ps1',
    );

    final file = File('${folder.path}\\windows_apps.ps1');
    await file.writeAsString(script, flush: true);
    return file.path;
  }

  static List<String> _arguments(String script, String action, String appKey) =>
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
        '-Action',
        action,
        '-AppKey',
        appKey,
      ];

  static Future<bool> _validPath(String? path, String appKey) async {
    if (path == null || path.isEmpty) return false;

    final expected = appKey == 'vlc' ? 'vlc.exe' : 'iptvnator.exe';
    final filename = path.replaceAll('/', '\\').split('\\').last;

    return filename.toLowerCase() == expected && await File(path).exists();
  }

  static Future<void> open(
    BuildContext context, {
    required String appKey,
    required String title,
    String? mediaPath,
  }) async {
    if (mediaPath != null &&
        (appKey != 'vlc' || !await File(mediaPath).exists())) {
      throw StateError(
        'The recording is unavailable. Refresh recordings and try again.',
      );
    }
    // Do not open duplicate windows when Enter is pressed repeatedly.
    if (!_opening.add(appKey)) return;

    Directory? signalDirectory;
    final sessionDone = Completer<void>();
    var launchConfirmed = false;
    try {
      final preferences = await SharedPreferences.getInstance();
      final preferenceKey = 'native.$appKey.executable';
      String? executable = preferences.getString(preferenceKey);

      final script = await _helperPath();

      if (!await _validPath(executable, appKey)) {
        final result = await Process.run(
          'powershell.exe',
          _arguments(script, 'Detect', appKey),
        ).timeout(const Duration(seconds: 90));

        if (result.exitCode != 0) {
          throw StateError('Application detection failed.\n${result.stderr}');
        }

        final detected =
            jsonDecode(
                  result.stdout.toString().replaceFirst('\uFEFF', '').trim(),
                )
                as Map<String, dynamic>;

        executable = detected['path'] as String?;

        if (await _validPath(executable, appKey)) {
          await preferences.setString(preferenceKey, executable!);
        } else {
          // Missing or unresolved app: show setup, not an Open confirmation.
          if (!context.mounted) return;

          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => NativeAppScreen(appKey: appKey, title: title),
            ),
          );
          return;
        }
      }

      if (!context.mounted) return;
      OpeningIndicator.show(context, title);
      DeviceConnection.instance.setMediaActive('native:$appKey', true);
      File? closeSignal;
      if (mediaPath != null) {
        signalDirectory = await Directory.systemTemp.createTemp(
          'MillitopVlcSession-',
        );
        closeSignal = File('${signalDirectory.path}\\close.signal');
        ViewingSessions.instance.register('native:$appKey', () async {
          await closeSignal!.writeAsString('close', flush: true);
          await sessionDone.future;
          if (!launchConfirmed) {
            throw StateError('VLC closure was not confirmed.');
          }
        });
      } else {
        ViewingSessions.instance.register('native:$appKey', () async {
          throw StateError(
            'Close this external application manually before the viewing timer ends.',
          );
        });
      }

      final result = await Process.run('powershell.exe', [
        ..._arguments(script, 'Launch', appKey),
        '-ExePath',
        executable!,
        if (mediaPath != null) ...['-MediaPath', mediaPath],
        if (closeSignal != null) ...['-CloseSignalPath', closeSignal.path],
      ]);

      launchConfirmed = result.exitCode == 0;
      await windowManager.show();
      await windowManager.focus();

      if (result.exitCode != 0) {
        throw StateError(
          'The application may still be running, but its window '
          'could not be tracked.\n${result.stderr}',
        );
      }
    } catch (error) {
      if (!context.mounted) return;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Could not open $title'),
          content: SingleChildScrollView(
            child: SelectableText(error.toString()),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      ViewingSessions.instance.remove('native:$appKey');
      if (!sessionDone.isCompleted) {
        sessionDone.complete();
      }
      if (signalDirectory != null) {
        try {
          await signalDirectory.delete(recursive: true);
        } catch (_) {}
      }
      DeviceConnection.instance.setMediaActive('native:$appKey', false);
      _opening.remove(appKey);
    }
  }
}
