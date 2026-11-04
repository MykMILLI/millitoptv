import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LiveTvProgram {
  final String title;
  final DateTime start;
  final DateTime end;

  const LiveTvProgram({
    required this.title,
    required this.start,
    required this.end,
  });

  bool contains(DateTime value) =>
      (value.isAtSameMomentAs(start) || value.isAfter(start)) &&
      value.isBefore(end);
}

class LiveTvEpg {
  final Map<String, List<LiveTvProgram>> byChannelId;
  final Map<String, String> channelIdByDisplayName;
  final Map<String, String> channelIdByNormalizedId;
  const LiveTvEpg(
    this.byChannelId, {
    this.channelIdByDisplayName = const {},
    this.channelIdByNormalizedId = const {},
  });

  String? resolveChannelId({String? tvgId, required String channelTitle}) {
    final direct = tvgId?.trim();
    if (direct != null && direct.isNotEmpty) {
      final candidates = direct
          .split(RegExp(r'[|,;]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty);
      for (final candidate in candidates) {
        if (byChannelId.containsKey(candidate)) {
          return candidate;
        }
        final normalized = _normalizeKey(candidate);
        final mapped = channelIdByNormalizedId[normalized];
        if (mapped != null) {
          return mapped;
        }
      }
    }
    final titleKey = _normalizeKey(channelTitle);
    final byName = channelIdByDisplayName[titleKey];
    if (byName != null) {
      return byName;
    }
    final byNormalized = channelIdByNormalizedId[titleKey];
    if (byNormalized != null) {
      return byNormalized;
    }
    final variants = _titleVariants(channelTitle)
        .map(_normalizeKey)
        .where((value) => value.isNotEmpty)
        .toSet();
    for (final variant in variants) {
      for (final entry in channelIdByDisplayName.entries) {
        final key = entry.key;
        if (key.contains(variant) || variant.contains(key)) {
          return entry.value;
        }
      }
      for (final entry in channelIdByNormalizedId.entries) {
        final key = entry.key;
        if (key.contains(variant) || variant.contains(key)) {
          return entry.value;
        }
      }
    }
    return null;
  }

  LiveTvProgram? current(String channelId, DateTime nowUtc) {
    final values = byChannelId[channelId];
    if (values == null || values.isEmpty) {
      return null;
    }
    for (final item in values) {
      if (item.contains(nowUtc)) {
        return item;
      }
    }
    return null;
  }

  LiveTvProgram? next(String channelId, DateTime nowUtc) {
    final values = byChannelId[channelId];
    if (values == null || values.isEmpty) {
      return null;
    }
    for (final item in values) {
      if (item.start.isAfter(nowUtc) || item.start.isAtSameMomentAs(nowUtc)) {
        return item;
      }
    }
    return null;
  }
}

class LiveTvEpgService {
  const LiveTvEpgService();

  Future<LiveTvEpg> loadFromUrl(String url) async {
    final normalized = _normalizeHttpUrl(url);
    final uri = Uri.parse(normalized);
    if (!uri.isAbsolute ||
        uri.userInfo.isNotEmpty ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
      throw const FormatException(
        'EPG URL must be HTTP/HTTPS without embedded credentials.',
      );
    }
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/xml,text/xml,*/*',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('EPG server returned HTTP ${response.statusCode}.');
      }
      final bytes = await response.fold<List<int>>(
        <int>[],
        (list, chunk) => list..addAll(chunk),
      );
      final gzipHeader =
          bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
      final gzByPath = uri.path.toLowerCase().endsWith('.gz');
      final gzByHeader =
          (response.headers.value(HttpHeaders.contentTypeHeader) ?? '')
              .toLowerCase()
              .contains('gzip');
      final bodyBytes = (gzipHeader || gzByPath || gzByHeader)
          ? gzip.decode(bytes)
          : bytes;
      final xml = utf8.decode(bodyBytes, allowMalformed: true);
      return _parseXmltv(xml);
    } on TimeoutException {
      throw StateError('EPG request timed out.');
    } on SocketException {
      throw StateError('EPG server is unreachable.');
    } finally {
      client.close(force: true);
    }
  }

  LiveTvEpg _parseXmltv(String xml) {
    final byId = <String, List<LiveTvProgram>>{};
    final normalizedIdMap = <String, String>{};
    final displayNameMap = <String, String>{};
    final channelRegex = RegExp(
      r'<channel\b([^>]*)>(.*?)</channel>',
      dotAll: true,
      caseSensitive: false,
    );
    for (final match in channelRegex.allMatches(xml)) {
      final attrs = _xmlAttributes(match.group(1) ?? '');
      final id = (attrs['id'] ?? '').trim();
      if (id.isEmpty) {
        continue;
      }
      normalizedIdMap[_normalizeKey(id)] = id;
      final body = match.group(2) ?? '';
      final names = RegExp(
        r'<display-name[^>]*>(.*?)</display-name>',
        dotAll: true,
        caseSensitive: false,
      ).allMatches(body);
      for (final nameMatch in names) {
        final name = _decodeXml(nameMatch.group(1)?.trim() ?? '');
        if (name.isEmpty) {
          continue;
        }
        displayNameMap[_normalizeKey(name)] = id;
      }
    }
    final regex = RegExp(
      r'<programme\b([^>]*)>(.*?)</programme>',
      dotAll: true,
      caseSensitive: false,
    );
    for (final match in regex.allMatches(xml)) {
      final attrs = _xmlAttributes(match.group(1) ?? '');
      final channel = (attrs['channel'] ?? '').trim();
      final startRaw = (attrs['start'] ?? '').trim();
      final stopRaw = (attrs['stop'] ?? '').trim();
      final body = match.group(2) ?? '';
      if (channel.isEmpty || startRaw.isEmpty || stopRaw.isEmpty) {
        continue;
      }
      final titleMatch = RegExp(
        r'<title[^>]*>(.*?)</title>',
        dotAll: true,
        caseSensitive: false,
      ).firstMatch(body);
      final title = _decodeXml(titleMatch?.group(1)?.trim() ?? '');
      if (title.isEmpty) {
        continue;
      }
      final start = _xmltvDate(startRaw);
      final end = _xmltvDate(stopRaw);
      if (start == null || end == null || !end.isAfter(start)) {
        continue;
      }
      byId
          .putIfAbsent(channel, () => [])
          .add(LiveTvProgram(title: title, start: start, end: end));
      normalizedIdMap[_normalizeKey(channel)] ??= channel;
    }
    for (final entry in byId.values) {
      entry.sort((a, b) => a.start.compareTo(b.start));
      final unique = <LiveTvProgram>[];
      final seen = <String>{};
      for (final item in entry) {
        final key =
            '${item.start.millisecondsSinceEpoch}|${item.end.millisecondsSinceEpoch}|${item.title.toLowerCase()}';
        if (seen.add(key)) {
          unique.add(item);
        }
      }
      entry
        ..clear()
        ..addAll(unique);
    }
    return LiveTvEpg(
      byId,
      channelIdByDisplayName: displayNameMap,
      channelIdByNormalizedId: normalizedIdMap,
    );
  }

  DateTime? _xmltvDate(String value) {
    final raw = value.trim();
    final match = RegExp(r'^(\d{14})(?:\s*([+-]\d{4}))?$').firstMatch(raw);
    if (match == null) {
      return null;
    }
    final stamp = match.group(1)!;
    final year = int.parse(stamp.substring(0, 4));
    final month = int.parse(stamp.substring(4, 6));
    final day = int.parse(stamp.substring(6, 8));
    final hour = int.parse(stamp.substring(8, 10));
    final minute = int.parse(stamp.substring(10, 12));
    final second = int.parse(stamp.substring(12, 14));
    final utc = DateTime.utc(year, month, day, hour, minute, second);
    final offset = match.group(2);
    if (offset == null) {
      return utc;
    }
    final sign = offset.startsWith('-') ? -1 : 1;
    final hh = int.parse(offset.substring(1, 3));
    final mm = int.parse(offset.substring(3, 5));
    return utc.subtract(Duration(hours: hh * sign, minutes: mm * sign));
  }

  String _decodeXml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  Map<String, String> _xmlAttributes(String attrs) {
    final values = <String, String>{};
    final matches = RegExp(
      "([a-zA-Z0-9:_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
      caseSensitive: false,
    ).allMatches(attrs);
    for (final match in matches) {
      final key = (match.group(1) ?? '').toLowerCase();
      final value = match.group(2) ?? match.group(3) ?? '';
      if (key.isNotEmpty) {
        values[key] = value.trim();
      }
    }
    return values;
  }
}

String _normalizeKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

Set<String> _titleVariants(String title) {
  final raw = title.trim();
  final values = <String>{raw};
  for (final separator in [':', '|', '-', '·']) {
    final index = raw.indexOf(separator);
    if (index > 0 && index + 1 < raw.length) {
      values.add(raw.substring(index + 1).trim());
    }
  }
  return values;
}

String _normalizeHttpUrl(String value) {
  final trimmed = value.trim();
  return trimmed.contains('://') ? trimmed : 'https://$trimmed';
}
