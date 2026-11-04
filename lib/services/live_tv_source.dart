String validateLiveTvSourceUrl(String value) {
  final text = value.trim();
  final normalized = text.contains('://') ? text : 'https://$text';
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      !uri.isAbsolute ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
    throw const FormatException(
      'Use an HTTP or HTTPS URL without embedded credentials.',
    );
  }
  return uri.toString();
}

class LiveTvSource {
  final String id;
  final String name;
  final String type;
  final String? m3uUrl;
  final String? m3uMoviesUrl;
  final List<String> m3uSeriesUrls;
  final String? serverUrl;
  final String? username;
  final String? password;
  final String? epgUrl;

  const LiveTvSource({
    required this.id,
    required this.name,
    required this.type,
    this.m3uUrl,
    this.m3uMoviesUrl,
    this.m3uSeriesUrls = const [],
    this.serverUrl,
    this.username,
    this.password,
    this.epgUrl,
  });

  bool get isM3u => type == 'm3u';
  bool get isXtream => type == 'xtream';

  LiveTvSource copyWith({
    String? id,
    String? name,
    String? type,
    String? m3uUrl,
    String? m3uMoviesUrl,
    List<String>? m3uSeriesUrls,
    String? serverUrl,
    String? username,
    String? password,
    String? epgUrl,
  }) => LiveTvSource(
    id: id ?? this.id,
    name: name ?? this.name,
    type: type ?? this.type,
    m3uUrl: m3uUrl ?? this.m3uUrl,
    m3uMoviesUrl: m3uMoviesUrl ?? this.m3uMoviesUrl,
    m3uSeriesUrls: m3uSeriesUrls ?? this.m3uSeriesUrls,
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    epgUrl: epgUrl ?? this.epgUrl,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    if (m3uUrl != null) 'm3uUrl': m3uUrl,
    if (m3uMoviesUrl != null) 'm3uMoviesUrl': m3uMoviesUrl,
    if (m3uSeriesUrls.isNotEmpty) 'm3uSeriesUrls': m3uSeriesUrls,
    if (serverUrl != null) 'serverUrl': serverUrl,
    if (username != null) 'username': username,
    if (password != null) 'password': password,
    if (epgUrl != null) 'epgUrl': epgUrl,
  };

  factory LiveTvSource.fromJson(Map<String, dynamic> data) {
    final id = (data['id'] as String?)?.trim() ?? '';
    final name = (data['name'] as String?)?.trim() ?? '';
    final type = (data['type'] as String?)?.trim().toLowerCase() ?? '';
    if (id.isEmpty || name.isEmpty || !const {'m3u', 'xtream'}.contains(type)) {
      throw const FormatException('Invalid Live TV source definition.');
    }

    final m3uUrl = (data['m3uUrl'] as String?)?.trim();
    final m3uMoviesUrl = (data['m3uMoviesUrl'] as String?)?.trim();
    final rawSeries = data['m3uSeriesUrls'];
    final m3uSeriesUrls = <String>[
      if (rawSeries is List)
        ...rawSeries.map((item) => item.toString().trim()).where((item) => item.isNotEmpty),
    ];
    final serverUrl = (data['serverUrl'] as String?)?.trim();
    final username = (data['username'] as String?)?.trim();
    final password = (data['password'] as String?)?.trim();
    final epgUrl = (data['epgUrl'] as String?)?.trim();
    if (epgUrl != null && epgUrl.isNotEmpty) {
      validateLiveTvSourceUrl(epgUrl);
    }
    if (type == 'm3u') {
      if (m3uUrl == null || m3uUrl.isEmpty) {
        throw const FormatException('M3U source requires a playlist URL.');
      }
      validateLiveTvSourceUrl(m3uUrl);
      if (m3uMoviesUrl != null && m3uMoviesUrl.isNotEmpty) {
        validateLiveTvSourceUrl(m3uMoviesUrl);
      }
      for (final seriesUrl in m3uSeriesUrls) {
        validateLiveTvSourceUrl(seriesUrl);
      }
    } else {
      if (serverUrl == null ||
          serverUrl.isEmpty ||
          username == null ||
          username.isEmpty ||
          password == null ||
          password.isEmpty) {
        throw const FormatException(
          'Xtream source requires server URL, username, and password.',
        );
      }
    }
    return LiveTvSource(
      id: id,
      name: name,
      type: type,
      m3uUrl: m3uUrl,
      m3uMoviesUrl: m3uMoviesUrl?.isNotEmpty == true ? m3uMoviesUrl : null,
      m3uSeriesUrls: m3uSeriesUrls,
      serverUrl: serverUrl,
      username: username,
      password: password,
      epgUrl: epgUrl?.isNotEmpty == true ? epgUrl : null,
    );
  }
}
