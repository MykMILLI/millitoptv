import 'dart:async';

import 'package:flutter/material.dart';

import '../services/sleep_mode.dart';
import '../services/sleep_sounds_controller.dart';
import '../services/home_preferences.dart';

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
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 900),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: 20 + MediaQuery.of(dialogContext).viewInsets.bottom,
            ),
            child: SleepModePanel(profileId: profileId),
          ),
        ),
      ),
    ),
  );
}

class SleepModePanel extends StatefulWidget {
  const SleepModePanel({super.key, required this.profileId});
  final int profileId;

  @override
  State<SleepModePanel> createState() => _SleepModePanelState();
}

class _SleepModePanelState extends State<SleepModePanel> {
  static const _timerChoices = <int>[15, 30, 45, 60];
  final sleep = SleepMode.instance;
  final sounds = SleepSoundsController.instance;
  int _selectedMinutes = 45;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(sounds.loadPreferences(widget.profileId));
  }

  Future<void> _act(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _startSounds() async {
    final url = await HomePreferences().sleepUrl(widget.profileId);
    await sounds.play(
      profileId: widget.profileId,
      url: url,
      launcher: sleep.openSounds,
      stopper: sleep.stopSounds,
    );
  }

  Future<void> _setCustomDuration() async {
    final controller = TextEditingController(text: '$_selectedMinutes');
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom timer duration'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Minutes (1–720)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value == null || value < 1 || value > 720) {
                return;
              }
              Navigator.pop(ctx, value);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && mounted) {
      setState(() => _selectedMinutes = value);
    }
  }

  IconData _iconFor(String soundId) {
    switch (soundId) {
      case 'heavy-rain':
        return Icons.grain;
      case 'thunder':
        return Icons.thunderstorm;
      case 'white-noise':
        return Icons.blur_on;
      case 'pink-noise':
        return Icons.multitrack_audio;
      default:
        return Icons.music_note;
    }
  }

  String _labelFor(String soundId) {
    switch (soundId) {
      case 'heavy-rain':
        return 'Heavy Rain';
      case 'thunder':
        return 'Thunder';
      case 'white-noise':
        return 'White Noise';
      case 'pink-noise':
        return 'Pink Noise';
      default:
        return soundId;
    }
  }

  Future<void> _handleMixAction() async {
    await _act(() async {
      if (sounds.state == SleepSoundsState.paused) {
        await sounds.resume();
        return;
      }
      if (sounds.state == SleepSoundsState.playing) {
        await sounds.pause();
        return;
      }
      await _startSounds();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([sleep, sounds]),
      builder: (context, _) {
        final disabled =
            _busy || sleep.applying || sounds.state == SleepSoundsState.loading;
        final runningTimer = sleep.deadline != null;
        final allDisabled = SleepSoundsController.simpleSoundIds.every(
          (id) => !(sounds.soundEnabled[id] ?? false),
        );
        final remaining = sleep.remaining;
        final minutesLeft = remaining.inMinutes < 0 ? 0 : remaining.inMinutes;
        final secondsLeft = remaining.inSeconds < 0
            ? 0
            : remaining.inSeconds % 60;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sleep Sounds',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Mix your sounds. Keep them playing all night.',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 18),
            for (final soundId in SleepSoundsController.simpleSoundIds) ...[
              _SoundRow(
                icon: _iconFor(soundId),
                label: _labelFor(soundId),
                enabled: sounds.soundEnabled[soundId] ?? false,
                value: (sounds.perSoundVolume[soundId] ?? 0)
                    .clamp(0, 100)
                    .toDouble(),
                disabled: disabled,
                onToggle: (enabled) => unawaited(
                  _act(() async {
                    await sounds.setSoundEnabled(soundId, enabled);
                    await sounds.savePreferences(widget.profileId);
                  }),
                ),
                onChanged: (value) =>
                    unawaited(sounds.setPerSoundVolume(soundId, value)),
                onChangeEnd: (_) =>
                    unawaited(sounds.savePreferences(widget.profileId)),
              ),
              const SizedBox(height: 10),
            ],
            if (allDisabled)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'Enable at least one sound before starting playback.',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: disabled ? null : _handleMixAction,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B6B),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: sounds.state == SleepSoundsState.loading
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('Working...'),
                        ],
                      )
                    : Text(
                        sounds.state == SleepSoundsState.paused
                            ? 'Resume sounds'
                            : sounds.state == SleepSoundsState.playing
                            ? 'Pause sounds'
                            : 'Start sounds',
                      ),
              ),
            ),
            const SizedBox(height: 14),
            const Divider(color: Colors.white24),
            const SizedBox(height: 14),
            const Text(
              'Screen-off timer',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Stops TV, videos and music. Sleep sounds keep playing.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            if (!runningTimer) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in _timerChoices)
                    ChoiceChip(
                      label: Text('$value min'),
                      selected: _selectedMinutes == value,
                      onSelected: disabled
                          ? null
                          : (_) => setState(() => _selectedMinutes = value),
                    ),
                  ActionChip(
                    label: const Text('Custom'),
                    onPressed: disabled ? null : _setCustomDuration,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: disabled
                      ? null
                      : () => _act(() async {
                          await sleep.startTimer(_selectedMinutes);
                        }),
                  child: Text('Start $_selectedMinutes-minute timer'),
                ),
              ),
            ] else ...[
              Text(
                'Remaining time: $minutesLeft:${secondsLeft.toString().padLeft(2, '0')}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _act(() async => sleep.extend(5)),
                    child: const Text('+5 min'),
                  ),
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _act(() async => sleep.extend(15)),
                    child: const Text('+15 min'),
                  ),
                  TextButton(
                    onPressed: disabled ? null : sleep.cancelTimer,
                    child: const Text('Cancel timer'),
                  ),
                ],
              ),
            ],
            if (sounds.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  sounds.error,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Screen off. PC stays on. Sleep sounds stay on.',
              style: TextStyle(color: Colors.white60),
            ),
          ],
        );
      },
    );
  }
}

class _SoundRow extends StatelessWidget {
  const _SoundRow({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.value,
    required this.disabled,
    required this.onToggle,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final double value;
  final bool disabled;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF152645),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: disabled ? null : onToggle,
                activeThumbColor: const Color(0xFFFF6B6B),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: value,
                  min: 0,
                  max: 100,
                  onChanged: disabled ? null : onChanged,
                  onChangeEnd: disabled ? null : onChangeEnd,
                ),
              ),
              SizedBox(
                width: 46,
                child: Text(
                  '${value.round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
