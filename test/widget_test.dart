import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:easytier_pro_app/main.dart';
import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_peer_status.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:easytier_pro_app/src/desktop/tray_support.dart';
import 'package:easytier_pro_app/src/shared/app_text_selection.dart';

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

    expect(find.textContaining('1.00 KiB/s'), findsOneWidget);
    expect(find.textContaining('2.00 KiB/s'), findsOneWidget);
    expect(find.textContaining('下载 3.00 KiB / 上传 6.00 KiB'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('network detail list stretches with window height', (
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

    expect(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
      findsOneWidget,
    );
    expect(find.text('desktop-1'), findsOneWidget);
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
        os: index.isEven ? 'windows' : 'linux',
        osDistribution: index.isEven ? 'Windows 11' : 'Ubuntu',
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
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
    );
    final controller = scrollView.controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));

    final beforeWheelOffset = controller.offset;
    final scrollFinder = find.byKey(
      const ValueKey<String>('network-node-list-scroll'),
    );
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(scrollFinder)),
    );
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 240)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.offset, greaterThan(beforeWheelOffset));

    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pump();
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(scrollFinder)),
    );
    final beforePrecisionOffset = controller.offset;
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 8)));
    await tester.pump();

    expect(controller.offset, greaterThan(beforePrecisionOffset + 8));

    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pump();
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(scrollFinder)),
    );
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -240)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.offset, controller.position.minScrollExtent);

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(scrollFinder)),
    );
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 240)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.offset, controller.position.maxScrollExtent);
  });

  testWidgets('network detail stacks safely in narrow windows', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(1200, 700));

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

    tester.view.physicalSize = const Size(360, 700);
    await _pumpAppMotionFrames(tester);

    expect(tester.takeException(), isNull);
    final listSize = tester.getSize(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
    );
    expect(listSize.width, closeTo(312, 0.1));
    expect(find.byTooltip('刷新节点'), findsOneWidget);
  });

  testWidgets('network detail remains stable before narrow width', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(760, 700));

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

    expect(tester.takeException(), isNull);
    final listSize = tester.getSize(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
    );
    expect(listSize.width, greaterThan(0));
    expect(listSize.width, lessThanOrEqualTo(712));
  });

  testWidgets('network detail enriches nodes with peer status', (
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
    final coreLifecycleService = _NoopCoreLifecycleService(
      authService: authService,
      machineId: 'machine-1',
      peerSamples: const <Map<String, CorePeerStatus>>[
        <String, CorePeerStatus>{
          '10.144.0.2': CorePeerStatus(
            cidr: '10.144.0.2/24',
            ipv4: '10.144.0.2',
            hostname: 'desktop-1',
            cost: 'p2p',
            latencyText: '3.45',
            lossText: '0.0%',
            rxBytes: '17.33 kB',
            txBytes: '20.42 kB',
            tunnelProto: 'udp',
            natType: 'FullCone',
            peerId: '390879727',
            version: '2.6.4',
          ),
          '10.144.0.99': CorePeerStatus(
            cidr: '10.144.0.99/24',
            ipv4: '10.144.0.99',
            hostname: 'peer-only',
            cost: 'p2p',
            latencyText: '1.00',
            lossText: '0.0%',
            rxBytes: '1 kB',
            txBytes: '1 kB',
            tunnelProto: 'udp',
            natType: 'FullCone',
            peerId: '999',
            version: '2.6.4',
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

    await _selectNetworkFromHeader(tester, '办公网');
    await _pumpAppMotionFrames(tester);

    expect(find.text('desktop-1'), findsOneWidget);
    expect(find.textContaining('P2P'), findsOneWidget);
    expect(find.textContaining('3.45 ms'), findsWidgets);
    expect(find.textContaining('Peer: 390879727'), findsOneWidget);
    expect(find.textContaining('Peer: 999'), findsNothing);
  });

  testWidgets('tapping selectable node text does not expand node card', (
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
    final coreLifecycleService = _NoopCoreLifecycleService(
      authService: authService,
      machineId: 'machine-1',
      peerSamples: const <Map<String, CorePeerStatus>>[
        <String, CorePeerStatus>{
          '10.144.0.2': CorePeerStatus(
            cidr: '10.144.0.2/24',
            ipv4: '10.144.0.2',
            hostname: 'desktop-1',
            cost: 'p2p',
            latencyText: '3.45',
            lossText: '0.0%',
            rxBytes: '17.33 kB',
            txBytes: '20.42 kB',
            tunnelProto: 'udp',
            natType: 'FullCone',
            peerId: '390879727',
            version: '2.6.4',
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

    await _selectNetworkFromHeader(tester, '办公网');
    await _pumpAppMotionFrames(tester);

    final cardFinder = find.byKey(
      const ValueKey<String>('network-node-node-1'),
    );
    final initialHeight = tester.getSize(cardFinder).height;

    final nodeNameRect = tester.getRect(find.text('desktop-1'));
    expect(_hasSelectionAreaAncestor(tester, find.text('desktop-1')), isTrue);
    expect(nodeNameRect.width, lessThan(tester.getSize(cardFinder).width / 3));
    appTextSelectionController.hasSelection.value = true;
    expect(appTextSelectionController.hasSelection.value, isTrue);

    await tester.tapAt(Offset(nodeNameRect.left + 24, nodeNameRect.center.dy));
    await _pumpAppMotionFrames(tester);

    expect(appTextSelectionController.hasSelection.value, isFalse);
    expect(tester.getSize(cardFinder).height, closeTo(initialHeight, 0.1));

    final cardRect = tester.getRect(cardFinder);
    await tester.tapAt(Offset(cardRect.right - 16, cardRect.top + 24));
    await _pumpAppMotionFrames(tester);

    expect(tester.getSize(cardFinder).height, greaterThan(initialHeight));
  });

  testWidgets('network detail keeps nodes visible when peer read fails', (
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
          peerError: StateError('peer unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _selectNetworkFromHeader(tester, '办公网');
    await _pumpAppMotionFrames(tester);

    expect(find.text('desktop-1'), findsOneWidget);
    expect(find.textContaining('运行态暂不可用'), findsOneWidget);
    expect(find.textContaining('运行态未知'), findsOneWidget);
  });

  testWidgets('refresh nodes reloads console nodes and peer status', (
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
    final coreLifecycleService = _NoopCoreLifecycleService(
      authService: authService,
      machineId: 'machine-1',
      peerSamples: const <Map<String, CorePeerStatus>>[
        <String, CorePeerStatus>{},
        <String, CorePeerStatus>{
          '10.144.0.2': CorePeerStatus(
            cidr: '10.144.0.2/24',
            ipv4: '10.144.0.2',
            hostname: 'desktop-1',
            cost: 'p2p',
            latencyText: '5.00',
            lossText: '0.0%',
            rxBytes: '1 kB',
            txBytes: '1 kB',
            tunnelProto: 'udp',
            natType: 'FullCone',
            peerId: '390879727',
            version: '2.6.4',
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

    await _selectNetworkFromHeader(tester, '办公网');
    await _pumpAppMotionFrames(tester);

    final nodeFetchCount = authService.networkDeviceFetchCount;
    final peerReadCount = coreLifecycleService.peerReadCount;

    await tester.tap(find.widgetWithText(FButton, '刷新节点'));
    await _pumpAppMotionFrames(tester);

    expect(authService.networkDeviceFetchCount, greaterThan(nodeFetchCount));
    expect(coreLifecycleService.peerReadCount, greaterThan(peerReadCount));
    expect(find.textContaining('P2P'), findsOneWidget);
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

  testWidgets('places network refresh control after create action', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
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

    final titleCenter = tester.getCenter(find.text('网络'));
    final refreshCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('network-refresh-button')),
    );
    final createCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('network-create-button')),
    );

    expect(refreshCenter.dx, greaterThan(titleCenter.dx));
    expect(refreshCenter.dx, greaterThan(createCenter.dx));
    expect((refreshCenter.dy - createCenter.dy).abs(), lessThanOrEqualTo(0.5));
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

    await tester.tap(find.byKey(const ValueKey<String>('network-tab-current')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('network-tab-popover')),
      findsOneWidget,
    );
    expect(find.text('研发网'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('network-tab-popover')),
        matching: find.text('研发网'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('研发网'), findsNWidgets(2));
    expect(find.text('办公网'), findsNothing);
  });

  testWidgets('navigation and dropdown labels are not selectable', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: 'Office', regions: ['ap-east']),
        ConsoleNetwork(id: 'net-2', name: 'Research', regions: ['ap-east']),
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
      _hasSelectionAreaAncestor(
        tester,
        find.byKey(const ValueKey<String>('network-tab-label')),
      ),
      isFalse,
    );
    expect(
      _hasSelectionAreaAncestor(tester, find.byType(FButton).first),
      isFalse,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('network-tab-dropdown')),
    );
    await tester.pumpAndSettle();

    expect(
      _hasSelectionAreaAncestor(
        tester,
        find.byKey(const ValueKey<String>('network-tab-option-net-2')),
      ),
      isFalse,
    );
  });

  testWidgets('confirms before deleting a network and hides it locally', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
        ConsoleNetwork(id: 'net-2', name: '研发网', regions: ['ap-east']),
      ],
      networkDevices: const <String, List<NetworkDevice>>{
        'net-1': <NetworkDevice>[
          NetworkDevice(id: 'node-1', name: 'desktop-1', online: true),
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

    await _openNetworkDeleteDialog(tester);

    expect(find.textContaining('删除后不可恢复'), findsOneWidget);
    expect(find.textContaining('所有节点会自动踢出网络'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(FDialog),
        matching: find.widgetWithText(FButton, '取消'),
      ),
    );
    await tester.pumpAndSettle();
    expect(authService.deletedNetworkIds, isEmpty);

    await _openNetworkDeleteDialog(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(FDialog),
        matching: find.widgetWithText(FButton, '删除网络'),
      ),
    );
    await tester.pumpAndSettle();

    expect(authService.deletedNetworkIds, <String>['net-1']);
    expect(authService.networks.map((network) => network.id), <String>[
      'net-2',
    ]);
    expect(authService.networkDevices.containsKey('net-1'), isFalse);
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

  test('parses peer statuses by normalized ipv4', () {
    final statuses = CoreLifecycleService.parseNetworkPeerStatusesFromJson(
      jsonEncode([
        {
          'cidr': '10.144.0.2/24',
          'ipv4': '10.144.0.2',
          'hostname': 'desktop-1',
          'cost': 'p2p',
          'lat_ms': '3.45',
          'loss_rate': '0.0%',
          'rx_bytes': '17.33 kB',
          'tx_bytes': '20.42 kB',
          'tunnel_proto': 'udp',
          'nat_type': 'FullCone',
          'id': '390879727',
          'version': '2.6.4',
        },
        {'cidr': '10.144.0.3/24', 'hostname': 'laptop-2', 'cost': 'relay'},
        'ignored',
      ]),
    );

    expect(statuses.keys, containsAll(<String>['10.144.0.2', '10.144.0.3']));
    expect(statuses['10.144.0.2']?.cost, 'p2p');
    expect(statuses['10.144.0.2']?.latencyText, '3.45');
    expect(statuses['10.144.0.2']?.peerId, '390879727');
    expect(statuses['10.144.0.3']?.ipv4, '10.144.0.3');
  });

  test('parses multi-instance peer status wrappers', () {
    final statuses = CoreLifecycleService.parseNetworkPeerStatusesFromJson(
      jsonEncode([
        {
          'instance_id': 'instance-1',
          'instance_name': 'nt-office',
          'result': [
            {
              'cidr': '10.144.0.2/24',
              'ipv4': '10.144.0.2',
              'hostname': 'desktop-1',
              'cost': 'Local',
            },
          ],
        },
        {
          'instance_id': 'instance-2',
          'instance_name': 'nt-lab',
          'result': [
            {
              'cidr': '10.145.0.2/24',
              'ipv4': '10.145.0.2',
              'hostname': 'laptop-2',
              'cost': 'p2p',
            },
          ],
        },
      ]),
    );

    expect(statuses.length, 2);
    expect(statuses['10.144.0.2']?.cost, 'Local');
    expect(statuses['10.145.0.2']?.cost, 'p2p');
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
              'os': 'windows',
              'os_version': '11',
              'os_distribution': 'Windows 11 Pro',
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
    expect(devices.single.os, 'windows');
    expect(devices.single.osVersion, '11');
    expect(devices.single.osDistribution, 'Windows 11 Pro');
    expect(devices.single.removed, isFalse);
  });

  test('console service preserves node operating system metadata', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final service = ConsoleAuthService(
      tokenStore: OAuthTokenStore(preferences),
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path ==
            '/api/v1/tenants/tenant-1/networks/net-1/nodes') {
          return _jsonResponse([
            {
              'id': 'node-1',
              'hostname': 'desktop-1',
              'machine_id': 'machine-1',
              'connectivity_state': 'online',
              'ipv4_addr': '10.144.0.2',
              'os': 'linux',
              'os_version': '6.8.0',
              'os_distribution': 'Ubuntu',
            },
          ]);
        }
        return http.Response('{}', 404);
      }),
    );

    final nodes = await service.fetchNetworkDevices(
      accessToken: 'token',
      workspaceId: 'tenant-1',
      networkId: 'net-1',
    );

    expect(nodes.single.os, 'linux');
    expect(nodes.single.osVersion, '6.8.0');
    expect(nodes.single.osDistribution, 'Ubuntu');
  });

  test('network lifecycle operations use tenant scoped console API', () async {
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
        if (request.url.path == '/api/v1/tenants/tenant-1/networks/net-1') {
          return _jsonResponse({
            'resource': {'id': 'net-1'},
            'operation': {'id': 'op-3'},
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
    await service.deleteNetwork(
      accessToken: 'token',
      workspaceId: 'tenant-1',
      networkId: 'net-1',
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
    expect(requests[3].method, 'DELETE');
    expect(requests[3].url.path, '/api/v1/tenants/tenant-1/networks/net-1');
  });
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

bool _hasSelectionAreaAncestor(WidgetTester tester, Finder finder) {
  final element = tester.element(finder);
  var found = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is SelectionArea) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
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
  await _pumpAppMotionFrames(tester);
}

Future<void> _openNetworkDeleteDialog(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('network-more-menu-button')),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('network-more-delete')),
    findsOneWidget,
  );
  await tester.tap(find.byKey(const ValueKey<String>('network-more-delete')));
  await tester.pumpAndSettle();
}

Future<void> _pumpAppMotionFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
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
  final List<String> deletedNetworkIds = <String>[];
  final List<String> createdNetworkNames = <String>[];
  final List<String?> createdNetworkIPv4Cidrs = <String?>[];
  int networkDeviceFetchCount = 0;

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
  Future<void> deleteNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    deletedNetworkIds.add(networkId);
    networks.removeWhere((network) => network.id == networkId);
    networkDevices.remove(networkId);
  }

  @override
  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    networkDeviceFetchCount++;
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
        os: device.os,
        osVersion: device.osVersion,
        osDistribution: device.osDistribution,
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
    this.peerSamples = const <Map<String, CorePeerStatus>>[],
    this.peerError,
  });

  final String? machineId;
  final List<Map<String, CoreNetworkTrafficTotals>> trafficSamples;
  final List<Map<String, CorePeerStatus>> peerSamples;
  final Object? peerError;
  int _trafficReadCount = 0;
  int peerReadCount = 0;

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

  @override
  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async {
    peerReadCount++;
    final error = peerError;
    if (error != null) {
      throw error;
    }
    if (peerSamples.isEmpty) {
      return const <String, CorePeerStatus>{};
    }
    final sampleIndex = peerReadCount - 1 < peerSamples.length
        ? peerReadCount - 1
        : peerSamples.length - 1;
    return peerSamples[sampleIndex];
  }
}
