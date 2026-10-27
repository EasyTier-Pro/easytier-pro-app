import 'dart:async';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:easytier_pro_app/src/core/core_peer_status.dart';
import 'package:flutter_test/flutter_test.dart';

const source = ConsoleWorkspace(id: 'source', name: '个人');
const target = ConsoleWorkspace(id: 'target', name: '公司');
const networkA = ConsoleNetwork(
  id: 'a',
  name: '个人网络',
  runtimeNetworkName: 'nt-a',
);
const networkB = ConsoleNetwork(
  id: 'b',
  name: '公司网络',
  runtimeNetworkName: 'nt-b',
);

AuthSession session({
  List<ConsoleWorkspace> workspaces = const [source, target],
}) => AuthSession(
  user: ConsoleUser(
    id: 'account-1',
    email: 'test@example.com',
    displayName: 'Test',
    workspaces: workspaces,
  ),
  tokenSet: TokenSet(
    accessToken: 'access',
    tokenType: 'Bearer',
    expiresIn: 3600,
    obtainedAt: DateTime.now(),
  ),
);

void main() {
  test(
    'source binding and original key survive reordered workspaces and restart',
    () async {
      final auth = _Auth();
      final runtime = _Runtime();
      var core = CoreLifecycleService(
        authService: auth,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      await core.bindSession(session());
      await core.connectNetwork(source, networkA);
      await core.selectWorkspace(target.id);
      await core.dispose();

      final restoredRuntime = _Runtime();
      core = CoreLifecycleService(
        authService: auth,
        runtime: restoredRuntime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(core.dispose);
      await core.bindSession(session(workspaces: const [target, source]));
      expect(core.sourceWorkspaceId, source.id);
      expect(core.localDeviceId, 'canonical');
      expect(core.selectedWorkspaceId.value, target.id);
      expect(auth.bootstrapKeys, [null, 'original-key']);
      expect(auth.bootstrapWorkspaces, ['source', 'source']);
    },
  );

  test(
    'joining another workspace retains source and uses canonical device ID',
    () async {
      final auth = _Auth()..includeDuplicateMachine = true;
      final runtime = _Runtime();
      final core = CoreLifecycleService(
        authService: auth,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(core.dispose);
      await core.bindSession(session());
      await core.connectNetwork(source, networkA);
      await core.selectWorkspace(target.id);
      expect(auth.shares, isEmpty);
      await core.connectNetwork(target, networkB);
      expect(auth.shares, ['source/canonical/target']);
      expect(auth.attaches, ['source/a/canonical', 'target/b/canonical']);
      expect(core.networkConnections.value.keys, containsAll(['a', 'b']));
      expect(runtime.ensureCount, 1);
      expect(runtime.stopCount, 0);
      await core.disconnectNetwork(source, networkA);
      expect(core.networkConnections.value.keys, ['b']);
      expect(runtime.running, contains('nt-b'));
    },
  );

  test('target approval is independent of the approved source', () async {
    final auth = _Auth()..targetApproved = false;
    final core = CoreLifecycleService(
      authService: auth,
      runtime: _Runtime(),
      engineVersionCheckInterval: Duration.zero,
    );
    addTearDown(core.dispose);
    await core.bindSession(session());
    await expectLater(
      core.connectNetwork(target, networkB),
      throwsA(isA<AuthException>()),
    );
    expect(auth.shares, hasLength(1));
    expect(auth.attaches, isEmpty);
    expect(core.networkConnections.value['b']?.message, contains('尚未批准'));
    auth.targetApproved = true;
    await core.connectNetwork(target, networkB);
    expect(auth.shares, hasLength(1));
    expect(auth.attaches, ['target/b/canonical']);
  });

  test(
    'workspace switch during connection keeps the operation in its original workspace',
    () async {
      final auth = _Auth()..attachGate = Completer<void>();
      final core = CoreLifecycleService(
        authService: auth,
        runtime: _Runtime(),
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(core.dispose);
      await core.bindSession(session());
      final connecting = core.connectNetwork(source, networkA);
      await Future<void>.delayed(Duration.zero);
      await core.selectWorkspace(target.id);
      expect(
        core.networkConnections.value['a']?.phase,
        CoreNetworkConnectionPhase.joining,
      );
      auth.attachGate!.complete();
      await connecting;
      expect(core.selectedWorkspaceId.value, target.id);
      expect(auth.attaches, ['source/a/canonical']);
      expect(core.networkConnections.value['a']?.workspace.id, source.id);
    },
  );

  test(
    'logout fences a pending connection without reviving its state',
    () async {
      final auth = _Auth()..attachGate = Completer<void>();
      final runtime = _Runtime();
      final core = CoreLifecycleService(
        authService: auth,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(core.dispose);
      await core.bindSession(session());
      final connecting = core.connectNetwork(source, networkA);
      final expectation = expectLater(
        connecting,
        throwsA(isA<AuthException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await core.onLogout();
      auth.attachGate!.complete();
      await expectation;
      expect(core.networkConnections.value, isEmpty);
      expect(runtime.waitCount, 0);
      expect(runtime.stopCount, 1);
    },
  );

  test(
    'Console node removal clears only the affected workspace connection',
    () async {
      final auth = _Auth();
      final runtime = _Runtime();
      final core = CoreLifecycleService(
        authService: auth,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(core.dispose);
      await core.bindSession(session());
      await core.connectNetwork(source, networkA);
      await core.connectNetwork(target, networkB);
      // Revoking the target grant removes its projected Node, even if a native
      // readiness sample still reflects the old instance.
      auth.shared = false;
      auth.nodes['b'] = [];
      await core.fetchWorkspaceNetworkDevices(target, networkB);
      expect(core.networkConnections.value.keys, ['a']);
      expect(core.networkConnections.value['a']?.ready, isTrue);
      expect(runtime.stopCount, 0);
    },
  );

  test('Console network removal clears only that workspace summary', () async {
    final auth = _Auth();
    final core = CoreLifecycleService(
      authService: auth,
      runtime: _Runtime(),
      engineVersionCheckInterval: Duration.zero,
    );
    addTearDown(core.dispose);
    await core.bindSession(session());
    await core.connectNetwork(source, networkA);
    await core.connectNetwork(target, networkB);
    auth.networks['target'] = [];
    expect(await core.fetchWorkspaceNetworks(target), isEmpty);
    expect(core.networkConnections.value.keys, ['a']);
  });

  test('stale node read cannot revive a completed disconnect', () async {
    final auth = _Auth();
    final core = CoreLifecycleService(
      authService: auth,
      runtime: _Runtime(),
      engineVersionCheckInterval: Duration.zero,
    );
    addTearDown(core.dispose);
    await core.bindSession(session());
    await core.connectNetwork(source, networkA);
    final gate = Completer<void>();
    auth.nodeReadGate = gate;
    final stale = core.fetchWorkspaceNetworkDevices(source, networkA);
    await core.disconnectNetwork(source, networkA);
    gate.complete();
    expect(await stale, isNull);
    expect(core.networkConnections.value, isEmpty);
  });

  test('stale network list cannot erase a newly completed join', () async {
    final auth = _Auth()..networks['target'] = [];
    final core = CoreLifecycleService(
      authService: auth,
      runtime: _Runtime(),
      engineVersionCheckInterval: Duration.zero,
    );
    addTearDown(core.dispose);
    await core.bindSession(session());
    final gate = Completer<void>();
    auth.networkReadGate = gate;
    final stale = core.fetchWorkspaceNetworks(target);
    await core.connectNetwork(target, networkB);
    gate.complete();
    await stale;
    expect(core.networkConnections.value.keys, ['b']);
  });

  test(
    'ordinary Console and readiness reads preserve an attached instance error',
    () async {
      final auth = _Auth();
      final runtime = _Runtime();
      final core = CoreLifecycleService(
        authService: auth,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(core.dispose);
      await core.bindSession(session());
      await core.connectNetwork(source, networkA);
      runtime.waitError = StateError('route conflict');
      await expectLater(
        core.connectNetwork(target, networkB),
        throwsStateError,
      );
      final error = core.networkConnections.value['b'];
      expect(error?.nodeId, 'node-b');
      await core.fetchWorkspaceNetworkDevices(target, networkB);
      await core.refreshWorkspaceConnections(target, [networkB]);
      core.updateNetworkReadiness('b', false);
      expect(core.networkConnections.value['b'], same(error));
      expect(core.networkConnections.value['a']?.ready, isTrue);
    },
  );
}

class _Auth extends Fake implements AuthService {
  WorkspacePreferences preferences = const WorkspacePreferences();
  final bootstrapKeys = <String?>[];
  final bootstrapWorkspaces = <String>[];
  final shares = <String>[];
  final attaches = <String>[];
  final nodes = <String, List<NetworkDevice>>{};
  final networks = <String, List<ConsoleNetwork>>{
    'source': [networkA],
    'target': [networkB],
  };
  bool shared = false;
  bool targetApproved = true;
  bool includeDuplicateMachine = false;
  Completer<void>? attachGate;
  Completer<void>? nodeReadGate;
  Completer<void>? networkReadGate;

  @override
  Future<List<ConsoleNetwork>> fetchNetworks({
    required String accessToken,
    required String workspaceId,
  }) async {
    final result = List<ConsoleNetwork>.of(networks[workspaceId] ?? []);
    final gate = networkReadGate;
    networkReadGate = null;
    await gate?.future;
    return result;
  }

  @override
  Future<WorkspacePreferences> loadWorkspacePreferences(
    String accountId,
  ) async => preferences;
  @override
  Future<void> saveWorkspacePreferences(
    String accountId,
    WorkspacePreferences value,
  ) async {
    preferences = value;
  }

  @override
  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
    String? enrollmentKeyId,
  }) async {
    bootstrapKeys.add(enrollmentKeyId);
    bootstrapWorkspaces.add(workspaceId);
    return const CoreBootstrapConfig(
      bootstrapToken: 'secret',
      version: 'v2.6.4',
      configServer: 'tcp://test:22020',
      enrollmentKeyId: 'original-key',
    );
  }

  @override
  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  }) async => [
    if (workspaceId == 'source' || shared)
      ManagedDevice(
        id: 'canonical',
        machineId: 'machine',
        hostname: 'test',
        workspaceId: 'source',
        enrollmentKeyId: workspaceId == 'source' ? 'original-key' : null,
        approvalState: 'approved',
        connectivityState: 'online',
        workspaceApprovalState: workspaceId == 'source'
            ? null
            : targetApproved
            ? 'approved'
            : 'pending',
        canManageNodes: workspaceId == 'source' || targetApproved,
      ),
    if (workspaceId == 'target' && includeDuplicateMachine)
      const ManagedDevice(
        id: 'other-record',
        machineId: 'machine',
        hostname: 'old',
        workspaceId: 'target',
        approvalState: 'approved',
        connectivityState: 'offline',
      ),
  ];
  @override
  Future<void> authorizeDeviceWorkspace({
    required String accessToken,
    required String sourceWorkspaceId,
    required String deviceId,
    required String targetWorkspaceId,
  }) async {
    shares.add('$sourceWorkspaceId/$deviceId/$targetWorkspaceId');
    shared = true;
  }

  @override
  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    final result = List<NetworkDevice>.of(nodes[networkId] ?? []);
    final gate = nodeReadGate;
    nodeReadGate = null;
    await gate?.future;
    return result;
  }

  @override
  Future<AttachNetworkResult> attachDeviceToNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
    required String deviceId,
  }) async {
    await attachGate?.future;
    attaches.add('$workspaceId/$networkId/$deviceId');
    nodes[networkId] = [
      NetworkDevice(
        id: 'node-$networkId',
        name: networkId,
        online: true,
        deviceId: deviceId,
        machineId: 'machine',
        instanceId: 'instance-$networkId',
        ipv4: '10.1.0.2',
      ),
    ];
    return AttachNetworkResult(nodeId: 'node-$networkId');
  }

  @override
  Future<void> removeNetworkNode({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  }) async {
    for (final list in nodes.values) {
      list.removeWhere((node) => node.id == nodeId);
    }
  }
}

class _Runtime extends CorePlatformRuntime {
  int ensureCount = 0;
  int stopCount = 0;
  int waitCount = 0;
  final running = <String>{};
  Object? waitError;
  @override
  Future<CoreRuntimeStartResult?> readStatus(
    CoreBootstrapConfig bootstrap,
  ) async => null;
  @override
  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  }) async {
    ensureCount++;
    return const CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: 'Ready',
      machineId: 'machine',
      coreVersion: 'v2.6.4',
    );
  }

  @override
  Future<void> stop() async {
    stopCount++;
    running.clear();
  }

  @override
  Future<String?> waitForNetworkConnection(
    String runtimeNetworkName, {
    required Future<String?> Function() readInstanceId,
  }) async {
    waitCount++;
    expect(await readInstanceId(), isNotNull);
    if (waitError != null) throw waitError!;
    running.add(runtimeNetworkName);
    return '10.1.0.2';
  }

  @override
  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async =>
      running.contains(runtimeNetworkName);
  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async => {};
  @override
  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async => {};
}
