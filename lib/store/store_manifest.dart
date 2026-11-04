import 'package:yaml/yaml.dart';
import 'store_catalog.dart';

class StorePackage {
  final String hash;
  final String kind;
  final String version;
  const StorePackage(this.hash, this.kind, this.version);
}

StorePackage parseStoreManifest(String content, StoreApp app) {
  final document = loadYaml(content);
  if (document is! Map || document['PackageIdentifier'] != app.packageId) {
    throw const FormatException('Downloaded manifest does not match this app.');
  }
  final version = document['PackageVersion']?.toString() ?? '';
  if (version.isEmpty) {
    throw const FormatException('Package version is missing.');
  }
  final rows = document['Installers'];
  final candidates = <Map>[];
  for (final row in rows is List ? rows : [document]) {
    if (row is! Map) continue;
    final merged = <dynamic, dynamic>{...document, ...row};
    if (merged['Architecture'] != 'x64') continue;
    // Scope must be explicit; never elevate a user-scoped package by guessing.
    if (merged['Scope'] != app.scope) continue;
    final kind = merged['InstallerType']?.toString().toLowerCase();
    final approved = app.key == 'vlc'
        ? ['msi', 'wix'].contains(kind)
        : kind == 'nullsoft';
    if (!approved) continue;
    final hash = merged['InstallerSha256']?.toString().toLowerCase() ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) continue;
    final url = Uri.tryParse(merged['InstallerUrl']?.toString() ?? '');
    if (url == null || url.scheme != 'https' || url.userInfo.isNotEmpty) {
      continue;
    }
    // Curated packages here have no additional install-time dependency graph.
    if (merged['Dependencies'] != null) {
      throw const FormatException(
        'This package now declares dependencies. Administrator review is required.',
      );
    }
    candidates.add(merged);
  }
  if (candidates.length != 1) {
    throw const FormatException(
      'A unique approved x64 installer could not be selected. Administrator review is required.',
    );
  }
  final chosen = candidates.single;
  return StorePackage(
    chosen['InstallerSha256'].toString().toLowerCase(),
    app.key == 'vlc' ? 'msi' : 'nsis',
    version,
  );
}
