part of 'console_auth_service.dart';

const _iosCredentialChannel = MethodChannel('net.easytier.pro/core_runtime');

bool get _usesIosKeychain =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

Future<String?> _loadCredential(
  SharedPreferences preferences,
  String key,
) async {
  if (!_usesIosKeychain) return preferences.getString(key);
  final stored = await _iosCredentialChannel.invokeMethod<String>(
    'readSecureValue',
    {'key': key},
  );
  if (stored != null) {
    await preferences.remove(key);
    return stored;
  }
  final legacy = preferences.getString(key);
  if (legacy != null) await _saveCredential(preferences, key, legacy);
  return legacy;
}

Future<void> _saveCredential(
  SharedPreferences preferences,
  String key,
  String value,
) async {
  if (!_usesIosKeychain) {
    await preferences.setString(key, value);
    return;
  }
  await _iosCredentialChannel.invokeMethod<void>('writeSecureValue', {
    'key': key,
    'value': value,
  });
  await preferences.remove(key);
}

Future<void> _clearCredential(SharedPreferences preferences, String key) async {
  if (_usesIosKeychain) {
    await _iosCredentialChannel.invokeMethod<void>('deleteSecureValue', {
      'key': key,
    });
  }
  await preferences.remove(key);
}
