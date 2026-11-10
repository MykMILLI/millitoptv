import 'ai_models.dart';

/// Implement through your authenticated backend, never with a provider key
/// shipped inside the Flutter client. No recording or write tools in v1.
abstract interface class AiService {
  Future<AiReply> reply(AiRequest request);
}

class DemoAiService implements AiService {
  @override
  Future<AiReply> reply(AiRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final query = request.messages.last.text.toLowerCase();
    if (query.contains('record') || query.contains('game')) {
      return const AiReply(
        text:
            'DEMO ONLY: A connected assistant would search '
            'your program guide and verify the event, channel, timezone and DVR '
            'capabilities. Nothing has been looked up or recorded. Recording '
            'actions are deliberately disabled in this starter.',
      );
    }
    if (query.contains('study') || query.contains('book')) {
      return const AiReply(
        text:
            'DEMO ONLY: Study and book search is planned '
            'for phase 3. No books, notes or certification materials were accessed.',
      );
    }
    return const AiReply(
      text:
          'DEMO ONLY: I can preview the MILLITOP AI chat '
          'experience. Live library search, cited web research and recommendations '
          'require an authenticated server integration. No AI provider was called.',
    );
  }
}
