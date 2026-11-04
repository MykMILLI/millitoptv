import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../services/native_app_launcher.dart';
import '../store/store_catalog.dart';
import '../store/store_job.dart';

class NativeAppScreen extends StatefulWidget {
  final String appKey;
  final String title;
  const NativeAppScreen({super.key, required this.appKey, required this.title});
  @override
  State<NativeAppScreen> createState() => _NativeAppScreenState();
}

class _NativeAppScreenState extends State<NativeAppScreen> {
  late final StoreJob job;
  bool opening = false;
  @override
  void initState() {
    super.initState();
    job = StoreJob(nativeStoreApp(widget.appKey));
    job.addListener(changed);
    unawaited(job.check());
  }

  void changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    job.removeListener(changed);
    job.dispose();
    super.dispose();
  }

  Future<void> install() async {
    final approved =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Install ${widget.title}?'),
            content: const Text(
              'Millitop will download and verify the package, then install it. '
              'This accepts its package and WinGet source agreements. Windows may ask for approval '
              'or an administrator password. Keep Millitop open until installation finishes.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Install'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved || !mounted) {
      return;
    }
    await job.install();
    if (!mounted || job.phase != StorePhase.ready || job.executable == null) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final text = job.message;
    Navigator.of(context).popUntil((r) => r.isFirst);
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> open() async {
    setState(() => opening = true);
    try {
      await NativeAppLauncher.open(
        context,
        appKey: widget.appKey,
        title: widget.title,
      );
    } finally {
      if (mounted) {
        setState(() => opening = false);
      }
    }
  }

  Future<void> locate() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Installed application', extensions: ['exe']),
        ],
      );
      if (file != null) {
        await job.locate(file.path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  int get step => switch (job.phase) {
    StorePhase.downloading => 0,
    StorePhase.verifying => 1,
    StorePhase.approval => 2,
    StorePhase.installing => 2,
    StorePhase.detecting => 3,
    StorePhase.ready => 4,
    _ => -1,
  };
  @override
  Widget build(BuildContext context) {
    final busy = job.busy || opening;
    const labels = ['Download', 'Verify', 'Install', 'Check'];
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1425),
        appBar: AppBar(
          title: const Text('App Store'),
          automaticallyImplyLeading: !busy,
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 850),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'assets/native/${widget.appKey}.png',
                        width: 64,
                        height: 64,
                        errorBuilder: (_, e, s) =>
                            const Icon(Icons.apps, size: 64),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(fontSize: 36),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    job.app.description,
                    style: const TextStyle(fontSize: 20, color: Colors.white70),
                  ),
                  const SizedBox(height: 28),
                  Text(job.message, style: const TextStyle(fontSize: 23)),
                  if (job.busy) ...[
                    const SizedBox(height: 20),
                    LinearProgressIndicator(
                      value: job.phase == StorePhase.downloading
                          ? job.progress
                          : null,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      job.phase == StorePhase.downloading &&
                              job.progress != null
                          ? '${(job.progress! * 100).round()}% downloaded'
                          : 'Please keep Millitop open.',
                    ),
                  ],
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 14,
                    runSpacing: 12,
                    children: [
                      for (int i = 0; i < labels.length; i++)
                        Chip(
                          avatar: Icon(
                            step > i
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 18,
                          ),
                          label: Text(labels[i]),
                        ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  Wrap(
                    spacing: 16,
                    runSpacing: 14,
                    children: [
                      if (job.phase == StorePhase.ready &&
                          job.executable != null)
                        FilledButton.icon(
                          onPressed: busy ? null : open,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Open'),
                        ),
                      if (!busy &&
                          job.phase != StorePhase.pending &&
                          job.executable == null &&
                          !job.installedEvidence &&
                          job.wingetAvailable)
                        FilledButton.icon(
                          onPressed: install,
                          icon: const Icon(Icons.download),
                          label: Text(
                            job.phase == StorePhase.failed
                                ? 'Retry'
                                : 'Install',
                          ),
                        ),
                      if (job.canCancel)
                        OutlinedButton(
                          onPressed: job.cancelDownload,
                          child: const Text('Cancel download'),
                        ),
                      OutlinedButton(
                        onPressed: busy ? null : () => job.check(),
                        child: const Text('Check again'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => Navigator.of(
                                context,
                              ).popUntil((r) => r.isFirst),
                        child: const Text('Back to Home'),
                      ),
                    ],
                  ),
                  if (!job.wingetAvailable &&
                      !job.busy &&
                      job.executable == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 18),
                      child: Text(
                        'Windows App Installer is unavailable. Contact support.',
                      ),
                    ),
                  const SizedBox(height: 22),
                  ExpansionTile(
                    title: const Text('Help and technical details'),
                    children: [
                      TextButton(
                        onPressed: busy ? null : locate,
                        child: const Text('Locate an app already installed'),
                      ),
                      if (job.executable != null)
                        SelectableText(job.executable!),
                      if (job.details.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            job.details,
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
