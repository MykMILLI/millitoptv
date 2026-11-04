import 'package:flutter/material.dart';
import '../store/store_catalog.dart';
import 'native_app_screen.dart';
import 'home_app_tiles.dart';
import 'app_settings_screen.dart';

class AppStoreScreen extends StatelessWidget {
  final int profileId;
  const AppStoreScreen({super.key, required this.profileId});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Apps and websites'),
      actions: [
        IconButton(
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) => AppSettingsScreen(profileId: profileId),
            ),
          ),
          icon: const Icon(Icons.settings),
          tooltip: 'App settings',
        ),
      ],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Open apps', style: TextStyle(fontSize: 30)),
          const SizedBox(height: 16),
          HomeAppTiles(profileId: profileId),
          const SizedBox(height: 28),
          const Text(
            'Install or manage native apps',
            style: TextStyle(fontSize: 25),
          ),
          for (final app in storeApps.where((a) => !a.isWebsite))
            ListTile(
              title: Text(app.title),
              subtitle: Text(app.description),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      NativeAppScreen(appKey: app.key, title: app.title),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
