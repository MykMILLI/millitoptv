import 'dart:async';
import 'package:flutter/material.dart';

const welcomeSayings = [
  'Great to see you again.',
  'Make yourself at home.',
  'Your next favorite is waiting.',
  'Settle in and enjoy the moment.',
  'A little downtime looks good on you.',
  'Pick something wonderful to watch.',
  'Good company. Great entertainment.',
  'Welcome to your happy place.',
];

class RotatingWelcomeMessage extends StatefulWidget {
  static int _nextIndex = DateTime.now().millisecondsSinceEpoch % welcomeSayings.length;
  static int nextInitialIndex() => _nextIndex++ % welcomeSayings.length;
  final int initialIndex;
  final TextStyle? style;
  const RotatingWelcomeMessage({super.key, required this.initialIndex, this.style});

  @override
  State<RotatingWelcomeMessage> createState() => _RotatingWelcomeMessageState();
}

class _RotatingWelcomeMessageState extends State<RotatingWelcomeMessage> {
  late int index = widget.initialIndex % welcomeSayings.length;
  late final Timer timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 20), (_) {
      setState(() => index = (index + 1) % welcomeSayings.length);
    });
  }

  @override
  void didUpdateWidget(covariant RotatingWelcomeMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialIndex != oldWidget.initialIndex) {
      index = widget.initialIndex % welcomeSayings.length;
    }
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 300),
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.centerLeft,
      children: [...previous, if (current != null) current],
    ),
    child: Text(welcomeSayings[index], key: ValueKey(index),
      style: widget.style, maxLines: 2, overflow: TextOverflow.ellipsis),
  );
}
