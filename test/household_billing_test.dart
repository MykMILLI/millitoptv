import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/billing_transport.dart';
import 'package:millitop_tv/services/billing_models.dart';
import 'package:millitop_tv/services/household_billing.dart';
import 'package:millitop_tv/services/billing_checkout.dart';
import 'package:millitop_tv/screens/customer_account_panel.dart';

Map<String, dynamic> snapshot() => {
  'linked': true,
  'locked': false,
  'accountId': '11111111-1111-4111-8111-111111111111',
  'householdName': 'Test household',
  'financial': {
    'available': true,
    'complete': true,
    'checkedAt': '2026-10-24T15:00:00Z',
    'customer': {
      'name': 'Test Customer',
      'email': 'test@example.invalid',
      'phone': '555-0100',
      'note': 'PRIVATE SQUARE NOTE',
    },
    'balances': [
      {'currency': 'USD', 'dueMinor': '7500', 'pendingMinor': '0'},
    ],
    'invoices': [
      {
        'id': 'INV-A',
        'number': '1001',
        'title': 'Services',
        'description': 'Public invoice',
        'status': 'PARTIALLY_PAID',
        'currency': 'USD',
        'totalMinor': '10000',
        'completedMinor': '2500',
        'remainingMinor': '7500',
        'dueDate': '2026-11-01',
        'canPay': true,
      },
    ],
  },
  'projects': [
    {
      'id': 'P-A',
      'title': 'Open Project',
      'description': 'Customer-visible description',
      'internalNote': 'ADMIN SECRET',
      'status': 'in_progress',
      'updatedAt': '2026-10-24T15:00:00Z',
      'updates': [
        {'body': 'Public progress', 'createdAt': '2026-10-24T15:00:00Z'},
      ],
    },
    {
      'id': 'P-B',
      'title': 'Closed Project',
      'description': 'Finished',
      'status': 'completed',
      'updatedAt': '2026-10-24T15:00:00Z',
      'updates': [],
    },
  ],
};

class FakeBilling implements HouseholdBillingGateway {
  @override
  String key = 'https://test.invalid|device-a';
  @override
  bool available = true;
  bool locked = false, httpsRequired = false;
  bool expired = false;
  String? receivedSession;
  int expirySeconds = 900;
  int offsetCalls = 0;
  String? failingRoute;
  Completer<Map<String, dynamic>>? pending;
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> secureOrigin() async {
    httpsRequired = false;
    key = 'https://test.invalid|device-secure';
  }

  @override
  Future<Map<String, dynamic>> post(
    String route,
    Map<String, dynamic> body, {
    String? session,
  }) async {
    calls.add(route);
    bodies.add(Map.of(body));
    receivedSession = session;
    if (httpsRequired) {
      throw const BillingTransportException(
        0,
        'https_required',
        'HTTPS required',
      );
    }
    if (route == failingRoute) {
      throw const BillingTransportException(
        403,
        'http',
        'Account session expired',
      );
    }
    if (route == '/api/device/account') {
      if (pending != null) {
        return pending!.future;
      }
      if (locked && (session == null || expired)) {
        return {'linked': true, 'locked': true};
      }
      return snapshot();
    }
    if (route == '/api/device/account/unlock') {
      if (body['pin'] != '123456') {
        throw const BillingTransportException(403, 'http', 'PIN not accepted');
      }
      return {
        'unlocked': true,
        'token': List.filled(43, 's').join(),
        'expiresInSeconds': expirySeconds,
      };
    }
    if (route == '/api/device/account/pay') {
      return {
        'invoiceId': body['invoiceId'],
        'url': 'https://squareup.com/pay-invoice/inv:0-example',
      };
    }
    if (route == '/api/device/account/payments') {
      offsetCalls++;
      return {
        'payments': [
          {
            'id': 'PAY-A',
            'invoiceId': 'INV-A',
            'status': 'COMPLETED',
            'createdAt': '2026-10-24T15:00:00Z',
            'amount': {'amountMinor': '2500', 'currency': 'USD'},
            'refunded': null,
            'card_details': {'PAN': 'NOT RETURNED'},
          },
        ],
        'complete': offsetCalls > 1,
        'nextOffset': offsetCalls > 1 ? null : 10,
      };
    }
    throw StateError('Unknown fake billing route.');
  }
}

class FakeCheckout implements BillingCheckout {
  Uri? opened;
  bool success = true;
  int restores = 0;
  @override
  Future<bool> open(Uri uri) async {
    opened = uri;
    return success;
  }

  @override
  Future<void> restore() async {
    restores++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('minor units format without floating point or currency mixing', () {
    expect(formatBillingMoney('USD', '7500'), 'USD 75.00');
    expect(formatBillingMoney('JPY', '7500'), 'JPY 7500');
    expect(formatBillingMoney('KWD', '12345'), 'KWD 12.345');
    expect(formatBillingMoney('USD', '-25'), '-USD 0.25');
    expect(() => formatBillingMoney('USD', '1.25'), throwsFormatException);
    expect(() => minorAmount(7500), throwsFormatException);
  });
  test('snapshot parses only public fields and exact invoice amounts', () {
    final data = AccountSnapshot.fromJson(snapshot());
    expect(data.name, 'Test Customer');
    expect(data.invoices.single.remaining, '7500');
    expect(data.projects.first.description, 'Customer-visible description');
    expect(data.projects.first.closed, isFalse);
    expect(data.projects.last.closed, isTrue);
  });
  test(
    'locked/unlinked and incomplete financial responses show no inferred total',
    () {
      expect(AccountSnapshot.fromJson({'linked': false}).invoices, isEmpty);
      expect(
        AccountSnapshot.fromJson({'linked': true, 'locked': true}).projects,
        isEmpty,
      );
      final value = snapshot();
      (value['financial'] as Map)['complete'] = false;
      expect(AccountSnapshot.fromJson(value).balances, isNull);
    },
  );
  test(
    'duplicate invoices fail instead of trusting a double-counted balance',
    () {
      final value = snapshot();
      final financial = value['financial'] as Map;
      final rows = financial['invoices'] as List;
      rows.add(Map<String, Object>.from(rows.first as Map));
      expect(() => AccountSnapshot.fromJson(value), throwsFormatException);
    },
  );
  test('only HTTPS Square invoice URLs may launch', () {
    expect(
      verifiedSquareCheckout('https://squareup.com/pay-invoice/test').host,
      'squareup.com',
    );
    for (final value in [
      'http://squareup.com/pay-invoice/test',
      'https://squareup.com.evil.invalid/pay-invoice/test',
      'javascript:alert(1)',
      'file:///C:/secret',
      'https://squareup.com:444/pay-invoice/test',
    ]) {
      expect(
        () => verifiedSquareCheckout(value),
        throwsA(isA<BillingTransportException>()),
      );
    }
  });
  test(
    'controller asks only the authenticated account endpoint, no customer selector',
    () async {
      final gateway = FakeBilling();
      final c = HouseholdBillingController(gateway: gateway);
      await c.load();
      expect(gateway.calls, ['/api/device/account']);
      expect(gateway.bodies.single, isEmpty);
      expect(c.snapshot!.name, 'Test Customer');
      c.dispose();
    },
  );
  test(
    'PIN unlock is kept in memory and scoped request headers, not request account IDs',
    () async {
      final gateway = FakeBilling()..locked = true;
      final c = HouseholdBillingController(gateway: gateway);
      await c.load();
      expect(c.snapshot!.locked, isTrue);
      await c.unlock('123456');
      expect(c.snapshot!.locked, isFalse);
      expect(c.canLock, isTrue);
      expect(gateway.receivedSession, List.filled(43, 's').join());
      c.lock();
      expect(c.snapshot!.locked, isTrue);
      expect(c.canLock, isFalse);
      c.dispose();
    },
  );
  test('wrong PIN does not expose account fields', () async {
    final gateway = FakeBilling()..locked = true;
    final c = HouseholdBillingController(gateway: gateway);
    await c.load();
    await c.unlock('654321');
    expect(c.snapshot!.locked, isTrue);
    expect(c.snapshot!.invoices, isEmpty);
    expect(c.error, isNotEmpty);
    c.dispose();
  });
  test(
    'late response is ignored after connection/profile invalidation',
    () async {
      final gateway = FakeBilling()
        ..pending = Completer<Map<String, dynamic>>();
      final c = HouseholdBillingController(gateway: gateway);
      final load = c.load();
      await Future<void>.delayed(Duration.zero);
      gateway.key = 'different-device';
      c.invalidate();
      gateway.pending!.complete(snapshot());
      await load;
      expect(c.snapshot, isNull);
      expect(c.payments, isEmpty);
      c.dispose();
    },
  );
  test('late response is ignored after controller disposal', () async {
    final gateway = FakeBilling()..pending = Completer<Map<String, dynamic>>();
    final c = HouseholdBillingController(gateway: gateway);
    final load = c.load();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    gateway.pending!.complete(snapshot());
    await load;
    expect(c.snapshot, isNull);
  });
  test('payment URL retrieval never marks the invoice paid', () async {
    final gateway = FakeBilling();
    final c = HouseholdBillingController(gateway: gateway);
    await c.load();
    final before = c.snapshot!.invoices.single;
    final uri = await c.paymentLink(before);
    expect(uri!.host, 'squareup.com');
    expect(c.snapshot!.invoices.single.status, 'PARTIALLY_PAID');
    expect(c.snapshot!.invoices.single.remaining, '7500');
    expect(gateway.bodies.last, {'invoiceId': 'INV-A'});
    c.dispose();
  });
  test('server expiry while paying locks and removes displayed data', () async {
    final gateway = FakeBilling()..failingRoute = '/api/device/account/pay';
    final c = HouseholdBillingController(gateway: gateway);
    await c.load();
    await c.paymentLink(c.snapshot!.invoices.single);
    expect(c.snapshot!.locked, isTrue);
    expect(c.snapshot!.invoices, isEmpty);
    c.dispose();
  });
  test('history pages deduplicate records and retain partial flag', () async {
    final gateway = FakeBilling();
    final c = HouseholdBillingController(gateway: gateway);
    await c.load();
    await c.loadPayments();
    expect(c.payments.length, 1);
    expect(c.historyComplete, isFalse);
    expect(c.nextOffset, 10);
    await c.loadPayments();
    expect(c.payments.length, 1);
    expect(c.historyComplete, isTrue);
    expect(c.nextOffset, isNull);
    c.dispose();
  });
  test('HTTPS requirement does not send billing over the LAN origin', () async {
    final gateway = FakeBilling()..httpsRequired = true;
    final c = HouseholdBillingController(gateway: gateway);
    await c.load();
    expect(c.secureRequired, isTrue);
    expect(c.snapshot, isNull);
    await c.useSecureOrigin();
    expect(c.secureRequired, isFalse);
    expect(c.snapshot!.name, 'Test Customer');
    c.dispose();
  });
  testWidgets(
    'PIN session expiry clears visible account data without disk IO',
    (tester) async {
      final gateway = FakeBilling()
        ..locked = true
        ..expirySeconds = 5;
      final c = HouseholdBillingController(gateway: gateway);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.load();
      await c.unlock('123456');
      expect(c.snapshot!.locked, isFalse);
      await tester.pump(const Duration(seconds: 6));
      expect(c.snapshot!.locked, isTrue);
      expect(c.snapshot!.invoices, isEmpty);
      c.dispose();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
  testWidgets(
    'Account shows linked customer, balances, invoices, payments and project groups',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = HouseholdBillingController(gateway: FakeBilling());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CustomerAccountPanel(
                profileId: 1,
                controller: c,
                checkout: FakeCheckout(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Test Customer'), findsOneWidget);
      expect(find.text('Due: USD 75.00'), findsOneWidget);
      expect(find.text('Pay invoice on Square'), findsOneWidget);
      expect(find.text('Open projects'), findsOneWidget);
      expect(find.text('Closed projects'), findsOneWidget);
      expect(find.text('Open Project'), findsOneWidget);
      expect(find.text('Closed Project'), findsOneWidget);
      expect(find.textContaining('ADMIN SECRET'), findsNothing);
      expect(find.textContaining('PRIVATE SQUARE NOTE'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
  testWidgets(
    'unlinked account does not expose a customer picker or fake balances',
    (tester) async {
      final gateway = FakeBilling()
        ..pending = Completer<Map<String, dynamic>>();
      final c = HouseholdBillingController(gateway: gateway);
      gateway.pending!.complete({'linked': false});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CustomerAccountPanel(
                profileId: 1,
                controller: c,
                checkout: FakeCheckout(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('has not been linked'), findsOneWidget);
      expect(find.text('Pay invoice on Square'), findsNothing);
      expect(find.byType(DropdownButton), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
