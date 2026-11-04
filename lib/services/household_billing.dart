import 'dart:async';
import 'package:flutter/foundation.dart';
import 'device_connection.dart';
import 'billing_transport.dart';
import 'billing_models.dart';

abstract class HouseholdBillingGateway {
  String get key;
  bool get available;
  Future<void> initialize();
  Future<Map<String, dynamic>> post(
    String route,
    Map<String, dynamic> body, {
    String? session,
  });
  Future<void> secureOrigin();
}

class DeviceBillingGateway implements HouseholdBillingGateway {
  final link = DeviceConnection.instance;
  @override
  Future<void> initialize() => link.start();
  @override
  String get key => link.connectionKey;
  @override
  bool get available => link.isEnrolled && !link.isSuspended;
  @override
  Future<Map<String, dynamic>> post(
    String route,
    Map<String, dynamic> body, {
    String? session,
  }) async {
    await link.start();
    return link.postBilling(
      route,
      body,
      expectedConnection: link.connectionKey,
      session: session,
    );
  }

  @override
  Future<void> secureOrigin() => link.useSecureBillingOrigin();
}

class HouseholdBillingController extends ChangeNotifier {
  final HouseholdBillingGateway gateway;
  AccountSnapshot? snapshot;
  final List<AccountPayment> payments = [];
  bool busy = false,
      historyLoaded = false,
      historyComplete = false,
      secureRequired = false;
  int? nextOffset = 0;
  String error = '', message = '';
  String? _session;
  Timer? _expiry;
  int _generation = 0;
  bool _disposed = false;
  String _connection = '';
  HouseholdBillingController({HouseholdBillingGateway? gateway})
    : gateway = gateway ?? DeviceBillingGateway();
  String get connectionKey => _connection;
  bool get canLock => _session != null;
  void _emit() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool _current(int token, String key) =>
      !_disposed &&
      token == _generation &&
      gateway.key == key &&
      gateway.available;
  void invalidate([
    String reason = 'Account connection changed. Check again.',
  ]) {
    _generation++;
    _expiry?.cancel();
    _session = null;
    snapshot = null;
    payments.clear();
    nextOffset = 0;
    historyLoaded = false;
    historyComplete = false;
    busy = false;
    error = reason;
    secureRequired = false;
    _connection = gateway.key;
    _emit();
  }

  void lock() {
    _generation++;
    _expiry?.cancel();
    _session = null;
    payments.clear();
    nextOffset = 0;
    historyLoaded = false;
    historyComplete = false;
    busy = false;
    snapshot = const AccountSnapshot(linked: true, locked: true);
    message = 'Account locked. Enter the account PIN to continue.';
    error = '';
    _emit();
  }

  void _failed(Object failure) {
    if (failure is BillingTransportException) {
      secureRequired = failure.code == 'https_required';
      error = failure.message;
      if (failure.status == 403) {
        _expiry?.cancel();
        _session = null;
        snapshot = const AccountSnapshot(linked: true, locked: true);
        payments.clear();
        nextOffset = 0;
        historyLoaded = false;
        historyComplete = false;
      }
      if (failure.status == 401) {
        _expiry?.cancel();
        _session = null;
        snapshot = null;
        payments.clear();
        nextOffset = 0;
        historyLoaded = false;
        historyComplete = false;
      }
    } else {
      error =
          'Account response could not be verified. No partial balance is shown.';
      snapshot = null;
      payments.clear();
    }
  }

  Future<void> load() async {
    if (_disposed || busy) {
      return;
    }
    final token = ++_generation;
    var expected = gateway.key;
    busy = true;
    error = '';
    message = 'Checking your household account...';
    _emit();
    try {
      await gateway.initialize();
      if (_disposed || token != _generation) {
        return;
      }
      expected = gateway.key;
      _connection = expected;
      if (!gateway.available) {
        throw const BillingTransportException(
          401,
          'connection',
          'Pair this device or restore its connection to view Account.',
        );
      }
      final raw = await gateway.post(
        '/api/device/account',
        {},
        session: _session,
      );
      if (!_current(token, expected)) {
        return;
      }
      final data = AccountSnapshot.fromJson(raw);
      if (!data.linked ||
          data.locked ||
          (snapshot != null &&
              snapshot!.accountId.isNotEmpty &&
              snapshot!.accountId != data.accountId)) {
        _expiry?.cancel();
        _session = null;
      }
      snapshot = data;
      payments.clear();
      nextOffset = 0;
      historyLoaded = false;
      historyComplete = false;
      secureRequired = false;
      message = !data.linked
          ? 'Your household has no linked billing account. Contact support.'
          : data.locked
          ? 'Enter your account PIN.'
          : 'Account information refreshed from the server.';
    } catch (e) {
      if (!_disposed && token == _generation) {
        _failed(e);
      }
    } finally {
      if (!_disposed && token == _generation) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> unlock(String pin) async {
    if (_disposed || busy) {
      return;
    }
    final token = ++_generation;
    final expected = gateway.key;
    busy = true;
    error = '';
    _emit();
    var success = false;
    try {
      final raw = await gateway.post('/api/device/account/unlock', {
        'pin': pin,
      });
      if (!_current(token, expected)) {
        return;
      }
      if (raw['unlocked'] != true) {
        throw const FormatException('Unlock not confirmed.');
      }
      final value = raw['token'];
      if (value != null &&
          (value is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value))) {
        throw const FormatException('Invalid unlock session.');
      }
      _session = value as String?;
      _expiry?.cancel();
      if (_session != null) {
        final seconds = raw['expiresInSeconds'];
        if (seconds is! int || seconds < 1 || seconds > 900) {
          throw const FormatException('Invalid session expiry.');
        }
        _expiry = Timer(Duration(seconds: seconds), lock);
      }
      success = true;
    } catch (e) {
      if (!_disposed && token == _generation) {
        _failed(e);
      }
    } finally {
      if (!_disposed && token == _generation) {
        busy = false;
        _emit();
      }
    }
    if (success && !_disposed) {
      await load();
    }
  }

  Future<void> loadPayments({bool reset = false}) async {
    if (_disposed ||
        busy ||
        snapshot == null ||
        snapshot!.locked ||
        !snapshot!.linked) {
      return;
    }
    if (!reset && historyLoaded && nextOffset == null) {
      return;
    }
    final token = ++_generation, expected = gateway.key;
    busy = true;
    error = '';
    _emit();
    try {
      final offset = reset ? 0 : nextOffset ?? 0;
      final raw = await gateway.post('/api/device/account/payments', {
        'offset': offset,
      }, session: _session);
      if (!_current(token, expected)) {
        return;
      }
      final rows = raw['payments'];
      if (rows is! List || rows.length > 1000) {
        throw const FormatException('Invalid payment history.');
      }
      final next = raw['nextOffset'];
      if (next != null && (next is! int || next <= offset || next > 1000)) {
        throw const FormatException('Invalid history page.');
      }
      final values = rows
          .map(
            (v) => AccountPayment.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
      final merged = <String, AccountPayment>{
        if (!reset)
          for (final p in payments) p.id: p,
        for (final p in values) p.id: p,
      };
      payments
        ..clear()
        ..addAll(merged.values);
      nextOffset = next as int?;
      historyLoaded = true;
      historyComplete = raw['complete'] == true;
      message =
          'Invoice-linked payment history retrieved. Closing a payment page does not itself confirm payment.';
    } catch (e) {
      if (!_disposed && token == _generation) {
        _failed(e);
      }
    } finally {
      if (!_disposed && token == _generation) {
        busy = false;
        _emit();
      }
    }
  }

  Future<Uri?> paymentLink(AccountInvoice invoice) async {
    if (_disposed || busy || !invoice.canPay) {
      return null;
    }
    final token = ++_generation, expected = gateway.key;
    busy = true;
    error = '';
    _emit();
    try {
      final raw = await gateway.post('/api/device/account/pay', {
        'invoiceId': invoice.id,
      }, session: _session);
      if (!_current(token, expected)) {
        return null;
      }
      if (raw['invoiceId'] != invoice.id) {
        throw const FormatException('Invoice changed.');
      }
      return verifiedSquareCheckout(raw['url']);
    } catch (e) {
      if (!_disposed && token == _generation) {
        _failed(e);
      }
      return null;
    } finally {
      if (!_disposed && token == _generation) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> useSecureOrigin() async {
    if (_disposed || busy) {
      return;
    }
    busy = true;
    error = '';
    _emit();
    try {
      await gateway.secureOrigin();
      if (_disposed) {
        return;
      }
      invalidate('Secure connection verified. Refreshing Account...');
      await load();
    } catch (e) {
      if (!_disposed) {
        _failed(e);
        busy = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _expiry?.cancel();
    _session = null;
    snapshot = null;
    payments.clear();
    super.dispose();
  }
}
