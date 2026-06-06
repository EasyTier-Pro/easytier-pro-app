import 'dart:async';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_peer_status.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CoreLifecycleService workspace binding', () {
    test('forces runtime reinstall when workspace changes', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      await service.bindSession(_session('tenant-2'));

      expect(authService.workspaceIds, ['tenant-1', 'tenant-2']);
      expect(runtime.ensureRunningCount, 2);
      expect(runtime.forceReinstallValues, [false, true]);
      expect(runtime.readStatusCount, 1);
      expect(service.status.value.phase, CoreRunPhase.running);
    });

    test('stops runtime when active session loses workspace', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      await service.bindSession(_sessionWithoutWorkspace());

      expect(authService.workspaceIds, ['tenant-1']);
      expect(runtime.stopCount, 1);
      expect(runtime.ensureRunningCount, 1);
      expect(service.status.value.phase, CoreRunPhase.error);
      expect(service.status.value.message, '当前账号未绑定工作区');
    });
  });

  group('CoreLifecycleService auth invalidation', () {
    test('stops runtime when local token has expired', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      await service.bindSession(_expiredSession('tenant-1'));

      expect(runtime.stopCount, 1);
      expect(runtime.ensureRunningCount, 1);
      expect(authService.workspaceIds, ['tenant-1']);
      expect(service.status.value.phase, CoreRunPhase.error);
      expect(service.status.value.message, '登录态已失效，连接已停止');
    });

    test('stops runtime when bootstrap reports invalid auth', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      authService.bootstrapError = const AuthException('当前登录态已失效，请重新登录。');
      await service.bindSession(_session('tenant-1'));

      expect(runtime.stopCount, 1);
      expect(runtime.ensureRunningCount, 1);
      expect(authService.prepareBootstrapCount, 2);
      expect(service.status.value.phase, CoreRunPhase.error);
      expect(service.status.value.message, '登录态已失效，连接已停止');
    });
  });

  group('CoreLifecycleService runtime events', () {
    test(
      'reconnects when config server stops while session is active',
      () async {
        final authService = _LifecycleAuthService();
        final runtime = _LifecycleRuntime();
        final service = CoreLifecycleService(
          authService: authService,
          runtime: runtime,
        );
        addTearDown(service.dispose);

        await service.bindSession(_session('tenant-1'));
        expect(runtime.ensureRunningCount, 1);
        expect(service.status.value.phase, CoreRunPhase.running);

        runtime.connected = false;
        runtime.emit(
          const CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.configServerStopped,
          ),
        );

        await _waitUntil(() => runtime.ensureRunningCount == 2);
        expect(authService.prepareBootstrapCount, 2);
        expect(runtime.forceReinstallValues, [false, false]);
        expect(service.status.value.phase, CoreRunPhase.running);
      },
    );

    test('does not reconnect after logout cleanup stops runtime', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      await service.onLogout();

      runtime.emit(
        const CoreRuntimeEvent(type: CoreRuntimeEventTypes.configServerStopped),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(runtime.ensureRunningCount, 1);
      expect(runtime.stopCount, 1);
      expect(service.status.value.phase, CoreRunPhase.signedOut);
    });

    test(
      'does not reconnect after Android runtime is intentionally stopped',
      () async {
        final authService = _LifecycleAuthService();
        final runtime = _LifecycleRuntime();
        final service = CoreLifecycleService(
          authService: authService,
          runtime: runtime,
        );
        addTearDown(service.dispose);

        await service.bindSession(_session('tenant-1'));
        runtime.connected = false;
        runtime.emit(
          const CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.configServerStopped,
            data: {
              'payload': {'reason': 'user_disconnect'},
            },
          ),
        );

        await _waitUntil(
          () => service.status.value.phase == CoreRunPhase.stopped,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(runtime.ensureRunningCount, 1);
        expect(service.status.value.message, '连接已断开');
        expect(service.status.value.machineId, 'machine-1');
      },
    );

    test('restores running status when Android VPN recovers', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      runtime.emit(
        const CoreRuntimeEvent(
          type: CoreRuntimeEventTypes.error,
          data: {'error': 'Android VPN route setup failed'},
        ),
      );
      await _waitUntil(() => service.status.value.phase == CoreRunPhase.error);

      runtime.emit(
        const CoreRuntimeEvent(
          type: CoreRuntimeEventTypes.vpnStarted,
          data: {
            'payload': {
              'instanceName': 'network-a',
              'routes': ['10.10.0.0/24'],
            },
          },
        ),
      );
      await _waitUntil(
        () => service.status.value.phase == CoreRunPhase.running,
      );

      expect(service.status.value.message, 'Android 连接引擎运行中');
      expect(service.status.value.machineId, 'machine-1');
      expect(service.status.value.details, 'EasyTier 2.6.4');
    });

    test(
      'does not restore running status until Android VPN is established',
      () async {
        final authService = _LifecycleAuthService();
        final runtime = _LifecycleRuntime();
        final service = CoreLifecycleService(
          authService: authService,
          runtime: runtime,
        );
        addTearDown(service.dispose);

        await service.bindSession(_session('tenant-1'));
        runtime.emit(
          const CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.error,
            data: {'error': 'Android VPN route setup failed'},
          ),
        );
        await _waitUntil(
          () => service.status.value.phase == CoreRunPhase.error,
        );

        runtime.emit(
          const CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.vpnConfigRefreshed,
            data: {
              'instance_name': 'network-a',
              'routes': ['10.10.0.0/24'],
            },
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(service.status.value.phase, CoreRunPhase.error);

        runtime.emit(
          const CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.vpnStarted,
            data: {
              'payload': {
                'instanceName': 'network-a',
                'routes': ['10.10.0.0/24'],
              },
            },
          ),
        );
        await _waitUntil(
          () => service.status.value.phase == CoreRunPhase.running,
        );
      },
    );
  });
}

AuthSession _session(String workspaceId) {
  return AuthSession(
    user: ConsoleUser(
      email: 'tester@example.com',
      displayName: 'Tester',
      workspaces: <ConsoleWorkspace>[
        ConsoleWorkspace(id: workspaceId, name: '测试工作区'),
      ],
    ),
    tokenSet: TokenSet(
      accessToken: 'access-token',
      tokenType: 'Bearer',
      expiresIn: 3600,
      obtainedAt: DateTime.now().toUtc(),
    ),
  );
}

AuthSession _sessionWithoutWorkspace() {
  return AuthSession(
    user: const ConsoleUser(
      email: 'tester@example.com',
      displayName: 'Tester',
      workspaces: <ConsoleWorkspace>[],
    ),
    tokenSet: TokenSet(
      accessToken: 'access-token',
      tokenType: 'Bearer',
      expiresIn: 3600,
      obtainedAt: DateTime.now().toUtc(),
    ),
  );
}

AuthSession _expiredSession(String workspaceId) {
  return AuthSession(
    user: ConsoleUser(
      email: 'tester@example.com',
      displayName: 'Tester',
      workspaces: <ConsoleWorkspace>[
        ConsoleWorkspace(id: workspaceId, name: '测试工作区'),
      ],
    ),
    tokenSet: TokenSet(
      accessToken: 'expired-token',
      tokenType: 'Bearer',
      expiresIn: 1,
      obtainedAt: DateTime.utc(2000, 1, 1),
    ),
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition');
}

class _LifecycleRuntime extends CorePlatformRuntime {
  final StreamController<CoreRuntimeEvent> _events =
      StreamController<CoreRuntimeEvent>.broadcast();

  var connected = false;
  var ensureRunningCount = 0;
  var readStatusCount = 0;
  var stopCount = 0;
  final forceReinstallValues = <bool>[];

  @override
  Stream<CoreRuntimeEvent> get events => _events.stream;

  void emit(CoreRuntimeEvent event) {
    _events.add(event);
  }

  @override
  Future<CoreRuntimeStartResult?> readStatus(
    CoreBootstrapConfig bootstrap,
  ) async {
    readStatusCount++;
    if (!connected) {
      return null;
    }
    return const CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: '连接引擎运行中',
      machineId: 'machine-1',
      details: 'EasyTier 2.6.4',
    );
  }

  @override
  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  }) async {
    ensureRunningCount++;
    forceReinstallValues.add(forceReinstall);
    connected = true;
    return const CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: '连接引擎运行中',
      machineId: 'machine-1',
      details: 'EasyTier 2.6.4',
    );
  }

  @override
  Future<void> stop() async {
    stopCount++;
    connected = false;
  }

  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    return const <String, CoreNetworkTrafficTotals>{};
  }

  @override
  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    return false;
  }

  @override
  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async {
    return const <String, CorePeerStatus>{};
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

class _LifecycleAuthService implements AuthService {
  var prepareBootstrapCount = 0;
  Object? bootstrapError;
  final workspaceIds = <String>[];

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<DeviceAuthInfo> startDeviceAuth() {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> completeDeviceAuth(DeviceAuthInfo info) {
    throw UnimplementedError();
  }

  @override
  Future<List<ConsoleNetwork>> fetchNetworks({
    required String accessToken,
    required String workspaceId,
  }) async {
    return const <ConsoleNetwork>[];
  }

  @override
  Future<List<ConsoleRegion>> fetchRegions({
    required String accessToken,
  }) async {
    return const <ConsoleRegion>[];
  }

  @override
  Future<ConsoleNetwork> createNetwork({
    required String accessToken,
    required String workspaceId,
    required String name,
    required List<String> regions,
    String? ipv4Cidr,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    return const <NetworkDevice>[];
  }

  @override
  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  }) async {
    return const <ManagedDevice>[];
  }

  @override
  Future<AttachNetworkResult> attachDeviceToNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
    required String deviceId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeNetworkNode({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
  }) async {
    prepareBootstrapCount++;
    workspaceIds.add(workspaceId);
    final error = bootstrapError;
    if (error != null) {
      throw error;
    }
    return const CoreBootstrapConfig(
      bootstrapToken: 'bootstrap-token',
      version: '2.6.4',
      configServer: 'tcp://127.0.0.1:22020',
    );
  }

  @override
  Future<void> logout() async {}
}
