import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

class DeepLinkAction {
  final String route;
  final Map<String, String> query;
  const DeepLinkAction({required this.route, this.query = const {}});
}

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  final _controller = StreamController<DeepLinkAction>.broadcast();
  Stream<DeepLinkAction> get actions => _controller.stream;
  AppLinks? _appLinks;
  StreamSubscription<Uri>? _sub;

  Future<void> start() async {
    if (_appLinks != null) {
      return;
    }
    _appLinks = AppLinks();
    try {
      final initial = await _appLinks!.getInitialLink();
      if (initial != null) {
        _emit(initial);
      }
    } catch (error) {
      debugPrint('Deep link initial read failed: $error');
    }
    _sub = _appLinks!.uriLinkStream.listen(
      _emit,
      onError: (error) {
        debugPrint('Deep link stream error: $error');
      },
    );
  }

  void _emit(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.contains('music')) {
      _controller.add(
        DeepLinkAction(
          route: 'music',
          query: uri.queryParameters.map((key, value) => MapEntry(key, value)),
        ),
      );
      return;
    }
    if (path.contains('livetv')) {
      _controller.add(
        DeepLinkAction(
          route: 'livetv',
          query: uri.queryParameters.map((key, value) => MapEntry(key, value)),
        ),
      );
      return;
    }
    _controller.add(const DeepLinkAction(route: 'home'));
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
