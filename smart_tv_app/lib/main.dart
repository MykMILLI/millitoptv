import 'package:flutter/material.dart';

void main() {
  runApp(const SmartTvApp());
}

class SmartTvApp extends StatelessWidget {
  const SmartTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MILLITOP TV App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const SmartTvHomeScreen(),
    );
  }
}

class SmartTvHomeScreen extends StatelessWidget {
  const SmartTvHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final channels = <String>[
      'Continue Watching',
      'Live TV',
      'Music',
      'Movies',
      'Group Listening',
      'Remote Control Pairing',
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('MILLITOP Smart TV')),
      body: GridView.builder(
        padding: const EdgeInsets.all(20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 1.6,
        ),
        itemCount: channels.length,
        itemBuilder: (context, index) => Card(
          child: InkWell(
            onTap: () {},
            child: Center(
              child: Text(
                channels[index],
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
