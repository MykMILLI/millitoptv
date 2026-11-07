import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum MediaAppIconKind { youtube, podcasts }

class AnimatedMediaAppIcon extends StatefulWidget {
  final MediaAppIconKind kind;
  const AnimatedMediaAppIcon({super.key, required this.kind});

  @override
  State<AnimatedMediaAppIcon> createState() => _AnimatedMediaAppIconState();
}

class _AnimatedMediaAppIconState extends State<AnimatedMediaAppIcon>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? pulse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (!enabled) {
      pulse?.cancel();
      pulse = null;
      motion.stop();
      motion.value = 0;
    } else if (pulse == null) {
      motion.forward(from: 0);
      pulse = Timer.periodic(const Duration(seconds: 6), (_) {
        motion.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    pulse?.cancel();
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final youtube = widget.kind == MediaAppIconKind.youtube;
    final color = youtube ? const Color(0xFFFF0033) : const Color(0xFFB46CFF);
    return ExcludeSemantics(
      child: SizedBox(
        width: 62,
        height: 62,
        child: AnimatedBuilder(
          animation: motion,
          builder: (context, _) {
            final beat = math.sin(motion.value * math.pi);
            return Stack(
              alignment: Alignment.center,
              children: [
                if (!youtube)
                  Container(
                    width: 42 + 20 * motion.value,
                    height: 42 + 20 * motion.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color.withAlpha((140 * beat).round()),
                        width: 2,
                      ),
                    ),
                  ),
                Transform.scale(
                  scale: 1 + beat * 0.08,
                  child: Container(
                    width: youtube ? 52 : 46,
                    height: youtube ? 38 : 46,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(youtube ? 11 : 23),
                      boxShadow: [
                        BoxShadow(
                          color: color.withAlpha((30 + beat * 80).round()),
                          blurRadius: 6 + beat * 10,
                        ),
                      ],
                    ),
                    child: Icon(
                      youtube
                          ? Icons.play_arrow_rounded
                          : Icons.podcasts_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
