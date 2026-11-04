import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/household_billing.dart';
import '../services/billing_models.dart';
import '../services/billing_checkout.dart';
import '../services/device_connection.dart';

class CustomerAccountPanel extends StatefulWidget {
  final int profileId;
  final HouseholdBillingController? controller;
  final BillingCheckout? checkout;
  const CustomerAccountPanel({
    super.key,
    required this.profileId,
    this.controller,
    this.checkout,
  });
  @override
  State<CustomerAccountPanel> createState() => _CustomerAccountPanelState();
}

class _CustomerAccountPanelState extends State<CustomerAccountPanel>
    with WidgetsBindingObserver {
  late HouseholdBillingController account;
  late BillingCheckout checkout;
  late bool owns;
  final pin = TextEditingController();
  bool checkoutPending = false, focusLeft = false, openingPayment = false;
  String checkoutMessage = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  void _attach() {
    owns = widget.controller == null;
    account = widget.controller ?? HouseholdBillingController();
    checkout = widget.checkout ?? SystemBillingCheckout();
    account.addListener(_changed);
    if (owns) {
      DeviceConnection.instance.status.addListener(_connectionChanged);
    }
    unawaited(_load());
  }

  void _detach() {
    account.removeListener(_changed);
    if (owns) {
      DeviceConnection.instance.status.removeListener(_connectionChanged);
      account.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant CustomerAccountPanel old) {
    super.didUpdateWidget(old);
    if (old.profileId != widget.profileId ||
        old.controller != widget.controller) {
      pin.clear();
      account.invalidate('Profile changed. Account data cleared.');
      _detach();
      _attach();
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  void _connectionChanged() {
    if (account.connectionKey.isNotEmpty &&
        (account.gateway.key != account.connectionKey ||
            !account.gateway.available)) {
      account.invalidate();
      pin.clear();
    }
  }

  Future<void> _load() async {
    await account.load();
    if (!mounted) {
      return;
    }
    final data = account.snapshot;
    if (data != null &&
        data.linked &&
        !data.locked &&
        data.financialAvailable) {
      await account.loadPayments(reset: true);
    }
  }

  Future<void> _unlock() async {
    final value = pin.text;
    pin.clear();
    await account.unlock(value);
    if (mounted &&
        account.snapshot?.financialAvailable == true &&
        !account.snapshot!.locked) {
      await account.loadPayments(reset: true);
    }
  }

  Future<void> _secure() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use secure Millitop connection?'),
        content: const Text(
          'This keeps the existing device ID, household and pairing credential, and verifies it at https://tvadmin.millitop.net before saving. It does not enroll a new device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verify and use HTTPS'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await account.useSecureOrigin();
    }
  }

  Future<void> _pay(AccountInvoice invoice) async {
    if (openingPayment) {
      return;
    }
    setState(() => openingPayment = true);
    try {
      final uri = await account.paymentLink(invoice);
      if (uri == null || !mounted) {
        return;
      }
      checkoutPending = true;
      focusLeft = false;
      final opened = await checkout.open(uri);
      if (!mounted) {
        return;
      }
      if (!opened) {
        checkoutPending = false;
        setState(
          () => checkoutMessage =
              'Windows could not open the Square payment page. Check your default browser.',
        );
      } else {
        setState(
          () => checkoutMessage =
              'Square payment page opened in your system browser. Complete payment there, then return and Refresh. The window closing does not itself confirm payment.',
        );
      }
    } catch (_) {
      if (mounted) {
        checkoutPending = false;
        setState(
          () => checkoutMessage =
              'The Square page could not be opened. No payment was marked successful.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => openingPayment = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!checkoutPending) {
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      focusLeft = true;
    }
    if (state == AppLifecycleState.resumed && focusLeft) {
      unawaited(_return());
    }
  }

  Future<void> _return() async {
    checkoutPending = false;
    focusLeft = false;
    try {
      await checkout.restore();
    } catch (_) {}
    if (mounted) {
      await _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pin.dispose();
    _detach();
    unawaited(checkout.restore().catchError((Object _) {}));
    super.dispose();
  }

  String _date(String raw) {
    final value = DateTime.tryParse(raw);
    if (value == null) {
      return raw.isEmpty ? 'Not supplied' : raw;
    }
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
    ),
  );
  Widget _project(AccountProject project) => Card(
    child: ExpansionTile(
      title: Text(project.title),
      subtitle: Text(project.status.replaceAll('_', ' ')),
      childrenPadding: const EdgeInsets.all(16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (project.description.isNotEmpty) Text(project.description),
        Text('Updated: ${_date(project.updatedAt)}'),
        if (project.updates.isEmpty)
          const Text('No customer-visible progress updates yet.'),
        for (final update in project.updates)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _date(update.createdAt),
                  style: const TextStyle(color: Colors.white60),
                ),
                Text(update.body),
              ],
            ),
          ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final data = account.snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your account',
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('billing-refresh'),
              onPressed: account.busy || openingPayment ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh account'),
            ),
            if (account.canLock &&
                data?.linked == true &&
                data?.locked == false)
              TextButton(
                onPressed: account.busy ? null : account.lock,
                child: const Text('Lock account view'),
              ),
            if (checkoutPending)
              TextButton(
                onPressed: account.busy ? null : _return,
                child: const Text('Return / refresh after payment'),
              ),
          ],
        ),
        if (account.busy || openingPayment)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        if (account.message.isNotEmpty)
          Text(account.message, style: const TextStyle(color: Colors.white70)),
        if (account.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              account.error,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          ),
        if (account.error.isNotEmpty && data?.financialAvailable == true)
          const Text(
            'Previously retrieved information below may be out of date. Payment availability is rechecked before opening Square.',
            style: TextStyle(color: Colors.orangeAccent),
          ),
        if (account.secureRequired)
          FilledButton(
            onPressed: account.busy ? null : _secure,
            child: const Text('Use secure billing connection'),
          ),
        if (checkoutMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(checkoutMessage),
          ),
        if (data != null && !data.linked)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'Your household has not been linked to a Square customer. Contact your support team. No customer selector is exposed on this device.',
            ),
          ),
        if (data?.locked == true) ...[
          _section('Unlock Account'),
          const Text(
            'Enter the account PIN set by your support team. This unlock is temporary and is not saved to disk.',
          ),
          SizedBox(
            width: 320,
            child: TextField(
              key: const ValueKey('billing-pin'),
              controller: pin,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              keyboardType: TextInputType.number,
              maxLength: 12,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Account PIN'),
              onSubmitted: account.busy ? null : (_) => _unlock(),
            ),
          ),
          FilledButton(
            onPressed: account.busy ? null : _unlock,
            child: const Text('Unlock Account'),
          ),
        ],
        if (data != null && data.linked && !data.locked) ...[
          if (data.householdName.isNotEmpty) _section(data.householdName),
          if (data.financialAvailable) ...[
            _section('Customer information'),
            Text(data.name, style: const TextStyle(fontSize: 23)),
            if (data.email.isNotEmpty) Text(data.email),
            if (data.phone.isNotEmpty) Text(data.phone),
            if (data.address.isNotEmpty) Text(data.address.values.join('\n')),
            Text(
              'Square data checked: ${_date(data.checkedAt)}',
              style: const TextStyle(color: Colors.white60),
            ),
            _section('Payments due'),
            if (data.balances == null)
              const Text(
                'A complete total is unavailable. Listed invoices may be only part of the account; no zero balance is assumed.',
              ),
            if (data.balances != null && data.balances!.isEmpty)
              const Text(
                'No published invoices with outstanding amounts were returned.',
              ),
            for (final balance in data.balances ?? <AccountBalance>[])
              Card(
                child: ListTile(
                  title: Text(
                    'Due: ${formatBillingMoney(balance.currency, balance.due)}',
                  ),
                  subtitle: Text(
                    'Payment processing: ${formatBillingMoney(balance.currency, balance.pending)}',
                  ),
                ),
              ),
            _section('Invoices'),
            if (data.invoices.isEmpty)
              const Text('No published customer invoices returned.'),
            for (final invoice in data.invoices)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${invoice.number.isEmpty ? invoice.id : invoice.number} · ${invoice.title}',
                        style: const TextStyle(fontSize: 22),
                      ),
                      Text(invoice.status.replaceAll('_', ' ')),
                      Text(
                        'Total: ${formatBillingMoney(invoice.currency, invoice.total)}',
                      ),
                      Text(
                        'Completed payments: ${formatBillingMoney(invoice.currency, invoice.paid)}',
                      ),
                      Text(
                        'Remaining: ${formatBillingMoney(invoice.currency, invoice.remaining)}',
                      ),
                      if (invoice.dueDate != null)
                        Text('Next outstanding due date: ${invoice.dueDate}'),
                      if (invoice.description.isNotEmpty)
                        Text(invoice.description),
                      if (invoice.canPay)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: FilledButton.icon(
                            onPressed: account.busy || openingPayment
                                ? null
                                : () => _pay(invoice),
                            icon: const Icon(Icons.open_in_browser),
                            label: const Text('Pay invoice on Square'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            _section('Past payments'),
            const Text(
              'Invoice-linked payments only. No seller bank/payout data or unrelated payer/card details are shown.',
            ),
            if (account.historyLoaded && account.payments.isEmpty)
              const Text(
                'No verifiable payments returned for this history batch.',
              ),
            for (final payment in account.payments)
              Card(
                child: ListTile(
                  title: Text(
                    formatBillingMoney(payment.currency, payment.amount),
                  ),
                  subtitle: Text(
                    'Invoice ${payment.invoiceId}\n${payment.status} · ${_date(payment.createdAt)}${payment.refunded == null ? '' : '\nRefunded: ${formatBillingMoney(payment.currency, payment.refunded!)}'}',
                  ),
                ),
              ),
            if (account.historyLoaded && !account.historyComplete)
              const Text(
                'History is partial or some tender records could not be verified. No missing payment is inferred.',
              ),
            if (!account.historyLoaded || account.nextOffset != null)
              OutlinedButton(
                onPressed: account.busy ? null : () => account.loadPayments(),
                child: Text(
                  account.historyLoaded
                      ? 'Load more payment history'
                      : 'Load payment history',
                ),
              ),
          ] else ...[
            _section('Billing information unavailable'),
            Text(
              data.error.isEmpty
                  ? 'Square data could not be verified. No balance or payment status is inferred.'
                  : data.error,
            ),
          ],
          _section('Open projects'),
          if (!data.projects.any((p) => !p.closed))
            const Text('No open projects for this account.'),
          for (final project in data.projects.where((p) => !p.closed))
            _project(project),
          _section('Closed projects'),
          if (!data.projects.any((p) => p.closed))
            const Text('No closed projects for this account.'),
          for (final project in data.projects.where((p) => p.closed))
            _project(project),
          const SizedBox(height: 20),
          const Text(
            'Payments are handled on Square’s hosted page. Project status and invoice payment status are separate. Contact support for account or project corrections.',
          ),
        ],
      ],
    );
  }
}
