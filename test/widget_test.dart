import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:easytier_pro_app/main.dart';
import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:easytier_pro_app/src/desktop/tray_support.dart';

void main() {
  testWidgets('starts core after login and joins networks independently', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
        ConsoleNetwork(id: 'net-2', name: '研发网', regions: ['ap-east']),
      ],
      managedDevices: const <ManagedDevice>[
        ManagedDevice(
          id: 'device-1',
          machineId: 'machine-1',
          hostname: 'desktop-1',
          approvalState: 'approved',
          connectivityState: 'online',
        ),
      ],
    );

    await tester.pumpWidget(
      MyApp(
        authService: authService,
        traySupport: createTraySupport(),
        coreLifecycleService: _NoopCoreLifecycleService(
          authService: authService,
          machineId: 'machine-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本机设备已就绪'), findsOneWidget);
    expect(find.text('办公网'), findsOneWidget);
    expect(find.text('研发网'), findsOneWidget);
    expect(find.widgetWithText(FButton, '加入'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(FButton, '加入').first);
    await tester.pumpAndSettle();

    expect(authService.attachedNetworkIds, <String>['net-1']);
    expect(find.text('已加入'), findsWidgets);
    expect(find.text('本机 IP 10.144.0.2'), findsOneWidget);
    expect(find.widgetWithText(FButton, '加入'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '加入').first);
    await tester.pumpAndSettle();

    expect(authService.attachedNetworkIds, <String>['net-1', 'net-2']);
    expect(find.text('本机 IP 10.145.0.2'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '退出').first);
    await tester.pumpAndSettle();

    expect(authService.removedNodeIds, <String>['node-1']);
    expect(find.text('本机 IP 10.144.0.2'), findsNothing);
    expect(find.widgetWithText(FButton, '加入'), findsOneWidget);
    expect(find.widgetWithText(FButton, '退出'), findsOneWidget);
  });

  testWidgets('shows create network flow when workspace has no networks', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService();
    await tester.pumpWidget(
      MyApp(
        authService: authService,
        traySupport: createTraySupport(),
        coreLifecycleService: _NoopCoreLifecycleService(
          authService: authService,
          machineId: 'machine-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('创建第一个网络'), findsOneWidget);
    expect(find.text('网络名称'), findsOneWidget);
    expect(find.text('区域'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '创建网络'));
    await tester.pumpAndSettle();

    expect(authService.createdNetworkNames, <String>['我的网络']);
    expect(find.text('我的网络'), findsOneWidget);
    expect(find.widgetWithText(FButton, '加入'), findsOneWidget);
  });

  testWidgets('shows approval blocker before attaching a device', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
      ],
      managedDevices: const <ManagedDevice>[
        ManagedDevice(
          id: 'device-1',
          machineId: 'machine-1',
          hostname: 'desktop-1',
          approvalState: 'pending',
          connectivityState: 'online',
        ),
      ],
    );
    await tester.pumpWidget(
      MyApp(
        authService: authService,
        traySupport: createTraySupport(),
        coreLifecycleService: _NoopCoreLifecycleService(
          authService: authService,
          machineId: 'machine-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FButton, '加入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('尚未批准'), findsOneWidget);
    expect(authService.attachedNetworkIds, isEmpty);
  });

  test('parses installer machine_id from finished event', () {
    final machineId = CoreLifecycleService.parseMachineIdFromDesktopEvent(
      const <String, dynamic>{
        'event': 'finished',
        'data': <String, dynamic>{'machine_id': 'machine-1'},
      },
    );

    expect(machineId, 'machine-1');
  });

  test('console service decodes regions and managed devices', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final service = ConsoleAuthService(
      tokenStore: OAuthTokenStore(preferences),
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/regions') {
          return _jsonResponse({
            'regions': [
              {
                'id': 'region-1',
                'code': 'ap-east',
                'display_name': '华东',
                'status': 'active',
              },
            ],
          });
        }
        if (request.url.path == '/api/v1/tenants/tenant-1/devices') {
          return _jsonResponse([
            {
              'id': 'device-1',
              'machine_id': 'machine-1',
              'hostname': 'desktop-1',
              'approval_state': 'approved',
              'connectivity_state': 'online',
            },
          ]);
        }
        return http.Response('{}', 404);
      }),
    );

    final regions = await service.fetchRegions(accessToken: 'token');
    final devices = await service.fetchManagedDevices(
      accessToken: 'token',
      workspaceId: 'tenant-1',
    );

    expect(regions.single.code, 'ap-east');
    expect(regions.single.active, isTrue);
    expect(devices.single.machineId, 'machine-1');
    expect(devices.single.approved, isTrue);
    expect(devices.single.online, isTrue);
  });

  test(
    'create network and attach device use tenant scoped console API',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final service = ConsoleAuthService(
        tokenStore: OAuthTokenStore(preferences),
        consoleBaseUrl: 'https://console.test',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/v1/tenants/tenant-1/networks') {
            return _jsonResponse({
              'id': 'net-1',
              'name': '我的网络',
              'regions': ['ap-east'],
            }, 201);
          }
          if (request.url.path ==
              '/api/v1/tenants/tenant-1/networks/net-1/nodes') {
            return _jsonResponse({
              'resource': {'id': 'node-1'},
              'operation': {'id': 'op-1'},
            }, 201);
          }
          if (request.url.path ==
              '/api/v1/tenants/tenant-1/nodes/node-1/remove') {
            return _jsonResponse({
              'resource': {'id': 'node-1'},
              'operation': {'id': 'op-2'},
            });
          }
          return http.Response('{}', 404);
        }),
      );

      final network = await service.createNetwork(
        accessToken: 'token',
        workspaceId: 'tenant-1',
        name: '我的网络',
        regions: const ['ap-east'],
      );
      final attach = await service.attachDeviceToNetwork(
        accessToken: 'token',
        workspaceId: 'tenant-1',
        networkId: 'net-1',
        deviceId: 'device-1',
      );
      await service.removeNetworkNode(
        accessToken: 'token',
        workspaceId: 'tenant-1',
        nodeId: 'node-1',
      );

      expect(network.id, 'net-1');
      expect(attach.nodeId, 'node-1');
      expect(attach.operationId, 'op-1');
      expect(requests[0].method, 'POST');
      expect(requests[0].url.path, '/api/v1/tenants/tenant-1/networks');
      expect(jsonDecode(requests[0].body), <String, Object>{
        'name': '我的网络',
        'regions': ['ap-east'],
      });
      expect(
        requests[1].url.path,
        '/api/v1/tenants/tenant-1/networks/net-1/nodes',
      );
      expect(jsonDecode(requests[1].body), <String, Object>{
        'device_id': 'device-1',
      });
      expect(requests[2].method, 'POST');
      expect(
        requests[2].url.path,
        '/api/v1/tenants/tenant-1/nodes/node-1/remove',
      );
    },
  );
}

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

http.Response _jsonResponse(Object body, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

class _FakeAuthService implements AuthService {
  _FakeAuthService({
    List<ConsoleNetwork> networks = const <ConsoleNetwork>[],
    this.managedDevices = const <ManagedDevice>[],
    Map<String, List<NetworkDevice>> networkDevices =
        const <String, List<NetworkDevice>>{},
  }) : networks = List<ConsoleNetwork>.of(networks),
       networkDevices = Map<String, List<NetworkDevice>>.from(networkDevices);

  final List<ConsoleNetwork> networks;
  final List<ManagedDevice> managedDevices;
  final Map<String, List<NetworkDevice>> networkDevices;
  final List<String> attachedNetworkIds = <String>[];
  final List<String> removedNodeIds = <String>[];
  final List<String> createdNetworkNames = <String>[];

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
    return List<ConsoleNetwork>.unmodifiable(networks);
  }

  @override
  Future<List<ConsoleRegion>> fetchRegions({
    required String accessToken,
  }) async {
    return const <ConsoleRegion>[
      ConsoleRegion(
        id: 'region-1',
        code: 'ap-east',
        displayName: '华东',
        status: 'active',
      ),
    ];
  }

  @override
  Future<ConsoleNetwork> createNetwork({
    required String accessToken,
    required String workspaceId,
    required String name,
    required List<String> regions,
  }) async {
    createdNetworkNames.add(name);
    final network = ConsoleNetwork(
      id: 'net-${networks.length + 1}',
      name: name,
      regions: regions,
    );
    networks.add(network);
    networkDevices[network.id] = const <NetworkDevice>[];
    return network;
  }

  @override
  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    return List<NetworkDevice>.unmodifiable(
      networkDevices[networkId] ?? const <NetworkDevice>[],
    );
  }

  @override
  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  }) async {
    return List<ManagedDevice>.unmodifiable(managedDevices);
  }

  @override
  Future<AttachNetworkResult> attachDeviceToNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
    required String deviceId,
  }) async {
    attachedNetworkIds.add(networkId);
    final device = managedDevices.firstWhere((item) => item.id == deviceId);
    networkDevices[networkId] = <NetworkDevice>[
      ...(networkDevices[networkId] ?? const <NetworkDevice>[]),
      NetworkDevice(
        id: 'node-${networkId.substring(networkId.length - 1)}',
        name: device.hostname,
        online: true,
        ipv4: networkId == 'net-1' ? '10.144.0.2' : '10.145.0.2',
        deviceId: device.id,
        machineId: device.machineId,
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
    removedNodeIds.add(nodeId);
    for (final entry in networkDevices.entries.toList()) {
      networkDevices[entry.key] = entry.value
          .where((device) => device.id != nodeId)
          .toList(growable: false);
    }
  }

  @override
  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
  }) async {
    return const CoreBootstrapConfig(
      bootstrapToken: 'bootstrap-token',
      version: 'v1.0.0',
      configServer: 'tcp://api.console.easytier.net:22020',
    );
  }
}

class _NoopCoreLifecycleService extends CoreLifecycleService {
  _NoopCoreLifecycleService({
    required super.authService,
    required this.machineId,
  });

  final String? machineId;

  @override
  Future<void> bindSession(AuthSession session) async {
    status.value = CoreRunStatus(
      phase: CoreRunPhase.running,
      message: '本机设备已就绪',
      machineId: machineId,
    );
  }

  @override
  Future<void> onLogout() async {
    status.value = CoreRunStatus.signedOut;
  }

  @override
  Future<void> repair() async {
    status.value = CoreRunStatus(
      phase: CoreRunPhase.running,
      message: '本机设备已就绪',
      machineId: machineId,
    );
  }
}
