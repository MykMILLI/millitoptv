import 'dart:async';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../services/sleep_mode.dart';
import '../services/app_updates.dart';
import '../store/store_job.dart';

final overnightNavigatorKey = GlobalKey<NavigatorState>();

class OvernightWindowGuard extends StatefulWidget {
  final Widget child;
  const OvernightWindowGuard({super.key, required this.child});
  @override
  State<OvernightWindowGuard> createState() => _OvernightWindowGuardState();
}

class _OvernightWindowGuardState extends State<OvernightWindowGuard>
    with WindowListener {
  bool closing = false;
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_protect());
  }

  Future<void> _protect() async {
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {}
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(_close());
  }

  Future<void> _close() async {
    if (closing) {
      return;
    }
    final context = overnightNavigatorKey.currentContext;
    if (context == null) {
      return;
    }
    if (StoreJob.operationActive ||
        AppUpdates.instance.view.value.busy ||
        AppUpdates.instance.recoveryRequired ||
        SleepMode.instance.applying) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Finish the active operation before closing Millitop.'),
        ),
      );
      return;
    }
    closing = true;
    try {
      final sleep = SleepMode.instance;
      if (sleep.overnight || sleep.deadline != null) {
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('End overnight mode and quit?'),
            content: const Text(
              'Closing Millitop ends its viewing timer and keep-awake protection. Sleep Sounds stays open, but Windows may later sleep and interrupt it.',
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep Millitop running'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('End overnight mode and quit'),
              ),
            ],
          ),
        );
        if (yes != true) {
          return;
        }
        if (StoreJob.operationActive ||
            AppUpdates.instance.view.value.busy ||
            sleep.applying) {
          return;
        }
        await sleep.endOvernight();
      }
      await windowManager.destroy();
    } finally {
      closing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
