import 'update_launch.dart';
import 'update_poller.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';
import '../profiles/household_store.dart';
import '../store/store_job.dart';
import 'device_connection.dart';
import 'remote_inbox.dart';

bool newerRelease(
  String version,
  int build,
  String installed,
  int installedBuild,
) {
  List<int>? parts(String value) {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value)) return null;
    return value.split('.').map(int.parse).toList();
  }

  final a = parts(version), b = parts(installed);
  if (a == null || b == null) return false;
  for (int i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return build > installedBuild;
}

class AppUpdateView {
  final Map<String, dynamic>? release;
  final String message;
  final bool busy;
  final double? progress;
  const AppUpdateView({
    this.release,
    this.message = '',
    this.busy = false,
    this.progress,
  });
}

class AppUpdates with WidgetsBindingObserver {
  AppUpdates._();
  static final instance = AppUpdates._();
  final view = ValueNotifier<AppUpdateView>(const AppUpdateView());
  final link = DeviceConnection.instance;
  bool _started = false, _checking = false, _installing = false;
  bool recoveryRequired = false;
  bool _prepared = false;
  final Set<String> _androidConfirmedAssignments = <String>{};
  late final UpdatePoller _poller = UpdatePoller(check);
  PackageInfo? _info;

  String _releasePlatform() {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isAndroid) return 'android-universal';
    if (Platform.isIOS) return 'ios-universal';
    if (Platform.isLinux) return 'linux-x64';
    if (Platform.isMacOS) return 'macos-universal';
    return 'unknown';
  }

  Map<String, dynamic> _updateCheckPayload(PackageInfo info) {
    final build = int.tryParse(info.buildNumber);
    final payload = <String, dynamic>{'platform': _releasePlatform()};
    if (RegExp(r'^\d+\.\d+\.\d+$').hasMatch(info.version) &&
        build != null &&
        build > 0) {
      payload['version'] = info.version;
      payload['build'] = build;
    }
    return payload;
  }

  String _currentPlatformKey() => _releasePlatform().toLowerCase();

  bool _releaseMatchesCurrentPlatform(Map<String, dynamic> release) {
    final offered = release['platform']?.toString().toLowerCase().trim();
    return offered != null &&
        offered.isNotEmpty &&
        offered == _currentPlatformKey();
  }

  String _updateFailureContext(Map<String, dynamic>? release, String branch) {
    final info = _info;
    final currentVersion = info == null
        ? 'unknown'
        : '${info.version}+${info.buildNumber}';
    final offeredPlatform = release?['platform']?.toString() ?? 'unknown';
    final offeredVersion = release == null
        ? 'unknown'
        : '${release['version'] ?? 'unknown'}+${release['build'] ?? 'unknown'}';
    return 'branch=$branch runtime=${_currentPlatformKey()} app=$currentVersion offeredPlatform=$offeredPlatform offered=$offeredVersion';
  }

  String _windowsLocalAppDataPath() {
    final direct = Platform.environment['LOCALAPPDATA']?.trim();
    if (direct != null && direct.isNotEmpty) {
      return direct;
    }
    final profile = Platform.environment['USERPROFILE']?.trim();
    if (profile != null && profile.isNotEmpty) {
      return '$profile\\AppData\\Local';
    }
    throw StateError(
      'Windows update storage could not be resolved. LOCALAPPDATA and USERPROFILE are unavailable.',
    );
  }

  Directory get root {
    return Directory('${_windowsLocalAppDataPath()}\\MILLITOPTV\\updates');
  }

  File get pending => File('${root.path}\\pending.json');
  void _show(
    String message, {
    Map<String, dynamic>? release,
    bool busy = false,
    double? progress,
  }) {
    view.value = AppUpdateView(
      release: release,
      message: message,
      busy: busy,
      progress: progress,
    );
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    link.status.addListener(_connectionChanged);
    // Schedule retries before initialization: transient startup failures must
    // never leave the service permanently marked started without a timer.
    _poller.start();
  }

  void _connectionChanged() {
    if (link.isConnected) _poller.checkSoon();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _poller.checkSoon();
  }

  Future<void> _report(String id, String status, {String? error}) async {
    final key = link.connectionKey;
    if (key.isEmpty) return;
    // Event IDs need no external secrets and conform to the server UUID contract.
    final random = await _uuid();
    try {
      await link.postDevice('/api/device/updates/report', {
        'eventId': random,
        'assignmentId': id,
        'status': status,
        if (error != null)
          'error': error.length > 900 ? error.substring(0, 900) : error,
      }, expectedConnection: key);
    } catch (_) {
      /* Startup confirmation retries independently. */
    }
  }

  Future<String> _uuid() async => const Uuid().v4();
  Future<void> _finishStartup() async {
    if (!await pending.exists() || _info == null || !link.isEnrolled) return;
    final p = jsonDecode(await pending.readAsString()) as Map<String, dynamic>;
    final id = p['assignmentId'] as String;
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) {
      throw const FormatException('Invalid pending update.');
    }
    final directory = Directory('${root.path}\\$id');
    final resultFile = File('${directory.path}\\result.json');
    if (!await resultFile.exists()) return;
    final result = jsonDecode(await resultFile.readAsString()) as Map;
    final code = result['installerExitCode'];
    if (code != 0 && code != 3010) {
      await _report(
        id,
        'failed',
        error: code == 1223
            ? 'User declined Windows approval.'
            : 'Installer did not complete (code $code).',
      );
      await pending.delete();
      _show(
        code == 1223
            ? 'Update cancelled. Your previous version is still available.'
            : 'Update did not finish. The previous app was reopened where possible.',
      );
      return;
    }
    if (_info!.version != p['version'] ||
        int.tryParse(_info!.buildNumber) != p['build']) {
      await _report(
        id,
        'failed',
        error:
            'Installer exited but the running version differs from the target.',
      );
      await pending.delete();
      _show('The expected update version did not start. Contact support.');
      return;
    }
    try {
      await HouseholdStore.instance.initialize();
      await RemoteInbox.instance.start();
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 15),
      );
      await link.checkNow();
      if (!link.isConnected) return;
      await _report(id, 'awaiting_confirmation');
      await link.postDevice('/api/device/updates/confirm', {
        'assignmentId': id,
        'version': _info!.version,
        'build': int.parse(_info!.buildNumber),
        'startupVerified': true,
      }, expectedConnection: link.connectionKey);
      await pending.delete();
      _show(
        'Millitop updated to ${_info!.version}+${_info!.buildNumber}. Startup confirmed by the dashboard.',
      );
    } catch (_) {
      _show(
        'The updated app started. Dashboard confirmation is pending and will retry.',
      );
    }
  }

  Future<void> check() async {
    if (_checking || _installing) return;
    _checking = true;
    try {
      _info ??= await PackageInfo.fromPlatform();
      if (Platform.isWindows && !_prepared) {
        await root.create(recursive: true);
        _prepared = true;
      }
      await link.start();
      if (!link.isConnected) return;
      // Pending confirmation must not permanently stop discovery of offers.
      // The existing pending-file/install guards still block unsafe installs.
      if (Platform.isWindows) {
        try {
          await _finishStartup();
        } catch (_) {
          recoveryRequired = true;
          debugPrint(
            'Update confirmation needs attention; discovery will retry.',
          );
        }
      }
      if (!link.isConnected) return;
      final expected = link.connectionKey;
      final response = await link.postDevice(
        '/api/device/updates/check',
        _updateCheckPayload(_info!),
        expectedConnection: expected,
      );
      if (link.connectionKey != expected || !link.isConnected) return;
      final raw = response['update'];
      if (raw is! Map) return;
      final r = Map<String, dynamic>.from(raw);
      if (r['version'] is! String ||
          r['build'] is! int ||
          r['assignmentId'] is! String) {
        return;
      }
      if (!_releaseMatchesCurrentPlatform(r)) {
        await _report(
          r['assignmentId'] as String,
          'failed',
          error:
              'Offered release platform does not match this device platform.',
        );
        return;
      }
      await _confirmAndroidInstallIfCurrent(r, expectedConnection: expected);
      if (!newerRelease(
        r['version'] as String,
        r['build'] as int,
        _info!.version,
        int.tryParse(_info!.buildNumber) ?? 0,
      )) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final until = prefs.getInt('updates.defer.${r['assignmentId']}') ?? 0;
      if (until > DateTime.now().millisecondsSinceEpoch) return;
      if (view.value.release?['assignmentId'] != r['assignmentId']) {
        _show(
          'Millitop ${r['version']}+${r['build']} is available.',
          release: r,
        );
        await _report(r['assignmentId'] as String, 'offered');
      }
    } catch (_) {
      debugPrint('Automatic update discovery failed; retry is scheduled.');
    } finally {
      _checking = false;
    }
  }

  Future<void> _confirmAndroidInstallIfCurrent(
    Map<String, dynamic> release, {
    required String expectedConnection,
  }) async {
    if (!Platform.isAndroid || _info == null || !link.isConnected) return;
    if (link.connectionKey != expectedConnection) return;
    final id = release['assignmentId']?.toString() ?? '';
    final version = release['version']?.toString() ?? '';
    final build = release['build'];
    final installedBuild = int.tryParse(_info!.buildNumber);
    if (id.isEmpty ||
        _androidConfirmedAssignments.contains(id) ||
        build is! int ||
        installedBuild == null ||
        version != _info!.version ||
        build != installedBuild) {
      return;
    }
    try {
      await _report(id, 'awaiting_confirmation');
      if (link.connectionKey != expectedConnection || !link.isConnected) return;
      await link.postDevice('/api/device/updates/confirm', {
        'assignmentId': id,
        'version': _info!.version,
        'build': installedBuild,
        'startupVerified': true,
      }, expectedConnection: expectedConnection);
      _androidConfirmedAssignments.add(id);
    } catch (_) {
      debugPrint(
        'Android update verification is pending; confirmation will retry.',
      );
    }
  }

  Future<Map<String, dynamic>?> availableForAccount() async {
    await link.start();
    if (!link.isEnrolled || link.isSuspended) {
      throw StateError(
        'Pair this device, or restore its connection, before checking updates.',
      );
    }
    final expected = link.connectionKey;
    final info = _info ?? await PackageInfo.fromPlatform();
    final response = await link.postDevice(
      '/api/device/updates/check',
      _updateCheckPayload(info),
      expectedConnection: expected,
    );
    if (link.connectionKey != expected) {
      throw StateError('Device connection changed. Check again.');
    }
    final raw = response['update'];
    if (raw is! Map) {
      return null;
    }
    final result = Map<String, dynamic>.from(raw);
    if (result['version'] is! String ||
        result['build'] is! int ||
        result['assignmentId'] is! String ||
        !_releaseMatchesCurrentPlatform(result) ||
        !newerRelease(
          result['version'] as String,
          result['build'] as int,
          info.version,
          int.tryParse(info.buildNumber) ?? 0,
        )) {
      return null;
    }
    return result;
  }

  bool _accountStarting = false;
  Future<void> installFromAccount(Map<String, dynamic> offered) async {
    if (_accountStarting || _installing) {
      return;
    }
    _accountStarting = true;
    try {
      final fresh = await availableForAccount();
      if (fresh == null || fresh['assignmentId'] != offered['assignmentId']) {
        throw StateError(
          'This update is no longer offered to this device. Check again.',
        );
      }
      _show(
        'Millitop ${fresh['version']}+${fresh['build']} is available.',
        release: fresh,
      );
      await _report(fresh['assignmentId'] as String, 'offered');
      await install();
    } finally {
      _accountStarting = false;
    }
  }

  Future<void> later() async {
    final r = view.value.release;
    if (r != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'updates.defer.${r['assignmentId']}',
        DateTime.now().add(const Duration(hours: 4)).millisecondsSinceEpoch,
      );
      await _report(r['assignmentId'] as String, 'deferred');
    }
    _show('');
  }

  void dismiss() {
    if (!view.value.busy) _show('');
  }

  Future<void> _download(
    Uri uri,
    File target,
    int maximum, {
    int? expected,
    Map<String, dynamic>? release,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      HttpClientResponse? response;
      for (int redirect = 0; redirect < 6; redirect++) {
        if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
          throw const FormatException('Updates require HTTPS.');
        }
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        response = await request.close().timeout(const Duration(seconds: 30));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final next = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (next == null) {
            throw const FormatException('Invalid update redirect.');
          }
          uri = uri.resolve(next);
          response = null;
          continue;
        }
        break;
      }
      if (response == null || response.statusCode != 200) {
        throw const HttpException('Could not download the update.');
      }
      if (response.contentLength > maximum) {
        throw const FormatException('Update exceeds allowed size.');
      }
      final sink = target.openWrite();
      int received = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 45),
        )) {
          received += chunk.length;
          if (received > maximum) {
            throw const FormatException('Update download is too large.');
          }
          sink.add(chunk);
          if (expected != null && release != null) {
            _show(
              'Downloading update...',
              release: release,
              busy: true,
              progress: (received / expected).clamp(0.0, 1.0),
            );
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (expected != null && received != expected) {
        throw const FormatException(
          'Update size does not match the signed release.',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _helper() async {
    final file = File('${root.path}\\update_worker.ps1');
    await file.writeAsString(
      await rootBundle.loadString('assets/native/update_worker.ps1'),
      flush: true,
    );
    return file.path;
  }

  List<String> _arguments(
    String helper,
    String action,
    Map<String, dynamic> r,
    File envelope,
    File exe,
  ) => [
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    helper,
    '-Action',
    action,
    '-EnvelopePath',
    envelope.path,
    '-ExpectedVersion',
    r['version'].toString(),
    '-ExpectedBuild',
    r['build'].toString(),
    '-ExpectedHash',
    r['sha256'].toString(),
    '-ExpectedBytes',
    r['sizeBytes'].toString(),
    '-InstallerPath',
    exe.path,
  ];
  Future<void> install() async {
    final r = view.value.release;
    if (r == null || _installing) return;
    if (!_releaseMatchesCurrentPlatform(r)) {
      final id = r['assignmentId']?.toString() ?? '';
      if (id.isNotEmpty) {
        await _report(
          id,
          'failed',
          error:
              'Release platform does not match this device. ${_updateFailureContext(r, 'install_guard')}',
        );
      }
      _show(
        'This update does not match this device platform. Refresh release status.',
        release: r,
      );
      return;
    }
    if (Platform.isAndroid) {
      await _installAndroid(r);
      return;
    }
    if (!Platform.isWindows) {
      _show(
        'This platform does not support in-app managed installer updates yet.',
        release: r,
      );
      return;
    }
    final storeInstallPending = Platform.isWindows
        ? await File(
            '${_windowsLocalAppDataPath()}\\MILLITOPTV\\store\\installation-pending.json',
          ).exists()
        : false;
    if (StoreJob.operationActive || link.mediaActive || storeInstallPending) {
      _show(
        'Finish playback or the other installation, then retry the update.',
        release: r,
      );
      return;
    }
    if (await pending.exists()) {
      recoveryRequired = true;
      _show(
        'A previous update needs confirmation before another can start.',
        release: r,
      );
      return;
    }
    _installing = true;
    try {
      final id = r['assignmentId'] as String;
      if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(id)) {
        throw const FormatException('Invalid assignment.');
      }
      final bytes = int.tryParse(r['sizeBytes'].toString());
      if (bytes == null ||
          bytes < 1 ||
          bytes > 1073741824 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(r['sha256'].toString())) {
        throw const FormatException('Invalid release metadata.');
      }
      final uri = Uri.parse(r['installerUrl'] as String);
      if (uri.scheme != 'https' ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException(
          'Use a stable HTTPS installer URL without query parameters.',
        );
      }
      final directory = Directory('${root.path}\\$id');
      await directory.create(recursive: true);
      final envelope = File('${directory.path}\\release.json');
      final exe = File('${directory.path}\\update.exe');
      final ready = File('${directory.path}\\ready.json');
      final result = File('${directory.path}\\result.json');
      for (final old in [ready, result]) {
        if (await old.exists()) await old.delete();
      }
      _show('Checking the signed release...', release: r, busy: true);
      await _download(
        uri.replace(path: '${uri.path}.release.json'),
        envelope,
        65536,
      );
      final helper = await _helper();
      final metadata = await Process.run(
        'powershell.exe',
        _arguments(helper, 'Metadata', r, envelope, exe),
      ).timeout(const Duration(seconds: 30));
      if (metadata.exitCode != 0) {
        throw StateError('Release signature failed. Nothing was installed.');
      }
      await _report(id, 'downloading');
      await _download(uri, exe, bytes, expected: bytes, release: r);
      _show('Verifying the installer...', release: r, busy: true);
      final hash = await sha256.bind(exe.openRead()).first;
      if (hash.toString() != r['sha256']) {
        throw const FormatException(
          'Installer hash mismatch. Nothing executed.',
        );
      }
      final verified = await Process.run(
        'powershell.exe',
        _arguments(helper, 'Verify', r, envelope, exe),
      ).timeout(const Duration(seconds: 60));
      if (verified.exitCode != 0) {
        throw StateError(
          'Installer verification failed. Nothing was installed.',
        );
      }
      await _report(id, 'downloaded');
      _show(
        'Preparing to close Millitop and install. Windows may request approval.',
        release: r,
        busy: true,
      );
      await pending.writeAsString(
        jsonEncode({
          'assignmentId': id,
          'version': r['version'],
          'build': r['build'],
        }),
        flush: true,
      );
      final bootstrap = File('${root.path}\\update_bootstrap.ps1');
      await bootstrap.writeAsString(
        await rootBundle.loadString('assets/native/update_bootstrap.ps1'),
        flush: true,
      );
      final request = File('${directory.path}\\worker-request.json');
      await request.writeAsString(
        jsonEncode({
          'worker': helper,
          'envelopePath': envelope.path,
          'version': r['version'],
          'build': r['build'],
          'sha256': r['sha256'],
          'sizeBytes': bytes,
          'installerPath': exe.path,
          'appPid': pid,
          'appExe': Platform.resolvedExecutable,
          'stateDirectory': directory.path,
        }),
        flush: true,
      );
      final systemRoot = Platform.environment['SystemRoot'];
      if (systemRoot == null) {
        throw StateError('Windows system directory is unavailable.');
      }
      final powershell =
          '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      final startupLog = File('${directory.path}\\worker-startup.log');
      void captureStartup(String text) {
        try {
          startupLog.writeAsStringSync(
            text,
            mode: FileMode.append,
            flush: true,
          );
        } catch (_) {
          // A logging failure must not disrupt the signed installer worker.
        }
      }

      captureStartup(
        '${DateTime.now().toUtc().toIso8601String()} starting normal launcher\n',
      );
      ProcessResult launch;
      try {
        launch = await Process.run(
          powershell,
          [
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle',
            'Hidden',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            updateWorkerLaunchCommand(powershell, bootstrap.path, request.path),
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 20));
      } catch (error) {
        recoveryRequired = true;
        captureStartup('Launcher failed: $error\n');
        rethrow;
      }
      captureStartup('Launcher exit code: ${launch.exitCode}\n');
      captureStartup(launch.stdout.toString());
      captureStartup(launch.stderr.toString());
      if (launch.exitCode != 0) {
        recoveryRequired = true;
        throw StateError(
          'Updater launcher failed (${launch.exitCode}). Retry is blocked; startup diagnostics were saved.',
        );
      }
      if (!RegExp(
        r'^WORKER_PID=\d+\r?$',
        multiLine: true,
      ).hasMatch(launch.stdout.toString())) {
        recoveryRequired = true;
        throw StateError(
          'Updater launcher returned no worker PID. Retry is blocked; startup diagnostics were saved.',
        );
      }
      bool handedOff = false;
      for (int attempt = 0; attempt < 120; attempt++) {
        if (await ready.exists()) {
          handedOff = true;
          break;
        }
        if (await result.exists()) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!handedOff) {
        recoveryRequired = true;
        String reason = 'Updater startup did not confirm readiness.';
        if (await result.exists()) {
          try {
            final failure = jsonDecode(await result.readAsString()) as Map;
            final error = failure['error'];
            if (error is String && error.isNotEmpty) {
              reason = error.length > 500 ? error.substring(0, 500) : error;
            }
          } catch (_) {}
        }
        throw StateError(
          '$reason Retry is blocked. Keep Millitop open; startup logs were saved for support.',
        );
      }
      await _report(id, 'installing');
      RemoteInbox.instance.stop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      await _report(
        r['assignmentId'].toString(),
        'failed',
        error: '${e.toString()} ${_updateFailureContext(r, 'windows_install')}',
      );
      _show(e.toString().replaceFirst('Bad state: ', ''), release: r);
    } finally {
      _installing = false;
    }
  }

  Future<void> _installAndroid(Map<String, dynamic> release) async {
    if (_installing) {
      return;
    }
    _installing = true;
    try {
      final id = release['assignmentId']?.toString() ?? '';
      final uri = Uri.parse(release['installerUrl']?.toString() ?? '');
      final bytes = int.tryParse(release['sizeBytes']?.toString() ?? '');
      final expectedSha = release['sha256']?.toString().toLowerCase() ?? '';
      if (id.isEmpty) {
        throw const FormatException('Invalid Android update assignment.');
      }
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException(
          'Android update URL must be stable HTTPS without query parameters.',
        );
      }
      if (bytes == null || bytes < 1 || bytes > 1073741824) {
        throw const FormatException('Invalid Android update size metadata.');
      }
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha)) {
        throw const FormatException(
          'Invalid Android update signature metadata.',
        );
      }
      final support = await getApplicationSupportDirectory();
      final downloadDir = await Directory(
        '${support.path}/updates/android',
      ).create(recursive: true);
      final apk = File('${downloadDir.path}/$id.apk');
      await _report(id, 'downloading');
      _show('Downloading Android update...', release: release, busy: true);
      await _download(uri, apk, bytes, expected: bytes, release: release);
      final actualSha = await sha256.bind(apk.openRead()).first;
      if (actualSha.toString() != expectedSha) {
        throw const FormatException(
          'Downloaded Android update does not match the signed release hash.',
        );
      }
      await _report(id, 'downloaded');
      _show('Opening Android installer...', release: release, busy: true);
      final result = await OpenFilex.open(
        apk.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw StateError(
          result.message.isEmpty
              ? 'Android installer could not be opened. Allow install from this app and try again.'
              : result.message,
        );
      }
      await _report(id, 'installing');
      _show(
        'Android installer is ready. Complete installation, then reopen Millitop for verification.',
        release: release,
      );
    } catch (e) {
      await _report(
        release['assignmentId']?.toString() ?? '',
        'failed',
        error:
            '${e.toString()} ${_updateFailureContext(release, 'android_install')}',
      );
      _show(e.toString().replaceFirst('Bad state: ', ''), release: release);
    } finally {
      _installing = false;
    }
  }
}
