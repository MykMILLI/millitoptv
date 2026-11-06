import 'package:flutter/material.dart';

void main() {
  runApp(const RemoteControlApp());
}

class RemoteControlApp extends StatelessWidget {
  const RemoteControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MILLITOP Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const RemoteControlScreen(),
    );
  }
}

class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key});

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  bool connected = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MILLITOP Remote')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    connected ? 'Connected to living-room session' : 'Not connected',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                FilledButton(
                  onPressed: () => setState(() => connected = !connected),
                  child: Text(connected ? 'Disconnect' : 'Connect'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _action(Icons.skip_previous, 'Prev'),
                _action(Icons.play_arrow, 'Play'),
                _action(Icons.pause, 'Pause'),
                _action(Icons.skip_next, 'Next'),
                _action(Icons.volume_up, 'Volume'),
                _action(Icons.queue_music, 'Queue'),
                _action(Icons.group, 'Group Sync'),
                _action(Icons.swap_horiz, 'Transfer'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label) {
    return SizedBox(
      width: 130,
      child: FilledButton.icon(
        onPressed: connected ? () {} : null,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}
