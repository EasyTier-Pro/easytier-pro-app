import 'package:flutter_test/flutter_test.dart';

import 'package:easytier_pro_app/main.dart';
import 'package:easytier_pro_app/src/auth/console_auth_service.dart';

void main() {
  testWidgets('shows logged in console state when credentials exist', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(MyApp(authService: _FakeAuthService()));
    await tester.pumpAndSettle();

    expect(find.text('已登录控制台'), findsOneWidget);
    expect(find.textContaining('tester@example.com'), findsOneWidget);
  });
}

class _FakeAuthService implements AuthService {
  @override
  Future<AuthSession> completeDeviceAuth(DeviceAuthInfo info) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession?> restoreSession() async {
    return AuthSession(
      user: const ConsoleUser(
        email: 'tester@example.com',
        displayName: 'Test User',
        tenantNames: <String>['个人空间'],
      ),
      tokenSet: TokenSet(
        accessToken: 'token',
        tokenType: 'Bearer',
        expiresIn: 3600,
        obtainedAt: DateTime.utc(2026, 1, 1),
      ),
    );
  }

  @override
  Future<DeviceAuthInfo> startDeviceAuth() {
    throw UnimplementedError();
  }
}
