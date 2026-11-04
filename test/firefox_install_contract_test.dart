import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Firefox provisioning uses supported installation and keeps signature/readiness checks',
    () async {
      final text = await File(
        'assets/native/firefox_provision.ps1',
      ).readAsString();
      expect(text, contains('FIREFOX_STANDARD_INSTALL_V1'));
      for (final option in [
        '/S',
        '/InstallDirectoryPath=',
        '/DesktopShortcut=false',
        '/StartMenuShortcut=false',
        '/TaskbarShortcut=false',
        '/PrivateBrowsingShortcut=false',
        '/MaintenanceService=false',
        '/RegisterDefaultAgent=false',
      ]) {
        expect(text, contains(option));
      }
      expect(text, contains('Diagnostics.ProcessStartInfo'));
      expect(text, contains('WaitForExit(240000)'));
      expect(text, contains(r'if($installCode -ne 0)'));
      expect(text, contains(r'Mozilla-Signed $installer'));
      expect(text, contains(r'Mozilla-Signed $exe'));
      expect(text, contains('Active-Extensions'));
      expect(text, contains("installation_mode='force_installed'"));
      expect(text, contains(r"if($purpose -eq 'payments')"));
      expect(text, contains("installation_mode='blocked'"));
      expect(text, contains('user-approved first-use action'));
      expect(text, isNot(contains("/ExtractDir=\"")));
    },
  );
}
