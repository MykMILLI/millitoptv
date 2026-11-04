import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/main.dart';

void main() {
  testWidgets('Launcher displays its home screen', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: Launcher(profileId: 1)));

    await tester.pumpAndSettle();

    expect(find.text('MILLITOP TV'), findsOneWidget);
    expect(find.text('Live TV'), findsOneWidget);
    expect(find.text('VLC player'), findsOneWidget);
    expect(find.text('Emby'), findsOneWidget);
    expect(find.text('Jellyfin'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
