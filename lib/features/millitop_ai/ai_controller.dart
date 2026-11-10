import 'package:flutter/foundation.dart';
import 'ai_models.dart';
import 'ai_service.dart';

class AiController extends ChangeNotifier {
  AiController({required this.service, required this.profileId});
  final AiService service;
  final String profileId;
  final List<AiMessage> _messages = [];
  List<AiMessage> get messages => List.unmodifiable(_messages);
  bool _busy = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;
  bool _disposed = false;
  int _generation = 0;
  Future<void> send(String input) async {
    final text = input.trim();
    if (_disposed || _busy || text.isEmpty) return;
    if (text.length > 4000) {
      _error = 'Please keep messages under 4,000 characters.';
      notifyListeners();
      return;
    }
    _messages.add(AiMessage(role: AiRole.user, text: text));
    _busy = true;
    _error = null;
    final generation = ++_generation;
    notifyListeners();
    try {
      final result = await service
          .reply(AiRequest(profileId: profileId, messages: _messages))
          .timeout(const Duration(seconds: 65));
      if (_disposed || generation != _generation) return;
      _messages.add(
        AiMessage(
          role: AiRole.assistant,
          text: result.text,
          media: result.media,
          proposal: result.proposal,
        ),
      );
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _messages.removeLast();
      _error =
          'Unable to get a reply. Check pairing or connection, or wait a moment and try again.';
    } finally {
      if (!_disposed && generation == _generation) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  void clear() {
    if (_disposed) return;
    ++_generation;
    _messages.clear();
    _busy = false;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
