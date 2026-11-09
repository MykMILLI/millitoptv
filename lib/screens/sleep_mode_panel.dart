import 'dart:async';

import 'package:flutter/material.dart';
import '../services/sleep_mode.dart';
import '../services/sleep_sounds_controller.dart';
import '../services/home_preferences.dart';
import '../services/web_app_definition.dart';

Future<void> showSleepModeSheet(
  BuildContext context, {
  required int profileId,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => Dialog(
      backgroundColor: const Color(0xFF0E1B33),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 900),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 16 + MediaQuery.of(dialogContext).viewInsets.bottom,
            ),
            child: SleepModePanel(profileId: profileId),
          ),
        ),
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
  final sounds = SleepSoundsController.instance;
  final minutes = TextEditingController(text: '45');
  final extensionMinutes = TextEditingController(text: '15');
  bool busy = false;
  String error = '';

  String _soundLabel(String key) {
    switch (key) {
      case 'heavy-rain':
        return 'Heavy Rain';
      case 'thunder':
        return 'Thunder';
      case 'white-noise':
        return 'White Noise';
      case 'pink-noise':
        return 'Pink Noise';
      case 'brown-noise':
        return 'Brown Noise';
      default:
        if (key.isEmpty) {
          return key;
        }
        final normalized = key.replaceAll('-', ' ');
        return normalized[0].toUpperCase() + normalized.substring(1);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(sounds.loadPreferences(widget.profileId));
  }

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

  Future<void> _openSounds() async {
    final url = await HomePreferences().sleepUrl(widget.profileId);
    await sounds.play(
      profileId: widget.profileId,
      url: url,
      launcher: sleep.openSounds,
      stopper: sleep.stopSounds,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([sleep, sounds]),
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
              'Sleep Sounds runs in-app with embedded playback by default. Browser fallback remains available if needed.',
            ),
            const SizedBox(height: 14),
            Text(
              'Sleep Sounds backend: ${sounds.backend == SleepSoundsBackend.browserFallback ? 'Browser fallback' : 'Embedded WebView'}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: busy || sleep.applying
                      ? null
                      : () => act(_openSounds),
                  icon: const Icon(Icons.nightlight_outlined),
                  label: const Text('Start / return to Sleep Sounds'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      busy ||
                          sleep.applying ||
                          !sounds.capabilities.supportsPauseResume
                      ? null
                      : () => act(() async {
                          if (sounds.state == SleepSoundsState.paused) {
                            await sounds.resume();
                            return;
                          }
                          await sounds.pause();
                        }),
                  icon: Icon(
                    sounds.state == SleepSoundsState.paused
                        ? Icons.play_arrow
                        : Icons.pause,
                  ),
                  label: Text(
                    sounds.state == SleepSoundsState.paused
                        ? 'Resume Sounds'
                        : 'Pause Sounds',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy || sleep.applying
                      ? null
                      : () => act(() async {
                          await sounds.stop();
                        }),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Sleep Sounds'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: sounds.selectedPreset,
                  items: const [
                    DropdownMenuItem(
                      value: 'overnight-storm',
                      child: Text('Overnight storm mix'),
                    ),
                    DropdownMenuItem(
                      value: 'heavy-rain',
                      child: Text('Heavy rain'),
                    ),
                    DropdownMenuItem(value: 'thunder', child: Text('Thunder')),
                    DropdownMenuItem(
                      value: 'white-noise',
                      child: Text('White noise'),
                    ),
                    DropdownMenuItem(
                      value: 'pink-noise',
                      child: Text('Pink noise'),
                    ),
                    DropdownMenuItem(value: 'rain', child: Text('Rain')),
                    DropdownMenuItem(value: 'ocean', child: Text('Ocean')),
                    DropdownMenuItem(value: 'forest', child: Text('Forest')),
                    DropdownMenuItem(
                      value: 'brown-noise',
                      child: Text('Brown noise'),
                    ),
                  ],
                  onChanged: busy || !sounds.capabilities.supportsPresets
                      ? null
                      : (value) => unawaited(
                          act(() async {
                            if (value == null) {
                              return;
                            }
                            sounds.setPreset(value);
                            await sounds.savePreferences(widget.profileId);
                          }),
                        ),
                ),
                SizedBox(
                  width: 180,
                  child: Slider(
                    min: 0,
                    max: 100,
                    value: sounds.volume.clamp(0, 100).toDouble(),
                    label: '${sounds.volume.round()}%',
                    onChanged: busy || !sounds.capabilities.supportsMasterVolume
                        ? null
                        : (value) => sounds.setVolume(value),
                    onChangeEnd:
                        busy || !sounds.capabilities.supportsMasterVolume
                        ? null
                        : (_) => unawaited(
                            sounds.savePreferences(widget.profileId),
                          ),
                  ),
                ),
                Text('Sleep Sounds volume ${sounds.volume.round()}%'),
              ],
            ),
            if (sounds.capabilities.supportsPerSoundVolume &&
                sounds.perSoundVolume.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  collapsedIconColor: Colors.white70,
                  iconColor: Colors.white70,
                  title: const Text(
                    'Individual sound levels',
                    style: TextStyle(color: Colors.white70),
                  ),
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final entry in sounds.perSoundVolume.entries)
                          SizedBox(
                            width: 220,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_soundLabel(entry.key)} ${entry.value.round()}%',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                Slider(
                                  min: 0,
                                  max: 100,
                                  value: entry.value.clamp(0, 100).toDouble(),
                                  onChanged: busy
                                      ? null
                                      : (value) => unawaited(
                                          sounds.setPerSoundVolume(
                                            entry.key,
                                            value,
                                          ),
                                        ),
                                  onChangeEnd: busy
                                      ? null
                                      : (_) => unawaited(
                                          sounds.savePreferences(
                                            widget.profileId,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              collapsedIconColor: Colors.white70,
              iconColor: Colors.white70,
              title: const Text(
                'Advanced backend options',
                style: TextStyle(color: Colors.white70),
              ),
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ChoiceChip(
                      label: const Text('Browser fallback'),
                      selected:
                          sounds.backend == SleepSoundsBackend.browserFallback,
                      onSelected: busy
                          ? null
                          : (_) => act(() async {
                              sounds.setBackend(
                                SleepSoundsBackend.browserFallback,
                              );
                              await sounds.savePreferences(widget.profileId);
                            }),
                    ),
                    ChoiceChip(
                      label: const Text('Embedded WebView (in-app)'),
                      selected:
                          sounds.backend == SleepSoundsBackend.embeddedWebView,
                      onSelected: busy
                          ? null
                          : (_) => act(() async {
                              sounds.setBackend(
                                SleepSoundsBackend.embeddedWebView,
                              );
                              await sounds.savePreferences(widget.profileId);
                            }),
                    ),
                    TextButton(
                      onPressed:
                          busy ||
                              sounds.backend !=
                                  SleepSoundsBackend.browserFallback
                          ? null
                          : () => act(editUrl),
                      child: const Text('Website address'),
                    ),
                  ],
                ),
                if (!sounds.capabilities.supportsPauseResume)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Pause/resume and in-app mixing are unavailable in browser fallback mode.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Playback state: ${sounds.state.name} · Active layers: ${sounds.activeLayers.isEmpty ? 'None' : sounds.activeLayers.join(', ')}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (sounds.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(sounds.message),
              ),
            if (sounds.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  sounds.error,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
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
                OutlinedButton(
                  onPressed: busy || sleep.applying
                      ? null
                      : () => act(sleep.stopEntertainmentNow),
                  child: const Text('Stop entertainment now'),
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
              'Display-off is not PC sleep. Keep Millitop running overnight. Canceling or extending the timer does not change Sleep Sounds playback. Updates are blocked while overnight mode is active.',
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
