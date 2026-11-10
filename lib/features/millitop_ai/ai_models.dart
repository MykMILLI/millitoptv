enum AiRole { user, assistant }

class AiMediaMatch {
  const AiMediaMatch({
    required this.sourceId,
    required this.sourceName,
    required this.mediaId,
    required this.title,
    required this.mediaType,
    required this.cachedAt,
    this.year,
  });
  final String sourceId;
  final String sourceName;
  final String mediaId;
  final String title;
  final String mediaType;
  final DateTime cachedAt;
  final int? year;
}

class AiMessage {
  const AiMessage({
    required this.role,
    required this.text,
    this.media = const [],
  });
  final AiRole role;
  final String text;
  final List<AiMediaMatch> media;
}

class AiRequest {
  AiRequest({required this.profileId, required List<AiMessage> messages})
    : messages = List.unmodifiable(messages);
  final String profileId;
  final List<AiMessage> messages;
}

class AiReply {
  const AiReply({required this.text, this.media = const []});
  final String text;
  final List<AiMediaMatch> media;
}
