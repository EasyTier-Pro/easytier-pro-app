import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
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

    expect(find.text('已在线'), findsOneWidget);
    expect(find.textContaining('尚未加入网络'), findsOneWidget);
    expect(find.text('办公网'), findsNWidgets(2));
    expect(find.text('研发网'), findsOneWidget);
    expect(find.byType(FSwitch), findsNWidgets(2));

    await tester.tap(find.byType(FSwitch).first);
    await tester.pumpAndSettle();

    expect(authService.attachedNetworkIds, <String>['net-1']);
    expect(find.textContaining('1 个网络'), findsOneWidget);
    expect(find.textContaining('10.144.0.2'), findsOneWidget);
    expect(find.byType(FSwitch), findsNWidgets(2));

    await tester.tap(find.byType(FSwitch).at(1));
    await tester.pumpAndSettle();

    expect(authService.attachedNetworkIds, <String>['net-1', 'net-2']);
    expect(find.textContaining('10.145.0.2'), findsOneWidget);

    await tester.tap(find.byType(FSwitch).first);
    await tester.pumpAndSettle();

    expect(authService.removedNodeIds, <String>['node-1']);
    expect(find.textContaining('10.144.0.2'), findsNothing);
    expect(find.byType(FSwitch), findsNWidgets(2));
  });

  testWidgets('shows realtime traffic after joining a network', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(
          id: 'net-1',
          name: '办公网',
          regions: ['ap-east'],
          runtimeNetworkName: 'nt-office',
        ),
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
    final coreLifecycleService = _NoopCoreLifecycleService(
      authService: authService,
      machineId: 'machine-1',
      trafficSamples: <Map<String, CoreNetworkTrafficTotals>>[
        {
          'nt-office': CoreNetworkTrafficTotals(
            runtimeNetworkName: 'nt-office',
            downloadBytes: 1024,
            uploadBytes: 2048,
            sampledAt: DateTime.utc(2026, 1, 1),
          ),
        },
        {
          'nt-office': CoreNetworkTrafficTotals(
            runtimeNetworkName: 'nt-office',
            downloadBytes: 3072,
            uploadBytes: 6144,
            sampledAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
          ),
        },
      ],
    );

    await tester.pumpWidget(
      MyApp(
        authService: authService,
        traySupport: createTraySupport(),
        coreLifecycleService: coreLifecycleService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FSwitch).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('计算中'), findsNWidgets(2));

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.textContaining('1.00 KiB/s'), findsNWidgets(2));
    expect(find.textContaining('2.00 KiB/s'), findsNWidgets(2));

    await _selectNetworkFromHeader(tester, '办公网');

    expect(find.text('实时流量'), findsOneWidget);
    expect(find.text('累计流量'), findsOneWidget);
    expect(find.textContaining('1.00 KiB/s'), findsOneWidget);
    expect(find.textContaining('2.00 KiB/s'), findsOneWidget);
    expect(find.textContaining('下载 3.00 KiB / 上传 6.00 KiB'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('network detail sidebar stretches with window height', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(1600, 1200));

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
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
      networkDevices: const <String, List<NetworkDevice>>{
        'net-1': <NetworkDevice>[
          NetworkDevice(
            id: 'node-1',
            name: 'desktop-1',
            online: true,
            ipv4: '10.144.0.2',
            deviceId: 'device-1',
            machineId: 'machine-1',
          ),
        ],
      },
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

    await _selectNetworkFromHeader(tester, '办公网');

    final sidebarSize = tester.getSize(
      find.byKey(const ValueKey<String>('network-sidebar')),
    );
    expect(sidebarSize.height, greaterThan(800));
  });

  testWidgets('network detail device list scrolls when content overflows', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(1600, 700));

    final networkDevices = List<NetworkDevice>.generate(24, (index) {
      final number = index + 1;
      return NetworkDevice(
        id: 'node-$number',
        name: 'desktop-$number',
        online: index.isEven,
        ipv4: '10.144.0.${number + 1}',
        deviceId: 'device-$number',
        machineId: 'machine-$number',
      );
    });
    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
      ],
      managedDevices: <ManagedDevice>[
        for (var index = 0; index < networkDevices.length; index++)
          ManagedDevice(
            id: 'device-${index + 1}',
            machineId: 'machine-${index + 1}',
            hostname: 'desktop-${index + 1}',
            approvalState: 'approved',
            connectivityState: index.isEven ? 'online' : 'offline',
          ),
      ],
      networkDevices: <String, List<NetworkDevice>>{'net-1': networkDevices},
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

    await _selectNetworkFromHeader(tester, '办公网');

    final scrollView = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey<String>('network-device-list-scroll')),
    );
    expect(scrollView.controller?.position.maxScrollExtent, greaterThan(0));
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
    expect(find.text('网络地址范围'), findsOneWidget);
    expect(find.text('区域'), findsOneWidget);

    await tester.enterText(find.byType(FTextField).at(1), '10.200.0.0/16');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FButton, '创建网络'));
    await tester.pumpAndSettle();

    expect(authService.createdNetworkNames, <String>['我的网络']);
    expect(authService.createdNetworkIPv4Cidrs, <String?>['10.200.0.0/16']);
    expect(find.textContaining('尚未加入网络'), findsOneWidget);

    expect(find.text('我的网络'), findsNWidgets(2));
    expect(find.byType(FSwitch), findsOneWidget);
  });

  testWidgets('switches active network from header dropdown', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
        ConsoleNetwork(id: 'net-2', name: '研发网', regions: ['ap-east']),
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

    expect(
      find.byKey(const ValueKey<String>('network-tab-current')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('network-tab-dropdown')),
      findsOneWidget,
    );
    expect(find.text('办公网'), findsNWidgets(2));
    expect(find.text('研发网'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('network-tab-current')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('network-tab-popover')),
      findsNothing,
    );
    expect(find.text('研发网'), findsNothing);

    await _selectNetworkFromHeader(tester, '研发网');

    expect(find.text('研发网'), findsNWidgets(2));
    expect(find.text('办公网'), findsNothing);
  });

  testWidgets('keeps network tab width stable for short and long names', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    const longNetworkName = 'very-long-network-name-that-should-be-truncated';
    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-short', name: 'A', regions: ['ap-east']),
        ConsoleNetwork(
          id: 'net-long',
          name: longNetworkName,
          regions: ['ap-east'],
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

    var labelSize = tester.getSize(
      find.byKey(const ValueKey<String>('network-tab-label')),
    );
    expect(labelSize.width, greaterThanOrEqualTo(44));
    expect(labelSize.width, lessThan(72));

    await _selectNetworkFromHeader(tester, longNetworkName);

    labelSize = tester.getSize(
      find.byKey(const ValueKey<String>('network-tab-label')),
    );
    expect(labelSize.width, greaterThanOrEqualTo(44));
    expect(labelSize.width, lessThanOrEqualTo(112.1));
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

    await tester.tap(find.byType(FSwitch).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('尚未批准'), findsOneWidget);
    expect(authService.attachedNetworkIds, isEmpty);
  });

  testWidgets('shows workspace devices instead of single-network nodes', (
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
          approvalState: 'approved',
          connectivityState: 'online',
        ),
        ManagedDevice(
          id: 'device-2',
          machineId: 'machine-2',
          hostname: 'laptop-2',
          approvalState: 'pending',
          connectivityState: 'offline',
        ),
        ManagedDevice(
          id: 'device-removed',
          machineId: 'machine-removed',
          hostname: 'old-desktop',
          approvalState: 'removed',
          connectivityState: 'offline',
          lifecycleState: 'deleted',
          desiredState: 'absent',
        ),
      ],
      networkDevices: const <String, List<NetworkDevice>>{
        'net-1': <NetworkDevice>[
          NetworkDevice(
            id: 'node-1',
            name: 'node-alias',
            online: true,
            ipv4: '10.144.0.2',
            deviceId: 'device-1',
            machineId: 'machine-1',
          ),
        ],
      },
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

    await tester.tap(find.widgetWithText(FButton, '设备'));
    await tester.pumpAndSettle();

    expect(find.text('desktop-1'), findsOneWidget);
    expect(find.text('laptop-2'), findsOneWidget);
    expect(find.text('old-desktop'), findsNothing);
    expect(find.text('node-alias'), findsNothing);
    expect(find.text('1 / 2 台在线'), findsOneWidget);
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

  test('parses self traffic stats by runtime network name', () {
    final sampledAt = DateTime.utc(2026, 1, 1);
    final totals = CoreLifecycleService.parseNetworkTrafficTotalsFromJson(
      jsonEncode([
        {
          'name': 'traffic_bytes_self_rx',
          'value': 1024,
          'labels': {'network_name': 'nt-office'},
        },
        {
          'name': 'traffic_bytes_self_tx',
          'value': 2048,
          'labels': {'network_name': 'nt-office'},
        },
        {
          'name': 'traffic_control_bytes_rx',
          'value': 9999,
          'labels': {'network_name': 'nt-office'},
        },
        {
          'name': 'traffic_bytes_rx',
          'value': 9999,
          'labels': {'network_name': 'nt-office'},
        },
        {
          'name': 'traffic_bytes_self_rx',
          'value': 9999,
          'labels': {'network_name': '__access__'},
        },
      ]),
      sampledAt: sampledAt,
    );

    expect(totals.length, 1);
    expect(totals.containsKey('__access__'), isFalse);
    expect(totals['nt-office']?.downloadBytes, 1024);
    expect(totals['nt-office']?.uploadBytes, 2048);
    expect(totals['nt-office']?.sampledAt, sampledAt);
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
              'lifecycle_state': 'active',
              'desired_state': 'present',
            },
            {
              'id': 'device-removed',
              'machine_id': 'machine-removed',
              'hostname': 'old-desktop',
              'approval_state': 'removed',
              'connectivity_state': 'offline',
              'lifecycle_state': 'deleted',
              'desired_state': 'absent',
            },
            {
              'id': 'device-absent',
              'machine_id': 'machine-absent',
              'hostname': 'old-laptop',
              'approval_state': 'approved',
              'connectivity_state': 'offline',
              'lifecycle_state': 'active',
              'desired_state': 'absent',
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
    expect(devices.single.removed, isFalse);
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
              'network_name': 'nt-runtime',
              'ipv4_cidr': '10.200.0.0/16',
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
        ipv4Cidr: '10.200.0.0/16',
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
      expect(network.runtimeNetworkName, 'nt-runtime');
      expect(network.ipv4Cidr, '10.200.0.0/16');
      expect(attach.nodeId, 'node-1');
      expect(attach.operationId, 'op-1');
      expect(requests[0].method, 'POST');
      expect(requests[0].url.path, '/api/v1/tenants/tenant-1/networks');
      expect(jsonDecode(requests[0].body), <String, Object>{
        'name': '我的网络',
        'regions': ['ap-east'],
        'ipv4_cidr': '10.200.0.0/16',
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

void _useDesktopViewport(
  WidgetTester tester, {
  Size size = const Size(1600, 900),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _selectNetworkFromHeader(
  WidgetTester tester,
  String networkName,
) async {
  await tester.tap(find.byKey(const ValueKey<String>('network-tab-dropdown')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey<String>('network-tab-popover')),
      matching: find.text(networkName),
    ),
  );
  await tester.pumpAndSettle();
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
  final List<String?> createdNetworkIPv4Cidrs = <String?>[];

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
    String? ipv4Cidr,
  }) async {
    createdNetworkNames.add(name);
    createdNetworkIPv4Cidrs.add(ipv4Cidr);
    final network = ConsoleNetwork(
      id: 'net-${networks.length + 1}',
      name: name,
      regions: regions,
      ipv4Cidr: ipv4Cidr ?? '',
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
    this.trafficSamples = const <Map<String, CoreNetworkTrafficTotals>>[],
  });

  final String? machineId;
  final List<Map<String, CoreNetworkTrafficTotals>> trafficSamples;
  int _trafficReadCount = 0;

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

  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    if (trafficSamples.isEmpty) {
      return const <String, CoreNetworkTrafficTotals>{};
    }
    final sampleIndex = _trafficReadCount < trafficSamples.length
        ? _trafficReadCount
        : trafficSamples.length - 1;
    _trafficReadCount++;
    return trafficSamples[sampleIndex];
  }
}
