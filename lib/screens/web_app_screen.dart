import 'dart:async';
import 'package:flutter/material.dart';
import '../services/firefox_browser.dart';

class WebAppScreen extends StatefulWidget {
  final String title, url;
  final int profileId;
  const WebAppScreen({
    super.key,
    required this.title,
    required this.url,
    required this.profileId,
  });
  @override
  State<WebAppScreen> createState() => _WebAppScreenState();
}

class _WebAppScreenState extends State<WebAppScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_launch());
      }
    });
  }

  Future<void> _launch() async {
    await FirefoxBrowser.open(
      context,
      profileId: widget.profileId,
      url: widget.url,
      appFullscreen: true,
    );
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: const Center(
      child: Text('Opening this website in your profile’s Firefox...'),
    ),
  );
}
