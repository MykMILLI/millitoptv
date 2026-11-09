/// Data shared between the watch party service, overlay and guest player.
library;

/// What the host is playing, in the shape the tvadmin server expects.
class WatchPartyMedia {
  /// movie | episode | live | youtube | podcast | music | video
  final String kind;
  final String title;
  final String? subtitle;
  final String? posterUrl;
  final int? durationMs;
  final bool live;
  final bool audioOnly;

  /// Short label such as "Shuffle · 3 of 40" shown to guests.
  final String? queueLabel;
  final String? youtubeId;

  /// Where tvadmin fetches the stream from. Never shown to guests.
  final String? upstreamUrl;
  final Map<String, String> upstreamHeaders;

  const WatchPartyMedia({
    required this.kind,
    required this.title,
    this.subtitle,
    this.posterUrl,
    this.durationMs,
    this.live = false,
    this.audioOnly = false,
    this.queueLabel,
    this.youtubeId,
    this.upstreamUrl,
    this.upstreamHeaders = const {},
  });

  /// Identity used to detect "the host started something else".
  String get identity =>
      youtubeId != null ? 'yt:$youtubeId' : '${upstreamUrl ?? ''}|$title';

  Map<String, dynamic> toServerJson() {
    final httpsPoster = safePosterUrl(posterUrl);
    return {
      'kind': kind,
      'title': _clip(title, 200),
      if (subtitle != null && subtitle!.trim().isNotEmpty)
        'subtitle': _clip(subtitle!, 200),
      'posterUrl': ?httpsPoster,
      if (durationMs != null && durationMs! > 0) 'durationMs': durationMs,
      'live': live,
      'audioOnly': audioOnly,
      if (queueLabel != null && queueLabel!.trim().isNotEmpty)
        'queueLabel': _clip(queueLabel!, 40),
      'youtubeId': ?youtubeId,
      if (upstreamUrl != null)
        'upstream': {
          'url': WatchPartyMedia.relayFriendlyUrl(upstreamUrl!),
          if (upstreamHeaders.isNotEmpty) 'headers': upstreamHeaders,
        },
    };
  }

  /// Jellyfin's static direct-stream is often MKV/HEVC that browsers cannot
  /// play. For guests, ask Jellyfin for an H.264/AAC HLS stream instead.
  static String relayFriendlyUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final segments = uri.pathSegments;
    final index = segments.lastIndexOf('stream');
    final isJellyfinStatic =
        index >= 2 &&
        segments[index - 2].toLowerCase() == 'videos' &&
        uri.queryParameters['api_key'] != null;
    if (!isJellyfinStatic) return url;
    final itemId = segments[index - 1];
    final prefix = segments.sublist(0, index - 2);
    return uri
        .replace(
          pathSegments: [...prefix, 'Videos', itemId, 'master.m3u8'],
          queryParameters: {
            'api_key': uri.queryParameters['api_key']!,
            'DeviceId':
                '${uri.queryParameters['DeviceId'] ?? 'millitop'}-party',
            'MediaSourceId': itemId,
            'PlaySessionId':
                'party${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
            'VideoCodec': 'h264',
            'AudioCodec': 'aac',
            'MaxStreamingBitrate': '8000000',
            'TranscodingMaxAudioChannels': '2',
            'SegmentContainer': 'ts',
            'BreakOnNonKeyFrames': 'true',
          },
        )
        .toString();
  }

  /// Guests see the poster address, so only share public HTTPS images that
  /// carry no credentials (Navidrome/Jellyfin art URLs embed tokens).
  static String? safePosterUrl(String? value) {
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      return null;
    }
    const secretKeys = {
      'api_key',
      'apikey',
      'token',
      'access_token',
      'x-emby-token',
      'key',
      'password',
      'pass',
      'p',
      't',
      's',
      'u',
      'auth',
      'signature',
    };
    if (uri.queryParameters.keys.any(
      (k) => secretKeys.contains(k.toLowerCase()),
    )) {
      return null;
    }
    return uri.toString();
  }

  static String _clip(String value, int max) {
    final trimmed = value.trim();
    return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
  }
}

class WatchPartyPerson {
  final String id;
  final String name;
  final String role;
  final String client;
  final bool online;
  final bool inVoice;
  final bool muted;
  final bool listenOnly;

  const WatchPartyPerson({
    required this.id,
    required this.name,
    required this.role,
    required this.client,
    required this.online,
    required this.inVoice,
    required this.muted,
    required this.listenOnly,
  });

  bool get isHost => role == 'host';

  factory WatchPartyPerson.fromJson(Map<String, dynamic> json) {
    final voice = json['voice'];
    return WatchPartyPerson(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Guest',
      role: json['role']?.toString() ?? 'guest',
      client: json['client']?.toString() ?? 'web',
      online: json['online'] == true,
      inVoice: voice is Map,
      muted: voice is Map && voice['muted'] == true,
      listenOnly: voice is Map && voice['listenOnly'] == true,
    );
  }
}

class WatchPartyMessage {
  final int id;
  final String from;
  final String name;
  final String body;
  final bool notice;
  final DateTime at;

  const WatchPartyMessage({
    required this.id,
    required this.from,
    required this.name,
    required this.body,
    required this.at,
    this.notice = false,
  });

  factory WatchPartyMessage.fromJson(Map<String, dynamic> json) =>
      WatchPartyMessage(
        id: (json['id'] as num?)?.toInt() ?? 0,
        from: json['from']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        body: json['body']?.toString() ?? '',
        at: DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.now(),
      );
}

/// Media as guests see it (no upstream details).
class WatchPartyRemoteMedia {
  final int rev;
  final String kind;
  final String title;
  final String? subtitle;
  final String? posterUrl;
  final bool live;
  final bool audioOnly;
  final String? queueLabel;
  final String? youtubeId;
  final String relayType;

  const WatchPartyRemoteMedia({
    required this.rev,
    required this.kind,
    required this.title,
    this.subtitle,
    this.posterUrl,
    this.live = false,
    this.audioOnly = false,
    this.queueLabel,
    this.youtubeId,
    this.relayType = 'file',
  });

  static WatchPartyRemoteMedia? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<String, dynamic>();
    final rev = (json['rev'] as num?)?.toInt();
    if (rev == null) return null;
    final relay = json['relay'];
    return WatchPartyRemoteMedia(
      rev: rev,
      kind: json['kind']?.toString() ?? 'video',
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString(),
      posterUrl: json['posterUrl']?.toString(),
      live: json['live'] == true,
      audioOnly: json['audioOnly'] == true,
      queueLabel: json['queueLabel']?.toString(),
      youtubeId: json['youtubeId']?.toString(),
      relayType: relay is Map ? relay['type']?.toString() ?? 'file' : 'file',
    );
  }
}

class WatchPartyPlayback {
  final int mediaRev;
  final int positionMs;
  final bool playing;
  final bool buffering;
  final double rate;
  final int updatedAtMs;

  const WatchPartyPlayback({
    required this.mediaRev,
    required this.positionMs,
    required this.playing,
    required this.buffering,
    required this.rate,
    required this.updatedAtMs,
  });

  static WatchPartyPlayback? fromJson(Object? value) {
    if (value is! Map) return null;
    final rev = (value['mediaRev'] as num?)?.toInt();
    if (rev == null) return null;
    return WatchPartyPlayback(
      mediaRev: rev,
      positionMs: (value['positionMs'] as num?)?.toInt() ?? 0,
      playing: value['playing'] == true,
      buffering: value['buffering'] == true,
      rate: (value['rate'] as num?)?.toDouble() ?? 1,
      updatedAtMs: (value['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// Where the host is right now, given the server clock.
  int targetPositionMs(int serverNowMs) {
    if (!playing || buffering) return positionMs;
    final elapsed = (serverNowMs - updatedAtMs).clamp(0, 1 << 31);
    return positionMs + (elapsed * rate).round();
  }
}
