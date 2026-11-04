import 'dart:async';
import 'package:flutter/material.dart';

class OpeningIndicator {
  static void show(BuildContext context, String title) {
    final navigator = Navigator.of(context, rootNavigator: true);

    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(),
                ),
                const SizedBox(width: 24),
                Flexible(
                  child: Text(
                    'Opening $title...',
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    navigator.push(route);

    Timer(const Duration(seconds: 3), () {
      if (route.isActive && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
  }
}
