import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class FirefoxSetupException implements Exception {
  final String message;
  final bool recovery;
  const FirefoxSetupException(this.message, {this.recovery = false});
  @override
  String toString() => message;
}

class FirefoxSetupStatus {
  final bool installed, ready, sessionActive;
  final String? executable;
  const FirefoxSetupStatus({
    required this.installed,
    required this.ready,
    this.executable,
    this.sessionActive = false,
  });
}

abstract class FirefoxSetupRunner {
  Future<Map<String, dynamic>> call(
    String action,
    int profile,
    String purpose,
    void Function(String, int) progress,
  );
}

class NativeFirefoxSetupRunner implements FirefoxSetupRunner {
  @override
  Future<Map<String, dynamic>> call(
    String action,
    int profile,
    String purpose,
    void Function(String, int) progress,
  ) async {
    final temp = await Directory.systemTemp.createTemp('MillitopBrowserSetup-');
    Process? process;
    final subscriptions = <StreamSubscription<String>>[];
    var done = false;
    Map<String, dynamic>? result;
    FirefoxSetupException? failure;
    try {
      final helper = File('${temp.path}\\firefox_provision.ps1'),
          manifest = File('${temp.path}\\firefox_extensions.json'),
          request = File('${temp.path}\\request.json');
      await helper.writeAsString(
        await rootBundle.loadString('assets/native/firefox_provision.ps1'),
        flush: true,
      );
      await manifest.writeAsString(
        await rootBundle.loadString('assets/native/firefox_extensions.json'),
        flush: true,
      );
      await request.writeAsString(
        jsonEncode({
          'action': action,
          'profileId': profile,
          'purpose': purpose,
          'manifest': manifest.path,
          'consent': action == 'ensure',
        }),
        flush: true,
      );
      final powershell =
          '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      process = await Process.start(powershell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        helper.path,
        '-RequestPath',
        request.path,
      ]);
      final outputDone = Completer<void>(), errorDone = Completer<void>();
      subscriptions.add(
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(
              (line) {
                try {
                  final data = Map<String, dynamic>.from(
                    jsonDecode(line.replaceFirst('\uFEFF', '')) as Map,
                  );
                  if (data['type'] == 'progress') {
                    progress(
                      data['message']?.toString() ?? 'Preparing browser...',
                      (data['percent'] as num?)?.toInt() ?? -1,
                    );
                  }
                  if (data['type'] == 'prepared' ||
                      data['type'] == 'inspected') {
                    result = data;
                  }
                  if (data['type'] == 'error') {
                    failure = FirefoxSetupException(
                      data['message']?.toString() ?? 'Browser setup failed.',
                      recovery: data['requiresRecovery'] == true,
                    );
                  }
                } catch (_) {}
              },
              onDone: () {
                if (!outputDone.isCompleted) {
                  outputDone.complete();
                }
              },
              onError: (Object _) {
                if (!outputDone.isCompleted) {
                  outputDone.complete();
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
                if (!errorDone.isCompleted) {
                  errorDone.complete();
                }
              },
              onError: (Object _) {
                if (!errorDone.isCompleted) {
                  errorDone.complete();
                }
              },
            ),
      );
      unawaited(process.stdin.close());
      final code = await process.exitCode.timeout(
        Duration(minutes: action == 'inspect' ? 2 : 15),
      );
      done = true;
      await Future.wait([
        outputDone.future,
        errorDone.future,
      ]).timeout(const Duration(seconds: 3));
      if (code != 0 || result == null) {
        throw failure ??
            const FirefoxSetupException(
              'Firefox setup could not be confirmed. Retry or contact support.',
            );
      }
      return result!;
    } on TimeoutException {
      throw const FirefoxSetupException(
        'Browser setup timed out. Close the Millitop Firefox setup window, wait for extraction to finish, then quit and reopen Millitop before retrying.',
        recovery: true,
      );
    } finally {
      for (final subscription in subscriptions) {
        try {
          await subscription.cancel().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      if (!done) {
        process?.kill();
      }
      if (done || process == null) {
        try {
          await temp.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}

class ManagedFirefoxSetup {
  static final instance = ManagedFirefoxSetup();
  final FirefoxSetupRunner runner;
  ManagedFirefoxSetup({FirefoxSetupRunner? runner})
    : runner = runner ?? NativeFirefoxSetupRunner();
  Future<FirefoxSetupStatus> inspect(
    int profile, {
    String purpose = 'media',
  }) async {
    final data = await runner.call(
      'inspect',
      profile,
      purpose,
      (_, percent) {},
    );
    return FirefoxSetupStatus(
      installed: data['installed'] == true,
      ready: data['ready'] == true,
      sessionActive: data['sessionActive'] == true,
      executable: data['executable'] as String?,
    );
  }

  Future<String?> ensure(
    BuildContext context,
    int profile, {
    String purpose = 'media',
  }) async {
    final status = await inspect(profile, purpose: purpose);
    if (status.sessionActive) {
      throw const FirefoxSetupException(
        'Close the existing Millitop Firefox window, then quit and reopen Millitop before retrying.',
        recovery: true,
      );
    }
    if (status.ready && status.executable != null) {
      return status.executable;
    }
    if (!context.mounted) {
      return null;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          purpose == 'payments'
              ? 'Prepare payment browser'
              : 'Prepare Firefox for Millitop',
        ),
        content: Text(
          purpose == 'payments'
              ? 'Millitop will prepare a separate Mozilla-signed Firefox for payment pages, without media extensions. Browser data remains separate. Windows security approval may be required.'
              : 'Firefox and the required AdBlocker Ultimate and SponsorBlock extensions are needed. Millitop will prepare its own browser without changing your personal Firefox or default browser. Your selected app opens after setup. Windows security approval may be required.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              status.installed ? 'Prepare and open' : 'Install and open',
            ),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted) {
      return null;
    }
    final outcome = await showDialog<_SetupOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _SetupDialog(runner: runner, profile: profile, purpose: purpose),
    );
    if (outcome?.error != null) {
      throw outcome!.error!;
    }
    return outcome?.path;
  }
}

class _SetupOutcome {
  final String? path;
  final FirefoxSetupException? error;
  const _SetupOutcome({this.path, this.error});
}

class _SetupDialog extends StatefulWidget {
  final FirefoxSetupRunner runner;
  final int profile;
  final String purpose;
  const _SetupDialog({
    required this.runner,
    required this.profile,
    required this.purpose,
  });
  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  String message = 'Preparing the browser...';
  int percent = -1;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_start());
      }
    });
  }

  Future<void> _start() async {
    try {
      final data = await widget.runner.call(
        'ensure',
        widget.profile,
        widget.purpose,
        (text, value) {
          if (mounted) {
            setState(() {
              message = text;
              percent = value;
            });
          }
        },
      );
      if (data['type'] != 'prepared' ||
          data['executable'] is! String ||
          data['extensionsReady'] != true) {
        throw const FirefoxSetupException(
          'Browser setup did not report readiness.',
        );
      }
      if (mounted) {
        Navigator.pop(
          context,
          _SetupOutcome(path: data['executable'] as String),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(
          context,
          _SetupOutcome(
            error: e is FirefoxSetupException
                ? e
                : const FirefoxSetupException(
                    'Browser setup failed. Check internet access and Windows security prompts.',
                  ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: const Text('Setting up Firefox'),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: percent >= 0 ? percent.clamp(0, 100) / 100 : null,
            ),
            const SizedBox(height: 16),
            Text(message),
            const SizedBox(height: 12),
            const Text(
              'Keep Millitop open. The first setup can take several minutes. No personal Firefox window is terminated.',
            ),
          ],
        ),
      ),
    ),
  );
}
