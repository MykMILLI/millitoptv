import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pstube_engine/pstube_engine.dart';

class TubeDownloads {
  final Future<Directory> Function() supportDirectory;
  TubeDownloads({Future<Directory> Function()? supportDirectory})
      : supportDirectory = supportDirectory ?? getApplicationSupportDirectory;
  Future<Directory> _folder(int profile) async =>
      Directory(path.join((await supportDirectory()).path, 'youtube', '$profile'));
  String _id(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('Invalid YouTube video identifier.');
    }
    return id;
  }
  Future<String?> local(int profile, String id) async {
    final file = File(path.join((await _folder(profile)).path, '${_id(id)}.media'));
    return await file.exists() ? file.path : null;
  }
  Future<List<TubeVideo>> list(int profile) async {
    final folder = await _folder(profile);
    if (!await folder.exists()) return [];
    final values = <TubeVideo>[];
    await for (final entry in folder.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        final video = TubeVideo.fromJson(Map<String, dynamic>.from(
          jsonDecode(await entry.readAsString()) as Map));
        if (await local(profile, video.id) != null) values.add(video);
      }
    }
    return values;
  }
  Future<void> remove(int profile, String id) async {
    final folder = await _folder(profile);
    for (final extension in ['.media', '.json']) {
      final file = File(path.join(folder.path, '${_id(id)}$extension'));
      if (await file.exists()) await file.delete();
    }
  }
  Future<void> clearProfile(int profile) async {
    final folder = await _folder(profile);
    if (!await folder.exists()) return;
    await for (final entry in folder.list()) {
      if (entry is File) await entry.delete();
    }
    await folder.delete();
  }
  Future<void> save(int profile, TubeVideo video, TubeStream stream,
      void Function(int bytes, int? total) progress) async {
    if (stream.videoOnly) throw StateError('Offline download needs a combined audio/video stream.');
    final folder = await _folder(profile);
    await folder.create(recursive: true);
    final file = File(path.join(folder.path, '${_id(video.id)}.media'));
    if (await file.exists()) return;
    final partial = File('${file.path}.part');
    final metadata = File(path.join(folder.path, '${_id(video.id)}.json'));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final sink = partial.openWrite();
    var complete = false;
    try {
      final request = await client.getUrl(Uri.parse(webUrl(stream.url)));
      final response = await request.close().timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw HttpException('Video download failed: HTTP ${response.statusCode}.');
      }
      var received = 0;
      await for (final bytes in response.timeout(const Duration(seconds: 30))) {
        received += bytes.length;
        if (received > 2 * 1024 * 1024 * 1024) {
          throw const FileSystemException('Video download exceeds 2 GB.');
        }
        sink.add(bytes);
        await sink.flush();
        progress(received, response.contentLength > 0 ? response.contentLength : null);
      }
      if (received == 0 || response.contentLength > 0 && received != response.contentLength) {
        throw const HttpException('Video download was incomplete.');
      }
      await sink.close();
      await partial.rename(file.path);
      await metadata.writeAsString(jsonEncode(video.toJson()), flush: true);
      complete = true;
    } finally {
      client.close(force: true);
      if (!complete) {
        await sink.close();
        for (final candidate in [partial, file, metadata]) {
          if (await candidate.exists()) await candidate.delete();
        }
      }
    }
  }
}
