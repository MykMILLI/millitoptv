import 'billing_transport.dart';

String _text(dynamic value, {int max = 20000}) {
  if (value == null) {
    return '';
  }
  if (value is! String || value.length > max) {
    throw const FormatException('Unsupported account text.');
  }
  return value;
}

String _id(dynamic value) {
  final id = _text(value, max: 192);
  if (id.isEmpty) {
    throw const FormatException('Missing account identifier.');
  }
  return id;
}

String minorAmount(dynamic value) {
  if (value is! String || !RegExp(r'^-?\d{1,30}$').hasMatch(value)) {
    throw const FormatException('Invalid money value.');
  }
  return value;
}

String currencyCode(dynamic value) {
  if (value is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(value)) {
    throw const FormatException('Invalid currency.');
  }
  return value;
}

String formatBillingMoney(String currency, String amount) {
  currencyCode(currency);
  minorAmount(amount);
  const zero = {
    'BIF',
    'CLP',
    'DJF',
    'GNF',
    'ISK',
    'JPY',
    'KMF',
    'KRW',
    'PYG',
    'RWF',
    'UGX',
    'UYI',
    'VND',
    'VUV',
    'XAF',
    'XOF',
    'XPF',
  };
  const three = {'BHD', 'IQD', 'JOD', 'KWD', 'LYD', 'OMR', 'TND'};
  final digits = zero.contains(currency)
      ? 0
      : three.contains(currency)
      ? 3
      : const {'CLF', 'UYW'}.contains(currency)
      ? 4
      : 2;
  final number = BigInt.parse(amount);
  final negative = number.isNegative;
  final absolute = number.abs();
  final scale = BigInt.from(10).pow(digits), whole = absolute ~/ scale;
  final fraction = digits == 0
      ? ''
      : '.${(absolute % scale).toString().padLeft(digits, '0')}';
  return '${negative ? '-' : ''}$currency $whole$fraction';
}

class AccountInvoice {
  final String id,
      number,
      title,
      description,
      status,
      currency,
      total,
      paid,
      remaining;
  final String? dueDate;
  final bool canPay;
  const AccountInvoice({
    required this.id,
    required this.number,
    required this.title,
    required this.description,
    required this.status,
    required this.currency,
    required this.total,
    required this.paid,
    required this.remaining,
    required this.canPay,
    this.dueDate,
  });
  factory AccountInvoice.fromJson(Map<String, dynamic> data) => AccountInvoice(
    id: _id(data['id']),
    number: _text(data['number'], max: 192),
    title: _text(data['title']),
    description: _text(data['description']),
    status: _text(data['status'], max: 80),
    currency: currencyCode(data['currency']),
    total: minorAmount(data['totalMinor']),
    paid: minorAmount(data['completedMinor']),
    remaining: minorAmount(data['remainingMinor']),
    canPay: data['canPay'] == true,
    dueDate: data['dueDate'] as String?,
  );
}

class AccountBalance {
  final String currency, due, pending;
  const AccountBalance(this.currency, this.due, this.pending);
  factory AccountBalance.fromJson(Map<String, dynamic> data) => AccountBalance(
    currencyCode(data['currency']),
    minorAmount(data['dueMinor']),
    minorAmount(data['pendingMinor']),
  );
}

class ProjectProgress {
  final String body, createdAt;
  const ProjectProgress(this.body, this.createdAt);
  factory ProjectProgress.fromJson(Map<String, dynamic> data) =>
      ProjectProgress(_text(data['body']), _text(data['createdAt'], max: 80));
}

class AccountProject {
  final String id, title, description, status, updatedAt;
  final List<ProjectProgress> updates;
  const AccountProject({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.updatedAt,
    this.updates = const [],
  });
  bool get closed => status == 'completed' || status == 'cancelled';
  factory AccountProject.fromJson(Map<String, dynamic> data) {
    final status = _text(data['status'], max: 80);
    if (!const {
      'planned',
      'in_progress',
      'waiting_customer',
      'on_hold',
      'completed',
      'cancelled',
    }.contains(status)) {
      throw const FormatException('Unsupported project status.');
    }
    return AccountProject(
      id: _id(data['id']),
      title: _text(data['title']),
      description: _text(data['description']),
      status: status,
      updatedAt: _text(data['updatedAt'], max: 80),
      updates: ((data['updates'] as List?) ?? [])
          .map(
            (v) =>
                ProjectProgress.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList(),
    );
  }
}

class AccountSnapshot {
  final bool linked, locked, financialAvailable, complete;
  final String accountId, householdName, name, email, phone, error, checkedAt;
  final Map<String, String> address;
  final List<AccountInvoice> invoices;
  final List<AccountBalance>? balances;
  final List<AccountProject> projects;
  const AccountSnapshot({
    required this.linked,
    required this.locked,
    this.financialAvailable = false,
    this.complete = false,
    this.accountId = '',
    this.householdName = '',
    this.name = '',
    this.email = '',
    this.phone = '',
    this.error = '',
    this.checkedAt = '',
    this.address = const {},
    this.invoices = const [],
    this.balances,
    this.projects = const [],
  });
  factory AccountSnapshot.fromJson(Map<String, dynamic> data) {
    if (data['linked'] is! bool) {
      throw const FormatException('Unsupported account response.');
    }
    if (data['linked'] == false) {
      return const AccountSnapshot(linked: false, locked: false);
    }
    if (data['locked'] == true) {
      return const AccountSnapshot(linked: true, locked: true);
    }
    final financial = Map<String, dynamic>.from(data['financial'] as Map);
    final available = financial['available'] == true;
    final customer = available
        ? Map<String, dynamic>.from(financial['customer'] as Map)
        : <String, dynamic>{};
    final rows = (financial['invoices'] as List?) ?? [];
    final projects = (data['projects'] as List?) ?? [];
    if (rows.length > 2000 || projects.length > 200) {
      throw const FormatException('Account response exceeded expected limits.');
    }
    final invoices = rows
        .map(
          (v) => AccountInvoice.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .toList();
    if (invoices.map((i) => i.id).toSet().length != invoices.length) {
      throw const FormatException(
        'Duplicate invoice records. No total was trusted.',
      );
    }
    final address = <String, String>{};
    if (customer['address'] is Map) {
      for (final key in [
        'line1',
        'line2',
        'city',
        'region',
        'postalCode',
        'country',
      ]) {
        final value = _text((customer['address'] as Map)[key], max: 500);
        if (value.isNotEmpty) {
          address[key] = value;
        }
      }
    }
    final complete = available && financial['complete'] == true;
    return AccountSnapshot(
      linked: true,
      locked: false,
      accountId: _id(data['accountId']),
      householdName: _text(data['householdName'], max: 500),
      financialAvailable: available,
      complete: complete,
      name: _text(customer['name'], max: 500),
      email: _text(customer['email'], max: 500),
      phone: _text(customer['phone'], max: 100),
      address: Map.unmodifiable(address),
      error: _text(financial['error'], max: 1000),
      checkedAt: _text(financial['checkedAt'], max: 100),
      invoices: List.unmodifiable(invoices),
      balances: complete && financial['balances'] is List
          ? (financial['balances'] as List)
                .map(
                  (v) => AccountBalance.fromJson(
                    Map<String, dynamic>.from(v as Map),
                  ),
                )
                .toList()
          : null,
      projects: projects
          .map(
            (v) => AccountProject.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList(),
    );
  }
}

class AccountPayment {
  final String id, invoiceId, status, createdAt, currency, amount;
  final String? refunded;
  const AccountPayment({
    required this.id,
    required this.invoiceId,
    required this.status,
    required this.createdAt,
    required this.currency,
    required this.amount,
    this.refunded,
  });
  factory AccountPayment.fromJson(Map<String, dynamic> data) {
    final amount = Map<String, dynamic>.from(data['amount'] as Map);
    final refund = data['refunded'];
    if (refund is Map && refund['currency'] != amount['currency']) {
      throw const FormatException('Mixed payment refund currencies.');
    }
    return AccountPayment(
      id: _id(data['id']),
      invoiceId: _id(data['invoiceId']),
      status: _text(data['status'], max: 80),
      createdAt: _text(data['createdAt'], max: 100),
      currency: currencyCode(amount['currency']),
      amount: minorAmount(amount['amountMinor']),
      refunded: refund is Map ? minorAmount(refund['amountMinor']) : null,
    );
  }
}

Uri verifiedSquareCheckout(dynamic value) {
  if (value is! String || value.length > 4096) {
    throw const BillingTransportException(
      0,
      'checkout',
      'Square checkout URL was not returned.',
    );
  }
  final uri = Uri.tryParse(value);
  final host = uri?.host.toLowerCase() ?? '';
  final allowed =
      host == 'squareup.com' ||
      host.endsWith('.squareup.com') ||
      host == 'squareupsandbox.com' ||
      host.endsWith('.squareupsandbox.com');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      !allowed ||
      !uri.path.startsWith('/pay-invoice/')) {
    throw const BillingTransportException(
      0,
      'checkout',
      'The payment URL is not a verified Square invoice page.',
    );
  }
  return uri;
}
