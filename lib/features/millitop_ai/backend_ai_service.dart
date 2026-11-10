import '../../services/device_connection.dart';
import 'ai_models.dart';
import 'ai_service.dart';

typedef AiSender =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body);

class BackendAiService implements AiService {
  BackendAiService({required AiSender send}) : _send = send;
  final AiSender _send;

  factory BackendAiService.pairedDevice() {
    final connection = DeviceConnection.instance;
    return BackendAiService(
      send: (body) async {
        await connection.start();
        final key = connection.connectionKey;
        if (key.isEmpty) throw StateError('Device is not paired.');
        final result = await connection.postDevice(
          '/api/device/ai/chat',
          body,
          expectedConnection: key,
        );
        if (connection.connectionKey != key) {
          throw StateError('Device connection changed.');
        }
        return result;
      },
    );
  }

  @override
  Future<AiReply> reply(AiRequest request) async {
    final messages = request.messages;
    if (messages.isEmpty || messages.length.isEven) {
      throw const FormatException('Invalid conversation.');
    }
    for (var i = 0; i < messages.length; i++) {
      final expected = i.isEven ? AiRole.user : AiRole.assistant;
      if (messages[i].role != expected || messages[i].text.trim().isEmpty) {
        throw const FormatException('Invalid conversation.');
      }
    }
    var start = messages.length > 7 ? messages.length - 7 : 0;
    int chars() => messages
        .skip(start)
        .fold(0, (sum, message) => sum + message.text.trim().length);
    bool oversized() => messages
        .skip(start)
        .any((message) => message.text.trim().length > 4000);
    while (start < messages.length - 1 && (chars() > 12000 || oversized())) {
      start += 2;
    }
    if (chars() > 12000 || oversized()) {
      throw const FormatException('Message is too long.');
    }
    final data = await _send({
      'messages': messages
          .skip(start)
          .map(
            (message) => {
              'role': message.role == AiRole.user ? 'user' : 'assistant',
              'text': message.text.trim(),
            },
          )
          .toList(),
    });
    final answer = data['answer'];
    final sources = data['sources'];
    if (data['mode'] != 'local_chat' ||
        data['actionsEnabled'] != false ||
        sources is! List ||
        sources.isNotEmpty ||
        answer is! String ||
        answer.trim().isEmpty ||
        answer.length > 60000) {
      throw const FormatException('Unexpected AI response.');
    }
    return AiReply(text: answer.trim());
  }
}
