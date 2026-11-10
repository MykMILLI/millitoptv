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
    this.posterUrl,
    this.overview,
    this.genres = const [],
  });
  final String sourceId;
  final String sourceName;
  final String mediaId;
  final String title;
  final String mediaType;
  final DateTime cachedAt;
  final int? year;
  final String? posterUrl;
  final String? overview;
  final List<String> genres;
}

class AiMessage {
  const AiMessage({
    required this.role,
    required this.text,
    this.media = const [],
    this.proposal,
  });
  final AiRole role;
  final String text;
  final List<AiMediaMatch> media;
  final AiActionProposal? proposal;
}

class AiRequest {
  AiRequest({required this.profileId, required List<AiMessage> messages})
    : messages = List.unmodifiable(messages);
  final String profileId;
  final List<AiMessage> messages;
}

class AiActionProposal {
  AiActionProposal({
    required this.tool,
    required Map<String, dynamic> arguments,
    required this.summary,
    required this.connectionKey,
    required this.stateKey,
  }) : arguments = Map.unmodifiable(arguments),
       createdAt = DateTime.now();
  final String tool;
  final Map<String, dynamic> arguments;
  final String summary;
  final String connectionKey;
  final String stateKey;
  final DateTime createdAt;
}

class AiReply {
  const AiReply({required this.text, this.media = const [], this.proposal});
  final String text;
  final List<AiMediaMatch> media;
  final AiActionProposal? proposal;
}
