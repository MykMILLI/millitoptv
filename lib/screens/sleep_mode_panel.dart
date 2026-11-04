import 'package:flutter/material.dart';
import '../services/sleep_mode.dart';
import '../services/home_preferences.dart';
import '../services/web_app_definition.dart';

class SleepModePanel extends StatefulWidget {
  final int profileId;
  const SleepModePanel({super.key, required this.profileId});
  @override
  State<SleepModePanel> createState() => _SleepModePanelState();
}

class _SleepModePanelState extends State<SleepModePanel> {
  final sleep = SleepMode.instance;
  final minutes = TextEditingController(text: '45');
  bool busy = false;
  String error = '';
  int handledPromptId = 0;
  bool countdownModalOpen = false;

  @override
  void initState() {
    super.initState();
    sleep.addListener(_onSleepChanged);
  }

  @override
  void dispose() {
    sleep.removeListener(_onSleepChanged);
    minutes.dispose();
    super.dispose();
  }

  Future<void> _onSleepChanged() async {
    if (!mounted || countdownModalOpen) {
      return;
    }
    if (sleep.countdownPromptId <= handledPromptId || sleep.deadline == null) {
      return;
    }
    handledPromptId = sleep.countdownPromptId;
    countdownModalOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Viewing timer ending soon'),
          content: ListenableBuilder(
            listenable: sleep,
            builder: (_, __) {
              final seconds = sleep.remaining.inSeconds.clamp(0, 30);
              return Text(
                seconds > 0
                    ? 'Your session ends in $seconds second${seconds == 1 ? '' : 's'}. Add more time?'
                    : 'Your timer is ending now.',
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                sleep.extend(5);
                Navigator.of(ctx).pop();
              },
              child: const Text('+5 min'),
            ),
            FilledButton(
              onPressed: () {
                sleep.extend(15);
                Navigator.of(ctx).pop();
              },
              child: const Text('+15 min'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Keep current timer'),
            ),
          ],
        ),
      );
    } finally {
      countdownModalOpen = false;
    }
  }

  Future<void> act(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> editUrl() async {
    final controller = TextEditingController(
      text: await HomePreferences().sleepUrl(widget.profileId),
    );
    if (!mounted) {
      controller.dispose();
      return;
    }
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sleep Sounds website'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'HTTPS address'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (value != null) {
      await HomePreferences().setSleepUrl(
        widget.profileId,
        validateAppUrl(value),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sleep,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sleep Sounds & viewing timer',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Start your sounds in the separate Sleep Sounds window, then return to watch TV. The viewing timer leaves that window running.',
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: busy || sleep.applying
                      ? null
                      : () => act(() async {
                          await sleep.openSounds(
                            widget.profileId,
                            await HomePreferences().sleepUrl(widget.profileId),
                          );
                        }),
                  icon: const Icon(Icons.nightlight_outlined),
                  label: const Text('Open / return to Sleep Sounds'),
                ),
                TextButton(
                  onPressed: busy ? null : () => act(editUrl),
                  child: const Text('Website address'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final n in [15, 30, 45, 60, 90, 120])
                  TextButton(
                    onPressed: busy || sleep.applying
                        ? null
                        : () => setState(() => minutes.text = '$n'),
                    child: Text('$n min'),
                  ),
              ],
            ),
            SizedBox(
              width: 240,
              child: TextField(
                controller: minutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Timer minutes (1–720)',
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton(
                  onPressed: busy || sleep.applying
                      ? null
                      : () => act(() async {
                          final n = int.tryParse(minutes.text);
                          if (n == null) {
                            throw const FormatException(
                              'Enter a number of minutes.',
                            );
                          }
                          await sleep.startTimer(n);
                        }),
                  child: const Text('Start viewing timer'),
                ),
                if (sleep.deadline != null)
                  OutlinedButton(
                    onPressed: sleep.applying ? null : () => sleep.extend(15),
                    child: const Text('Add 15 minutes'),
                  ),
                if (sleep.deadline != null)
                  TextButton(
                    onPressed: sleep.applying ? null : sleep.cancelTimer,
                    child: const Text('Cancel timer'),
                  ),
                if (sleep.overnight)
                  TextButton(
                    onPressed: busy || sleep.applying
                        ? null
                        : () => act(sleep.endOvernight),
                    child: const Text('End overnight keep-awake'),
                  ),
              ],
            ),
            if (sleep.deadline != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Viewing ends in ${sleep.remaining.inMinutes}:${(sleep.remaining.inSeconds % 60).toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 24),
                ),
              ),
            if (sleep.applying) const LinearProgressIndicator(),
            if (sleep.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(sleep.message),
              ),
            const SizedBox(height: 6),
            Text(
              'Last timer action: ${sleep.lastTimerAction}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: Colors.orangeAccent)),
            const SizedBox(height: 10),
            const Text(
              'Display-off is not PC sleep. Keep Millitop running overnight. Starting a timer does not start website audio. Closing Sleep Sounds does not automatically end keep-awake. Updates are blocked while overnight mode is active.',
              style: TextStyle(color: Colors.white60),
            ),
          ],
        ),
      ),
    ),
  );
}
