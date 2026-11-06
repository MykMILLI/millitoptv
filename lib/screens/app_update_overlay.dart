import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/app_updates.dart';
import '../theme/millitop_visual_theme.dart';

class AppUpdateOverlay extends StatelessWidget {
  final Widget child;
  const AppUpdateOverlay({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      ValueListenableBuilder<AppUpdateView>(
        valueListenable: AppUpdates.instance.view,
        builder: (context, value, _) {
          if (value.message.isEmpty) {
            return const SizedBox.shrink();
          }
          final maxWidth = MediaQuery.sizeOf(context).width;
          return Positioned(
            top: 20,
            right: 20,
            child: SafeArea(
              child: Material(
                elevation: 16,
                color: context.millitopTheme.panelColor,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: maxWidth < 520 ? maxWidth - 24 : 430,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Millitop app update',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(value.message),
                      if (value.release != null) ...[
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 150),
                          child: SingleChildScrollView(
                            child: Text(
                              value.release!['notes']?.toString() ?? '',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          defaultTargetPlatform == TargetPlatform.android
                              ? 'Download opens the Android installer path. Install the APK, then reopen Millitop.'
                              : 'Download and install will close and restart Millitop. Windows may require administrator approval.',
                        ),
                      ],
                      if (value.busy) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(value: value.progress),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        children: [
                          if (value.release != null)
                            FilledButton(
                              onPressed:
                                  (value.busy ||
                                      AppUpdates.instance.recoveryRequired)
                                  ? null
                                  : () => AppUpdates.instance.install(),
                              child: Text(
                                defaultTargetPlatform == TargetPlatform.android
                                    ? 'Download APK update'
                                    : 'Download and install',
                              ),
                            ),
                          if (value.release != null)
                            TextButton(
                              onPressed: value.busy
                                  ? null
                                  : () => AppUpdates.instance.later(),
                              child: const Text('Later'),
                            ),
                          if (value.release == null)
                            TextButton(
                              onPressed: value.busy
                                  ? null
                                  : () => AppUpdates.instance.dismiss(),
                              child: const Text('Close'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ],
  );
}
