import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/update_launch.dart';

String decodeCommand(String encoded) {
  final bytes = base64Decode(encoded);
  return String.fromCharCodes([
    for (int i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ]);
}

void main() {
  test('encodes Windows bootstrap command as UTF16LE', () {
    final command = decodeCommand(
      updateBootstrapCommand(
        r'C:\Program Files\bootstrap.ps1',
        r'C:\User Data\request.json',
      ),
    );
    expect(
      command,
      r"& 'C:\Program Files\bootstrap.ps1' -RequestPath 'C:\User Data\request.json'",
    );
  });
  test('escapes apostrophes in user paths', () {
    final command = decodeCommand(
      updateBootstrapCommand("C:\\O'Neil\\bootstrap.ps1", r'C:\request.json'),
    );
    expect(command, contains("O''Neil"));
  });
  test('preserves non-ASCII Windows paths', () {
    final command = decodeCommand(
      updateBootstrapCommand('C:\\Müller\\bootstrap.ps1', r'C:\request.json'),
    );
    expect(command, contains('Müller'));
  });
}
