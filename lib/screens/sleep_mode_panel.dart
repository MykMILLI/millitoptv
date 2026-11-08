import 'dart:async';

import 'package:flutter/material.dart';
import '../services/sleep_mode.dart';
import '../services/home_preferences.dart';
import '../services/web_app_definition.dart';

Future<void> showSleepModeSheet(
  BuildContext context, {
  required int profileId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF0E1B33),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: SleepModePanel(profileId: profileId),
      ),
    ),
  );
}

class SleepModePanel extends StatefulWidget {
  final int profileId;
  const SleepModePanel({super.key, required this.profileId});
  @override
  State<SleepModePanel> createState() => _SleepModePanelState();
}

class _SleepModePanelState extends State<SleepModePanel> {
  final sleep = SleepMode.instance;
  final minutes = TextEditingController(text: '45');
  final extensionMinutes = TextEditingController(text: '15');
  bool busy = false;
  String error = '';

  @override
  void dispose() {
    minutes.dispose();
    extensionMinutes.dispose();
    super.dispose();
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

  Future<void> _extendTimer(int minutes) async {
    await act(() async {
      sleep.extend(minutes);
    });
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
                    onPressed: sleep.applying
                        ? null
                        : () => unawaited(_extendTimer(5)),
                    child: const Text('+5 min'),
                  ),
                if (sleep.deadline != null)
                  OutlinedButton(
                    onPressed: sleep.applying
                        ? null
                        : () => unawaited(_extendTimer(15)),
                    child: const Text('+15 min'),
                  ),
                if (sleep.deadline != null)
                  OutlinedButton(
                    onPressed: sleep.applying
                        ? null
                        : () => unawaited(_extendTimer(30)),
                    child: const Text('+30 min'),
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
                  'Viewing ends in ${sleep.remaining.inMinutes}:${(sleep.remaining.inSeconds % 60).toString().padLeft(2, '0')}'
                  '  ·  End time ${TimeOfDay.fromDateTime(sleep.deadline!.toLocal()).format(context)}',
                  style: const TextStyle(fontSize: 24),
                ),
              ),
            if (sleep.deadline != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: extensionMinutes,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Custom add (minutes)',
                        ),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: busy || sleep.applying
                          ? null
                          : () => unawaited(
                              act(() async {
                                final n = int.tryParse(extensionMinutes.text);
                                if (n == null) {
                                  throw const FormatException(
                                    'Enter extension minutes.',
                                  );
                                }
                                sleep.extend(n);
                              }),
                            ),
                      child: const Text('Add custom time'),
                    ),
                  ],
                ),
              ),
            if (sleep.applying) const LinearProgressIndicator(),
            if (sleep.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(sleep.message),
              ),
            if (sleep.darkScreenModeAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              sleep.setDarkScreenMode(
                                !sleep.darkScreenModeEnabled,
                              );
                            }),
                      icon: Icon(
                        sleep.darkScreenModeEnabled
                            ? Icons.visibility_outlined
                            : Icons.brightness_2_outlined,
                      ),
                      label: Text(
                        sleep.darkScreenModeEnabled
                            ? 'Disable dark-screen mode'
                            : 'Enable dark-screen mode',
                      ),
                    ),
                    const Text(
                      'Use this only when Windows display-off is unavailable.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
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
            const SizedBox(height: 8),
            const Text(
              'When the timer expires, Millitop stops app-owned entertainment playback, keeps Sleep Sounds running, and then requests display-off.',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    ),
  );
}
