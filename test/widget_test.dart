import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'package:easytier_pro_app/main.dart';
import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/desktop/tray_support.dart';

void main() {
  testWidgets('shows logged in console state when credentials exist', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MyApp(authService: _FakeAuthService(), traySupport: createTraySupport()),
    );
    await tester.pumpAndSettle();

    expect(find.text('EasyTier Pro'), findsWidgets);
    expect(find.text('概览'), findsWidgets);
    expect(find.text('网络'), findsWidgets);
    expect(find.text('节点'), findsWidgets);
    expect(find.text('服务'), findsWidgets);
    expect(find.text('网络 1'), findsOneWidget);
    expect(find.text('设备 1'), findsOneWidget);
    expect(find.text('在线 1'), findsOneWidget);
    expect(find.text('办公网'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '网络'));
    await tester.pumpAndSettle();

    expect(find.text('所有网络'), findsOneWidget);
    expect(find.text('1 / 1 台设备在线'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '节点'));
    await tester.pumpAndSettle();

    expect(find.text('节点列表'), findsOneWidget);
    expect(find.text('办公室网关'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '网络'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('办公网'));
    await tester.pumpAndSettle();

    expect(find.text('所有网络'), findsOneWidget);
    expect(find.widgetWithText(FButton, '关闭'), findsOneWidget);
    expect(find.text('设备列表'), findsOneWidget);
    expect(find.text('办公室网关'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '关闭'));
    await tester.pumpAndSettle();

    expect(find.text('设备列表'), findsNothing);
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
        workspaces: <ConsoleWorkspace>[
          ConsoleWorkspace(id: 'tenant-1', name: '个人空间'),
        ],
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

  @override
  Future<List<ConsoleNetwork>> fetchNetworks({
    required String accessToken,
    required String workspaceId,
  }) async {
    return const <ConsoleNetwork>[ConsoleNetwork(id: 'net-1', name: '办公网')];
  }

  @override
  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    return const <NetworkDevice>[
      NetworkDevice(
        id: 'node-1',
        name: '办公室网关',
        online: true,
        ipv4: '10.10.0.1',
      ),
    ];
  }
}
