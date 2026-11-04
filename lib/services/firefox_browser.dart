import 'viewing_sessions.dart';
import 'managed_firefox_setup.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'device_connection.dart';
import 'web_app_definition.dart';

class FirefoxBrowser {
  static bool _busy = false, _recoveryRequired = false;
  static const executablePreference = 'browser.firefox.executable.v1';
  static Future<String> _helper() async {
    final directory = Directory(
      '${Platform.environment['LOCALAPPDATA']}\\MILLITOPTV\\helpers',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}\\firefox_session.ps1');
    await file.writeAsString(
      await rootBundle.loadString('assets/native/firefox_session.ps1'),
      flush: true,
    );
    return file.path;
  }

  static Future<String?> detect({int profileId = 1}) async {
    final status = await ManagedFirefoxSetup.instance.inspect(profileId);
    return status.executable;
  }

  static String _powershell() =>
      '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  static Future<void> open(
    BuildContext context, {
    required int profileId,
    String? url,
    bool addons = false,
    bool payment = false,
    bool appFullscreen = false,
  }) async {
    if (_recoveryRequired) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Close the Millitop Firefox window, then quit and reopen Millitop before retrying.',
          ),
        ),
      );
      return;
    }
    if (_busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Close the current Millitop Firefox window before opening another.',
          ),
        ),
      );
      return;
    }
    if (profileId < 1) {
      return;
    }
    if (payment && addons) {
      throw StateError(
        'Payment browser extensions are intentionally disabled.',
      );
    }
    final target = addons ? 'about:addons' : validateAppUrl(url ?? '');
    _busy = true;
    final key = 'firefox:$profileId';
    final link = DeviceConnection.instance;
    link.setMediaActive(key, true);
    Directory? temp;
    Process? process;
    final sessionDone = Completer<void>();
    final subscriptions = <StreamSubscription<String>>[];
    bool? fullscreen, topmost;
    var confirmedClosed = false;
    var mightHaveStarted = false;
    try {
      fullscreen = await windowManager.isFullScreen();
      topmost = await windowManager.isAlwaysOnTop();
      if (!context.mounted) {
        return;
      }
      final executable = await ManagedFirefoxSetup.instance.ensure(
        context,
        profileId,
        purpose: payment ? 'payments' : 'media',
      );
      if (executable == null || !context.mounted) {
        return;
      }
      await (await SharedPreferences.getInstance()).setString(
        executablePreference,
        executable,
      );
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setFullScreen(false);
      temp = await Directory.systemTemp.createTemp('MillitopFirefoxSession-');
      final file = File('${temp.path}\\request.json');
      final stopSignal = File('${temp.path}\\close-viewing.signal');
      ViewingSessions.instance.register(key, () async {
        if (payment || addons) {
          throw StateError(
            'Close the payment or browser-settings session before the viewing timer can finish.',
          );
        }
        await stopSignal.writeAsString('close', flush: true);
        await sessionDone.future;
        if (!confirmedClosed) {
          throw StateError('Viewing-session shutdown was not confirmed.');
        }
      });
      await file.writeAsString(
        jsonEncode({
          'action': addons ? 'addons' : 'launch',
          'profileId': profileId,
          'purpose': payment ? 'payments' : 'media',
          'managedOnly': true,
          'url': target,
          'appFullscreen': appFullscreen && !addons && !payment,
          'executable': (await SharedPreferences.getInstance()).getString(
            executablePreference,
          ),
        }),
        flush: true,
      );
      process = await Process.start(_powershell(), [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        await _helper(),
        '-RequestPath',
        file.path,
      ]);
      mightHaveStarted = true;
      final ready = Completer<void>(),
          outDone = Completer<void>(),
          errDone = Completer<void>();
      String? failure;
      subscriptions.add(
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(
              (line) {
                try {
                  final event =
                      jsonDecode(line.replaceFirst('\uFEFF', '')) as Map;
                  if (event['type'] == 'ready') {
                    mightHaveStarted = true;
                    if (!ready.isCompleted) {
                      ready.complete();
                    }
                  }
                  if (event['type'] == 'closed') {
                    confirmedClosed = true;
                  }
                  if (event['type'] == 'error') {
                    mightHaveStarted = event['started'] == true;
                    failure = event['message']?.toString();
                  }
                } catch (_) {}
              },
              onDone: () {
                if (!outDone.isCompleted) {
                  outDone.complete();
                }
              },
              onError: (Object _) {
                if (!outDone.isCompleted) {
                  outDone.complete();
                }
              },
            ),
      );
      subscriptions.add(
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(
              (_) {},
              onDone: () {
                if (!errDone.isCompleted) {
                  errDone.complete();
                }
              },
              onError: (Object _) {
                if (!errDone.isCompleted) {
                  errDone.complete();
                }
              },
            ),
      );
      unawaited(process.stdin.close());
      final exited = process.exitCode;
      unawaited(
        exited.then((code) async {
          await outDone.future.timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
          if (!ready.isCompleted) {
            ready.completeError(
              StateError(
                failure ?? 'Firefox did not start. Check Settings > Browser.',
              ),
            );
          }
        }),
      );
      await ready.future.timeout(const Duration(seconds: 65));
      await windowManager.minimize();
      final code = await exited;
      await Future.wait([
        outDone.future,
        errDone.future,
      ]).timeout(const Duration(seconds: 3));
      if (code != 0 || !confirmedClosed) {
        throw StateError(
          failure ??
              'Firefox session could not be confirmed closed. Close it before retrying.',
        );
      }
    } catch (e) {
      if (e is FirefoxSetupException && e.recovery) {
        mightHaveStarted = true;
      }
      if (context.mounted) {
        await windowManager.show();
        if (!context.mounted) {
          return;
        }
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Firefox could not complete this session'),
            content: Text(e.toString().replaceFirst('Bad state: ', '')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } finally {
      for (final subscription in subscriptions) {
        try {
          await subscription.cancel().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      if (confirmedClosed || !mightHaveStarted) {
        link.setMediaActive(key, false);
      } else {
        _recoveryRequired = true;
      }
      // Unknown live Firefox windows are not killed; updates stay guarded until app restart.
      if (!confirmedClosed && process != null) {
        process.kill();
      }
      try {
        if (fullscreen != null) {
          await windowManager.setFullScreen(fullscreen);
        }
        if (topmost != null) {
          await windowManager.setAlwaysOnTop(topmost);
        }
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
      if (temp != null) {
        try {
          await temp.delete(recursive: true);
        } catch (_) {}
      }
      ViewingSessions.instance.remove(key);
      if (!sessionDone.isCompleted) {
        sessionDone.complete();
      }
      _busy = false;
    }
  }
}
