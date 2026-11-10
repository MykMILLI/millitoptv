import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/features/millitop_ai/ai_models.dart';
import 'package:millitop_tv/features/millitop_ai/ai_service.dart';
import 'package:millitop_tv/features/millitop_ai/ai_controller.dart';
import 'package:millitop_tv/features/millitop_ai/backend_ai_service.dart';

Map<String, dynamic> validReply() => {
  'answer': 'Local answer',
  'sources': <dynamic>[],
  'mode': 'local_chat',
  'actionsEnabled': false,
};

class RetryService implements AiService {
  int calls = 0;
  @override
  Future<AiReply> reply(AiRequest request) async {
    calls++;
    if (calls == 1) throw StateError('private');
    expect(request.messages.length, 1);
    return const AiReply(text: 'Recovered');
  }
}

void main() {
  test(
    'backend service serializes messages without profile or credentials',
    () async {
      final service = BackendAiService(
        send: (body) async {
          expect(body.keys, ['messages']);
          expect(body['messages'], [
            {'role': 'user', 'text': 'Hello'},
          ]);
          return validReply();
        },
      );
      final reply = await service.reply(
        AiRequest(
          profileId: 'p',
          messages: [const AiMessage(role: AiRole.user, text: 'Hello')],
        ),
      );
      expect(reply.text, 'Local answer');
    },
  );
  test('long history retains seven alternating messages', () async {
    final service = BackendAiService(
      send: (body) async {
        final list = body['messages'] as List;
        expect(list.length, 7);
        expect(list.first['text'], '2');
        expect(list.last['text'], '8');
        return validReply();
      },
    );
    await service.reply(
      AiRequest(
        profileId: 'p',
        messages: List.generate(
          9,
          (i) => AiMessage(
            role: i.isEven ? AiRole.user : AiRole.assistant,
            text: '$i',
          ),
        ),
      ),
    );
  });
  test('unexpected response capabilities are rejected', () async {
    final service = BackendAiService(
      send: (_) async => {...validReply(), 'actionsEnabled': true},
    );
    await expectLater(
      service.reply(
        AiRequest(
          profileId: 'p',
          messages: [const AiMessage(role: AiRole.user, text: 'Hello')],
        ),
      ),
      throwsFormatException,
    );
  });
  test(
    'failed request does not leave adjacent user messages on retry',
    () async {
      final controller = AiController(service: RetryService(), profileId: 'p');
      addTearDown(controller.dispose);
      await controller.send('First');
      expect(controller.messages, isEmpty);
      expect(controller.error, isNotNull);
      await controller.send('Retry');
      expect(controller.messages.length, 2);
      expect(controller.messages.last.text, 'Recovered');
    },
  );
}
