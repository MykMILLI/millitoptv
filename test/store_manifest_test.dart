import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/store/store_catalog.dart';
import 'package:millitop_tv/store/store_manifest.dart';

void main() {
  String manifest({
    String scope = 'machine',
    String architecture = 'x64',
    String kind = 'msi',
    String id = 'VideoLAN.VLC',
  }) =>
      '''
PackageIdentifier: $id
PackageVersion: 1.2.3
InstallerType: $kind
Installers:
- Architecture: $architecture
  Scope: $scope
  InstallerUrl: https://example.invalid/app.msi
  InstallerSha256: "${'a' * 64}"
''';
  test('accepts curated x64 VLC machine package', () {
    final p = parseStoreManifest(manifest(), nativeStoreApp('vlc'));
    expect(p.kind, 'msi');
    expect(p.hash, 'a' * 64);
  });
  test('rejects wrong package identity', () {
    expect(
      () =>
          parseStoreManifest(manifest(id: 'Other.App'), nativeStoreApp('vlc')),
      throwsFormatException,
    );
  });
  test('rejects wrong scope', () {
    expect(
      () => parseStoreManifest(manifest(scope: 'user'), nativeStoreApp('vlc')),
      throwsFormatException,
    );
  });
  test('rejects unapproved installer type', () {
    expect(
      () => parseStoreManifest(manifest(kind: 'exe'), nativeStoreApp('vlc')),
      throwsFormatException,
    );
  });
  test('rejects wrong architecture', () {
    expect(
      () => parseStoreManifest(
        manifest(architecture: 'arm64'),
        nativeStoreApp('vlc'),
      ),
      throwsFormatException,
    );
  });
  test('rejects unapproved app key', () {
    expect(() => nativeStoreApp('arbitrary'), throwsArgumentError);
  });
}
