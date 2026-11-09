import 'dart:async';
import 'package:flutter/material.dart';
import '../services/firefox_browser.dart';
import '../services/sleep_mode.dart';
import 'sleep_mode_panel.dart';

/// Shows a web app (Emby, Discovery+, Tennis Channel, ...) in the profile's
/// app-owned Firefox, docked inside the MILLITOP window below this top bar.
class WebAppScreen extends StatefulWidget {
  final String title, url;
  final int profileId;
  const WebAppScreen({
    super.key,
    required this.title,
    required this.url,
    required this.profileId,
  });

  /// Height of the top bar Firefox is docked under (logical pixels).
  static const double barHeight = 56;

  @override
  State<WebAppScreen> createState() => _WebAppScreenState();
}

class _WebAppScreenState extends State<WebAppScreen> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_launch());
    });
  }

  Future<void> _launch() async {
    await FirefoxBrowser.open(
      context,
      profileId: widget.profileId,
      url: widget.url,
      appFullscreen: true,
      dock: true,
      dockTopInset: WebAppScreen.barHeight,
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _back() async {
    if (_closing) return;
    setState(() => _closing = true);
    await FirefoxBrowser.requestClose();
  }

  /// MILLITOP sheets would open behind the docked browser, so hide it while
  /// one is showing.
  Future<void> _withBrowserHidden(Future<void> Function() action) async {
    await FirefoxBrowser.setDockHidden(true);
    try {
      await action();
    } finally {
      await FirefoxBrowser.setDockHidden(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0D14),
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(WebAppScreen.barHeight),
          child: Material(
            color: const Color(0xFF121520),
            child: SizedBox(
              height: WebAppScreen.barHeight,
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Back to MILLITOP TV',
                    color: Colors.white,
                    onPressed: _closing ? null : _back,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Sleep timer',
                    color: Colors.white,
                    onPressed: () => unawaited(
                      _withBrowserHidden(
                        () => showSleepModeSheet(
                          context,
                          profileId: widget.profileId,
                        ),
                      ),
                    ),
                    icon: ListenableBuilder(
                      listenable: SleepMode.instance,
                      builder: (context, _) => Icon(
                        SleepMode.instance.deadline == null
                            ? Icons.nightlight_round_outlined
                            : Icons.timer_outlined,
                      ),
                    ),
                  ),
                  ValueListenableBuilder(
                    valueListenable: FirefoxBrowser.docked,
                    builder: (context, docked, _) => IconButton(
                      tooltip: 'Open in its own Firefox window',
                      color: Colors.white,
                      onPressed: docked ? FirefoxBrowser.popOut : null,
                      icon: const Icon(Icons.open_in_new),
                    ),
                  ),
                  // Leaves room for the watch party pill on the right.
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: FirefoxBrowser.docked,
            builder: (context, docked, _) => Text(
              _closing
                  ? 'Closing ${widget.title}…'
                  : docked
                  ? '${widget.title} is open in Firefox.'
                  : 'Opening ${widget.title} in your profile’s Firefox…',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ),
    );
  }
}
