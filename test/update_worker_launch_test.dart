import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/update_launch.dart';

String decodeLaunch(String encoded) {
  final bytes = base64Decode(encoded);
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ]);
}

void main() {
  test('worker launcher uses independent Start-Process and returns PID', () {
    final command = decodeLaunch(
      updateWorkerLaunchCommand(
        r'C:\Windows\powershell.exe',
        r'C:\App Data\bootstrap.ps1',
        r'C:\App Data\request.json',
      ),
    );
    expect(command, contains('Start-Process'));
    expect(command, contains('-WindowStyle Hidden -PassThru'));
    expect(command, contains('WORKER_PID='));
    expect(command, contains('SilentlyContinue'));
    expect(command, isNot(contains('-Wait')));
  });
  test('worker launcher embeds the exact encoded bootstrap invocation', () {
    final bootstrap = "C:\\O'Neil\\bootstrap.ps1";
    final request = 'C:\\Müller\\request.json';
    final inner = updateBootstrapCommand(bootstrap, request);
    final outer = decodeLaunch(
      updateWorkerLaunchCommand(
        r'C:\Windows\powershell.exe',
        bootstrap,
        request,
      ),
    );
    expect(outer, contains("'-EncodedCommand','$inner'"));
    expect(decodeLaunch(inner), contains("O''Neil"));
    expect(decodeLaunch(inner), contains('Müller'));
  });
  test(
    'Windows independent bootstrap smoke test with spaced apostrophe paths',
    () async {
      final root = await Directory.systemTemp.createTemp(
        "Millitop launch O'Neil ",
      );
      final stub = File('${root.path}\\fake bootstrap.ps1');
      final request = File('${root.path}\\request with spaces.json');
      final marker = File('${root.path}\\marker.txt');
      final powershell =
          '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      String quote(String value) => "'${value.replaceAll("'", "''")}'";
      await request.writeAsString('{}');
      await stub.writeAsString(
        'param([string]\$RequestPath)\n'
        '\$ErrorActionPreference=\'Stop\'\n'
        'Start-Sleep -Milliseconds 750\n'
        '[IO.File]::WriteAllText(${quote(marker.path)}, \$RequestPath)\n',
      );
      bool passed = false;
      try {
        final result = await Process.run(
          powershell,
          [
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle',
            'Hidden',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            updateWorkerLaunchCommand(powershell, stub.path, request.path),
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 20));
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(
          result.stdout.toString(),
          matches(RegExp(r'^WORKER_PID=\d+\r?$', multiLine: true)),
        );
        for (var i = 0; i < 150; i++) {
          if (await marker.exists()) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          await marker.exists(),
          isTrue,
          reason:
              'Independent child did not write its marker. Diagnostics: ${root.path}',
        );
        expect(await marker.readAsString(), request.path);
        passed = true;
      } finally {
        if (passed) {
          await root.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
