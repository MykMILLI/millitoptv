import 'dart:async';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/app_updates.dart';
import '../services/device_connection.dart';

class AccountUpdatesPanel extends StatefulWidget {
  const AccountUpdatesPanel({super.key});
  @override
  State<AccountUpdatesPanel> createState() => _AccountUpdatesPanelState();
}

class _AccountUpdatesPanelState extends State<AccountUpdatesPanel> {
  String version = 'Checking installed version...', message = '';
  Map<String, dynamic>? release;
  bool loading = true, starting = false;
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => version = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      if (mounted) {
        setState(() => version = 'Version unavailable');
      }
    }
    await _check();
  }

  Future<void> _check() async {
    if (starting) {
      return;
    }
    setState(() => loading = true);
    try {
      final result = await AppUpdates.instance.availableForAccount();
      if (mounted) {
        setState(() {
          release = result;
          message = result == null
              ? 'No newer enabled update is currently offered to this device.'
              : 'An update is available for this device.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          release = null;
          message =
              'Update availability could not be confirmed. Check device pairing and connectivity, then retry.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _install() async {
    final offered = release;
    if (offered == null || starting) {
      return;
    }
    setState(() => starting = true);
    try {
      await AppUpdates.instance.installFromAccount(offered);
    } catch (e) {
      if (mounted) {
        setState(() => message = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => starting = false);
        await _check();
      }
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppUpdateView>(
    valueListenable: AppUpdates.instance.view,
    builder: (context, update, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'App updates',
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(
          'Device: ${DeviceConnection.instance.deviceName.isEmpty ? 'Not paired' : DeviceConnection.instance.deviceName}',
        ),
        Text('Installed: $version'),
        const SizedBox(height: 14),
        Text(message),
        if (loading || starting || update.busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        if (release != null) ...[
          const SizedBox(height: 12),
          Text(
            'Millitop ${release!['version']}+${release!['build']}',
            style: const TextStyle(fontSize: 25),
          ),
          Text(release!['notes']?.toString() ?? ''),
          const SizedBox(height: 10),
          const Text(
            'Installation closes and restarts Millitop. Windows may ask for approval.',
          ),
          FilledButton(
            onPressed:
                loading ||
                    starting ||
                    update.busy ||
                    AppUpdates.instance.recoveryRequired
                ? null
                : _install,
            child: const Text('Download and install'),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: loading || starting || update.busy ? null : _check,
          icon: const Icon(Icons.refresh),
          label: const Text('Check available updates'),
        ),
        const SizedBox(height: 12),
        const Text(
          'Only the update offered by the server to this enrolled device is shown. Paused, unassigned and older releases are not a public catalogue.',
        ),
      ],
    ),
  );
}
