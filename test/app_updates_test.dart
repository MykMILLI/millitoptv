import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/app_updates.dart';

void main() {
  test('accepts newer semantic version', () {
    expect(newerRelease('1.2.1', 1, '1.2.0', 7), isTrue);
  });
  test('accepts newer build for same version', () {
    expect(newerRelease('1.2.0', 8, '1.2.0', 7), isTrue);
  });
  test('rejects identical installed release', () {
    expect(newerRelease('1.2.0', 7, '1.2.0', 7), isFalse);
  });
  test('rejects semantic downgrade even with higher build', () {
    expect(newerRelease('1.1.9', 999, '1.2.0', 7), isFalse);
  });
  test('rejects malformed release version', () {
    expect(newerRelease('latest', 8, '1.2.0', 7), isFalse);
  });
  test('compares version numbers numerically', () {
    expect(newerRelease('1.10.0', 1, '1.9.0', 99), isTrue);
  });
}
