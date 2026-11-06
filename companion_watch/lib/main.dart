import 'package:flutter/material.dart';

void main() {
  runApp(const CompanionWatchApp());
}

class CompanionWatchApp extends StatelessWidget {
  const CompanionWatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MILLITOP Watch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const WatchHomeScreen(),
    );
  }
}

class WatchHomeScreen extends StatefulWidget {
  const WatchHomeScreen({super.key});

  @override
  State<WatchHomeScreen> createState() => _WatchHomeScreenState();
}

class _WatchHomeScreenState extends State<WatchHomeScreen> {
  bool playing = false;
  final downloads = <String>[
    'Offline Session · Chill Mix',
    'Offline Session · Most Played',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MILLITOP Watch')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    const Text(
                      'Now Playing',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    const Text('Do Sum Tricks Wit Her Mouth'),
                    const Text(
                      'Rich Homie Quan',
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          onPressed: () {},
                          icon: const Icon(Icons.skip_previous),
                        ),
                        IconButton(
                          onPressed: () => setState(() => playing = !playing),
                          icon: Icon(
                            playing
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            size: 34,
                          ),
                        ),
                        IconButton(
                          onPressed: () {},
                          icon: const Icon(Icons.skip_next),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Watch Downloads',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                itemCount: downloads.length,
                itemBuilder: (context, index) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.download_done),
                  title: Text(downloads[index]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
