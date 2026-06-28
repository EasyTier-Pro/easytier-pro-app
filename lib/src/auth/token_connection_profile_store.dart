part of 'console_auth_service.dart';

class TokenConnectionProfile {
  const TokenConnectionProfile({
    required this.bootstrapToken,
    required this.configServer,
    required this.displayName,
    required this.updatedAt,
  });

  final String bootstrapToken;
  final String configServer;
  final String displayName;
  final DateTime updatedAt;

  String get effectiveDisplayName {
    final name = displayName.trim();
    return name.isEmpty ? '设备令牌连接' : name;
  }

  CoreBootstrapConfig toBootstrap({required String version}) {
    return CoreBootstrapConfig(
      bootstrapToken: bootstrapToken,
      version: version,
      configServer: configServer,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'bootstrap_token': bootstrapToken,
      'config_server': configServer,
      'display_name': displayName,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory TokenConnectionProfile.fromJson(Map<String, dynamic> json) {
    return TokenConnectionProfile(
      bootstrapToken: json['bootstrap_token']?.toString() ?? '',
      configServer: json['config_server']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }

  factory TokenConnectionProfile.fromInput({
    required String input,
    required String defaultConfigServer,
    String displayName = '',
  }) {
    final token = _parseDeviceTokenInput(input);
    return TokenConnectionProfile(
      bootstrapToken: token,
      configServer: _normalizeConfigServer(defaultConfigServer),
      displayName: displayName.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
  }
}

class TokenConnectionProfileStore {
  TokenConnectionProfileStore(this.preferences) : _memoryValues = null;

  TokenConnectionProfileStore.memory()
    : preferences = null,
      _memoryValues = <String, String>{};

  static const String _profileKey = 'token_connection_profile';

  final SharedPreferences? preferences;
  final Map<String, String>? _memoryValues;

  Future<TokenConnectionProfile?> load() async {
    final source =
        _memoryValues?[_profileKey] ?? preferences?.getString(_profileKey);
    if (source == null || source.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        await clear();
        return null;
      }
      final profile = TokenConnectionProfile.fromJson(decoded);
      if (!_isUsableProfile(profile)) {
        await clear();
        return null;
      }
      return profile;
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<void> save(TokenConnectionProfile profile) async {
    if (!_isUsableProfile(profile)) {
      throw const AuthException('设备令牌或控制服务器地址不能为空。');
    }
    final source = jsonEncode(profile.toJson());
    final memory = _memoryValues;
    if (memory != null) {
      memory[_profileKey] = source;
      return;
    }
    await preferences?.setString(_profileKey, source);
  }

  Future<void> clear() async {
    final memory = _memoryValues;
    if (memory != null) {
      memory.remove(_profileKey);
      return;
    }
    await preferences?.remove(_profileKey);
  }

  static bool _isUsableProfile(TokenConnectionProfile profile) {
    return profile.bootstrapToken.trim().isNotEmpty &&
        profile.configServer.trim().isNotEmpty;
  }
}

String _parseDeviceTokenInput(String input) {
  final text = input.trim();
  if (text.isEmpty) {
    throw const AuthException('请输入设备令牌。');
  }

  final uri = Uri.tryParse(text);
  if (uri != null && uri.hasScheme) {
    throw const AuthException('请粘贴设备令牌，不支持连接链接。');
  }

  return text;
}

String _normalizeConfigServer(String value) {
  final text = value.trim();
  if (text.isEmpty) {
    throw const AuthException('控制服务器地址不能为空。');
  }
  return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
}
