import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'billing_models.dart';
import 'device_connection.dart';

abstract class BillingCheckout {
  Future<bool> open(Uri uri);
  Future<void> restore();
}

class SystemBillingCheckout implements BillingCheckout {
  bool? _fullscreen, _topmost;
  @override
  Future<bool> open(Uri uri) async {
    verifiedSquareCheckout(uri.toString());
    DeviceConnection.instance.setMediaActive('square-checkout', true);
    try {
      _fullscreen = await windowManager.isFullScreen();
      _topmost = await windowManager.isAlwaysOnTop();
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setFullScreen(false);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        await restore();
      }
      return launched;
    } catch (_) {
      await restore();
      rethrow;
    }
  }

  @override
  Future<void> restore() async {
    final fullscreen = _fullscreen, topmost = _topmost;
    _fullscreen = null;
    _topmost = null;
    try {
      if (fullscreen != null) {
        await windowManager.setFullScreen(fullscreen);
      }
      if (topmost != null) {
        await windowManager.setAlwaysOnTop(topmost);
      }
    } finally {
      DeviceConnection.instance.setMediaActive('square-checkout', false);
    }
  }
}
