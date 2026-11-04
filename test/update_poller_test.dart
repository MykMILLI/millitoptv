import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/update_poller.dart';

void main() {
  testWidgets('startup failure still retries without restarting', (
    tester,
  ) async {
    var calls = 0;
    final poller = UpdatePoller(() async {
      calls++;
      if (calls == 1) throw StateError('offline');
    }, interval: const Duration(seconds: 1));
    poller.start();
    await tester.pump();
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    poller.stop();
  });
  testWidgets('start is idempotent and stop cancels timers', (tester) async {
    var calls = 0;
    final poller = UpdatePoller(() async {
      calls++;
    }, interval: const Duration(seconds: 1));
    poller.start();
    poller.start();
    await tester.pump();
    expect(calls, 1);
    poller.stop();
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 1);
  });
  testWidgets('reconnect and resume requests are debounced', (tester) async {
    var calls = 0;
    final poller = UpdatePoller(() async {
      calls++;
    });
    poller.start();
    await tester.pump();
    poller.checkSoon();
    poller.checkSoon();
    poller.checkSoon();
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls, 2);
    poller.stop();
  });
  testWidgets('slow checks do not overlap', (tester) async {
    var calls = 0;
    final pending = Completer<void>();
    final poller = UpdatePoller(() {
      calls++;
      return pending.future;
    }, interval: const Duration(seconds: 1));
    poller.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(calls, 1);
    pending.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    poller.stop();
  });
}
