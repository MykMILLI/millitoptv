import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Severity of a log entry.
enum LogLevel { debug, info, warn, error }

/// Well-known log categories. Plain strings so new areas can add their own.
abstract final class LogCategory {
  static const app = 'app';
  static const nav = 'nav';
  static const catalog = 'catalog';
  static const jellyfin = 'jellyfin';
  static const playback = 'playback';
  static const dvr = 'dvr';
  static const weather = 'weather';
  static const sync = 'sync';
  static const network = 'network';
  static const audit = 'audit';
  static const analytics = 'analytics';

  static const all = [
    app,
    nav,
    catalog,
    jellyfin,
    playback,
    dvr,
    weather,
    sync,
    network,
    audit,
    analytics,
  ];
}

class AppLogEntry {
  AppLogEntry({
    required this.time,
    required this.level,
    required this.category,
    required this.message,
    this.details = const {},
    this.error,
    this.stackTrace,
    this.hint,
    this.sessionId = '',
    this.profileId,
  });

  final DateTime time;
  final LogLevel level;
  final String category;
  final String message;
  final Map<String, Object?> details;
  final String? error;
  final String? stackTrace;

  /// Plain-language suggestion for fixing the problem, when one is known.
  final String? hint;
  final String sessionId;
  final int? profileId;

  bool get isAnalytics => category == LogCategory.analytics;

  Map<String, Object?> toJson() => {
    't': time.toUtc().toIso8601String(),
    'lvl': level.name,
    'cat': category,
    'msg': message,
    if (details.isNotEmpty) 'details': details,
    'err': ?error,
    'stack': ?stackTrace,
    'hint': ?hint,
    if (sessionId.isNotEmpty) 'session': sessionId,
    'profile': ?profileId,
  };

  static AppLogEntry? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final time = DateTime.tryParse(raw['t']?.toString() ?? '');
    if (time == null) {
      return null;
    }
    final level = LogLevel.values.firstWhere(
      (item) => item.name == raw['lvl'],
      orElse: () => LogLevel.info,
    );
    final details = raw['details'];
    return AppLogEntry(
      time: time.toLocal(),
      level: level,
      category: raw['cat']?.toString() ?? LogCategory.app,
      message: raw['msg']?.toString() ?? '',
      details: details is Map
          ? details.map((key, value) => MapEntry(key.toString(), value))
          : const {},
      error: raw['err']?.toString(),
      stackTrace: raw['stack']?.toString(),
      hint: raw['hint']?.toString(),
      sessionId: raw['session']?.toString() ?? '',
      profileId: int.tryParse(raw['profile']?.toString() ?? ''),
    );
  }

  /// One readable line (plus hint/error lines) for exports and copy/paste.
  String toDisplayString() {
    final buffer = StringBuffer()
      ..write(time.toIso8601String())
      ..write(' ')
      ..write(level.name.toUpperCase().padRight(5))
      ..write(' [')
      ..write(category)
      ..write('] ')
      ..write(message);
    if (details.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(jsonEncode(details));
    }
    if (error != null) {
      buffer
        ..write('\n    error: ')
        ..write(error);
    }
    if (hint != null) {
      buffer
        ..write('\n    fix: ')
        ..write(hint);
    }
    if (stackTrace != null && stackTrace!.isNotEmpty) {
      buffer
        ..write('\n    ')
        ..write(stackTrace!.trim().split('\n').take(12).join('\n    '));
    }
    return buffer.toString();
  }
}

/// Sends a batch of redacted entries to the dashboard. Returns normally on
/// success; throwing keeps the batch queued for the next attempt.
typedef AppLogUploader =
    Future<void> Function(List<Map<String, Object?>> batch);

/// App-wide audit, diagnostics, and usage-analytics log.
///
/// * Keeps the most recent [bufferSize] entries in memory for the in-app
///   Diagnostics screen.
/// * Appends JSON lines to `<app support>/logs/millitop-YYYY-MM-DD.log`,
///   keeping [retainDays] days and at most [maxFileBytes] per day.
/// * Redacts tokens, API keys, passwords and URL credentials before anything
///   is stored or uploaded.
/// * Attaches a fix suggestion ([AppLogEntry.hint]) to known error types.
/// * Optionally uploads warnings, errors, audit and analytics events in
///   batches (never debug/info noise) when usage sharing is enabled.
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int bufferSize = 2000;
  static const int retainDays = 7;
  static const int maxFileBytes = 5 * 1024 * 1024;
  static const String _shareUsageKey = 'diagnostics.shareUsage.v1';
  static const String _verboseKey = 'diagnostics.verbose.v1';

  final ListQueue<AppLogEntry> _buffer = ListQueue<AppLogEntry>();
  final List<String> _pendingLines = [];
  final List<Map<String, Object?>> _pendingUpload = [];

  /// Bumps whenever an entry is added so UI can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final String sessionId = _newSessionId();
  int? profileId;
  String appVersion = '';
  String platform = kIsWeb ? 'web' : defaultTargetPlatform.name;

  Directory? _directory;
  Timer? _flushTimer;
  Timer? _uploadTimer;
  bool _writing = false;
  bool _initialized = false;
  bool shareUsage = true;
  bool verbose = false;
  AppLogUploader? uploader;

  /// Overridable clock for tests.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  List<AppLogEntry> get entries => List.unmodifiable(_buffer);
  Directory? get directory => _directory;

  static String _newSessionId() {
    final random = Random();
    return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  /// Opens the log directory and loads preferences. Safe to call more than
  /// once; logging works (memory only) before this completes.
  Future<void> init({
    Future<Directory> Function()? directory,
    bool writeFiles = true,
  }) async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      shareUsage = prefs.getBool(_shareUsageKey) ?? true;
      verbose = prefs.getBool(_verboseKey) ?? false;
    } catch (_) {}
    if (!writeFiles || kIsWeb) {
      return;
    }
    try {
      final base = await (directory ?? getApplicationSupportDirectory)();
      final logs = Directory(p.join(base.path, 'logs'));
      await logs.create(recursive: true);
      _directory = logs;
      unawaited(_pruneOldFiles());
      _scheduleFlush();
    } catch (error) {
      debugPrint('AppLog: file logging unavailable: $error');
    }
  }

  Future<void> setShareUsage(bool value) async {
    shareUsage = value;
    if (!value) {
      _pendingUpload.clear();
    }
    await (await SharedPreferences.getInstance()).setBool(
      _shareUsageKey,
      value,
    );
    audit('Usage sharing ${value ? 'enabled' : 'disabled'}');
  }

  Future<void> setVerbose(bool value) async {
    verbose = value;
    await (await SharedPreferences.getInstance()).setBool(_verboseKey, value);
  }

  // ---- Static shorthands ---------------------------------------------------

  static void debug(
    String category,
    String message, {
    Map<String, Object?> details = const {},
  }) => instance.log(LogLevel.debug, category, message, details: details);

  static void info(
    String category,
    String message, {
    Map<String, Object?> details = const {},
  }) => instance.log(LogLevel.info, category, message, details: details);

  static void warn(
    String category,
    String message, {
    Map<String, Object?> details = const {},
    Object? error,
    StackTrace? stackTrace,
    String? hint,
  }) => instance.log(
    LogLevel.warn,
    category,
    message,
    details: details,
    error: error,
    stackTrace: stackTrace,
    hint: hint,
  );

  static void error(
    String category,
    String message, {
    Map<String, Object?> details = const {},
    Object? error,
    StackTrace? stackTrace,
    String? hint,
  }) => instance.log(
    LogLevel.error,
    category,
    message,
    details: details,
    error: error,
    stackTrace: stackTrace,
    hint: hint,
  );

  /// Something a user or admin changed (settings, sign-in, deletes...).
  static void audit(String action, {Map<String, Object?> details = const {}}) =>
      instance.log(LogLevel.info, LogCategory.audit, action, details: details);

  /// A usage event for analytics, e.g. `media.play` or `screen.view`.
  static void event(String name, {Map<String, Object?> props = const {}}) =>
      instance.log(LogLevel.info, LogCategory.analytics, name, details: props);

  // ---- Core ----------------------------------------------------------------

  void log(
    LogLevel level,
    String category,
    String message, {
    Map<String, Object?> details = const {},
    Object? error,
    StackTrace? stackTrace,
    String? hint,
  }) {
    if (level == LogLevel.debug && !verbose && !kDebugMode) {
      return;
    }
    final errorText = error == null ? null : redact(_describeError(error));
    final entry = AppLogEntry(
      time: clock(),
      level: level,
      category: category,
      message: redact(message),
      details: _redactDetails(details),
      error: errorText,
      stackTrace: stackTrace == null ? null : redact(stackTrace.toString()),
      hint:
          hint ??
          (level.index >= LogLevel.warn.index ? hintFor(error, message) : null),
      sessionId: sessionId,
      profileId: profileId,
    );
    _buffer.addLast(entry);
    while (_buffer.length > bufferSize) {
      _buffer.removeFirst();
    }
    if (kDebugMode && level.index >= LogLevel.warn.index) {
      debugPrint(entry.toDisplayString());
    }
    if (_directory != null) {
      _pendingLines.add(jsonEncode(entry.toJson()));
      _scheduleFlush();
    }
    if (shareUsage &&
        uploader != null &&
        (level.index >= LogLevel.warn.index ||
            category == LogCategory.analytics ||
            category == LogCategory.audit)) {
      _pendingUpload.add({
        ...entry.toJson()..remove('stack'),
        'app': appVersion,
        'platform': platform,
      });
      if (_pendingUpload.length > 500) {
        _pendingUpload.removeRange(0, _pendingUpload.length - 500);
      }
      _scheduleUpload();
    }
    revision.value++;
  }

  static String _describeError(Object error) {
    final text = error.toString();
    if (error is Error || error is Exception) {
      final type = error.runtimeType.toString();
      return text.startsWith(type) ? text : '$type: $text';
    }
    return text;
  }

  Map<String, Object?> _redactDetails(Map<String, Object?> details) {
    if (details.isEmpty) {
      return const {};
    }
    return details.map((key, value) {
      if (_secretKey.hasMatch(key)) {
        return MapEntry(key, '***');
      }
      if (value is String) {
        return MapEntry(key, redact(value));
      }
      if (value is num || value is bool || value == null) {
        return MapEntry(key, value);
      }
      return MapEntry(key, redact(value.toString()));
    });
  }

  static final RegExp _secretKey = RegExp(
    r'(token|password|passwd|secret|api[_-]?key|authorization)',
    caseSensitive: false,
  );

  static final List<(RegExp, String)> _redactions = [
    // scheme://user:pass@host
    (RegExp(r'(\w+://)[^/\s:@]+:[^/\s@]+@'), r'$1***:***@'),
    // ?api_key=..., &token=..., password=..., X-Emby-Token=...
    (
      RegExp(
        r'((?:api[_-]?key|access[_-]?token|token|password|passwd|pw|secret|x-emby-token|x-mediabrowser-token)=)[^&\s"]+',
        caseSensitive: false,
      ),
      r'$1***',
    ),
    // Token="..." inside MediaBrowser authorization headers
    (RegExp(r'(Token=")[^"]*(")', caseSensitive: false), r'$1***$2'),
    // Authorization: Bearer xxx
    (RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]+', caseSensitive: false), r'$1***'),
    // Xtream style /live/<user>/<pass>/123.ts, /movie/..., /series/...
    (
      RegExp(r'/(live|movie|series|timeshift)/[^/\s]+/[^/\s]+/'),
      r'/$1/***/***/',
    ),
    // username=...&password=... handled above; also user=
    (RegExp(r'((?:username|user)=)[^&\s"]+', caseSensitive: false), r'$1***'),
  ];

  /// Removes credentials from free text (URLs, headers, exception messages).
  static String redact(String input) {
    var output = input;
    for (final (pattern, replacement) in _redactions) {
      output = output.replaceAllMapped(pattern, (match) {
        return replacement.replaceAllMapped(RegExp(r'\$(\d)'), (group) {
          final index = int.parse(group[1]!);
          return index <= match.groupCount ? (match[index] ?? '') : '';
        });
      });
    }
    return output;
  }

  /// Maps common failures to a plain-language next step.
  static String? hintFor(Object? error, [String message = '']) {
    final text = '${error ?? ''} $message'.toLowerCase();
    final status = RegExp(
      r'(?:http|status|statuscode|code)[^0-9]{0,4}([1-5]\d\d)',
    ).firstMatch(text)?.group(1);
    if (error is TimeoutException || text.contains('timed out')) {
      return 'The server took too long to answer. Check that it is online '
          'and reachable from this device, then retry. Large IPTV lists may '
          'need a faster connection or a smaller category set.';
    }
    if (error is HandshakeException ||
        text.contains('handshake') ||
        text.contains('certificate')) {
      return 'TLS/certificate problem. Use the correct https address, make '
          'sure the certificate is valid and the device clock is correct, or '
          'try http:// for a server on your local network.';
    }
    if (error is SocketException ||
        text.contains('failed host lookup') ||
        text.contains('connection refused') ||
        text.contains('network is unreachable') ||
        text.contains('connection reset')) {
      return 'Could not reach the server. Check the address and port, the '
          'device network connection, VPN, and that a firewall is not '
          'blocking the app (on Windows: allow MILLITOP TV in Defender '
          'Firewall).';
    }
    if (status == '401' || text.contains('unauthorized')) {
      return 'The server rejected the credentials. Sign in again or update '
          'the username/password or API key for this source.';
    }
    if (status == '403' || text.contains('forbidden')) {
      return 'The account does not have permission for this. Check the user '
          'permissions on the server (for Jellyfin: Library access in the '
          'user settings) or the IPTV subscription status.';
    }
    if (status == '404') {
      return 'The address was reached but the path does not exist. Check the '
          'server URL (no extra path), the playlist URL, or update the server.';
    }
    if (status == '429') {
      return 'Too many requests. Wait a minute before retrying; the provider '
          'may limit how often the list can be downloaded.';
    }
    if (status != null && status.startsWith('5')) {
      return 'The server returned an internal error ($status). Check the '
          'server logs; restarting the server often fixes this.';
    }
    if (error is FormatException ||
        text.contains('formatexception') ||
        text.contains('unexpected character')) {
      return 'The server answered with something that is not the expected '
          'format. Usually the URL points at a web page instead of the API '
          'or playlist; check the source address.';
    }
    if (text.contains('codec') ||
        text.contains('failed to open') ||
        text.contains('demux') ||
        text.contains('unsupported')) {
      return 'The player could not open this stream. Try another version of '
          'the title, switch the playback engine in Settings > Playback, or '
          'check that the stream URL plays in VLC.';
    }
    if (text.contains('no space left') || text.contains('disk full')) {
      return 'The device storage is full. Free up space and try again.';
    }
    if (error is FileSystemException || text.contains('permission denied')) {
      return 'The app could not read or write a file. Check folder '
          'permissions and that the drive/share is connected.';
    }
    return null;
  }

  // ---- Files ---------------------------------------------------------------

  File? _todayFile() {
    final dir = _directory;
    if (dir == null) {
      return null;
    }
    final now = clock();
    final day =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return File(p.join(dir.path, 'millitop-$day.log'));
  }

  void _scheduleFlush() {
    if (_flushTimer?.isActive ?? false) {
      return;
    }
    _flushTimer = Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  /// Writes buffered lines to today's log file.
  Future<void> flush() async {
    if (_writing || _pendingLines.isEmpty) {
      return;
    }
    final file = _todayFile();
    if (file == null) {
      _pendingLines.clear();
      return;
    }
    _writing = true;
    final lines = List<String>.from(_pendingLines);
    _pendingLines.clear();
    try {
      final size = await file.exists() ? await file.length() : 0;
      if (size < maxFileBytes) {
        await file.writeAsString(
          '${lines.join('\n')}\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    } catch (error) {
      debugPrint('AppLog: write failed: $error');
    } finally {
      _writing = false;
    }
    if (_pendingLines.isNotEmpty) {
      _scheduleFlush();
    }
  }

  Future<void> _pruneOldFiles() async {
    final dir = _directory;
    if (dir == null) {
      return;
    }
    final cutoff = clock().subtract(const Duration(days: retainDays));
    try {
      await for (final item in dir.list()) {
        if (item is File && item.path.endsWith('.log')) {
          final stat = await item.stat();
          if (stat.modified.isBefore(cutoff)) {
            await item.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// Log files on disk, newest first.
  Future<List<File>> logFiles() async {
    await flush();
    final dir = _directory;
    if (dir == null || !await dir.exists()) {
      return const [];
    }
    final files = <File>[
      await for (final item in dir.list())
        if (item is File && item.path.endsWith('.log')) item,
    ];
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// Human-readable report of the in-memory log with a device header,
  /// suitable for copy/paste into a support ticket.
  String report({Iterable<AppLogEntry>? only}) {
    final selected = (only ?? _buffer).toList();
    final buffer = StringBuffer()
      ..writeln('MILLITOP TV diagnostics')
      ..writeln('Generated: ${clock().toIso8601String()}')
      ..writeln('App version: ${appVersion.isEmpty ? 'unknown' : appVersion}')
      ..writeln('Platform: $platform')
      ..writeln('Session: $sessionId')
      ..writeln('Profile: ${profileId ?? '-'}')
      ..writeln(
        'Errors: ${selected.where((e) => e.level == LogLevel.error).length}, '
        'warnings: ${selected.where((e) => e.level == LogLevel.warn).length}',
      )
      ..writeln('-' * 60);
    for (final entry in selected) {
      buffer.writeln(entry.toDisplayString());
    }
    return buffer.toString();
  }

  /// Writes [report] to a file in the log folder and returns it.
  Future<File?> exportReport({Iterable<AppLogEntry>? only}) async {
    final dir = _directory ?? await Directory.systemTemp.createTemp('millitop');
    final stamp = clock().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File(p.join(dir.path, 'millitop-report-$stamp.txt'));
    await file.writeAsString(report(only: only));
    return file;
  }

  void clearMemory() {
    _buffer.clear();
    revision.value++;
  }

  // ---- Upload --------------------------------------------------------------

  void _scheduleUpload() {
    if (_uploadTimer?.isActive ?? false) {
      return;
    }
    _uploadTimer = Timer(
      const Duration(seconds: 45),
      () => unawaited(uploadPending()),
    );
  }

  /// Sends queued entries now. Failures keep them queued.
  Future<void> uploadPending() async {
    final send = uploader;
    if (send == null || !shareUsage || _pendingUpload.isEmpty) {
      return;
    }
    final batch = List<Map<String, Object?>>.from(_pendingUpload.take(100));
    try {
      await send(batch);
      _pendingUpload.removeRange(0, batch.length);
    } catch (error) {
      debugPrint('AppLog: upload failed: $error');
      return;
    }
    if (_pendingUpload.isNotEmpty) {
      _scheduleUpload();
    }
  }

  @visibleForTesting
  int get pendingUploadCount => _pendingUpload.length;

  @visibleForTesting
  void resetForTest() {
    _buffer.clear();
    _pendingLines.clear();
    _pendingUpload.clear();
    _flushTimer?.cancel();
    _uploadTimer?.cancel();
    _directory = null;
    _initialized = false;
    uploader = null;
    shareUsage = true;
    verbose = true;
    profileId = null;
    clock = DateTime.now;
  }
}

/// Records screen views for navigation troubleshooting and analytics.
class AppLogNavigatorObserver extends NavigatorObserver {
  String _name(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return route?.runtimeType.toString() ?? 'unknown';
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      AppLog.event(
        'screen.view',
        props: {'screen': _name(route), 'from': _name(previousRoute)},
      );
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      AppLog.debug(
        LogCategory.nav,
        'Back from ${_name(route)} to ${_name(previousRoute)}',
      );
    }
  }
}
