part of 'console_auth_service.dart';

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
