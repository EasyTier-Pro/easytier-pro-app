import 'dart:convert';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('net.easytier.pro/core_runtime');
  late Map<String, String> secrets;
  late SharedPreferences preferences;
  bool failWrite = false;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    secrets = {};
    failWrite = false;
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          final key = args['key'] as String;
          switch (call.method) {
            case 'readSecureValue':
              return secrets[key];
            case 'writeSecureValue':
              if (failWrite) throw PlatformException(code: 'KEYCHAIN_ERROR');
              secrets[key] = args['value'] as String;
              return null;
            case 'deleteSecureValue':
              secrets.remove(key);
              return null;
          }
          throw StateError('Unexpected method ${call.method}');
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'migrates an existing OAuth session only after Keychain accepts it',
    () async {
      final session = jsonEncode({
        'access_token': 'access',
        'refresh_token': 'refresh',
        'token_type': 'Bearer',
        'obtained_at': '2099-01-01T00:00:00Z',
      });
      await preferences.setString('console_oauth_token', session);
      failWrite = true;
      await expectLater(
        OAuthTokenStore(preferences).load(),
        throwsA(isA<PlatformException>()),
      );
      expect(preferences.getString('console_oauth_token'), session);
      failWrite = false;
      expect(
        (await OAuthTokenStore(preferences).load())?.accessToken,
        'access',
      );
      expect(secrets['console_oauth_token'], session);
      expect(preferences.containsKey('console_oauth_token'), isFalse);
      await OAuthTokenStore(preferences).clear();
      expect(secrets, isEmpty);
    },
  );

  test(
    'device token profiles persist in Keychain and clear from both stores',
    () async {
      final store = TokenConnectionProfileStore(preferences);
      final profile = TokenConnectionProfile.fromInput(
        input: 'device-secret',
        defaultConfigServer: 'tcp://console.test:22020',
      );
      await store.save(profile);
      expect(preferences.containsKey('token_connection_profile'), isFalse);
      expect(secrets['token_connection_profile'], contains('device-secret'));
      expect((await store.load())?.bootstrapToken, 'device-secret');
      await store.clear();
      expect(await store.load(), isNull);
      expect(secrets, isEmpty);
    },
  );
}
