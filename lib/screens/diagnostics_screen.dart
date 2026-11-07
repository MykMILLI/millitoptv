import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_log.dart';

/// Settings > Diagnostics: the first stop when troubleshooting.
///
/// Shows the app log newest-first with level/category filters and search,
/// the fix suggestion attached to each error, and lets the user copy,
/// export or share a report. Also holds the usage-sharing opt-out.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, this.log});

  /// Injectable for tests; defaults to [AppLog.instance].
  final AppLog? log;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final TextEditingController query = TextEditingController();
  LogLevel minLevel = LogLevel.info;
  String category = 'all';

  AppLog get log => widget.log ?? AppLog.instance;

  @override
  void initState() {
    super.initState();
    query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  List<AppLogEntry> _filtered() {
    final text = query.text.trim().toLowerCase();
    return log.entries.reversed.where((entry) {
      if (entry.level.index < minLevel.index) {
        return false;
      }
      if (category != 'all' && entry.category != category) {
        return false;
      }
      if (text.isEmpty) {
        return true;
      }
      return entry.message.toLowerCase().contains(text) ||
          (entry.error ?? '').toLowerCase().contains(text) ||
          entry.category.contains(text);
    }).toList();
  }

  Color _levelColor(LogLevel level) => switch (level) {
    LogLevel.error => const Color(0xFFE53935),
    LogLevel.warn => const Color(0xFFF59E0B),
    LogLevel.info => const Color(0xFF63DFCB),
    LogLevel.debug => const Color(0xFF8FA3BF),
  };

  IconData _levelIcon(LogLevel level) => switch (level) {
    LogLevel.error => Icons.error_outline,
    LogLevel.warn => Icons.warning_amber_outlined,
    LogLevel.info => Icons.info_outline,
    LogLevel.debug => Icons.code,
  };

  Future<void> _copy(List<AppLogEntry> entries) async {
    await Clipboard.setData(
      ClipboardData(text: log.report(only: entries.reversed)),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied ${entries.length} log entries')),
      );
    }
  }

  Future<void> _share(List<AppLogEntry> entries) async {
    try {
      final file = await log.exportReport(only: entries.reversed);
      if (file == null) {
        return;
      }
      AppLog.audit('Diagnostics report exported', details: {'file': file.path});
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'MILLITOP TV diagnostics',
          text: 'MILLITOP TV diagnostics report',
        ),
      );
    } catch (error, stack) {
      AppLog.error(
        LogCategory.app,
        'Could not export diagnostics',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
      }
    }
  }

  Future<void> _showFolder() async {
    final files = await log.logFiles();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log files'),
        content: SizedBox(
          width: 480,
          child: SelectableText(
            [
              'Folder: ${log.directory?.path ?? 'memory only'}',
              '',
              if (files.isEmpty) 'No files yet.',
              for (final file in files) file.path,
            ].join('\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showEntry(AppLogEntry entry) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            '${entry.level.name.toUpperCase()} · ${entry.category}',
            style: TextStyle(color: _levelColor(entry.level)),
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: SelectableText(entry.toDisplayString()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: entry.toDisplayString()),
              ),
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: log.revision,
      builder: (context, _, _) {
        final entries = _filtered();
        final all = log.entries;
        final errors = all.where((e) => e.level == LogLevel.error).length;
        final warnings = all.where((e) => e.level == LogLevel.warn).length;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Diagnostics & logs'),
            actions: [
              IconButton(
                tooltip: 'Copy report',
                onPressed: entries.isEmpty ? null : () => _copy(entries),
                icon: const Icon(Icons.copy_all_outlined),
              ),
              IconButton(
                tooltip: 'Export / share report',
                onPressed: entries.isEmpty ? null : () => _share(entries),
                icon: const Icon(Icons.ios_share),
              ),
              IconButton(
                tooltip: 'Log files',
                onPressed: _showFolder,
                icon: const Icon(Icons.folder_open_outlined),
              ),
            ],
          ),
          // One scroll view so the controls never push the log list off
          // screen on phones or in landscape.
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    children: [
                      ListTile(
                        dense: true,
                        title: Text(
                          'Session ${log.sessionId} · '
                          '$errors errors · $warnings warnings · '
                          '${all.length} entries',
                        ),
                        subtitle: Text(
                          'Version ${log.appVersion.isEmpty ? 'unknown' : log.appVersion} '
                          '· ${log.platform}',
                        ),
                      ),
                      SwitchListTile(
                        key: const ValueKey('diagnostics-share-usage'),
                        dense: true,
                        title: const Text('Share usage & error reports'),
                        subtitle: const Text(
                          'Sends warnings, errors and anonymous usage events '
                          '(no passwords, tokens or URLs with credentials) to '
                          'your MILLITOP dashboard to help improve the app.',
                        ),
                        value: log.shareUsage,
                        onChanged: (value) async {
                          await log.setShareUsage(value);
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                      SwitchListTile(
                        dense: true,
                        title: const Text('Verbose logging'),
                        subtitle: const Text(
                          'Also records debug details such as every server '
                          'request. Turn on while reproducing a problem.',
                        ),
                        value: log.verbose,
                        onChanged: (value) async {
                          await log.setVerbose(value);
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: math.min(
                          260,
                          MediaQuery.sizeOf(context).width - 24,
                        ),
                        child: TextField(
                          key: const ValueKey('diagnostics-search'),
                          controller: query,
                          decoration: const InputDecoration(
                            isDense: true,
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Search logs',
                          ),
                        ),
                      ),
                      for (final level in LogLevel.values)
                        ChoiceChip(
                          label: Text('${level.name}+'),
                          selected: minLevel == level,
                          onSelected: (_) => setState(() => minLevel = level),
                        ),
                      DropdownButton<String>(
                        value: category,
                        onChanged: (value) =>
                            setState(() => category = value ?? 'all'),
                        items: [
                          const DropdownMenuItem(
                            value: 'all',
                            child: Text('All areas'),
                          ),
                          for (final item in LogCategory.all)
                            DropdownMenuItem(value: item, child: Text(item)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: Divider(height: 1)),
              if (entries.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('No log entries match.')),
                )
              else
                SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final time = TimeOfDay.fromDateTime(entry.time);
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        _levelIcon(entry.level),
                        color: _levelColor(entry.level),
                      ),
                      title: Text(
                        entry.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          '${time.format(context)} · ${entry.category}',
                          if (entry.error != null) entry.error!,
                          if (entry.hint != null) 'Fix: ${entry.hint}',
                        ].join('\n'),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _showEntry(entry),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
