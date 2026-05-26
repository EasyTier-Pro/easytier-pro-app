import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
    required this.tenantNames,
  });

  final String email;
  final String displayName;
  final List<String> tenantNames;

  String get effectiveName => displayName.isEmpty ? email : displayName;
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

  @override
  Future<AuthSession?> restoreSession() async {
    final tokenSet = await tokenStore.load();
    if (tokenSet == null || tokenSet.isExpired) {
      await tokenStore.clear();
      return null;
    }

    try {
      final user = await _fetchCurrentUser(tokenSet.accessToken);
      return AuthSession(user: user, tokenSet: tokenSet);
    } on AuthException {
      await tokenStore.clear();
      return null;
    }
  }

  @override
  Future<DeviceAuthInfo> startDeviceAuth() async {
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
    await tokenStore.clear();
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
        .map((item) => item['name']?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);

    return ConsoleUser(
      email: user['email']?.toString() ?? '',
      displayName: user['display_name']?.toString() ?? '',
      tenantNames: tenants,
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
