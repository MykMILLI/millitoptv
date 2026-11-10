import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/features/millitop_ai/mavae_agent_service.dart';
import 'package:millitop_tv/features/millitop_ai/ai_models.dart';
import 'package:millitop_tv/features/millitop_ai/ai_controller.dart';
import 'package:millitop_tv/features/millitop_ai/ai_service.dart';

class ProposalService implements AiService {
  @override
  Future<AiReply> reply(AiRequest request) async => AiReply(
    text: 'Preview only',
    proposal: AiActionProposal(
      tool: 'preview_sleep_timer',
      arguments: {'operation': 'start', 'minutes': 45},
      summary: 'Start a timer',
      connectionKey: 'test',
      stateKey: 'test',
    ),
  );
}

void main() {
  test('validates broad movie search plan', () {
    final value = MavaeAgentService.validatePlan({
      'kind': 'tool',
      'message': 'Search movies',
      'tool': 'search_media',
      'arguments': {'query': 'Halloween', 'mediaType': 'movie'},
    });
    expect(value['tool'], 'search_media');
  });
  test('rejects arbitrary tool names', () {
    expect(
      () => MavaeAgentService.validatePlan({
        'kind': 'tool',
        'message': 'Run',
        'tool': 'run_shell',
        'arguments': {},
      }),
      throwsFormatException,
    );
  });
  test('rejects invalid timer and hidden parameters', () {
    for (final args in [
      {'operation': 'start', 'minutes': 0},
      {'operation': 'start', 'minutes': 721},
      {'operation': 'start', 'minutes': 45, 'url': 'http://untrusted'},
    ]) {
      expect(
        () => MavaeAgentService.validatePlan({
          'kind': 'tool',
          'message': 'Preview',
          'tool': 'preview_sleep_timer',
          'arguments': args,
        }),
        throwsFormatException,
      );
    }
  });
  test('clarification uses planner without invoking device plugins', () async {
    final service = MavaeAgentService(
      profileId: 1,
      planSend: (body) async {
        expect(body['task'], 'plan');
        return {
          'mode': 'local_plan',
          'actionsEnabled': false,
          'plan': {
            'kind': 'clarify',
            'message': 'How many minutes?',
            'tool': 'none',
            'arguments': {},
          },
        };
      },
    );
    final reply = await service.reply(
      AiRequest(
        profileId: '1',
        messages: [const AiMessage(role: AiRole.user, text: 'Set a timer')],
      ),
    );
    expect(reply.text, 'How many minutes?');
    expect(reply.proposal, isNull);
  });
  test('controller preserves preview rather than executing it', () async {
    final controller = AiController(service: ProposalService(), profileId: '1');
    addTearDown(controller.dispose);
    await controller.send('Set timer');
    expect(controller.messages.last.proposal?.tool, 'preview_sleep_timer');
  });
  test('metadata fields survive card construction', () {
    final item = AiMediaMatch(
      sourceId: 's',
      sourceName: 'Library',
      mediaId: 'm',
      title: 'Movie',
      mediaType: 'movie',
      cachedAt: DateTime(2026),
      posterUrl: 'https://example.com/poster',
      overview: 'Overview',
      genres: ['Horror'],
    );
    expect(item.posterUrl, isNotNull);
    expect(item.genres, ['Horror']);
  });
}
