import 'dart:io';

String validateAppUrl(String value) {
  final text = value.trim();
  if (text.isEmpty ||
      text.length > 2048 ||
      RegExp(r'[\x00-\x20\x7f"\\]').hasMatch(text)) {
    throw const FormatException(
      'Enter a full HTTPS URL, or HTTP for a local network service.',
    );
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Invalid URL or embedded credentials.');
  }
  final host = uri.host
      .toLowerCase()
      .replaceFirst(RegExp(r'^\['), '')
      .replaceFirst(RegExp(r'\]$'), '');
  final ip = InternetAddress.tryParse(host);
  var local =
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.lan');
  if (ip?.type == InternetAddressType.IPv4) {
    final bytes = ip!.rawAddress;
    local =
        bytes[0] == 10 ||
        bytes[0] == 127 ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31);
  } else if (ip?.type == InternetAddressType.IPv6) {
    final bytes = ip!.rawAddress;
    local =
        ip.isLoopback ||
        (bytes[0] & 254) == 252 ||
        (bytes[0] == 254 && (bytes[1] & 192) == 128);
  }
  if (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) {
    throw const FormatException(
      'Only HTTPS, or HTTP for local network hosts, is permitted.',
    );
  }
  final secret = RegExp(
    r'^(access[_-]?token|refresh[_-]?token|token|password|passwd|api[_-]?key|secret|authorization)$',
    caseSensitive: false,
  );
  if (uri.queryParameters.keys.any(secret.hasMatch) ||
      RegExp(
        r'(?:^|[&#?])(access_token|refresh_token|password|token)=',
        caseSensitive: false,
      ).hasMatch(uri.fragment)) {
    throw const FormatException(
      'Do not save passwords or access tokens in URLs. Sign in through Firefox.',
    );
  }
  return uri.toString();
}

class WebAppDefinition {
  final String id, title, url, icon;
  final bool enabled, managed;
  final int revision;
  const WebAppDefinition({
    required this.id,
    required this.title,
    required this.url,
    this.icon = 'web',
    this.enabled = true,
    this.managed = false,
    this.revision = 1,
  });
  bool get builtin => id == 'emby' || id == 'jellyfin';
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'icon': icon,
    'enabled': enabled,
    'revision': revision,
  };
  factory WebAppDefinition.fromJson(
    Map<String, dynamic> json, {
    bool managed = false,
  }) {
    final raw = json['id'] as String;
    final id = managed ? 'managed:$raw' : raw;
    final valid = managed
        ? RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(raw)
        : raw == 'emby' ||
              raw == 'jellyfin' ||
              RegExp(r'^local:[0-9a-fA-F-]{36}$').hasMatch(raw);
    final title = (json['title'] as String).trim();
    final icon = json['icon'] as String;
    if (!valid ||
        title.isEmpty ||
        title.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(title) ||
        !const {'web', 'emby', 'jellyfin'}.contains(icon) ||
        (!managed && json['enabled'] is! bool) ||
        (json['revision'] != null &&
            ((json['revision'] is! int) || (json['revision'] as int) < 1))) {
      throw const FormatException('Invalid web-app definition.');
    }
    return WebAppDefinition(
      id: id,
      title: title,
      url: validateAppUrl(json['url'] as String),
      icon: icon,
      enabled: managed ? true : json['enabled'] == true,
      managed: managed,
      revision: (json['revision'] as int?) ?? 1,
    );
  }
}

const builtinWebApps = [
  WebAppDefinition(
    id: 'emby',
    title: 'Emby',
    url: 'https://watch.millitop.net',
    icon: 'emby',
  ),
];
