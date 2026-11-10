import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/features/millitop_ai/ai_controller.dart';
import 'package:millitop_tv/features/millitop_ai/ai_service.dart';
import 'package:millitop_tv/features/millitop_ai/ai_models.dart';

class FailingService implements AiService {
  @override
  Future<AiReply> reply(AiRequest request) async => throw StateError('private');
}

void main() {
  test('blank input does not create a message', () async {
    final controller = AiController(service: DemoAiService(), profileId: 'p');
    addTearDown(controller.dispose);
    await controller.send('  ');
    expect(controller.messages, isEmpty);
  });
  test('demo sends a clearly labeled reply', () async {
    final controller = AiController(service: DemoAiService(), profileId: 'p');
    addTearDown(controller.dispose);
    await controller.send('record a game');
    expect(controller.messages.length, 2);
    expect(controller.messages.last.text, contains('DEMO ONLY'));
    expect(controller.busy, isFalse);
  });
  test('errors do not expose server details', () async {
    final controller = AiController(service: FailingService(), profileId: 'p');
    addTearDown(controller.dispose);
    await controller.send('hello');
    expect(controller.error, isNot(contains('private')));
    expect(controller.busy, isFalse);
  });
  test('clear ignores an in-flight stale response', () async {
    final controller = AiController(service: DemoAiService(), profileId: 'p');
    addTearDown(controller.dispose);
    final pending = controller.send('hello');
    controller.clear();
    await pending;
    expect(controller.messages, isEmpty);
    expect(controller.busy, isFalse);
  });
}
