import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

class AppQuitButton extends StatefulWidget {
  final bool blocked;
  final bool Function()? canQuit;
  final Future<void> Function()? onQuit;
  final bool autofocus;
  const AppQuitButton({
    super.key,
    this.blocked = false,
    this.canQuit,
    this.onQuit,
    this.autofocus = false,
  });
  @override
  State<AppQuitButton> createState() => _AppQuitButtonState();
}

class _AppQuitButtonState extends State<AppQuitButton> {
  bool _closing = false;
  Future<void> _quit() async {
    if (_closing) {
      return;
    }
    if (widget.blocked || !(widget.canQuit?.call() ?? true)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Finish the active installation or update recovery before quitting.',
          ),
        ),
      );
      return;
    }
    setState(() => _closing = true);
    try {
      final quit = widget.onQuit;
      if (quit != null) {
        await quit();
      } else {
        await windowManager.close();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _closing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not quit Millitop. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.blocked || !(widget.canQuit?.call() ?? true);
    return Tooltip(
      message: blocked
          ? 'Finish the installation or update recovery before quitting.'
          : 'Exit Millitop TV',
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: FilledButton.icon(
          key: const ValueKey('millitop-quit'),
          autofocus: widget.autofocus,
          style: FilledButton.styleFrom(minimumSize: const Size(120, 46)),
          onPressed: blocked || _closing ? null : _quit,
          icon: const Icon(Icons.power_settings_new),
          label: Text(_closing ? 'Quitting...' : 'Quit'),
        ),
      ),
    );
  }
}
