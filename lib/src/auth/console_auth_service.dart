import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

const String defaultConsoleBaseUrl = String.fromEnvironment(
  'EASYTIER_CONSOLE_URL',
  defaultValue: 'https://api.console.easytier.net',
);

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DeviceAuthInfo {
  const DeviceAuthInfo({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String verificationUriComplete;
  final int expiresIn;
  final int interval;
}

class TokenSet {
  const TokenSet({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
    required this.obtainedAt,
    this.idToken,
    this.refreshToken,
  });

  final String accessToken;
  final String? idToken;
  final String? refreshToken;
  final String tokenType;
  final int expiresIn;
  final DateTime obtainedAt;

  bool get isExpired {
    final bufferSeconds = expiresIn > 120 ? 60 : 0;
    return DateTime.now().toUtc().isAfter(
      obtainedAt.toUtc().add(Duration(seconds: expiresIn - bufferSeconds)),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'access_token': accessToken,
      'id_token': idToken,
      'refresh_token': refreshToken,
      'token_type': tokenType,
      'expires_in': expiresIn,
      'obtained_at': obtainedAt.toUtc().toIso8601String(),
    };
  }

  factory TokenSet.fromJson(Map<String, dynamic> json) {
    return TokenSet(
      accessToken: json['access_token'] as String,
      idToken: json['id_token'] as String?,
      refreshToken: json['refresh_token'] as String?,
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 3600,
      obtainedAt: DateTime.parse(json['obtained_at'] as String).toUtc(),
    );
  }
}

class ConsoleUser {
  const ConsoleUser({
    required this.email,
    required this.displayName,
    required this.workspaces,
  });

  final String email;
  final String displayName;
  final List<ConsoleWorkspace> workspaces;

  List<String> get tenantNames =>
      workspaces.map((workspace) => workspace.name).toList(growable: false);

  ConsoleWorkspace? get currentWorkspace =>
      workspaces.isEmpty ? null : workspaces.first;

  String get effectiveName => displayName.isEmpty ? email : displayName;
}

class ConsoleWorkspace {
  const ConsoleWorkspace({required this.id, required this.name});

  final String id;
  final String name;
}

class ConsoleNetwork {
  const ConsoleNetwork({
    required this.id,
    required this.name,
    this.regions = const <String>[],
    this.lifecycleState = '',
  });

  final String id;
  final String name;
  final List<String> regions;
  final String lifecycleState;
}

class ConsoleRegion {
  const ConsoleRegion({
    required this.id,
    required this.code,
    required this.displayName,
    required this.status,
  });

  final String id;
  final String code;
  final String displayName;
  final String status;

  bool get active => status.toLowerCase() == 'active';
}

class NetworkDevice {
  const NetworkDevice({
    required this.id,
    required this.name,
    required this.online,
    this.ipv4,
    this.deviceId,
    this.machineId,
    this.connectivityState = '',
  });

  final String id;
  final String name;
  final bool online;
  final String? ipv4;
  final String? deviceId;
  final String? machineId;
  final String connectivityState;
}

class ManagedDevice {
  const ManagedDevice({
    required this.id,
    required this.machineId,
    required this.hostname,
    required this.approvalState,
    required this.connectivityState,
  });

  final String id;
  final String machineId;
  final String hostname;
  final String approvalState;
  final String connectivityState;

  bool get approved => approvalState.toLowerCase() == 'approved';
  bool get online => connectivityState.toLowerCase() == 'online';
}

class AttachNetworkResult {
  const AttachNetworkResult({required this.nodeId, this.operationId});

  final String nodeId;
  final String? operationId;
}

class CoreBootstrapConfig {
  const CoreBootstrapConfig({
    required this.bootstrapToken,
    required this.version,
    required this.configServer,
  });

  final String bootstrapToken;
  final String version;
  final String configServer;
}

class AuthSession {
  const AuthSession({required this.user, required this.tokenSet});

  final ConsoleUser user;
  final TokenSet tokenSet;
}

abstract class AuthService {
  Future<AuthSession?> restoreSession();

  Future<DeviceAuthInfo> startDeviceAuth();

  Future<AuthSession> completeDeviceAuth(DeviceAuthInfo info);

  Future<List<ConsoleNetwork>> fetchNetworks({
    required String accessToken,
    required String workspaceId,
  });

  Future<List<ConsoleRegion>> fetchRegions({required String accessToken});

  Future<ConsoleNetwork> createNetwork({
    required String accessToken,
    required String workspaceId,
    required String name,
    required List<String> regions,
  });

  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  });

  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  });

  Future<AttachNetworkResult> attachDeviceToNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
    required String deviceId,
  });

  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
  });

  Future<void> logout();
}

class OAuthTokenStore {
  OAuthTokenStore(this._preferences);

  static const String _tokenKey = 'console_oauth_token';

  final SharedPreferences _preferences;

  Future<TokenSet?> load() async {
    final raw = _preferences.getString(_tokenKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return TokenSet.fromJson(decoded);
  }

  Future<void> save(TokenSet tokenSet) async {
    await _preferences.setString(_tokenKey, jsonEncode(tokenSet.toJson()));
  }

  Future<void> clear() async {
    await _preferences.remove(_tokenKey);
  }
}

class ConsoleAuthService implements AuthService {
  ConsoleAuthService({
    required this.tokenStore,
    http.Client? httpClient,
    this.consoleBaseUrl = defaultConsoleBaseUrl,
  }) : _httpClient = httpClient ?? http.Client();

  final OAuthTokenStore tokenStore;
  final http.Client _httpClient;
  final String consoleBaseUrl;
  final AppLogger _logger = AppLogger.instance;

  @override
  Future<AuthSession?> restoreSession() async {
    _logger.info('auth', 'Restoring local session');
    final tokenSet = await tokenStore.load();
    if (tokenSet == null || tokenSet.isExpired) {
      await tokenStore.clear();
      return null;
    }

    try {
      final user = await _fetchCurrentUser(tokenSet.accessToken);
      _logger.info(
        'auth',
        'Session restored',
        context: {'workspace_count': user.workspaces.length},
      );
      return AuthSession(user: user, tokenSet: tokenSet);
    } on AuthException {
      _logger.warn('auth', 'Stored session invalid, clearing local token');
      await tokenStore.clear();
      return null;
    }
  }

  @override
  Future<DeviceAuthInfo> startDeviceAuth() async {
    _logger.info('auth', 'Starting device authorization');
    final response = await _httpClient.post(
      Uri.parse('$consoleBaseUrl/api/v1/auth/device'),
      body: const {'client_id': '', 'scope': 'openid profile email'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('获取登录验证码失败：${_extractErrorMessage(response.body)}');
    }

    final body = _decodeObject(response.body);
    final verificationUri = _stripCancelToken(
      body['verification_uri']?.toString() ?? '',
    );
    final verificationUriComplete =
        (body['verification_uri_complete']?.toString().isNotEmpty ?? false)
        ? body['verification_uri_complete'].toString()
        : verificationUri;

    return DeviceAuthInfo(
      deviceCode: body['device_code']?.toString() ?? '',
      userCode: body['user_code']?.toString() ?? '',
      verificationUri: verificationUri,
      verificationUriComplete: verificationUriComplete,
      expiresIn: (body['expires_in'] as num?)?.toInt() ?? 600,
      interval: ((body['interval'] as num?)?.toInt() ?? 5).clamp(5, 600),
    );
  }

  @override
  Future<AuthSession> completeDeviceAuth(DeviceAuthInfo info) async {
    _logger.info('auth', 'Waiting for device authorization approval');
    final deadline = DateTime.now().toUtc().add(
      Duration(seconds: info.expiresIn),
    );
    var intervalSeconds = info.interval;

    while (DateTime.now().toUtc().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: intervalSeconds));

      final response = await _httpClient.post(
        Uri.parse('$consoleBaseUrl/api/v1/auth/device/token'),
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': info.deviceCode,
          'client_id': '',
        },
      );

      if (response.statusCode.toString().startsWith('2')) {
        final body = _decodeObject(response.body);
        final tokenSet = TokenSet(
          accessToken: body['access_token']?.toString() ?? '',
          idToken: body['id_token']?.toString(),
          refreshToken: body['refresh_token']?.toString(),
          tokenType: body['token_type']?.toString() ?? 'Bearer',
          expiresIn: (body['expires_in'] as num?)?.toInt() ?? 3600,
          obtainedAt: DateTime.now().toUtc(),
        );

        await tokenStore.save(tokenSet);
        final user = await _fetchCurrentUser(tokenSet.accessToken);
        _logger.info(
          'auth',
          'Device authorization completed',
          context: {'workspace_count': user.workspaces.length},
        );
        return AuthSession(user: user, tokenSet: tokenSet);
      }

      final body = _tryDecodeObject(response.body);
      final error = body?['error']?.toString() ?? 'unknown_error';
      final description =
          body?['error_description']?.toString() ??
          body?['description']?.toString() ??
          _extractErrorMessage(response.body);

      switch (error) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          intervalSeconds += ((body?['interval'] as num?)?.toInt() ?? 5);
          continue;
        case 'expired_token':
          throw const AuthException('登录验证码已过期，请重新发起登录。');
        case 'access_denied':
          throw const AuthException('用户拒绝了授权，请重新登录。');
        default:
          throw AuthException('登录失败：$description');
      }
    }

    throw const AuthException('登录超时，请重新发起设备登录。');
  }

  @override
  Future<void> logout() async {
    _logger.info('auth', 'Clearing local auth token');
    await tokenStore.clear();
  }

  @override
  Future<List<ConsoleNetwork>> fetchNetworks({
    required String accessToken,
    required String workspaceId,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$consoleBaseUrl/api/v1/tenants/$workspaceId/networks'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('读取网络列表失败：${_extractErrorMessage(response.body)}');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map(_networkFromJson)
        .whereType<ConsoleNetwork>()
        .toList(growable: false);
  }

  @override
  Future<List<ConsoleRegion>> fetchRegions({
    required String accessToken,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$consoleBaseUrl/api/v1/regions'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('读取区域列表失败：${_extractErrorMessage(response.body)}');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map((item) {
          final id = item['id']?.toString() ?? item['code']?.toString() ?? '';
          final code = item['code']?.toString() ?? '';
          final displayName =
              item['display_name']?.toString() ??
              item['name']?.toString() ??
              code;
          final status =
              item['status']?.toString() ??
              (item['active'] == true ? 'active' : '');
          if (id.isEmpty || code.isEmpty) {
            return null;
          }
          return ConsoleRegion(
            id: id,
            code: code,
            displayName: displayName,
            status: status,
          );
        })
        .whereType<ConsoleRegion>()
        .toList(growable: false);
  }

  @override
  Future<ConsoleNetwork> createNetwork({
    required String accessToken,
    required String workspaceId,
    required String name,
    required List<String> regions,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$consoleBaseUrl/api/v1/tenants/$workspaceId/networks'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'name': name, 'regions': regions}),
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('创建网络失败：${_extractErrorMessage(response.body)}');
    }

    final network = _networkFromJson(_decodeObject(response.body));
    if (network == null) {
      throw const AuthException('创建网络后服务端返回了无法识别的数据格式。');
    }
    return network;
  }

  static ConsoleNetwork? _networkFromJson(Map<String, dynamic> item) {
    final id = item['id']?.toString() ?? '';
    final name =
        item['name']?.toString() ?? item['network_name']?.toString() ?? '';
    if (id.isEmpty || name.isEmpty) {
      return null;
    }
    final rawRegions = item['regions'];
    final regions = rawRegions is List<dynamic>
        ? rawRegions.map((region) => region.toString()).toList(growable: false)
        : const <String>[];
    return ConsoleNetwork(
      id: id,
      name: name,
      regions: regions,
      lifecycleState: item['lifecycle_state']?.toString() ?? '',
    );
  }

  @override
  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$consoleBaseUrl/api/v1/tenants/$workspaceId/devices'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('读取设备列表失败：${_extractErrorMessage(response.body)}');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map((item) {
          final id = item['id']?.toString() ?? '';
          final machineId = item['machine_id']?.toString() ?? '';
          if (id.isEmpty || machineId.isEmpty) {
            return null;
          }
          final hostname =
              item['hostname']?.toString() ??
              item['display_name']?.toString() ??
              machineId;
          return ManagedDevice(
            id: id,
            machineId: machineId,
            hostname: hostname,
            approvalState: item['approval_state']?.toString() ?? '',
            connectivityState: item['connectivity_state']?.toString() ?? '',
          );
        })
        .whereType<ManagedDevice>()
        .toList(growable: false);
  }

  @override
  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    final response = await _httpClient.get(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/networks/$networkId/nodes',
      ),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('读取设备列表失败：${_extractErrorMessage(response.body)}');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map((item) {
          final id = item['id']?.toString() ?? '';
          if (id.isEmpty) {
            return null;
          }
          final device = item['device'] as Map<String, dynamic>?;
          final rawName =
              item['hostname']?.toString() ??
              item['name']?.toString() ??
              item['device_name']?.toString() ??
              device?['hostname']?.toString() ??
              device?['display_name']?.toString();
          final status =
              item['connectivity_state']?.toString() ??
              device?['connectivity_state']?.toString() ??
              item['status']?.toString() ??
              item['state']?.toString() ??
              '';
          final online =
              status.toLowerCase() == 'online' ||
              status.toLowerCase() == 'connected';
          final ipv4 =
              item['ipv4_addr']?.toString() ??
              item['ipv4']?.toString() ??
              item['ip']?.toString();
          final deviceId =
              item['device_id']?.toString() ?? device?['id']?.toString();
          final machineId =
              item['machine_id']?.toString() ??
              device?['machine_id']?.toString();

          return NetworkDevice(
            id: id,
            name: (rawName == null || rawName.isEmpty) ? id : rawName,
            online: online,
            ipv4: ipv4,
            deviceId: deviceId == null || deviceId.isEmpty ? null : deviceId,
            machineId: machineId == null || machineId.isEmpty
                ? null
                : machineId,
            connectivityState: status,
          );
        })
        .whereType<NetworkDevice>()
        .toList(growable: false);
  }

  @override
  Future<AttachNetworkResult> attachDeviceToNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
    required String deviceId,
  }) async {
    final response = await _httpClient.post(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/networks/$networkId/nodes',
      ),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'device_id': deviceId}),
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('加入网络失败：${_extractErrorMessage(response.body)}');
    }

    final body = _decodeObject(response.body);
    final resource =
        (body['resource'] as Map<String, dynamic>?) ??
        (body['node'] as Map<String, dynamic>?) ??
        body;
    final nodeId = resource['id']?.toString() ?? '';
    if (nodeId.isEmpty) {
      throw const AuthException('加入网络后服务端返回了无法识别的数据格式。');
    }
    final operation = body['operation'] as Map<String, dynamic>?;
    return AttachNetworkResult(
      nodeId: nodeId,
      operationId: operation?['id']?.toString(),
    );
  }

  @override
  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
  }) async {
    _logger.info(
      'auth.bootstrap',
      'Preparing core bootstrap payload',
      context: {'workspace_id': workspaceId},
    );
    final releaseResponse = await _httpClient.get(
      Uri.parse('$consoleBaseUrl/api/v1/releases/latest'),
    );
    if (!releaseResponse.statusCode.toString().startsWith('2')) {
      throw AuthException(
        '读取版本信息失败：${_extractErrorMessage(releaseResponse.body)}',
      );
    }

    final releaseBody = _decodeObject(releaseResponse.body);
    final stable =
        (releaseBody['stable'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final rawVersion =
        stable['version']?.toString() ??
        releaseBody['version']?.toString() ??
        '';
    if (rawVersion.trim().isEmpty) {
      _logger.error(
        'auth.bootstrap',
        'No release version available from console',
      );
      throw const AuthException('控制台未返回可用版本');
    }
    final version = rawVersion.startsWith('v') ? rawVersion : 'v$rawVersion';

    final keysResponse = await _httpClient.get(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/device-enrollment-keys',
      ),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (!keysResponse.statusCode.toString().startsWith('2')) {
      throw AuthException(
        '读取注册密钥失败：${_extractErrorMessage(keysResponse.body)}',
      );
    }
    final keyItems = _decodeObjectOrList(keysResponse.body);

    final key = keyItems.firstWhere(
      (item) =>
          item['id']?.toString().isNotEmpty == true &&
          item['revoked'] != true &&
          item['lifecycle_state']?.toString() != 'expired',
      orElse: () => const <String, dynamic>{},
    );

    String bootstrapToken;
    if (key.isNotEmpty) {
      final keyId = key['id']!.toString();
      final secretResponse = await _httpClient.get(
        Uri.parse(
          '$consoleBaseUrl/api/v1/tenants/$workspaceId/device-enrollment-keys/$keyId/secret',
        ),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (secretResponse.statusCode.toString().startsWith('2')) {
        final secretBody = _decodeObject(secretResponse.body);
        bootstrapToken = secretBody['bootstrap_token']?.toString() ?? '';
      } else {
        bootstrapToken = '';
      }
    } else {
      bootstrapToken = '';
    }

    if (bootstrapToken.isEmpty) {
      _logger.info(
        'auth.bootstrap',
        'No reusable key available, creating a new enrollment key',
      );
      final createResponse = await _httpClient.post(
        Uri.parse(
          '$consoleBaseUrl/api/v1/tenants/$workspaceId/device-enrollment-keys',
        ),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'display_name': 'Desktop Auto Key',
          'reusable': true,
          'pre_approved': true,
        }),
      );
      if (!createResponse.statusCode.toString().startsWith('2')) {
        throw AuthException(
          '创建注册密钥失败：${_extractErrorMessage(createResponse.body)}',
        );
      }
      final createBody = _decodeObject(createResponse.body);
      bootstrapToken = createBody['bootstrap_token']?.toString() ?? '';
      if (bootstrapToken.isEmpty) {
        throw const AuthException('创建密钥后未返回 bootstrap_token');
      }
    }

    final configServerRaw =
        releaseBody['web_config_server_url']?.toString() ??
        'tcp://api.console.easytier.net:22020';
    final configServer = configServerRaw.trim().isEmpty
        ? 'tcp://api.console.easytier.net:22020'
        : configServerRaw;

    return CoreBootstrapConfig(
      bootstrapToken: bootstrapToken,
      version: version,
      configServer: configServer,
    );
  }

  Future<ConsoleUser> _fetchCurrentUser(String accessToken) async {
    final response = await _httpClient.get(
      Uri.parse('$consoleBaseUrl/api/v1/auth/me'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('当前登录态已失效。');
    }

    final body = _decodeObject(response.body);
    final user =
        (body['user'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final tenants = (body['tenants'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item as Map<String, dynamic>)
        .map(
          (item) => ConsoleWorkspace(
            id: item['id']?.toString() ?? '',
            name: item['name']?.toString() ?? '',
          ),
        )
        .where((item) => item.id.isNotEmpty && item.name.isNotEmpty)
        .toList(growable: false);

    return ConsoleUser(
      email: user['email']?.toString() ?? '',
      displayName: user['display_name']?.toString() ?? '',
      workspaces: tenants,
    );
  }

  static Map<String, dynamic> _decodeObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const AuthException('服务端返回了无法识别的数据格式。');
  }

  static Map<String, dynamic>? _tryDecodeObject(String source) {
    try {
      return _decodeObject(source);
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _decodeObjectOrList(String source) {
    final decoded = jsonDecode(source);
    if (decoded is List<dynamic>) {
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    if (decoded is Map<String, dynamic>) {
      if (decoded['items'] is List<dynamic>) {
        return (decoded['items'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['networks'] is List<dynamic>) {
        return (decoded['networks'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['nodes'] is List<dynamic>) {
        return (decoded['nodes'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['devices'] is List<dynamic>) {
        return (decoded['devices'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['regions'] is List<dynamic>) {
        return (decoded['regions'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
    }
    return const <Map<String, dynamic>>[];
  }

  static String _extractErrorMessage(String source) {
    final body = _tryDecodeObject(source);
    return body?['message']?.toString() ??
        body?['error_description']?.toString() ??
        body?['description']?.toString() ??
        source;
  }

  static String _stripCancelToken(String url) {
    final parts = url.split('?cancelToken=');
    return parts.first;
  }
}
