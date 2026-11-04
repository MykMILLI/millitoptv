class BillingTransportException implements Exception {
  final int status;
  final String code, message;
  const BillingTransportException(this.status, this.code, this.message);
  @override
  String toString() => message;
}
