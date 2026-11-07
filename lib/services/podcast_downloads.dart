import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'podcast_service.dart';

class PodcastDownloads {
  final Future<Directory> Function() supportDirectory;
  PodcastDownloads({Future<Directory> Function()? supportDirectory})
      : supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  Future<Directory> _folder(int profile) async {
    final root = await supportDirectory();
    return Directory(path.join(root.path, 'podcasts', '$profile'));
  }

  Future<File> _file(int profile, PodcastEpisode episode) async {
    final folder = await _folder(profile);
    await folder.create(recursive: true);
    final id = sha256.convert(utf8.encode(episode.key)).toString();
    return File(path.join(folder.path, '$id.media'));
  }

  Future<String?> localPath(int profile, PodcastEpisode episode) async {
    final file = await _file(profile, episode);
    return await file.exists() ? file.path : null;
  }

  Future<void> remove(int profile, PodcastEpisode episode) async {
    final file = await _file(profile, episode);
    if (await file.exists()) await file.delete();
    final metadata = File('${file.path}.json');
    if (await metadata.exists()) await metadata.delete();
  }

  Future<List<PodcastEpisode>> list(int profile) async {
    final folder = await _folder(profile);
    if (!await folder.exists()) return [];
    final episodes = <PodcastEpisode>[];
    await for (final entry in folder.list()) {
      if (entry is File && entry.path.endsWith('.media.json')) {
        final episode = PodcastEpisode.fromJson(
          Map<String, dynamic>.from(jsonDecode(await entry.readAsString()) as Map));
        if (await localPath(profile, episode) != null) episodes.add(episode);
      }
    }
    return episodes;
  }

  Future<void> clearProfile(int profile) async {
    final folder = await _folder(profile);
    if (!await folder.exists()) return;
    await for (final entry in folder.list()) {
      if (entry is File) await entry.delete();
    }
    await folder.delete();
  }

  Future<void> download(int profile, PodcastEpisode episode,
      void Function(int bytes, int? total) onProgress) async {
    final file = await _file(profile, episode);
    if (await file.exists()) return;
    final temporary = File('${file.path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final sink = temporary.openWrite();
    var success = false;
    try {
      final request = await client.getUrl(Uri.parse(episode.mediaUrl));
      final response = await request.close().timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw HttpException('Download failed (HTTP ${response.statusCode}).');
      }
      var received = 0;
      await for (final bytes in response.timeout(const Duration(seconds: 30))) {
        received += bytes.length;
        if (received > 2 * 1024 * 1024 * 1024) {
          throw const FileSystemException('Podcast download exceeds the 2 GB limit.');
        }
        sink.add(bytes);
        await sink.flush();
        onProgress(received, response.contentLength < 0 ? null : response.contentLength);
      }
      await sink.flush();
      await sink.close();
      await temporary.rename(file.path);
      await File('${file.path}.json').writeAsString(jsonEncode(episode.toJson()), flush: true);
      success = true;
    } finally {
      client.close(force: true);
      if (!success) {
        await sink.close();
        if (await temporary.exists()) await temporary.delete();
        if (await file.exists()) await file.delete();
        final metadata = File('${file.path}.json');
        if (await metadata.exists()) await metadata.delete();
      }
    }
  }
}
