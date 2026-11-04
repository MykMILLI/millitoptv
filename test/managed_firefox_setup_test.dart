import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/managed_firefox_setup.dart';

class FakeSetup implements FirefoxSetupRunner {
  bool ready = false, fail = false;
  final calls = <String>[];
  final purposes = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String action,
    int profile,
    String purpose,
    void Function(String, int) progress,
  ) async {
    calls.add(action);
    purposes.add(purpose);
    if (action == 'inspect') {
      return {
        'installed': ready,
        'ready': ready,
        'executable': ready ? r'C:\Managed\firefox.exe' : null,
      };
    }
    progress('Preparing required extensions...', 50);
    if (fail) {
      throw const FirefoxSetupException('Test setup failure');
    }
    return {
      'type': 'prepared',
      'executable': r'C:\Managed\firefox.exe',
      'extensionsReady': true,
    };
  }
}

void main() {
  testWidgets('ready browser opens without repeat consent', (tester) async {
    final runner = FakeSetup()..ready = true;
    final setup = ManagedFirefoxSetup(runner: runner);
    String? path;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                path = await setup.ensure(context, 1);
              },
              child: const Text('Launch'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch'));
    await tester.pump();
    expect(path, r'C:\Managed\firefox.exe');
    expect(runner.calls, ['inspect']);
    expect(find.text('Install and open'), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 20)));
  testWidgets(
    'first use asks once then prepares and returns signed browser path',
    (tester) async {
      final runner = FakeSetup();
      final setup = ManagedFirefoxSetup(runner: runner);
      String? path;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  path = await setup.ensure(context, 2);
                },
                child: const Text('Launch'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      expect(find.text('Install and open'), findsOneWidget);
      await tester.tap(find.text('Install and open'));
      await tester.pumpAndSettle();
      expect(path, r'C:\Managed\firefox.exe');
      expect(runner.calls, ['inspect', 'ensure']);
      expect(runner.purposes, ['media', 'media']);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
  testWidgets('declining first use never downloads or prepares', (
    tester,
  ) async {
    final runner = FakeSetup();
    final setup = ManagedFirefoxSetup(runner: runner);
    String? path = 'unchanged';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                path = await setup.ensure(context, 1);
              },
              child: const Text('Launch'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(path, isNull);
    expect(runner.calls, ['inspect']);
  }, timeout: const Timeout(Duration(seconds: 20)));
  testWidgets(
    'payment setup uses separate purpose and no media extension message',
    (tester) async {
      final runner = FakeSetup();
      final setup = ManagedFirefoxSetup(runner: runner);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => setup.ensure(context, 1, purpose: 'payments'),
                child: const Text('Pay'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      expect(find.text('Prepare payment browser'), findsOneWidget);
      expect(runner.purposes, ['payments']);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
  testWidgets('failed provisioning never returns a browser path', (
    tester,
  ) async {
    final runner = FakeSetup()..fail = true;
    final setup = ManagedFirefoxSetup(runner: runner);
    Object? error;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                try {
                  await setup.ensure(context, 1);
                } catch (e) {
                  error = e;
                }
              },
              child: const Text('Launch'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install and open'));
    await tester.pumpAndSettle();
    expect(error, isA<FirefoxSetupException>());
    expect(runner.calls, ['inspect', 'ensure']);
  }, timeout: const Timeout(Duration(seconds: 20)));
}
