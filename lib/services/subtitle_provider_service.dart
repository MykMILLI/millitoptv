import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum SubtitleProvider { openSubtitles, subdl }

class SubtitleSearchResult {
  final SubtitleProvider provider;
  final String id;
  final String title;
  final String language;
  final String? release;
  final String? hearingImpaired;
  final bool forced;
  final String downloadUrl;

  const SubtitleSearchResult({
    required this.provider,
    required this.id,
    required this.title,
    required this.language,
    required this.downloadUrl,
    this.release,
    this.hearingImpaired,
    this.forced = false,
  });
}

class SubtitleProviderService {
  const SubtitleProviderService();

  String _providerLabel(SubtitleProvider provider) {
    switch (provider) {
      case SubtitleProvider.openSubtitles:
        return 'OpenSubtitles';
      case SubtitleProvider.subdl:
        return 'SubDL';
    }
  }

  Future<List<SubtitleSearchResult>> search({
    required String query,
    required String language,
    required Map<String, dynamic> providerConfig,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const <SubtitleSearchResult>[];
    }
    final results = <SubtitleSearchResult>[];
    final openSubtitles = await _searchOpenSubtitles(
      query: normalizedQuery,
      language: language,
      providerConfig: providerConfig,
    );
    results.addAll(openSubtitles);
    final subdl = await _searchSubdl(
      query: normalizedQuery,
      language: language,
      providerConfig: providerConfig,
    );
    results.addAll(subdl);
    return results;
  }

  Future<String> _openSubtitlesToken(Map<String, dynamic> config) async {
    final apiKey = config['openSubtitlesApiKey']?.toString().trim() ?? '';
    final username = config['openSubtitlesUsername']?.toString().trim() ?? '';
    final password = config['openSubtitlesPassword']?.toString().trim() ?? '';
    if (apiKey.isEmpty) {
      throw StateError('OpenSubtitles API key is required.');
    }
    if (username.isEmpty || password.isEmpty) {
      throw StateError('OpenSubtitles username/password are required.');
    }
    final client = HttpClient();
    try {
      final uri = Uri.parse('https://api.opensubtitles.com/api/v1/login');
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set('Api-Key', apiKey);
      request.headers.set(HttpHeaders.userAgentHeader, 'MillitopTV/1.0');
      request.write(
        jsonEncode({
          'username': username,
          'password': password,
        }),
      );
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'OpenSubtitles login failed (HTTP ${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('OpenSubtitles login response is invalid.');
      }
      final token = decoded['token']?.toString().trim() ?? '';
      if (token.isEmpty) {
        throw const FormatException('OpenSubtitles token is missing.');
      }
      return token;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<SubtitleSearchResult>> _searchOpenSubtitles({
    required String query,
    required String language,
    required Map<String, dynamic> providerConfig,
  }) async {
    final apiKey = providerConfig['openSubtitlesApiKey']?.toString().trim() ?? '';
    if (apiKey.isEmpty) {
      return const <SubtitleSearchResult>[];
    }
    final token = await _openSubtitlesToken(providerConfig);
    final client = HttpClient();
    try {
      final uri = Uri.https('api.opensubtitles.com', '/api/v1/subtitles', {
        'query': query,
        'languages': language,
        'order_by': 'download_count',
      });
      final request = await client.getUrl(uri);
      request.headers.set('Api-Key', apiKey);
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set(HttpHeaders.userAgentHeader, 'MillitopTV/1.0');
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <SubtitleSearchResult>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const <SubtitleSearchResult>[];
      }
      final data = decoded['data'];
      if (data is! List) {
        return const <SubtitleSearchResult>[];
      }
      final results = <SubtitleSearchResult>[];
      for (final item in data) {
        if (item is! Map) {
          continue;
        }
        final row = Map<String, dynamic>.from(item);
        final attributesRaw = row['attributes'];
        if (attributesRaw is! Map) {
          continue;
        }
        final attributes = Map<String, dynamic>.from(attributesRaw);
        final filesRaw = attributes['files'];
        if (filesRaw is! List || filesRaw.isEmpty) {
          continue;
        }
        final fileMapRaw = filesRaw.first;
        if (fileMapRaw is! Map) {
          continue;
        }
        final fileMap = Map<String, dynamic>.from(fileMapRaw);
        final fileId = fileMap['file_id']?.toString().trim() ?? '';
        if (fileId.isEmpty) {
          continue;
        }
        final detailUri = Uri.parse('https://api.opensubtitles.com/api/v1/download');
        final detailRequest = await client.postUrl(detailUri);
        detailRequest.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        detailRequest.headers.set('Api-Key', apiKey);
        detailRequest.headers.set('Authorization', 'Bearer $token');
        detailRequest.headers.set(HttpHeaders.userAgentHeader, 'MillitopTV/1.0');
        detailRequest.write(jsonEncode({'file_id': int.tryParse(fileId) ?? fileId}));
        final detailResponse = await detailRequest.close();
        final detailRaw = await utf8.decoder.bind(detailResponse).join();
        if (detailResponse.statusCode < 200 || detailResponse.statusCode >= 300) {
          continue;
        }
        final detail = jsonDecode(detailRaw);
        if (detail is! Map) {
          continue;
        }
        final downloadUrl = detail['link']?.toString().trim() ?? '';
        if (downloadUrl.isEmpty) {
          continue;
        }
        final title = attributes['feature_details'] is Map
            ? (Map<String, dynamic>.from(attributes['feature_details'])['title']
                      ?.toString()
                      .trim() ??
                  '')
            : '';
        final release = attributes['release']?.toString().trim();
        final hearing = attributes['hearing_impaired']?.toString().trim();
        final forced = attributes['foreign_parts_only'] == true;
        final languageName = attributes['language']?.toString().trim() ?? language;
        results.add(
          SubtitleSearchResult(
            provider: SubtitleProvider.openSubtitles,
            id: row['id']?.toString().trim() ?? fileId,
            title: title.isEmpty ? query : title,
            language: languageName,
            release: release == null || release.isEmpty ? null : release,
            hearingImpaired: hearing == null || hearing.isEmpty ? null : hearing,
            forced: forced,
            downloadUrl: downloadUrl,
          ),
        );
      }
      return results;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<SubtitleSearchResult>> _searchSubdl({
    required String query,
    required String language,
    required Map<String, dynamic> providerConfig,
  }) async {
    final apiKey = providerConfig['subdlApiKey']?.toString().trim() ?? '';
    if (apiKey.isEmpty) {
      return const <SubtitleSearchResult>[];
    }
    final client = HttpClient();
    try {
      final uri = Uri.parse('https://api.subdl.com/api/v1/subtitles').replace(
        queryParameters: {
          'api_key': apiKey,
          'film_name': query,
          'languages': language,
        },
      );
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'MillitopTV/1.0');
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <SubtitleSearchResult>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const <SubtitleSearchResult>[];
      }
      final list = decoded['subtitles'];
      if (list is! List) {
        return const <SubtitleSearchResult>[];
      }
      final results = <SubtitleSearchResult>[];
      for (final entry in list) {
        if (entry is! Map) {
          continue;
        }
        final row = Map<String, dynamic>.from(entry);
        final downloadUrl = row['url']?.toString().trim() ??
            row['download_url']?.toString().trim() ??
            '';
        if (downloadUrl.isEmpty) {
          continue;
        }
        results.add(
          SubtitleSearchResult(
            provider: SubtitleProvider.subdl,
            id: row['id']?.toString().trim() ?? downloadUrl,
            title: row['name']?.toString().trim() ?? query,
            language: row['language']?.toString().trim() ?? language,
            release: row['release_name']?.toString().trim(),
            hearingImpaired: row['hearing_impaired']?.toString().trim(),
            forced: row['is_forced'] == true,
            downloadUrl: downloadUrl,
          ),
        );
      }
      return results;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> downloadSubtitleToTemp(
    SubtitleSearchResult item, {
    String? baseName,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(item.downloadUrl);
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'MillitopTV/1.0');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          '${_providerLabel(item.provider)} download failed (HTTP ${response.statusCode}).',
        );
      }
      final bytes = await response.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      if (bytes.isEmpty) {
        throw StateError('${_providerLabel(item.provider)} returned empty subtitle file.');
      }
      final tempDir = await getTemporaryDirectory();
      final ext = p.extension(Uri.parse(item.downloadUrl).path).trim();
      final safeExt = ext.isEmpty ? '.srt' : ext;
      final safeBase = (baseName ?? item.title)
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_')
          .trim();
      final file = File(
        p.join(
          tempDir.path,
          'subtitle_${DateTime.now().microsecondsSinceEpoch}_${safeBase.isEmpty ? 'track' : safeBase}$safeExt',
        ),
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> translateText({
    required String text,
    required String fromLanguage,
    required String toLanguage,
    required Map<String, dynamic> providerConfig,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) {
      return '';
    }
    final libreEndpoint = providerConfig['translateEndpoint']?.toString().trim();
    if (libreEndpoint != null && libreEndpoint.isNotEmpty) {
      final translated = await _translateViaLibreTranslate(
        endpoint: libreEndpoint,
        apiKey: providerConfig['translateApiKey']?.toString().trim(),
        text: cleaned,
        fromLanguage: fromLanguage,
        toLanguage: toLanguage,
      );
      if (translated.isNotEmpty) {
        return translated;
      }
    }
    return _translateViaMyMemory(
      text: cleaned,
      fromLanguage: fromLanguage,
      toLanguage: toLanguage,
    );
  }

  Future<String> _translateViaLibreTranslate({
    required String endpoint,
    String? apiKey,
    required String text,
    required String fromLanguage,
    required String toLanguage,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(endpoint);
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(
        jsonEncode({
          'q': text,
          'source': fromLanguage,
          'target': toLanguage,
          'format': 'text',
          if (apiKey != null && apiKey.trim().isNotEmpty) 'api_key': apiKey.trim(),
        }),
      );
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return '';
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return '';
      }
      return decoded['translatedText']?.toString().trim() ?? '';
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _translateViaMyMemory({
    required String text,
    required String fromLanguage,
    required String toLanguage,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.https('api.mymemory.translated.net', '/get', {
        'q': text,
        'langpair': '$fromLanguage|$toLanguage',
      });
      final request = await client.getUrl(uri);
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('MyMemory translation failed (HTTP ${response.statusCode}).');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('MyMemory response is invalid.');
      }
      final data = decoded['responseData'];
      if (data is! Map) {
        throw const FormatException('MyMemory translation payload is invalid.');
      }
      return data['translatedText']?.toString().trim() ?? '';
    } finally {
      client.close(force: true);
    }
  }
}

