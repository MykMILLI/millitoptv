import 'package:flutter/material.dart';
import '../services/device_connection.dart';
import '../theme/millitop_visual_theme.dart';

class DeviceSetupScreen extends StatefulWidget {
  const DeviceSetupScreen({super.key});

  @override
  State<DeviceSetupScreen> createState() => _DeviceSetupScreenState();
}

class _DeviceSetupScreenState extends State<DeviceSetupScreen> {
  final address = TextEditingController(
    text: 'http://192.168.1.36:8185',
  );
  final code = TextEditingController();

  bool busy = false;
  String? error;

  DeviceConnection get connection => DeviceConnection.instance;

  @override
  void initState() {
    super.initState();
    connection.start();
  }

  @override
  void dispose() {
    address.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> pair() async {
    setState(() {
      busy = true;
      error = null;
    });

    try {
      await connection.enroll(address.text, code.text);
      code.clear();
    } catch (exception) {
      if (mounted) {
        setState(() => error = exception.toString());
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Disconnect this PC?'),
        content: const Text(
          'This removes the saved connection from this Windows user and '
          'stops reporting. It does not revoke or remove the dashboard '
          'record. Revoke that record in the dashboard if it is no longer used.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => busy = true);

    try {
      await connection.disconnect();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Windows could not remove the saved connection.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 700;
    final horizontalPadding = compact ? 16.0 : 36.0;
    final titleSize = compact ? 26.0 : 34.0;
    final statusSize = compact ? 18.0 : 23.0;
    final bodySize = compact ? 16.0 : 21.0;

    return PopScope(
      canPop: !busy,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(title: const Text('Device setup')),
        body: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(horizontalPadding),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: compact ? 560 : 760),
              child: ValueListenableBuilder<String>(
                valueListenable: connection.status,
                builder: (context, status, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connect to MILLITOP',
                        style: TextStyle(fontSize: titleSize),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        status,
                        style: TextStyle(
                          fontSize: statusSize,
                          color: context.millitopTheme.accentColor,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (connection.isEnrolled) ...[
                        Text(
                          connection.deviceName,
                          style: TextStyle(fontSize: compact ? 20 : 25),
                        ),
                        const SizedBox(height: 10),
                        Text(connection.serverUrl),
                        const SizedBox(height: 24),
                        Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            FilledButton(
                              onPressed: busy || connection.isSuspended
                                  ? null
                                  : () => connection.checkNow(),
                              child: const Text('Check connection'),
                            ),
                            OutlinedButton(
                              onPressed: busy ? null : disconnect,
                              child: const Text('Disconnect this PC'),
                            ),
                          ],
                        ),
                      ] else ...[
                        Text(
                          'Generate a pairing code in the admin dashboard, '
                          'then enter it here.',
                          style: TextStyle(fontSize: bodySize, height: 1.5),
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: address,
                          enabled: !busy,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Dashboard server',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: code,
                          enabled: !busy,
                          autofocus: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'Pairing code',
                            hintText: 'ABCD-1234-EF56',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) {
                            if (!busy) pair();
                          },
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: busy ? null : pair,
                          icon: const Icon(Icons.link),
                          label: Text(busy ? 'Pairing…' : 'Connect this PC'),
                        ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 24),
                        Text(
                          error!,
                          style: TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: compact ? 15 : 19,
                          ),
                        ),
                      ],
                      const SizedBox(height: 30),
                      const Text(
                        'The HTTP LAN address is for local testing only. '
                        'Use HTTPS for remote deployment.',
                        style: TextStyle(color: Colors.white60),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
