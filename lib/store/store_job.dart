import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'store_catalog.dart';
import 'store_manifest.dart';

enum StorePhase {
  checking,
  available,
  downloading,
  verifying,
  approval,
  installing,
  detecting,
  ready,
  failed,
  pending,
}

class StoreJob extends ChangeNotifier {
  StoreJob(this.app);
  final StoreApp app;
  static bool _operation = false;
  static bool get operationActive => _operation;
  StorePhase phase = StorePhase.checking;
  String message = 'Checking this PC...';
  String details = '';
  String? executable;
  bool installedEvidence = false;
  bool wingetAvailable = false;
  double? progress;
  Process? _download;
  bool _cancelled = false;
  bool _closed = false;
  bool get busy => [
    StorePhase.checking,
    StorePhase.downloading,
    StorePhase.verifying,
    StorePhase.approval,
    StorePhase.installing,
    StorePhase.detecting,
  ].contains(phase);
  bool get canCancel => phase == StorePhase.downloading;
  Directory get root {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null) {
      throw StateError('Windows application-data folder is unavailable.');
    }
    return Directory('$base\\MILLITOPTV\\store');
  }

  File get pendingFile => File('${root.path}\\installation-pending.json');
  void _set(StorePhase value, String text) {
    phase = value;
    message = text;
    progress = null;
    if (!_closed) notifyListeners();
  }

  void _log(String text) {
    details += text;
    if (details.length > 16000) {
      details = details.substring(details.length - 16000);
    }
    if (phase == StorePhase.downloading) {
      final matches = RegExp(
        r'(\d{1,3}(?:\.\d+)?)\s*%',
      ).allMatches(text).toList();
      if (matches.isNotEmpty) {
        final value = double.tryParse(matches.last.group(1)!);
        if (value != null && value >= 0 && value <= 100) progress = value / 100;
      }
    }
    if (!_closed) notifyListeners();
  }

  Future<String> _helper(String asset) async {
    await root.create(recursive: true);
    final path = '${root.path}\\${asset.split('/').last}';
    await File(
      path,
    ).writeAsString(await rootBundle.loadString(asset), flush: true);
    return path;
  }

  List<String> _ps(String path, List<String> args) => [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    path,
    ...args,
  ];
  Future<({int code, String output})> _run(
    String command,
    List<String> args,
    Duration timeout, {
    bool download = false,
  }) async {
    final process = await Process.start(command, args);
    if (download) _download = process;
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    final buffer = StringBuffer();
    final out = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            buffer.write(text);
            _log(text);
          },
          onDone: () {
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
          onError: (Object e) {
            _log('$e');
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
        );
    final err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          _log,
          onDone: () {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
          onError: (Object e) {
            _log('$e');
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
        );
    try {
      final code = await process.exitCode.timeout(timeout);
      try {
        await Future.wait<void>([
          stdoutDone.future,
          stderrDone.future,
        ]).timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _log('\nOutput capture closed after process exit.\n');
      }
      return (code: code, output: buffer.toString());
    } on TimeoutException {
      // Never kill an installer. Only download/detection processes are stopped.
      if (phase != StorePhase.installing && phase != StorePhase.approval) {
        process.kill();
      }
      rethrow;
    } finally {
      if (download) _download = null;
      for (final subscription in [out, err]) {
        try {
          await subscription.cancel().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
  }

  Future<String?> _detect() async {
    final script = await _helper('assets/native/windows_apps.ps1');
    final r = await _run(
      'powershell.exe',
      _ps(script, ['-Action', 'Detect', '-AppKey', app.key]),
      const Duration(seconds: 45),
    );
    if (r.code != 0) throw StateError('Installed app detection failed.');
    final data = jsonDecode(r.output.replaceFirst('\uFEFF', '').trim()) as Map;
    wingetAvailable = data['wingetAvailable'] == true;
    installedEvidence = data['installedEvidence'] == true;
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString('native.${app.key}.executable');
    final expected = app.key == 'vlc' ? 'vlc.exe' : 'iptvnator.exe';
    for (final value in [data['path'], saved]) {
      if (value is String &&
          value.replaceAll('/', '\\').split('\\').last.toLowerCase() ==
              expected &&
          await File(value).exists()) {
        await preferences.setString('native.${app.key}.executable', value);
        return value;
      }
    }
    return null;
  }

  Future<void> check() async {
    if (_operation) {
      _set(
        StorePhase.failed,
        'Another app installation is active. Please wait.',
      );
      return;
    }
    _set(StorePhase.checking, 'Checking this PC...');
    try {
      executable = await _detect();
      _set(
        executable != null ? StorePhase.ready : StorePhase.available,
        executable != null
            ? '${app.title} is ready to open.'
            : 'Get ${app.title} for this PC.',
      );
      if (await pendingFile.exists() && executable == null) {
        _set(
          StorePhase.pending,
          'A previous installation needs review. Do not start another installer.',
        );
      }
    } catch (e) {
      _log('\n$e');
      _set(
        StorePhase.failed,
        'Could not check this PC. Try again or locate the app.',
      );
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _download?.kill();
  }

  Future<void> locate(String path) async {
    final expected = app.key == 'vlc' ? 'vlc.exe' : 'iptvnator.exe';
    if (path.replaceAll('/', '\\').split('\\').last.toLowerCase() != expected ||
        !await File(path).exists()) {
      throw const FormatException(
        'Choose the correct installed app executable.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('native.${app.key}.executable', path);
    executable = path;
    _set(StorePhase.ready, '${app.title} is ready.');
  }

  Future<void> install() async {
    if (_operation || busy) return;
    if (await pendingFile.exists()) {
      _set(
        StorePhase.pending,
        'An earlier installation needs review before retrying.',
      );
      return;
    }
    _operation = true;
    _cancelled = false;
    details = '';
    _set(StorePhase.checking, 'Checking the app before download...');
    bool? fullscreen;
    bool? topmost;
    bool windowChanged = false;
    bool unknown = false;
    Directory? cache;
    try {
      final found = await _detect();
      if (found != null) {
        executable = found;
        _set(StorePhase.ready, '${app.title} is already installed.');
        return;
      }
      if (installedEvidence) {
        throw StateError(
          'An existing installation was detected. Locate it instead of installing again.',
        );
      }
      if (!wingetAvailable) {
        throw StateError(
          'Windows App Installer (WinGet) is unavailable. Contact support.',
        );
      }
      cache = Directory(
        '${root.path}\\downloads\\${app.key}-${DateTime.now().microsecondsSinceEpoch}',
      );
      await cache.create(recursive: true);
      _set(StorePhase.downloading, 'Downloading ${app.title}...');
      final r = await _run(
        'winget.exe',
        [
          'download',
          '--id',
          app.packageId!,
          '--exact',
          '--source',
          'winget',
          '--architecture',
          'x64',
          '--scope',
          app.scope!,
          '--download-directory',
          cache.path,
          '--accept-source-agreements',
          '--accept-package-agreements',
          '--disable-interactivity',
        ],
        const Duration(minutes: 15),
        download: true,
      );
      if (_cancelled) {
        _set(
          StorePhase.available,
          'Download cancelled. Nothing was installed.',
        );
        return;
      }
      if (r.code != 0) {
        if (r.code == -2147012889 ||
            details.toLowerCase().contains('80072ee7')) {
          throw StateError(
            'The download server could not be resolved. Check your connection and retry.',
          );
        }
        throw StateError(
          'Download failed (WinGet ${r.code}). Nothing was executed.',
        );
      }
      _set(StorePhase.verifying, 'Verifying the downloaded package...');
      final packages = <StorePackage>[];
      final binaries = <File>[];
      await for (final entry in cache.list()) {
        if (entry is! File) continue;
        final lower = entry.path.toLowerCase();
        if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
          try {
            packages.add(parseStoreManifest(await entry.readAsString(), app));
          } on FormatException catch (e) {
            _log('\nManifest rejected: $e');
          }
        } else if (lower.endsWith('.exe') || lower.endsWith('.msi')) {
          binaries.add(entry);
        }
      }
      if (packages.length != 1) {
        throw StateError(
          'WinGet did not provide one approved manifest. Do not install manually; send Details to support.',
        );
      }
      final package = packages.single;
      File? installer;
      for (final binary in binaries) {
        final digest = await sha256.bind(binary.openRead()).first;
        if (digest.toString() == package.hash) {
          if (installer != null) {
            throw StateError('Multiple matching installers found.');
          }
          installer = binary;
        }
      }
      if (installer == null) {
        throw StateError(
          'Downloaded installer hash does not match the manifest. Nothing executed.',
        );
      }
      if ((package.kind == 'msi' &&
              !installer.path.toLowerCase().endsWith('.msi')) ||
          (package.kind == 'nsis' &&
              !installer.path.toLowerCase().endsWith('.exe'))) {
        throw StateError(
          'Installer file type does not match the approved package.',
        );
      }
      final helper = await _helper('assets/native/store_install.ps1');
      fullscreen = await windowManager.isFullScreen();
      topmost = await windowManager.isAlwaysOnTop();
      windowChanged = true;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setFullScreen(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );
      await windowManager.show();
      await windowManager.focus();
      _set(
        StorePhase.approval,
        app.scope == 'machine'
            ? 'Approve the Windows request to install ${app.title}.'
            : 'Preparing installation for your Windows account...',
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await pendingFile.writeAsString(
        jsonEncode({
          'app': app.key,
          'started': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      unknown = true;
      _set(
        StorePhase.installing,
        'Installing ${app.title}. Windows approval may be required...',
      );
      final result = await _run(
        'powershell.exe',
        _ps(helper, [
          '-AppKey',
          app.key,
          '-Installer',
          installer.path,
          '-ExpectedHash',
          package.hash,
        ]),
        const Duration(minutes: 12),
      );
      if (result.code != 0) {
        throw StateError(
          'Installer result could not be confirmed. Contact support before retrying.',
        );
      }
      final response =
          jsonDecode(result.output.replaceFirst('\uFEFF', '').trim()) as Map;
      if (response['pending'] == true) {
        _set(
          StorePhase.pending,
          'Windows installation is still running. Do not launch another installer.',
        );
        return;
      }
      unknown = false;
      if (await pendingFile.exists()) await pendingFile.delete();
      if (response['cancelled'] == true || response['code'] == 1223) {
        _set(
          StorePhase.available,
          'Windows approval was declined. Nothing else will be started.',
        );
        return;
      }
      if (response['code'] != 0 && response['code'] != 3010) {
        throw StateError(
          'Windows installer returned ${response['code']}. Review Details or contact support.',
        );
      }
      _set(StorePhase.detecting, 'Checking that ${app.title} is ready...');
      for (int i = 0; i < 6; i++) {
        executable = await _detect();
        if (executable != null) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (executable == null) {
        throw StateError(
          'Setup finished but the app was not found. Restart Windows if requested, or contact support.',
        );
      }
      _set(
        StorePhase.ready,
        response['code'] == 3010
            ? '${app.title} installed. Restart Windows before use.'
            : '${app.title} installed and ready.',
      );
    } catch (e) {
      _log('\n$e');
      _set(
        unknown ? StorePhase.pending : StorePhase.failed,
        _cancelled
            ? 'Download cancelled. Nothing was installed.'
            : e.toString().replaceFirst('Bad state: ', ''),
      );
    } finally {
      if (windowChanged && !unknown) {
        try {
          await windowManager.setTitleBarStyle(
            TitleBarStyle.hidden,
            windowButtonVisibility: false,
          );
          if (fullscreen != null) await windowManager.setFullScreen(fullscreen);
          if (topmost != null) await windowManager.setAlwaysOnTop(topmost);
          await windowManager.show();
          await windowManager.focus();
        } catch (e) {
          _log('\nWindow restoration: $e');
        }
      }
      if (!unknown && cache != null) {
        try {
          await cache.delete(recursive: true);
        } catch (_) {}
      }
      _operation = false;
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
