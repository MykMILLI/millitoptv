import 'package:flutter/material.dart';
import 'app_quit_button.dart';

class LauncherFooter extends StatelessWidget {
  final Widget connection;
  final Widget? sleepChip;
  final String profileName;
  final VoidCallback? onSwitchProfile;
  final bool blocked;
  final bool Function()? canLeave;
  final Future<void> Function()? onQuit;
  const LauncherFooter({
    super.key,
    required this.connection,
    this.sleepChip,
    required this.profileName,
    this.onSwitchProfile,
    this.blocked = false,
    this.canLeave,
    this.onQuit,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final unavailable = blocked || !(canLeave?.call() ?? true);
      final actions = Wrap(
        alignment: WrapAlignment.end,
        spacing: 12,
        runSpacing: 8,
        children: [
          connection,
          if (sleepChip != null) sleepChip!,
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth < 260 ? constraints.maxWidth : 260,
            ),
            child: Tooltip(
              message: '$profileName · Switch profile',
              child: FilledButton.tonalIcon(
                key: const ValueKey('footer-switch-profile'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                onPressed: unavailable || onSwitchProfile == null
                    ? null
                    : () {
                        if (!(canLeave?.call() ?? true)) {
                          return;
                        }
                        onSwitchProfile!();
                      },
                icon: const Icon(Icons.switch_account),
                label: const Text(
                  'Switch profile',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          AppQuitButton(
            blocked: unavailable,
            canQuit: canLeave,
            onQuit: onQuit,
          ),
        ],
      );
      final help = Text(
        'Profile: $profileName\nArrow keys: move    Enter: open    Esc: back',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface.withAlpha(170),
        ),
      );
      if (constraints.maxWidth >= 1050) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: help),
            const SizedBox(width: 16),
            actions,
          ],
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          help,
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: actions),
        ],
      );
    },
  );
}
