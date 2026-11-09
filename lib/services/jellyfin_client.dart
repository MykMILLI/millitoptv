import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'live_tv_playlist.dart';
import 'live_tv_source.dart';

/// Placeholder stream scheme for Jellyfin titles. The real stream URL carries
/// the access token, so it is only built at play time and never written to
/// the catalog cache, watch history or playback memory.
const jellyfinStreamScheme = 'jellyfin';
const jellyfinSourcePrefix = 'jellyfin:';

String jellyfinPlaceholderUrl(String itemId) =>
    '$jellyfinStreamScheme://item/$itemId';

String? jellyfinItemIdFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme != jellyfinStreamScheme || uri.host != 'item') {
    return null;
  }
  final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  return segments.isEmpty ? null : segments.first;
}

bool isJellyfinSourceId(String id) => id.startsWith(jellyfinSourcePrefix);

/// Normalizes what the user typed into a server origin plus optional base
/// path (Jellyfin is often hosted under /jellyfin).
String normalizeJellyfinServerUrl(String value) {
  var text = value.trim();
  if (text.isEmpty) {
    throw const FormatException('Enter your Jellyfin server address.');
  }
  if (!text.contains('://')) {
    text = 'http://$text';
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
    throw const FormatException(
      'Use an address like http://192.168.1.20:8096 or https://jellyfin.example.com',
    );
  }
  var path = uri.path;
  for (final suffix in const ['/web/index.html', '/web/', '/web']) {
    if (path.toLowerCase().endsWith(suffix)) {
      path = path.substring(0, path.length - suffix.length);
    }
  }
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  ).toString();
}

class JellyfinException implements Exception {
  final String message;
  final int? statusCode;
  const JellyfinException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class JellyfinHttpResponse {
  final int statusCode;
  final String body;
  const JellyfinHttpResponse(this.statusCode, this.body);
}

typedef JellyfinTransport =
    Future<JellyfinHttpResponse> Function(
      String method,
      Uri uri,
      Map<String, String> headers,
      String? body,
    );

Future<JellyfinHttpResponse> _defaultTransport(
  String method,
  Uri uri,
  Map<String, String> headers,
  String? body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 15));
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decoder.bind(response).join();
    return JellyfinHttpResponse(response.statusCode, text);
  } finally {
    client.close(force: true);
  }
}

class JellyfinLibrary {
  final String id;
  final String name;
  final String collectionType;
  final String? imageTag;
  const JellyfinLibrary({
    required this.id,
    required this.name,
    required this.collectionType,
    this.imageTag,
  });

  bool get isVideo => const {
    'movies',
    'tvshows',
    'homevideos',
    'mixed',
    '',
  }.contains(collectionType);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'collectionType': collectionType,
    if (imageTag != null) 'imageTag': imageTag,
  };

  static JellyfinLibrary fromJson(Map<String, dynamic> json) => JellyfinLibrary(
    id: json['id']?.toString() ?? json['Id']?.toString() ?? '',
    name: json['name']?.toString() ?? json['Name']?.toString() ?? 'Library',
    collectionType:
        (json['collectionType'] ?? json['CollectionType'])
            ?.toString()
            .toLowerCase() ??
        '',
    imageTag:
        json['imageTag']?.toString() ??
        (json['ImageTags'] is Map ? json['ImageTags']['Primary'] : null)
            ?.toString(),
  );
}

/// Per-profile Jellyfin connection. The access token lives in secure storage;
/// the password is never stored.
class JellyfinAccount {
  final String serverUrl;
  final String serverName;
  final String userId;
  final String userName;
  final String accessToken;
  final String deviceId;
  final List<JellyfinLibrary> libraries;
  final Set<String> selectedLibraryIds;
  final bool syncProgress;
  final bool showContinueWatching;

  const JellyfinAccount({
    required this.serverUrl,
    this.serverName = 'Jellyfin',
    required this.userId,
    required this.userName,
    required this.accessToken,
    required this.deviceId,
    this.libraries = const [],
    this.selectedLibraryIds = const {},
    this.syncProgress = true,
    this.showContinueWatching = true,
  });

  List<JellyfinLibrary> get selectedLibraries => libraries
      .where((library) => selectedLibraryIds.contains(library.id))
      .toList();

  JellyfinAccount copyWith({
    List<JellyfinLibrary>? libraries,
    Set<String>? selectedLibraryIds,
    bool? syncProgress,
    bool? showContinueWatching,
    String? serverName,
  }) => JellyfinAccount(
    serverUrl: serverUrl,
    serverName: serverName ?? this.serverName,
    userId: userId,
    userName: userName,
    accessToken: accessToken,
    deviceId: deviceId,
    libraries: libraries ?? this.libraries,
    selectedLibraryIds: selectedLibraryIds ?? this.selectedLibraryIds,
    syncProgress: syncProgress ?? this.syncProgress,
    showContinueWatching: showContinueWatching ?? this.showContinueWatching,
  );

  /// Everything except the token (stored separately in secure storage).
  Map<String, dynamic> toConfigJson() => {
    'serverUrl': serverUrl,
    'serverName': serverName,
    'userId': userId,
    'userName': userName,
    'deviceId': deviceId,
    'libraries': libraries.map((item) => item.toJson()).toList(),
    'selectedLibraryIds': selectedLibraryIds.toList(),
    'syncProgress': syncProgress,
    'showContinueWatching': showContinueWatching,
  };

  static JellyfinAccount? fromConfigJson(
    Map<String, dynamic> json,
    String token,
  ) {
    final serverUrl = json['serverUrl']?.toString() ?? '';
    final userId = json['userId']?.toString() ?? '';
    if (serverUrl.isEmpty || userId.isEmpty || token.isEmpty) {
      return null;
    }
    return JellyfinAccount(
      serverUrl: serverUrl,
      serverName: json['serverName']?.toString() ?? 'Jellyfin',
      userId: userId,
      userName: json['userName']?.toString() ?? '',
      accessToken: token,
      deviceId: json['deviceId']?.toString() ?? '',
      libraries: [
        for (final entry in (json['libraries'] as List? ?? const []))
          if (entry is Map)
            JellyfinLibrary.fromJson(Map<String, dynamic>.from(entry)),
      ],
      selectedLibraryIds: {
        for (final id in (json['selectedLibraryIds'] as List? ?? const []))
          id.toString(),
      },
      syncProgress: json['syncProgress'] != false,
      showContinueWatching: json['showContinueWatching'] != false,
    );
  }

  /// Library rows shown as sources in Movies & Series.
  List<LiveTvSource> get sources => [
    for (final library in selectedLibraries)
      LiveTvSource(
        id: '$jellyfinSourcePrefix${library.id}',
        name: '${library.name} (Jellyfin)',
        type: 'jellyfin',
        serverUrl: serverUrl,
        // Not a credential: identifies whose catalog the cache holds.
        username: userId,
        m3uUrl: library.id,
      ),
  ];
}

abstract class JellyfinSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _SecureSecretStore implements JellyfinSecretStore {
  static const _storage = FlutterSecureStorage();
  const _SecureSecretStore();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryJellyfinSecretStore implements JellyfinSecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class JellyfinAccountStore {
  static const _configPrefix = 'jellyfin.account.v1.';
  static const _tokenPrefix = 'jellyfin.token.v1.';
  static const _deviceIdKey = 'jellyfin.device-id.v1';

  final JellyfinSecretStore secrets;
  JellyfinAccountStore({JellyfinSecretStore? secrets})
    : secrets = secrets ?? const _SecureSecretStore();

  /// Lets widget tests inject an account without touching plugins.
  static JellyfinAccountStore? debugOverride;
  factory JellyfinAccountStore.instance() =>
      debugOverride ?? JellyfinAccountStore();

  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await prefs.setString(_deviceIdKey, value);
    return value;
  }

  Future<JellyfinAccount?> load(int profileId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_configPrefix$profileId');
      if (raw == null || raw.isEmpty) {
        return null;
      }
      final token = await secrets.read('$_tokenPrefix$profileId') ?? '';
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return JellyfinAccount.fromConfigJson(
        Map<String, dynamic>.from(decoded),
        token,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(int profileId, JellyfinAccount account) async {
    final prefs = await SharedPreferences.getInstance();
    await secrets.write('$_tokenPrefix$profileId', account.accessToken);
    await prefs.setString(
      '$_configPrefix$profileId',
      jsonEncode(account.toConfigJson()),
    );
  }

  Future<void> clear(int profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_configPrefix$profileId');
    await secrets.delete('$_tokenPrefix$profileId');
  }
}

class JellyfinAuthResult {
  final String userId;
  final String userName;
  final String accessToken;
  final String serverId;
  const JellyfinAuthResult({
    required this.userId,
    required this.userName,
    required this.accessToken,
    required this.serverId,
  });
}

class JellyfinQuickConnect {
  final String code;
  final String secret;
  final bool authenticated;
  const JellyfinQuickConnect({
    required this.code,
    required this.secret,
    required this.authenticated,
  });
}

/// Watch state reported by Jellyfin for one item.
class JellyfinUserData {
  final int positionMs;
  final bool played;
  final double? playedPercentage;
  final int? unplayedCount;
  final DateTime? lastPlayed;
  const JellyfinUserData({
    this.positionMs = 0,
    this.played = false,
    this.playedPercentage,
    this.unplayedCount,
    this.lastPlayed,
  });
}

/// A Jellyfin item converted for the Movies & Series screen, plus the
/// Jellyfin-only fields the Home rows need.
class JellyfinEntry {
  final LiveTvMediaItem media;
  final String itemId;
  final String type;
  final String? seriesId;
  final String? seriesName;
  final int? season;
  final int? episode;
  final int? runtimeMs;
  final JellyfinUserData userData;
  const JellyfinEntry({
    required this.media,
    required this.itemId,
    required this.type,
    this.seriesId,
    this.seriesName,
    this.season,
    this.episode,
    this.runtimeMs,
    this.userData = const JellyfinUserData(),
  });

  bool get isEpisode => type == 'Episode';
  bool get isSeries => type == 'Series';

  double get progress {
    final runtime = runtimeMs ?? 0;
    if (runtime <= 0 || userData.positionMs <= 0) {
      return (userData.playedPercentage ?? 0) / 100;
    }
    return (userData.positionMs / runtime).clamp(0.0, 1.0);
  }
}

class JellyfinApi {
  static const clientName = 'Millitop TV';
  static const clientVersion = '1.0.0';
  static const _itemFields =
      'Overview,Genres,ProviderIds,DateCreated,PremiereDate,ProductionYear,'
      'ParentId';
  static const ticksPerMs = 10000;

  final String serverUrl;
  final String deviceId;
  final String deviceName;
  final String? accessToken;
  final JellyfinTransport _transport;

  JellyfinApi({
    required String serverUrl,
    required this.deviceId,
    String? deviceName,
    this.accessToken,
    JellyfinTransport? transport,
  }) : serverUrl = normalizeJellyfinServerUrl(serverUrl),
       deviceName = deviceName ?? _platformName(),
       _transport = transport ?? _defaultTransport;

  factory JellyfinApi.forAccount(
    JellyfinAccount account, {
    JellyfinTransport? transport,
  }) => JellyfinApi(
    serverUrl: account.serverUrl,
    deviceId: account.deviceId,
    accessToken: account.accessToken,
    transport: transport,
  );

  static String _platformName() {
    try {
      return 'Millitop TV (${Platform.operatingSystem})';
    } catch (_) {
      return 'Millitop TV';
    }
  }

  static String _quote(String value) => value.replaceAll('"', "'");

  String get authorizationHeader {
    final parts = [
      'Client="${_quote(clientName)}"',
      'Device="${_quote(deviceName)}"',
      'DeviceId="${_quote(deviceId)}"',
      'Version="$clientVersion"',
      if (accessToken != null && accessToken!.isNotEmpty)
        'Token="${_quote(accessToken!)}"',
    ];
    return 'MediaBrowser ${parts.join(', ')}';
  }

  Uri uri(String path, [Map<String, String?> query = const {}]) {
    final base = Uri.parse(serverUrl);
    final cleaned = <String, String>{
      for (final entry in query.entries)
        if (entry.value != null && entry.value!.isNotEmpty)
          entry.key: entry.value!,
    };
    return base.replace(
      path: '${base.path}$path',
      queryParameters: cleaned.isEmpty ? null : cleaned,
    );
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, String?> query = const {},
    Object? body,
  }) async {
    final JellyfinHttpResponse response;
    final watch = Stopwatch()..start();
    try {
      response = await _transport(method, uri(path, query), {
        'Accept': 'application/json',
        'Authorization': authorizationHeader,
        // Older servers only read the legacy header name.
        'X-Emby-Authorization': authorizationHeader,
      }, body == null ? null : jsonEncode(body));
    } on TimeoutException catch (error, stack) {
      _logFailure(method, path, watch, error, stack);
      throw const JellyfinException('Jellyfin server timed out.');
    } on SocketException catch (error, stack) {
      _logFailure(method, path, watch, error, stack);
      throw const JellyfinException(
        'Jellyfin server is unreachable. Check the address and network.',
      );
    } on HandshakeException catch (error, stack) {
      _logFailure(method, path, watch, error, stack);
      throw const JellyfinException(
        'Secure connection to Jellyfin failed. Check the HTTPS certificate.',
      );
    }
    final failed = response.statusCode < 200 || response.statusCode >= 300;
    // 404 on the modern path is expected on old servers (legacy fallback).
    if (failed && response.statusCode != 404) {
      AppLog.warn(
        LogCategory.jellyfin,
        'Jellyfin $method $path returned HTTP ${response.statusCode}',
        details: {
          'status': response.statusCode,
          'ms': watch.elapsedMilliseconds,
          'server': serverUrl,
        },
      );
    } else {
      AppLog.debug(
        LogCategory.jellyfin,
        'Jellyfin $method $path ${response.statusCode}',
        details: {'ms': watch.elapsedMilliseconds},
      );
    }
    if (response.statusCode == 401) {
      throw const JellyfinException(
        'Jellyfin rejected the sign-in. Sign in again.',
        statusCode: 401,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JellyfinException(
        'Jellyfin returned HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    if (response.body.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw const JellyfinException(
        'That address did not answer like a Jellyfin server.',
      );
    }
  }

  void _logFailure(
    String method,
    String path,
    Stopwatch watch,
    Object error,
    StackTrace stack,
  ) {
    AppLog.error(
      LogCategory.jellyfin,
      'Jellyfin $method $path failed',
      error: error,
      stackTrace: stack,
      details: {'ms': watch.elapsedMilliseconds, 'server': serverUrl},
    );
  }

  /// Tries the current endpoint, then the pre-10.9 path on 404.
  Future<dynamic> _requestWithLegacy(
    String method,
    String path,
    String legacyPath, {
    Map<String, String?> query = const {},
  }) async {
    try {
      return await _request(method, path, query: query);
    } on JellyfinException catch (error) {
      if (error.statusCode != 404) {
        rethrow;
      }
      return _request(method, legacyPath, query: query);
    }
  }

  Future<Map<String, dynamic>> publicInfo() async {
    final result = await _request('GET', '/System/Info/Public');
    if (result is! Map || result['Id'] == null) {
      throw const JellyfinException(
        'That address did not answer like a Jellyfin server.',
      );
    }
    return Map<String, dynamic>.from(result);
  }

  Future<bool> quickConnectEnabled() async {
    try {
      final result = await _request('GET', '/QuickConnect/Enabled');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<JellyfinQuickConnect> initiateQuickConnect() async {
    final result = await _request('POST', '/QuickConnect/Initiate');
    return _quickConnect(result);
  }

  Future<JellyfinQuickConnect> quickConnectStatus(String secret) async {
    final result = await _request(
      'GET',
      '/QuickConnect/Connect',
      query: {'secret': secret},
    );
    return _quickConnect(result);
  }

  JellyfinQuickConnect _quickConnect(dynamic result) {
    if (result is! Map) {
      throw const JellyfinException('Quick Connect is not available.');
    }
    return JellyfinQuickConnect(
      code: result['Code']?.toString() ?? '',
      secret: result['Secret']?.toString() ?? '',
      authenticated: result['Authenticated'] == true,
    );
  }

  Future<JellyfinAuthResult> authenticateWithQuickConnect(String secret) async {
    final result = await _request(
      'POST',
      '/Users/AuthenticateWithQuickConnect',
      body: {'Secret': secret},
    );
    return _auth(result);
  }

  Future<JellyfinAuthResult> authenticateByName(
    String username,
    String password,
  ) async {
    final result = await _request(
      'POST',
      '/Users/AuthenticateByName',
      body: {'Username': username, 'Pw': password},
    );
    return _auth(result);
  }

  JellyfinAuthResult _auth(dynamic result) {
    if (result is! Map) {
      throw const JellyfinException('Jellyfin sign-in failed.');
    }
    final user = result['User'];
    final token = result['AccessToken']?.toString() ?? '';
    final userId = user is Map ? user['Id']?.toString() ?? '' : '';
    if (token.isEmpty || userId.isEmpty) {
      throw const JellyfinException('Jellyfin sign-in failed.');
    }
    return JellyfinAuthResult(
      userId: userId,
      userName: user is Map ? user['Name']?.toString() ?? '' : '',
      accessToken: token,
      serverId: result['ServerId']?.toString() ?? '',
    );
  }

  Future<List<JellyfinLibrary>> libraries(String userId) async {
    final result = await _requestWithLegacy(
      'GET',
      '/UserViews',
      '/Users/$userId/Views',
      query: {'userId': userId},
    );
    return [
      for (final entry in _items(result))
        JellyfinLibrary.fromJson(Map<String, dynamic>.from(entry)),
    ];
  }

  static List<Map> _items(dynamic result) {
    if (result is List) {
      return result.whereType<Map>().toList();
    }
    if (result is Map && result['Items'] is List) {
      return (result['Items'] as List).whereType<Map>().toList();
    }
    return const [];
  }

  /// Every movie and series in a library, paged so huge libraries load.
  Future<List<JellyfinEntry>> libraryItems(
    String userId,
    JellyfinLibrary library, {
    int pageSize = 500,
  }) async {
    final entries = <JellyfinEntry>[];
    var start = 0;
    while (true) {
      final result = await _request(
        'GET',
        '/Items',
        query: {
          'userId': userId,
          'ParentId': library.id,
          'Recursive': 'true',
          'IncludeItemTypes': 'Movie,Series',
          'Fields': _itemFields,
          'EnableImageTypes': 'Primary,Backdrop,Thumb',
          'SortBy': 'SortName',
          'StartIndex': '$start',
          'Limit': '$pageSize',
        },
      );
      final page = _items(result);
      entries.addAll(page.map((item) => entry(item, group: library.name)));
      final total = result is Map
          ? int.tryParse(result['TotalRecordCount']?.toString() ?? '')
          : null;
      start += page.length;
      if (page.length < pageSize || (total != null && start >= total)) {
        break;
      }
    }
    return entries;
  }

  Future<List<JellyfinEntry>> resume(
    String userId, {
    int limit = 20,
    String? parentId,
    String? group,
  }) async {
    final query = {
      'userId': userId,
      'ParentId': parentId,
      'Limit': '$limit',
      'MediaTypes': 'Video',
      'Fields': _itemFields,
      'EnableImageTypes': 'Primary,Backdrop,Thumb',
    };
    final result = await _requestWithLegacy(
      'GET',
      '/UserItems/Resume',
      '/Users/$userId/Items/Resume',
      query: query,
    );
    return _items(result).map((item) => entry(item, group: group)).toList();
  }

  Future<List<JellyfinEntry>> nextUp(
    String userId, {
    int limit = 20,
    String? parentId,
    String? group,
  }) async {
    final result = await _request(
      'GET',
      '/Shows/NextUp',
      query: {
        'userId': userId,
        'ParentId': parentId,
        'Limit': '$limit',
        'Fields': _itemFields,
        'EnableImageTypes': 'Primary,Backdrop,Thumb',
      },
    );
    return _items(result).map((item) => entry(item, group: group)).toList();
  }

  Future<List<JellyfinEntry>> latest(
    String userId, {
    String? parentId,
    int limit = 20,
    String? group,
  }) async {
    final query = {
      'userId': userId,
      'ParentId': parentId,
      'Limit': '$limit',
      'Fields': _itemFields,
      'GroupItems': 'true',
    };
    final result = await _requestWithLegacy(
      'GET',
      '/Items/Latest',
      '/Users/$userId/Items/Latest',
      query: query,
    );
    return _items(result).map((item) => entry(item, group: group)).toList();
  }

  Future<List<JellyfinEntry>> similar(
    String userId,
    String itemId, {
    int limit = 12,
  }) async {
    final result = await _request(
      'GET',
      '/Items/$itemId/Similar',
      query: {'userId': userId, 'Limit': '$limit', 'Fields': _itemFields},
    );
    return _items(result).map((item) => entry(item)).toList();
  }

  Future<List<JellyfinEntry>> episodes(
    String userId,
    String seriesId, {
    int pageSize = 400,
  }) async {
    final entries = <JellyfinEntry>[];
    var start = 0;
    while (true) {
      final result = await _request(
        'GET',
        '/Items',
        query: {
          'userId': userId,
          'ParentId': seriesId,
          'Recursive': 'true',
          'IncludeItemTypes': 'Episode',
          'Fields': '$_itemFields,ParentIndexNumber,IndexNumber,SeriesName,SeriesId,RunTimeTicks,OfficialRating',
          'EnableImageTypes': 'Primary,Backdrop,Thumb',
          'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
          'SortOrder': 'Ascending',
          'StartIndex': '$start',
          'Limit': '$pageSize',
        },
      );
      final page = _items(result);
      entries.addAll(page.map((item) => entry(item)));
      final total = result is Map
          ? int.tryParse(result['TotalRecordCount']?.toString() ?? '')
          : null;
      start += page.length;
      if (page.length < pageSize || (total != null && start >= total)) {
        break;
      }
    }
    return entries;
  }

  Future<JellyfinEntry?> item(String userId, String itemId) async {
    final result = await _requestWithLegacy(
      'GET',
      '/Items/$itemId',
      '/Users/$userId/Items/$itemId',
      query: {'userId': userId},
    );
    return result is Map ? entry(result) : null;
  }

  Future<void> setPlayed(String userId, String itemId, bool played) =>
      _requestWithLegacy(
        played ? 'POST' : 'DELETE',
        '/UserPlayedItems/$itemId',
        '/Users/$userId/PlayedItems/$itemId',
        query: {'userId': userId},
      );

  String imageUrl(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int maxHeight = 600,
  }) => uri('/Items/$itemId/Images/$type', {
    'maxHeight': '$maxHeight',
    'quality': '90',
    'tag': tag,
  }).toString();

  /// Direct stream; mpv handles nearly every container, so no transcoding.
  String streamUrl(String itemId) => uri('/Videos/$itemId/stream', {
    'static': 'true',
    'api_key': accessToken,
    'DeviceId': deviceId,
  }).toString();

  Future<void> reportPlaybackStart(
    String itemId,
    String playSessionId, {
    required int positionMs,
  }) => _request(
    'POST',
    '/Sessions/Playing',
    body: _progressBody(itemId, playSessionId, positionMs, false),
  );

  Future<void> reportPlaybackProgress(
    String itemId,
    String playSessionId, {
    required int positionMs,
    required bool paused,
  }) => _request(
    'POST',
    '/Sessions/Playing/Progress',
    body: _progressBody(itemId, playSessionId, positionMs, paused),
  );

  Future<void> reportPlaybackStopped(
    String itemId,
    String playSessionId, {
    required int positionMs,
  }) => _request(
    'POST',
    '/Sessions/Playing/Stopped',
    body: _progressBody(itemId, playSessionId, positionMs, false),
  );

  Map<String, dynamic> _progressBody(
    String itemId,
    String playSessionId,
    int positionMs,
    bool paused,
  ) => {
    'ItemId': itemId,
    'PlaySessionId': playSessionId,
    'PositionTicks': positionMs * ticksPerMs,
    'IsPaused': paused,
    'PlayMethod': 'DirectStream',
    'CanSeek': true,
  };

  JellyfinEntry entry(Map raw, {String? group}) {
    final id = raw['Id']?.toString() ?? '';
    final type = raw['Type']?.toString() ?? 'Movie';
    final imageTags = raw['ImageTags'] is Map ? raw['ImageTags'] as Map : {};
    final backdropTags = raw['BackdropImageTags'] is List
        ? raw['BackdropImageTags'] as List
        : const [];
    final parentBackdropTags = raw['ParentBackdropImageTags'] is List
        ? raw['ParentBackdropImageTags'] as List
        : const [];
    final seriesId = raw['SeriesId']?.toString();
    String? poster;
    if (imageTags['Primary'] != null) {
      poster = imageUrl(id, tag: imageTags['Primary'].toString());
    } else if (seriesId != null && raw['SeriesPrimaryImageTag'] != null) {
      poster = imageUrl(seriesId, tag: raw['SeriesPrimaryImageTag'].toString());
    }
    String? backdrop;
    if (backdropTags.isNotEmpty) {
      backdrop = imageUrl(
        id,
        type: 'Backdrop',
        tag: backdropTags.first.toString(),
        maxHeight: 1080,
      );
    } else if (parentBackdropTags.isNotEmpty) {
      final parent = raw['ParentBackdropItemId']?.toString() ?? seriesId ?? id;
      backdrop = imageUrl(
        parent,
        type: 'Backdrop',
        tag: parentBackdropTags.first.toString(),
        maxHeight: 1080,
      );
    } else if (imageTags['Thumb'] != null) {
      backdrop = imageUrl(
        id,
        type: 'Thumb',
        tag: imageTags['Thumb'].toString(),
        maxHeight: 720,
      );
    }
    final userData = raw['UserData'] is Map ? raw['UserData'] as Map : {};
    final ticks = int.tryParse(
      userData['PlaybackPositionTicks']?.toString() ?? '',
    );
    final runtimeTicks = int.tryParse(raw['RunTimeTicks']?.toString() ?? '');
    final year = int.tryParse(raw['ProductionYear']?.toString() ?? '');
    final rating = raw['OfficialRating']?.toString().trim().toUpperCase();
    final genres = [
      if (raw['Genres'] is List)
        ...(raw['Genres'] as List).map((item) => item.toString()),
      // Rated adult on the server: tag it so it lands in the Adult section.
      if (rating == 'XXX' || rating == 'X' || rating == 'AO') 'Adult',
    ];
    final name = raw['Name']?.toString() ?? 'Untitled';
    return JellyfinEntry(
      itemId: id,
      type: type,
      seriesId: seriesId,
      seriesName: raw['SeriesName']?.toString(),
      season: int.tryParse(raw['ParentIndexNumber']?.toString() ?? ''),
      episode: int.tryParse(raw['IndexNumber']?.toString() ?? ''),
      runtimeMs: runtimeTicks == null ? null : runtimeTicks ~/ ticksPerMs,
      userData: JellyfinUserData(
        positionMs: ticks == null ? 0 : ticks ~/ ticksPerMs,
        played: userData['Played'] == true,
        playedPercentage: double.tryParse(
          userData['PlayedPercentage']?.toString() ?? '',
        ),
        unplayedCount: int.tryParse(
          userData['UnplayedItemCount']?.toString() ?? '',
        ),
        lastPlayed: DateTime.tryParse(
          userData['LastPlayedDate']?.toString() ?? '',
        ),
      ),
      media: LiveTvMediaItem(
        id: 'jf:$id',
        title: name,
        streamUrl: jellyfinPlaceholderUrl(id),
        posterUrl: poster,
        backdropUrl: backdrop,
        description: raw['Overview']?.toString(),
        group: group,
        series: type == 'Series',
        seriesId: type == 'Series' ? id : null,
        year: year,
        genres: genres,
        releaseDate: DateTime.tryParse(raw['PremiereDate']?.toString() ?? ''),
        addedAt: DateTime.tryParse(raw['DateCreated']?.toString() ?? ''),
      ),
    );
  }

  /// Converts a series' episodes for the existing series details screen.
  Future<LiveTvSeriesDetails> seriesDetails(
    String userId,
    LiveTvMediaItem series,
  ) async {
    final seriesId = series.seriesId ?? series.id.replaceFirst('jf:', '');
    final items = await episodes(userId, seriesId);
    return LiveTvSeriesDetails(
      seriesId: seriesId,
      title: series.title,
      description: series.description,
      posterUrl: series.posterUrl,
      backdropUrl: series.backdropUrl,
      episodes: [
        for (final item in items)
          LiveTvSeriesEpisode(
            id: item.media.id,
            title: item.media.title,
            streamUrl: item.media.streamUrl,
            season: item.season ?? 1,
            episode: item.episode ?? 0,
            posterUrl: item.media.backdropUrl ?? item.media.posterUrl,
            description: item.media.description,
          ),
      ],
    );
  }
}

/// Reports playback to Jellyfin so resume points and watched state follow
/// the user to every Jellyfin client. Progress is throttled to every 10s.
class JellyfinPlaybackReporter {
  final JellyfinApi api;
  final String itemId;
  final String playSessionId;
  final int? resumeMs;
  final bool enabled;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  bool _started = false;
  bool _stopped = false;

  JellyfinPlaybackReporter({
    required this.api,
    required this.itemId,
    this.resumeMs,
    this.enabled = true,
  }) : playSessionId =
           '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
           '${Random().nextInt(1 << 30).toRadixString(36)}';

  String get playUrl => api.streamUrl(itemId);

  void progress(int positionMs, {required bool paused}) {
    if (!enabled || _stopped) {
      return;
    }
    if (!_started) {
      _started = true;
      unawaited(
        api
            .reportPlaybackStart(itemId, playSessionId, positionMs: positionMs)
            .catchError((_) {}),
      );
      _lastProgress = DateTime.now();
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastProgress) < const Duration(seconds: 10)) {
      return;
    }
    _lastProgress = now;
    unawaited(
      api
          .reportPlaybackProgress(
            itemId,
            playSessionId,
            positionMs: positionMs,
            paused: paused,
          )
          .catchError((_) {}),
    );
  }

  Future<void> stopped(int positionMs) async {
    if (!enabled || _stopped || !_started) {
      return;
    }
    _stopped = true;
    try {
      await api.reportPlaybackStopped(
        itemId,
        playSessionId,
        positionMs: positionMs,
      );
    } catch (_) {}
  }
}
