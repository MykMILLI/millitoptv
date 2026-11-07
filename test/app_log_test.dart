import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.instance.resetForTest();
  });

  test('redacts credentials in URLs, query strings and headers', () {
    expect(
      AppLog.redact('http://bob:hunter2@host:8080/get.php'),
      'http://***:***@host:8080/get.php',
    );
    expect(
      AppLog.redact(
        'https://h/player_api.php?username=bob&password=pw&action=x',
      ),
      'https://h/player_api.php?username=***&password=***&action=x',
    );
    expect(
      AppLog.redact('http://h/movie/bob/pw/123.mp4'),
      'http://h/movie/***/***/123.mp4',
    );
    expect(
      AppLog.redact('/Videos/1/stream?static=true&api_key=abc123'),
      '/Videos/1/stream?static=true&api_key=***',
    );
    expect(
      AppLog.redact('MediaBrowser Client="x", Token="secret"'),
      'MediaBrowser Client="x", Token="***"',
    );
  });

  test('suggests fixes for common failures', () {
    expect(
      AppLog.hintFor(const SocketException('Failed host lookup')),
      contains('Could not reach the server'),
    );
    expect(AppLog.hintFor(TimeoutException('x')), contains('too long'));
    expect(
      AppLog.hintFor(null, 'Jellyfin returned HTTP 401.'),
      contains('Sign in again'),
    );
    expect(AppLog.hintFor(null, 'returned HTTP 404'), contains('path'));
    expect(
      AppLog.hintFor(const FormatException('Unexpected character')),
      contains('not the expected format'),
    );
    expect(AppLog.hintFor(null, 'all good'), isNull);
  });

  test('errors carry redacted details and a hint; secrets keys are masked', () {
    AppLog.error(
      LogCategory.jellyfin,
      'GET /Items failed',
      error: const SocketException('Connection refused'),
      details: {'url': 'http://u:p@h/x', 'apiKey': 'abc', 'ms': 12},
    );
    final entry = AppLog.instance.entries.single;
    expect(entry.level, LogLevel.error);
    expect(entry.hint, isNotNull);
    expect(entry.details['url'], 'http://***:***@h/x');
    expect(entry.details['apiKey'], '***');
    expect(entry.details['ms'], 12);
    expect(entry.error, contains('SocketException'));
  });

  test('ring buffer keeps the newest entries', () {
    for (var i = 0; i < AppLog.bufferSize + 25; i++) {
      AppLog.info(LogCategory.app, 'entry $i');
    }
    expect(AppLog.instance.entries.length, AppLog.bufferSize);
    expect(
      AppLog.instance.entries.last.message,
      'entry ${AppLog.bufferSize + 24}',
    );
  });

  test('uploads only warnings, errors, audit and analytics', () async {
    final sent = <Map<String, Object?>>[];
    AppLog.instance.uploader = (batch) async => sent.addAll(batch);
    AppLog.info(LogCategory.catalog, 'noise');
    AppLog.debug(LogCategory.catalog, 'more noise');
    AppLog.warn(LogCategory.catalog, 'slow source');
    AppLog.audit('Adult content shown');
    AppLog.event('media.play', props: {'seconds': 30});
    expect(AppLog.instance.pendingUploadCount, 3);
    await AppLog.instance.uploadPending();
    expect(sent.map((e) => e['msg']), [
      'slow source',
      'Adult content shown',
      'media.play',
    ]);
    expect(AppLog.instance.pendingUploadCount, 0);
  });

  test('opting out stops uploads', () async {
    AppLog.instance.uploader = (_) async {};
    await AppLog.instance.setShareUsage(false);
    AppLog.error(LogCategory.app, 'boom');
    expect(AppLog.instance.pendingUploadCount, 0);
  });

  test('writes JSON lines to the log folder and builds a report', () async {
    final dir = await Directory.systemTemp.createTemp('applog');
    addTearDown(() => dir.delete(recursive: true));
    await AppLog.instance.init(directory: () async => dir);
    AppLog.error(LogCategory.playback, 'Could not open "Movie"');
    await AppLog.instance.flush();
    final files = await AppLog.instance.logFiles();
    expect(files, hasLength(1));
    final text = await files.single.readAsString();
    expect(text, contains('"cat":"playback"'));
    final report = AppLog.instance.report();
    expect(report, contains('MILLITOP TV diagnostics'));
    expect(report, contains('Could not open "Movie"'));
  });
}
