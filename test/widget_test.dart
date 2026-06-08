import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:forui/forui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:easytier_pro_app/main.dart';
import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_peer_status.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:easytier_pro_app/src/desktop/tray_support.dart';
import 'package:easytier_pro_app/src/shared/app_text_selection.dart';

void main() {
  testWidgets('android login waits until app resumes before polling token', (
    WidgetTester tester,
  ) async {
    final previousLauncher = UrlLauncherPlatform.instance;
    final launcher = _FakeUrlLauncherPlatform();
    final authService = _LoginFlowAuthService();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    UrlLauncherPlatform.instance = launcher;

    try {
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

      await tester.tap(find.byType(FButton).first);
      await tester.pumpAndSettle();

      expect(launcher.launchCount, 1);
      expect(authService.startDeviceAuthCount, 1);
      expect(authService.completeDeviceAuthCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(authService.completeDeviceAuthCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(authService.completeDeviceAuthCount, 1);
    } finally {
      UrlLauncherPlatform.instance = previousLauncher;
      debugDefaultTargetPlatformOverride = null;
    }
  });

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

  testWidgets('android blocks joining a second active network', (
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
          hostname: 'android-phone',
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
        androidMvpSingleActiveNetworkOverride: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FSwitch).first);
    await tester.pumpAndSettle();
    expect(authService.attachedNetworkIds, <String>['net-1']);

    await tester.tap(find.byType(FSwitch).at(1));
    await tester.pumpAndSettle();

    expect(authService.attachedNetworkIds, <String>['net-1']);
    expect(find.textContaining('Android 当前仅支持一个活跃 VPN 网络'), findsWidgets);
  });

  testWidgets(
    'android blocks joining a second network while first is joining',
    (WidgetTester tester) async {
      _useDesktopViewport(tester);

      final attachGate = Completer<void>();
      final authService = _FakeAuthService(
        networks: const <ConsoleNetwork>[
          ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
          ConsoleNetwork(id: 'net-2', name: '研发网', regions: ['ap-east']),
        ],
        managedDevices: const <ManagedDevice>[
          ManagedDevice(
            id: 'device-1',
            machineId: 'machine-1',
            hostname: 'android-phone',
            approvalState: 'approved',
            connectivityState: 'online',
          ),
        ],
        attachDeviceDelay: attachGate.future,
      );

      await tester.pumpWidget(
        MyApp(
          authService: authService,
          traySupport: createTraySupport(),
          coreLifecycleService: _NoopCoreLifecycleService(
            authService: authService,
            machineId: 'machine-1',
          ),
          androidMvpSingleActiveNetworkOverride: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FSwitch).first);
      await tester.pump();
      await tester.pump();
      expect(authService.attachedNetworkIds, isEmpty);

      await tester.tap(find.byType(FSwitch).at(1));
      await tester.pump();
      await tester.pump();

      expect(authService.attachedNetworkIds, isEmpty);
      expect(find.textContaining('Android 当前仅支持一个活跃 VPN 网络'), findsWidgets);

      attachGate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'android blocks joining a second network while first is leaving',
    (WidgetTester tester) async {
      _useDesktopViewport(tester);

      final removeGate = Completer<void>();
      final authService = _FakeAuthService(
        networks: const <ConsoleNetwork>[
          ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
          ConsoleNetwork(id: 'net-2', name: '研发网', regions: ['ap-east']),
        ],
        managedDevices: const <ManagedDevice>[
          ManagedDevice(
            id: 'device-1',
            machineId: 'machine-1',
            hostname: 'android-phone',
            approvalState: 'approved',
            connectivityState: 'online',
          ),
        ],
        networkDevices: const <String, List<NetworkDevice>>{
          'net-1': <NetworkDevice>[
            NetworkDevice(
              id: 'node-1',
              name: 'android-phone',
              online: true,
              ipv4: '10.144.0.2',
              deviceId: 'device-1',
              machineId: 'machine-1',
            ),
          ],
        },
        removeNetworkNodeDelay: removeGate.future,
      );

      await tester.pumpWidget(
        MyApp(
          authService: authService,
          traySupport: createTraySupport(),
          coreLifecycleService: _NoopCoreLifecycleService(
            authService: authService,
            machineId: 'machine-1',
          ),
          androidMvpSingleActiveNetworkOverride: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FSwitch).first);
      await tester.pump();
      await tester.pump();
      expect(authService.removedNodeIds, isEmpty);

      await tester.tap(find.byType(FSwitch).at(1));
      await tester.pump();
      await tester.pump();

      expect(authService.attachedNetworkIds, isEmpty);
      expect(find.textContaining('Android 当前仅支持一个活跃 VPN 网络'), findsWidgets);

      removeGate.complete();
      await tester.pumpAndSettle();
    },
  );

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

    expect(
      find.byKey(const ValueKey<String>('status-traffic-strip')),
      findsOneWidget,
    );
    expect(find.text('1.0K/s'), findsOneWidget);
    expect(find.text('2.0K/s'), findsOneWidget);
    expect(find.textContaining('1.00 KiB/s'), findsOneWidget);
    expect(find.textContaining('2.00 KiB/s'), findsOneWidget);

    await _selectNetworkFromHeader(tester, '办公网');

    expect(
      find.byKey(const ValueKey<String>('status-traffic-strip')),
      findsNothing,
    );
    expect(find.textContaining('1.00 KiB/s'), findsOneWidget);
    expect(find.textContaining('2.00 KiB/s'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('very narrow status badge keeps online copy beside traffic', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(320, 760));

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
          hostname: 'phone-1',
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
            downloadBytes: 0,
            uploadBytes: 0,
            sampledAt: DateTime.utc(2026, 1, 1),
          ),
        },
        {
          'nt-office': CoreNetworkTrafficTotals(
            runtimeNetworkName: 'nt-office',
            downloadBytes: 204800,
            uploadBytes: 614400,
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
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('status-traffic-strip')),
      findsOneWidget,
    );
    expect(find.text('100K/s'), findsOneWidget);
    expect(find.text('300K/s'), findsOneWidget);
    expect(find.textContaining('100 KiB/s'), findsNothing);
    expect(find.textContaining('300 KiB/s'), findsNothing);
    expect(find.text('已在线'), findsOneWidget);
    expect(find.text('1 个网络'), findsOneWidget);
  });

  testWidgets('keeps traffic sparkline x-axis stable as samples grow', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(
          id: 'net-1',
          name: 'office-network',
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
        {
          'nt-office': CoreNetworkTrafficTotals(
            runtimeNetworkName: 'nt-office',
            downloadBytes: 5120,
            uploadBytes: 10240,
            sampledAt: DateTime.utc(2026, 1, 1, 0, 0, 4),
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

    _expectTrafficSparklineWindow(tester, <double>[29]);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    _expectTrafficSparklineWindow(tester, <double>[28, 29]);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    _expectTrafficSparklineWindow(tester, <double>[27, 28, 29]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows detailed traffic graph on sparkline hover', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(
          id: 'net-1',
          name: 'office-network',
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
        {
          'nt-office': CoreNetworkTrafficTotals(
            runtimeNetworkName: 'nt-office',
            downloadBytes: 8192,
            uploadBytes: 12288,
            sampledAt: DateTime.utc(2026, 1, 1, 0, 0, 4),
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
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('实时流量'), findsNothing);
    expect(find.byType(LineChart), findsOneWidget);
    _expectTrafficChartAnimations(tester);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(LineChart)),
    );
    await tester.pump();

    expect(find.text('实时流量'), findsOneWidget);
    expect(find.text('速率'), findsNothing);
    expect(find.text('采样点'), findsNothing);
    expect(find.text('0 B/s'), findsNothing);
    expect(find.text('10.0 KiB/s'), findsOneWidget);
    _expectTextSingleLine(tester, find.text('10.0 KiB/s'));
    expect(_trafficTimeLabels(), findsAtLeastNWidgets(1));
    _expectTrafficTimeLabelsFitInside(tester);
    _expectTrafficXAxisLabelsOutsideGraph(tester);
    expect(find.text('15min'), findsNothing);
    _expectDetailedTrafficChartMaxX(tester, 60);
    expect(find.byType(LineChart), findsNWidgets(2));
    _expectTrafficChartYScalesFixed(tester);
    _expectTrafficChartAnimations(tester);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('实时流量'), findsOneWidget);
    expect(find.byType(LineChart), findsNWidgets(2));
    _expectTrafficChartAnimations(tester);

    await gesture.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(find.text('实时流量'), findsNothing);
    expect(find.byType(LineChart), findsOneWidget);

    await tester.tap(find.byType(LineChart));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('traffic-fullscreen-overlay')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('traffic-fullscreen-animation')),
      findsOneWidget,
    );
    expect(find.text('实时流量'), findsOneWidget);
    expect(find.text('实时流量详情'), findsNothing);
    expect(find.text('1min'), findsOneWidget);
    expect(find.text('15min'), findsOneWidget);
    expect(find.text('60min'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
      findsNothing,
    );
    expect(find.byType(LineChart), findsNWidgets(2));
    _expectDetailedTrafficChartMaxX(tester, 60);
    _expectTrafficChartAnimations(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('traffic-window-15min')),
    );
    await tester.pumpAndSettle();
    _expectDetailedTrafficChartMaxX(tester, 900);

    await tester.tap(
      find.byKey(const ValueKey<String>('traffic-window-60min')),
    );
    await tester.pumpAndSettle();
    _expectDetailedTrafficChartMaxX(tester, 3600);

    await tester.tap(
      find.byKey(const ValueKey<String>('traffic-fullscreen-close')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('traffic-fullscreen-overlay')),
      findsNothing,
    );
    expect(find.text('实时流量详情'), findsNothing);
    expect(find.text('实时流量'), findsNothing);
    expect(find.byType(LineChart), findsOneWidget);

    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('traffic fullscreen panel stays no taller than wide on mobile', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(390, 760));

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(
          id: 'net-1',
          name: 'office-network',
          regions: ['ap-east'],
          runtimeNetworkName: 'nt-office',
        ),
      ],
      managedDevices: const <ManagedDevice>[
        ManagedDevice(
          id: 'device-1',
          machineId: 'machine-1',
          hostname: 'phone-1',
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
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.textContaining('1.00 KiB/s'), findsNothing);
    expect(find.textContaining('2.00 KiB/s'), findsNothing);

    await tester.tap(find.byType(LineChart));
    await tester.pumpAndSettle();

    final panelRect = tester.getRect(
      find.byKey(const ValueKey<String>('traffic-fullscreen-panel')),
    );
    expect(panelRect.height, lessThanOrEqualTo(panelRect.width));

    await tester.tap(
      find.byKey(const ValueKey<String>('traffic-fullscreen-close')),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('shows startup state when network instance is missing', (
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
      instanceRunning: false,
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

    expect(find.text('实例启动中'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'keeps idle joined networks connected when traffic stats are empty',
    (WidgetTester tester) async {
      _useDesktopViewport(tester);

      final authService = _FakeAuthService(
        networks: const <ConsoleNetwork>[
          ConsoleNetwork(
            id: 'net-1',
            name: 'office-network',
            regions: ['ap-east'],
            runtimeNetworkName: 'nt-office',
          ),
          ConsoleNetwork(
            id: 'net-2',
            name: 'lab-network',
            regions: ['ap-east'],
            runtimeNetworkName: 'nt-lab',
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
          'net-2': <NetworkDevice>[
            NetworkDevice(
              id: 'node-2',
              name: 'desktop-1',
              online: true,
              ipv4: '10.145.0.2',
              deviceId: 'device-1',
              machineId: 'machine-1',
            ),
          ],
        },
      );
      final coreLifecycleService = _NoopCoreLifecycleService(
        authService: authService,
        machineId: 'machine-1',
        trafficSamples: const <Map<String, CoreNetworkTrafficTotals>>[
          <String, CoreNetworkTrafficTotals>{},
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
      await tester.pump();

      expect(find.text('实例启动中'), findsNothing);
      expect(find.textContaining('10.144.0.2'), findsOneWidget);
      expect(find.textContaining('10.145.0.2'), findsOneWidget);
      expect(find.textContaining('B/s'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

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
            name: '工作笔记本',
            online: true,
            hostname: 'desktop-1',
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
    expect(find.text('工作笔记本'), findsOneWidget);

    final scrollTop = tester
        .getTopLeft(
          find.byKey(const ValueKey<String>('network-node-list-scroll')),
        )
        .dy;
    final nodeTop = tester
        .getTopLeft(find.byKey(const ValueKey<String>('network-node-node-1')))
        .dy;
    expect(nodeTop - scrollTop, lessThan(8));
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
          machineId: 'local-machine',
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

    final headerFinder = find.byKey(
      const ValueKey<String>('network-detail-header'),
    );
    final expandedHeaderHeight = tester.getSize(headerFinder).height;
    final scrollFinder = find.byKey(
      const ValueKey<String>('network-node-list-scroll'),
    );
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(scrollFinder)),
    );
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 96)));
    await tester.pump();
    await _pumpAppMotionFrames(tester);

    expect(tester.getSize(headerFinder).height, lessThan(expandedHeaderHeight));
    expect(controller.offset, controller.position.minScrollExtent);
    final headerRect = tester.getRect(headerFinder);
    final joinButtonRect = tester.getRect(
      find
          .ancestor(of: find.text('加入网络'), matching: find.byType(FButton))
          .first,
    );
    expect(joinButtonRect.bottom, lessThanOrEqualTo(headerRect.bottom - 3));

    final beforeWheelOffset = controller.offset;
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 96)));
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

    controller.jumpTo(80);
    await tester.pump();
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(scrollFinder)),
    );
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -240)));
    await tester.pump();
    await _pumpAppMotionFrames(tester);

    expect(controller.offset, controller.position.minScrollExtent);
    expect(
      tester.getSize(headerFinder).height,
      closeTo(expandedHeaderHeight, 0.1),
    );

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

  testWidgets(
    'network detail expands when collapsed content stops overflowing',
    (WidgetTester tester) async {
      _useDesktopViewport(tester, size: const Size(1600, 700));

      final networkDevices = List<NetworkDevice>.generate(5, (index) {
        final number = index + 1;
        return NetworkDevice(
          id: 'node-$number',
          name: 'desktop-$number',
          online: true,
          ipv4: '10.144.0.${number + 1}',
          deviceId: 'device-$number',
          machineId: 'machine-$number',
        );
      });
      final authService = _FakeAuthService(
        networks: const <ConsoleNetwork>[
          ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
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

      final headerFinder = find.byKey(
        const ValueKey<String>('network-detail-header'),
      );
      final expandedHeaderHeight = tester.getSize(headerFinder).height;
      final scrollFinder = find.byKey(
        const ValueKey<String>('network-node-list-scroll'),
      );
      final scrollView = tester.widget<SingleChildScrollView>(scrollFinder);
      final controller = scrollView.controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));

      final mouse = TestPointer(4, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.hover(tester.getCenter(scrollFinder)),
      );
      await tester.pump();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 64)));
      await tester.pump();
      await _pumpAppMotionFrames(tester);

      expect(
        tester.getSize(headerFinder).height,
        lessThan(expandedHeaderHeight),
      );
      expect(
        controller.position.maxScrollExtent,
        lessThanOrEqualTo(controller.position.minScrollExtent),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(scrollFinder),
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        tester.getSize(headerFinder).height,
        closeTo(expandedHeaderHeight, 0.1),
      );
    },
  );

  testWidgets('network detail subnets collapse header while scrolling', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(1600, 700));

    final subnetRoutes = NetworkSubnetRouteList(
      routes: List<NetworkSubnetRoute>.generate(18, (index) {
        final number = index + 1;
        return NetworkSubnetRoute(
          id: 'route-$number',
          cidr: '192.168.$number.0/24',
          mappedCidr: '10.$number.0.0/24',
        );
      }),
      allowedProxyCidrs: const <String>[],
      quotaLimit: 20,
      quotaUsed: 18,
    );
    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
      ],
      subnetRoutes: <String, NetworkSubnetRouteList>{'net-1': subnetRoutes},
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
    await tester.tap(find.text('子网 18'));
    await _pumpAppMotionFrames(tester);

    final headerFinder = find.byKey(
      const ValueKey<String>('network-detail-header'),
    );
    final expandedHeaderHeight = tester.getSize(headerFinder).height;
    final subnetScrollFinder = find.descendant(
      of: find.byKey(const ValueKey<String>('network-detail-section-subnets')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.vertical,
      ),
    );
    expect(subnetScrollFinder, findsOneWidget);

    final scrollView = tester.widget<SingleChildScrollView>(subnetScrollFinder);
    final controller = scrollView.controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));

    final mouse = TestPointer(2, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(subnetScrollFinder)),
    );
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 96)));
    await tester.pump();
    await _pumpAppMotionFrames(tester);

    expect(tester.getSize(headerFinder).height, lessThan(expandedHeaderHeight));
    expect(controller.offset, controller.position.minScrollExtent);

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 96)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.offset, greaterThan(controller.position.minScrollExtent));
  });

  testWidgets('network detail resets collapsed header for empty node lists', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(1600, 700));

    final networkDevices = List<NetworkDevice>.generate(18, (index) {
      final number = index + 1;
      return NetworkDevice(
        id: 'node-$number',
        name: 'desktop-$number',
        online: true,
        ipv4: '10.144.0.${number + 1}',
        deviceId: 'device-$number',
        machineId: 'machine-$number',
      );
    });
    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
        ConsoleNetwork(id: 'net-2', name: '空网络', regions: ['ap-east']),
      ],
      networkDevices: <String, List<NetworkDevice>>{
        'net-1': networkDevices,
        'net-2': const <NetworkDevice>[],
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

    final headerFinder = find.byKey(
      const ValueKey<String>('network-detail-header'),
    );
    final expandedHeaderHeight = tester.getSize(headerFinder).height;
    final scrollView = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
    );
    final controller = scrollView.controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));

    final scrollFinder = find.byKey(
      const ValueKey<String>('network-node-list-scroll'),
    );
    final mouse = TestPointer(3, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.hover(tester.getCenter(scrollFinder)),
    );
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 96)));
    await tester.pump();
    await _pumpAppMotionFrames(tester);

    expect(tester.getSize(headerFinder).height, lessThan(expandedHeaderHeight));
    expect(controller.offset, controller.position.minScrollExtent);

    await _selectNetworkFromHeader(tester, '空网络');

    expect(
      find.byKey(const ValueKey<String>('network-node-list-empty')),
      findsOneWidget,
    );
    expect(
      tester.getSize(headerFinder).height,
      closeTo(expandedHeaderHeight, 0.1),
    );
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
      subnetRoutes: const <String, NetworkSubnetRouteList>{
        'net-1': NetworkSubnetRouteList(
          routes: <NetworkSubnetRoute>[
            NetworkSubnetRoute(
              id: 'route-1',
              cidr: '192.168.50.0/24',
              mappedCidr: '10.50.0.0/24',
              nodes: <SubnetRouteNodeSummary>[
                SubnetRouteNodeSummary(
                  id: 'node-1',
                  hostname: 'desktop-1',
                  machineId: 'machine-1',
                  status: 'online',
                  provisioningState: 'ready',
                ),
              ],
              manualRouteNodes: <SubnetRouteNodeSummary>[
                SubnetRouteNodeSummary(
                  id: 'node-1',
                  hostname: 'desktop-1',
                  machineId: 'machine-1',
                  status: 'online',
                  provisioningState: 'ready',
                ),
              ],
            ),
          ],
          allowedProxyCidrs: <String>['192.168.0.0/16'],
          quotaLimit: 8,
          quotaUsed: 1,
        ),
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
    final tabsSize = tester.getSize(
      find.byKey(const ValueKey<String>('network-detail-section-tabs')),
    );
    expect(tabsSize.width, greaterThan(0));

    final listSize = tester.getSize(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
    );
    expect(listSize.width, closeTo(328, 0.1));
    expect(tabsSize.width, lessThan(listSize.width));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('network-node-list-scroll')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        ),
      ),
      findsNothing,
    );
    final listRect = tester.getRect(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
    );
    final cardRect = tester.getRect(
      find.byKey(const ValueKey<String>('network-node-node-1')),
    );
    expect(cardRect.left, greaterThanOrEqualTo(listRect.left - 0.1));
    expect(cardRect.right, lessThanOrEqualTo(listRect.right + 0.1));
    expect(find.byTooltip('刷新节点'), findsOneWidget);

    await tester.tap(find.text('子网'));
    await _pumpAppMotionFrames(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('192.168.50.0/24'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('network-detail-section-subnets'),
        ),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        ),
      ),
      findsNothing,
    );
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
          NetworkDevice(
            id: 'node-2',
            name: 'laptop-2',
            online: true,
            ipv4: '10.144.0.3',
            deviceId: 'device-2',
            machineId: 'machine-2',
          ),
          NetworkDevice(
            id: 'node-3',
            name: 'relay-node',
            online: true,
            ipv4: '10.144.0.4',
            deviceId: 'device-3',
            machineId: 'machine-3',
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
          '10.144.0.3': CorePeerStatus(
            cidr: '10.144.0.3/24',
            ipv4: '10.144.0.3',
            hostname: 'laptop-2',
            cost: '1',
            latencyText: '8.00',
            lossText: '0.0%',
            rxBytes: '0 B',
            txBytes: '0 B',
            tunnelProto: 'tcp',
            natType: 'Symmetric',
            peerId: '123',
            version: '2.6.4',
          ),
          '10.144.0.4': CorePeerStatus(
            cidr: '10.144.0.4/24',
            ipv4: '10.144.0.4',
            hostname: 'relay-node',
            cost: 'relay(2)',
            latencyText: '9.00',
            lossText: '0.0%',
            rxBytes: '0 B',
            txBytes: '0 B',
            tunnelProto: 'tcp',
            natType: 'Symmetric',
            peerId: '124',
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
    final p2pMeta = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('network-node-node-1')),
            matching: find.textContaining('10.144.0.2'),
          )
          .first,
    );
    final numericCostMeta = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('network-node-node-2')),
            matching: find.textContaining('10.144.0.3'),
          )
          .first,
    );
    final relayMeta = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('network-node-node-3')),
            matching: find.textContaining('10.144.0.4'),
          )
          .first,
    );
    expect(p2pMeta.data, contains('P2P'));
    expect(p2pMeta.data, contains('UDP'));
    expect(p2pMeta.data, isNot(contains('17.33 kB')));
    expect(p2pMeta.data, isNot(contains('20.42 kB')));
    expect(numericCostMeta.data, contains('TCP'));
    expect(numericCostMeta.data, isNot(contains(' ·  1')));
    expect(relayMeta.data, contains('中继'));
    expect(relayMeta.data, isNot(contains('relay(2)')));
    expect(find.textContaining('3.45 ms'), findsWidgets);
    expect(find.textContaining('Peer: 390879727'), findsNothing);
    expect(find.textContaining('Peer: 123'), findsNothing);
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

  testWidgets('network detail subnet segment shows route summaries', (
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
          NetworkDevice(
            id: 'node-router',
            name: 'edge-router',
            online: true,
            ipv4: '10.144.0.3',
            deviceId: 'device-router',
            machineId: 'machine-router',
          ),
        ],
      },
      subnetRoutes: const <String, NetworkSubnetRouteList>{
        'net-1': NetworkSubnetRouteList(
          routes: <NetworkSubnetRoute>[
            NetworkSubnetRoute(
              id: 'route-1',
              cidr: '192.168.50.0/24',
              mappedCidr: '10.50.0.0/24',
              nodeIds: <String>['node-router'],
              nodes: <SubnetRouteNodeSummary>[
                SubnetRouteNodeSummary(
                  id: 'node-router',
                  hostname: 'edge-router',
                  machineId: 'machine-router',
                  status: 'online',
                  provisioningState: 'ready',
                ),
              ],
              manualRouteNodeIds: <String>['node-1'],
              manualRouteNodes: <SubnetRouteNodeSummary>[
                SubnetRouteNodeSummary(
                  id: 'node-1',
                  hostname: 'desktop-1',
                  machineId: 'machine-1',
                  status: 'online',
                  provisioningState: 'ready',
                ),
              ],
            ),
          ],
          allowedProxyCidrs: <String>['192.168.0.0/16'],
          quotaLimit: 8,
          quotaUsed: 1,
        ),
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
    await tester.tap(find.text('子网 1'));
    await _pumpAppMotionFrames(tester);

    expect(
      find.byKey(const ValueKey<String>('network-node-list-scroll')),
      findsNothing,
    );
    expect(find.text('192.168.50.0/24'), findsOneWidget);
    expect(find.text('映射为 10.50.0.0/24'), findsOneWidget);
    expect(find.textContaining('1 个 · 1 在线'), findsWidgets);
    expect(find.textContaining('edge-router'), findsOneWidget);
  });

  testWidgets('network detail subnet segment shows empty state', (
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _selectNetworkFromHeader(tester, '办公网');
    await tester.tap(find.text('子网 0'));
    await _pumpAppMotionFrames(tester);

    expect(find.textContaining('还没有配置子网路由'), findsOneWidget);
  });

  testWidgets('network detail subnet segment retries failed route load', (
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
      subnetRouteFailures: <String, List<Object>>{
        'net-1': <Object>[
          const AuthException('temporary route failure'),
          const AuthException('temporary route failure'),
        ],
      },
      subnetRoutes: const <String, NetworkSubnetRouteList>{
        'net-1': NetworkSubnetRouteList(
          routes: <NetworkSubnetRoute>[
            NetworkSubnetRoute(id: 'route-1', cidr: '192.168.50.0/24'),
          ],
          allowedProxyCidrs: <String>[],
          quotaLimit: 8,
          quotaUsed: 1,
        ),
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
    await tester.tap(find.text('子网'));
    await _pumpAppMotionFrames(tester);

    expect(find.textContaining('temporary route failure'), findsOneWidget);
    await tester.tap(find.widgetWithText(FButton, '重试'));
    await _pumpAppMotionFrames(tester);

    expect(find.textContaining('temporary route failure'), findsNothing);
    expect(find.text('192.168.50.0/24'), findsOneWidget);
  });

  testWidgets('network detail local segment shows local node config', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(
          id: 'net-1',
          name: 'office-network',
          regions: ['ap-east'],
          runtimeNetworkName: 'nt-office',
          ipv4Cidr: '10.144.0.0/16',
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
      nodeConfigs: const <String, NodeInstanceConfigView>{
        'node-1': NodeInstanceConfigView(
          defaults: NodeInstanceConfigSettings(),
          overrides: NodeInstanceConfigSettings(p2pMode: 'p2p_only'),
          effective: NodeInstanceConfigSettings(
            ipv4: '10.144.0.2',
            hostname: 'desktop-1',
            p2pMode: 'p2p_only',
            listenerProtocols: <String>['tcp', 'udp'],
            magicDnsEnabled: true,
            noTun: false,
            proxyForwardBySystem: true,
            userspaceStack: false,
          ),
          configScope: 'customized',
          applyStatus: 'applied',
          driftStatus: 'in_sync',
          assignedSubnetRoutes: <AssignedSubnetRoute>[
            AssignedSubnetRoute(
              id: 'route-1',
              cidr: '192.168.50.0/24',
              mappedCidr: '10.50.0.0/24',
            ),
          ],
          manualSubnetRoutes: <AssignedSubnetRoute>[
            AssignedSubnetRoute(id: 'route-2', cidr: '172.16.8.0/24'),
          ],
          manualRoutesEnabled: true,
        ),
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

    await _selectNetworkFromHeader(tester, 'office-network');
    await tester.tap(find.text('本机已加入'));
    await _pumpAppMotionFrames(tester);

    expect(find.text('10.144.0.2'), findsOneWidget);
    expect(find.text('desktop-1'), findsWidgets);
    expect(find.text('本机覆盖'), findsOneWidget);
    expect(find.text('已应用'), findsOneWidget);
    expect(find.text('一致'), findsOneWidget);
    expect(find.text('仅 P2P'), findsOneWidget);
    expect(find.text('TCP, UDP'), findsOneWidget);
    expect(find.text('Magic DNS 启用'), findsOneWidget);
    expect(find.text('No-TUN 关闭'), findsOneWidget);
    expect(find.text('系统转发 启用'), findsOneWidget);
    expect(find.text('用户态协议栈 关闭'), findsOneWidget);
    expect(find.text('192.168.50.0/24 -> 10.50.0.0/24'), findsOneWidget);
    expect(find.text('172.16.8.0/24'), findsOneWidget);
  });

  testWidgets('network detail local segment handles missing local node', (
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
      networkDevices: const <String, List<NetworkDevice>>{
        'net-1': <NetworkDevice>[
          NetworkDevice(
            id: 'node-1',
            name: 'desktop-1',
            online: true,
            ipv4: '10.144.0.2',
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
          machineId: 'machine-other',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _selectNetworkFromHeader(tester, '办公网');
    await tester.tap(find.text('本机'));
    await _pumpAppMotionFrames(tester);

    expect(find.textContaining('本机尚未加入此网络'), findsOneWidget);
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

    await tester.tap(find.byTooltip('刷新节点'));
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

    expect(
      _hasSelectionAreaAncestor(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey<String>('cidr-preset-10.144.0.0/16')),
          matching: find.byType(Text),
        ),
      ),
      isFalse,
    );
    expect(
      _hasSelectionAreaAncestor(tester, find.widgetWithText(FButton, '创建网络')),
      isFalse,
    );

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

  testWidgets('create network dialog submits selected CIDR preset', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(900, 560));

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

    await tester.tap(
      find.byKey(const ValueKey<String>('network-create-button')),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(FDialog),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(FDialog),
        matching: find.byType(Scrollbar),
      ),
      findsNothing,
    );

    await tester.tap(find.text('172.16.0.0/16'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(FDialog),
        matching: find.widgetWithText(FButton, '创建网络'),
      ),
    );
    await tester.pumpAndSettle();

    expect(authService.createdNetworkNames, <String>['我的网络']);
    expect(authService.createdNetworkIPv4Cidrs, <String?>['172.16.0.0/16']);
  });

  testWidgets('create network dialog shows name validation error', (
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

    await tester.tap(
      find.byKey(const ValueKey<String>('network-create-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(FDialog),
            matching: find.byType(FTextField),
          )
          .first,
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(FDialog),
        matching: find.widgetWithText(FButton, '创建网络'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('请输入网络名称。'), findsOneWidget);
    expect(authService.createdNetworkNames, isEmpty);
    expect(find.byType(FDialog), findsOneWidget);
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

  testWidgets('opens network detail when tapping network list name', (
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

    final officeTitle = find.descendant(
      of: find.byKey(const ValueKey<String>('network-switch-net-1')),
      matching: find.text('Office'),
    );

    expect(officeTitle, findsOneWidget);
    expect(_hasSelectionAreaAncestor(tester, officeTitle), isFalse);
    expect(
      find.byKey(const ValueKey<String>('network-detail-header')),
      findsNothing,
    );

    await tester.tap(officeTitle);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('network-detail-header')),
      findsOneWidget,
    );
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
    expect(
      _hasSelectionAreaAncestor(
        tester,
        find.byKey(const ValueKey<String>('network-create-button')),
      ),
      isFalse,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('network-tab-dropdown')),
    );
    await tester.pumpAndSettle();

    expect(
      _hasSelectionAreaAncestor(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey<String>('network-tab-option-net-2')),
          matching: find.text('Research'),
        ),
      ),
      isFalse,
    );
  });

  testWidgets('user menu labels are not selectable', (
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

    await tester.tap(
      find.descendant(of: find.byType(FAvatar), matching: find.text('T')),
    );
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(_hasSelectionAreaAncestor(tester, find.text('Test User')), isFalse);
    expect(_hasSelectionAreaAncestor(tester, find.text('个人空间')), isFalse);
    expect(_hasSelectionAreaAncestor(tester, find.text('设置')), isFalse);
    expect(_hasSelectionAreaAncestor(tester, find.text('退出登录')), isFalse);
  });

  testWidgets('android settings keeps diagnostics mobile friendly', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(390, 760));
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
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

      await _openSettingsFromUserMenu(tester);

      expect(find.text('导出诊断日志'), findsOneWidget);
      expect(find.text('打开日志目录'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'mobile settings account card stays compact and does not scroll sideways',
    (WidgetTester tester) async {
      _useDesktopViewport(tester, size: const Size(390, 760));

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

      await _openSettingsFromUserMenu(tester);

      final titleRect = tester.getRect(
        find.byKey(const ValueKey<String>('settings-section-title')),
      );
      final accountCardRect = tester.getRect(
        find.byKey(const ValueKey<String>('settings-account-card')),
      );
      expect(accountCardRect.top - titleRect.bottom, lessThanOrEqualTo(14));

      final horizontalScrolls = find.descendant(
        of: find.byKey(const ValueKey<String>('settings-account-card')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        ),
      );
      expect(horizontalScrolls, findsNothing);
    },
  );

  testWidgets('wide shell avoids top system inset without growing header', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(760, 390));
    tester.view.padding = const FakeViewPadding(top: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24);
    addTearDown(() {
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });

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

    expect(
      find.byKey(const ValueKey<String>('desktop-system-top-inset')),
      findsOneWidget,
    );
    final headerRect = tester.getRect(
      find.byKey(const ValueKey<String>('desktop-dashboard-header-content')),
    );
    expect(headerRect.top, 24);
    expect(headerRect.height, 64);
  });

  testWidgets('mobile shell uses bottom navigation', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(390, 760));

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
      ],
      managedDevices: const <ManagedDevice>[
        ManagedDevice(
          id: 'device-1',
          machineId: 'machine-1',
          hostname: 'phone-1',
          approvalState: 'approved',
          connectivityState: 'online',
        ),
      ],
      networkDevices: const <String, List<NetworkDevice>>{
        'net-1': <NetworkDevice>[
          NetworkDevice(
            id: 'node-1',
            name: 'phone-1',
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

    expect(
      find.byKey(const ValueKey<String>('mobile-dashboard-navigation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('network-tab-current')),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate((widget) => widget is FHeader),
      findsOneWidget,
    );
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('EasyTier Pro'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('mobile-nav-devices')));
    await tester.pumpAndSettle();

    expect(find.text('phone-1'), findsOneWidget);
  });

  testWidgets('mobile shell switches pages with horizontal swipes', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(390, 760));

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: '办公网', regions: ['ap-east']),
      ],
      managedDevices: const <ManagedDevice>[
        ManagedDevice(
          id: 'device-1',
          machineId: 'machine-1',
          hostname: 'phone-1',
          approvalState: 'approved',
          connectivityState: 'online',
        ),
      ],
      networkDevices: const <String, List<NetworkDevice>>{
        'net-1': <NetworkDevice>[
          NetworkDevice(
            id: 'node-1',
            name: 'phone-1',
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

    final navigation = find.byKey(
      const ValueKey<String>('mobile-dashboard-navigation'),
    );
    final swipeTarget = find.byKey(
      const ValueKey<String>('mobile-dashboard-page-swipe'),
    );
    expect(tester.widget<FBottomNavigationBar>(navigation).index, 0);

    await tester.fling(swipeTarget, const Offset(-220, -440), 1600);
    await tester.pumpAndSettle();
    expect(tester.widget<FBottomNavigationBar>(navigation).index, 0);

    await tester.fling(swipeTarget, const Offset(-320, 0), 1000);
    await tester.pumpAndSettle();
    expect(tester.widget<FBottomNavigationBar>(navigation).index, 1);

    await tester.fling(swipeTarget, const Offset(-320, 0), 1000);
    await tester.pumpAndSettle();
    expect(tester.widget<FBottomNavigationBar>(navigation).index, 2);

    await tester.fling(swipeTarget, const Offset(320, 0), 1000);
    await tester.pumpAndSettle();
    expect(tester.widget<FBottomNavigationBar>(navigation).index, 1);
  });

  testWidgets('mobile network nav opens picker when already on network page', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester, size: const Size(390, 760));

    final authService = _FakeAuthService(
      networks: const <ConsoleNetwork>[
        ConsoleNetwork(id: 'net-1', name: 'Office', regions: ['ap-east']),
        ConsoleNetwork(id: 'net-2', name: 'Lab', regions: ['ap-east']),
      ],
      networkDevices: const <String, List<NetworkDevice>>{
        'net-1': <NetworkDevice>[
          NetworkDevice(id: 'node-1', name: 'office-phone', online: true),
        ],
        'net-2': <NetworkDevice>[
          NetworkDevice(id: 'node-2', name: 'lab-phone', online: true),
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

    await tester.tap(find.byKey(const ValueKey<String>('mobile-nav-network')));
    await tester.pumpAndSettle();

    expect(find.text('office-phone'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mobile-network-picker-sheet')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('mobile-nav-network')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('mobile-network-picker-sheet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mobile-network-option-net-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('mobile-network-option-net-2')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('mobile-network-option-net-2')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('mobile-network-picker-sheet')),
      findsNothing,
    );
    expect(find.text('lab-phone'), findsOneWidget);
    expect(find.text('office-phone'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('mobile-nav-network')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mobile-network-option-net-1')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mobile-network-option-net-2')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('settings exposes selectable and copyable runtime errors', (
    WidgetTester tester,
  ) async {
    _useDesktopViewport(tester);

    const errorText = 'Android VPN 缺少虚拟 IP 配置，instance_key=8af8e8c8-4dd4-4f82';
    final authService = _FakeAuthService();
    final coreLifecycleService = _NoopCoreLifecycleService(
      authService: authService,
      machineId: 'machine-1',
    );

    await tester.pumpWidget(
      MyApp(
        authService: authService,
        traySupport: createTraySupport(),
        coreLifecycleService: coreLifecycleService,
      ),
    );
    await tester.pumpAndSettle();

    coreLifecycleService.status.value = const CoreRunStatus(
      phase: CoreRunPhase.error,
      message: '连接引擎运行异常',
      lastError: errorText,
      machineId: 'machine-1',
    );
    await tester.pump();

    await _openSettingsFromUserMenu(tester);

    expect(
      find.byWidgetPredicate((widget) {
        return widget is SelectableText && widget.data == errorText;
      }),
      findsOneWidget,
    );
    expect(find.text('复制错误'), findsOneWidget);

    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final data = call.arguments as Map<Object?, Object?>;
            clipboardText = data['text']?.toString();
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.tap(find.text('复制错误'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(clipboardText, errorText);
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

    expect(find.text('本机设备尚未批准，请先在控制台批准设备。'), findsOneWidget);
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
          displayName: '工作笔记本',
          hostname: 'desktop-1',
          approvalState: 'approved',
          connectivityState: 'online',
          os: 'windows',
          osDistribution: 'Windows 11 Pro',
        ),
        ManagedDevice(
          id: 'device-2',
          machineId: 'machine-2',
          hostname: 'laptop-2',
          approvalState: 'pending',
          connectivityState: 'offline',
          os: 'linux',
          osDistribution: 'Ubuntu',
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

    expect(find.text('工作笔记本'), findsOneWidget);
    expect(find.textContaining('desktop-1'), findsOneWidget);
    expect(find.text('laptop-2'), findsOneWidget);
    expect(find.text('old-desktop'), findsNothing);
    expect(find.text('node-alias'), findsNothing);
    expect(find.byTooltip('Windows 11 Pro · windows'), findsOneWidget);
    expect(find.byTooltip('Ubuntu · linux'), findsOneWidget);
    expect(find.text('2 台设备 · 1 在线 · 1 待批准'), findsOneWidget);
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

  test('parses fanout traffic stats by runtime network name', () {
    final totals = CoreLifecycleService.parseNetworkTrafficTotalsFromJson(
      jsonEncode([
        {
          'instance_id': 'instance-1',
          'instance_name': 'nt-office',
          'result': [
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
          ],
        },
        {
          'instance_id': 'instance-2',
          'instance_name': 'nt-lab',
          'result': [
            {
              'name': 'traffic_bytes_self_rx',
              'value': 4096,
              'labels': {'network_name': 'nt-lab'},
            },
            {
              'name': 'traffic_bytes_self_tx',
              'value': 8192,
              'labels': {'network_name': 'nt-lab'},
            },
          ],
        },
      ]),
      sampledAt: DateTime.utc(2026, 1, 1),
    );

    expect(totals.length, 2);
    expect(totals['nt-office']?.downloadBytes, 1024);
    expect(totals['nt-office']?.uploadBytes, 2048);
    expect(totals['nt-lab']?.downloadBytes, 4096);
    expect(totals['nt-lab']?.uploadBytes, 8192);
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
              'display_name': '工作笔记本',
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
    expect(devices.single.displayName, '工作笔记本');
    expect(devices.single.displayLabel, '工作笔记本');
    expect(devices.single.hostname, 'desktop-1');
    expect(devices.single.approved, isTrue);
    expect(devices.single.online, isTrue);
    expect(devices.single.os, 'windows');
    expect(devices.single.osVersion, '11');
    expect(devices.single.osDistribution, 'Windows 11 Pro');
    expect(devices.single.removed, isFalse);
  });

  test('console service reports host when DNS lookup fails', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final service = ConsoleAuthService(
      tokenStore: OAuthTokenStore(preferences),
      httpClient: MockClient((request) async {
        throw http.ClientException(
          "SocketException: Failed host lookup: '${request.url.host}' "
          '(OS Error: No address associated with hostname, errno = 7)',
          request.url,
        );
      }),
    );

    await expectLater(
      service.startDeviceAuth(),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          allOf(contains('api.console.easytier.net'), contains('无法解析')),
        ),
      ),
    );
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
              'device': {
                'display_name': '工作笔记本',
                'hostname': 'device-hostname',
              },
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
    expect(nodes.single.name, '工作笔记本');
    expect(nodes.single.hostname, 'desktop-1');
  });

  test('console service parses subnet routes and node config views', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final service = ConsoleAuthService(
      tokenStore: OAuthTokenStore(preferences),
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path ==
            '/api/v1/tenants/tenant-1/networks/net-1/subnet-routes') {
          return _jsonResponse({
            'routes': [
              {
                'id': 'route-1',
                'cidr': '192.168.50.0/24',
                'mapped_cidr': '10.50.0.0/24',
                'node_ids': ['node-router'],
                'nodes': [
                  {
                    'id': 'node-router',
                    'hostname': 'edge-router',
                    'machine_id': 'machine-router',
                    'status': 'online',
                    'provisioning_state': 'ready',
                  },
                ],
                'manual_route_node_ids': ['node-1'],
                'manual_route_nodes': [
                  {
                    'id': 'node-1',
                    'hostname': 'desktop-1',
                    'machine_id': 'machine-1',
                    'status': 'offline',
                    'provisioning_state': 'ready',
                  },
                ],
              },
            ],
            'allowed_proxy_cidrs': ['192.168.0.0/16'],
            'quota_limit': 8,
            'quota_used': 1,
          });
        }
        if (request.url.path ==
            '/api/v1/tenants/tenant-1/nodes/node-1/config') {
          return _jsonResponse({
            'defaults': {
              'p2p_mode': 'automatic',
              'listener_protocols': ['tcp'],
            },
            'override': {'p2p_mode': 'p2p_only'},
            'effective': {
              'ipv4': '10.144.0.2',
              'hostname': 'desktop-1',
              'p2p_mode': 'p2p_only',
              'listener_protocols': ['tcp', 'udp'],
              'magic_dns_enabled': true,
              'no_tun': false,
              'proxy_forward_by_system': true,
              'userspace_stack': false,
            },
            'config_scope': 'customized',
            'apply_status': 'applied',
            'drift_status': 'in_sync',
            'assigned_subnet_routes': [
              {
                'id': 'route-1',
                'cidr': '192.168.50.0/24',
                'mapped_cidr': '10.50.0.0/24',
              },
            ],
            'manual_subnet_routes': [
              {'id': 'route-2', 'cidr': '172.16.8.0/24'},
            ],
            'manual_routes_enabled': true,
          });
        }
        return http.Response('{}', 404);
      }),
    );

    final routes = await service.fetchNetworkSubnetRoutes(
      accessToken: 'token',
      workspaceId: 'tenant-1',
      networkId: 'net-1',
    );
    final config = await service.fetchNodeConfig(
      accessToken: 'token',
      workspaceId: 'tenant-1',
      nodeId: 'node-1',
    );

    expect(requests[0].method, 'GET');
    expect(
      requests[0].url.path,
      '/api/v1/tenants/tenant-1/networks/net-1/subnet-routes',
    );
    expect(requests[1].method, 'GET');
    expect(
      requests[1].url.path,
      '/api/v1/tenants/tenant-1/nodes/node-1/config',
    );
    expect(routes.quotaLimit, 8);
    expect(routes.quotaUsed, 1);
    expect(routes.allowedProxyCidrs, <String>['192.168.0.0/16']);
    expect(routes.routes.single.cidr, '192.168.50.0/24');
    expect(routes.routes.single.mappedCidr, '10.50.0.0/24');
    expect(routes.routes.single.nodes.single.displayLabel, 'edge-router');
    expect(routes.routes.single.manualRouteNodes.single.status, 'offline');
    expect(config.defaults.p2pMode, 'automatic');
    expect(config.overrides.p2pMode, 'p2p_only');
    expect(config.effective.ipv4, '10.144.0.2');
    expect(config.effective.listenerProtocols, <String>['tcp', 'udp']);
    expect(config.effective.magicDnsEnabled, isTrue);
    expect(config.configScope, 'customized');
    expect(config.applyStatus, 'applied');
    expect(config.driftStatus, 'in_sync');
    expect(config.assignedSubnetRoutes.single.mappedCidr, '10.50.0.0/24');
    expect(config.manualSubnetRoutes.single.cidr, '172.16.8.0/24');
    expect(config.manualRoutesEnabled, isTrue);
  });

  test(
    'console service prefers per-network node status over device status',
    () async {
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
                'id': 'node-online',
                'status': 'online',
                'device': {'connectivity_state': 'offline'},
              },
              {
                'id': 'node-offline',
                'status': 'offline',
                'device': {'connectivity_state': 'online'},
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

      expect(nodes, hasLength(2));
      expect(nodes[0].id, 'node-online');
      expect(nodes[0].online, isTrue);
      expect(nodes[1].id, 'node-offline');
      expect(nodes[1].online, isFalse);
    },
  );

  test(
    'console service creates platform scoped enrollment key names',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      Future<String> createKeyNameFor(TargetPlatform platform) async {
        debugDefaultTargetPlatformOverride = platform;
        final requests = <http.Request>[];
        final service = ConsoleAuthService(
          tokenStore: OAuthTokenStore(preferences),
          consoleBaseUrl: 'https://console.test',
          httpClient: MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/api/v1/releases/latest') {
              return _jsonResponse({
                'stable': {'version': 'v2.6.4'},
                'web_config_server_url': 'tcp://config.test:22020',
              });
            }
            if (request.url.path ==
                '/api/v1/tenants/tenant-1/device-enrollment-keys') {
              if (request.method == 'GET') {
                return _jsonResponse([]);
              }
              return _jsonResponse({'bootstrap_token': 'bootstrap-token'}, 201);
            }
            return http.Response('{}', 404);
          }),
        );

        await service.prepareCoreBootstrap(
          accessToken: 'token',
          workspaceId: 'tenant-1',
        );
        final createRequest = requests.singleWhere(
          (request) => request.method == 'POST',
        );
        return (jsonDecode(createRequest.body)
                as Map<String, dynamic>)['display_name']
            as String;
      }

      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      expect(
        await createKeyNameFor(TargetPlatform.android),
        'Android Auto Key',
      );
      expect(
        await createKeyNameFor(TargetPlatform.windows),
        'Desktop Auto Key',
      );
    },
  );

  test('console service prefers platform scoped enrollment keys', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    final requests = <http.Request>[];
    final service = ConsoleAuthService(
      tokenStore: OAuthTokenStore(preferences),
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/v1/releases/latest') {
          return _jsonResponse({
            'stable': {'version': 'v2.6.4'},
            'web_config_server_url': 'tcp://config.test:22020',
          });
        }
        if (request.url.path ==
            '/api/v1/tenants/tenant-1/device-enrollment-keys') {
          return _jsonResponse([
            {
              'id': 'desktop-key',
              'display_name': 'Desktop Auto Key',
              'reusable': true,
            },
            {
              'id': 'android-key',
              'display_name': 'Android Auto Key',
              'reusable': true,
            },
          ]);
        }
        if (request.url.path.endsWith('/android-key/secret')) {
          return _jsonResponse({'bootstrap_token': 'android-token'});
        }
        if (request.url.path.endsWith('/desktop-key/secret')) {
          return _jsonResponse({'bootstrap_token': 'desktop-token'});
        }
        return http.Response('{}', 404);
      }),
    );

    final bootstrap = await service.prepareCoreBootstrap(
      accessToken: 'token',
      workspaceId: 'tenant-1',
    );

    expect(bootstrap.bootstrapToken, 'android-token');
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    expect(
      requests.any(
        (request) => request.url.path.endsWith('/desktop-key/secret'),
      ),
      isFalse,
    );
  });

  test(
    'console service creates Android key instead of reusing other platform keys',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      final requests = <http.Request>[];
      final service = ConsoleAuthService(
        tokenStore: OAuthTokenStore(preferences),
        consoleBaseUrl: 'https://console.test',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/v1/releases/latest') {
            return _jsonResponse({
              'stable': {'version': 'v2.6.4'},
              'web_config_server_url': 'tcp://config.test:22020',
            });
          }
          if (request.url.path ==
              '/api/v1/tenants/tenant-1/device-enrollment-keys') {
            if (request.method == 'GET') {
              return _jsonResponse([
                {
                  'id': 'desktop-key',
                  'display_name': 'Desktop Auto Key',
                  'reusable': true,
                },
                {
                  'id': 'android-one-time-key',
                  'display_name': 'Android Auto Key',
                  'reusable': false,
                },
              ]);
            }
            return _jsonResponse({'bootstrap_token': 'android-token'}, 201);
          }
          if (request.url.path.endsWith('/android-one-time-key/secret')) {
            return _jsonResponse({'bootstrap_token': 'one-time-token'});
          }
          if (request.url.path.endsWith('/desktop-key/secret')) {
            return _jsonResponse({'bootstrap_token': 'desktop-token'});
          }
          return http.Response('{}', 404);
        }),
      );

      final bootstrap = await service.prepareCoreBootstrap(
        accessToken: 'token',
        workspaceId: 'tenant-1',
      );

      final createRequest = requests.singleWhere(
        (request) => request.method == 'POST',
      );
      expect(bootstrap.bootstrapToken, 'android-token');
      expect(
        (jsonDecode(createRequest.body)
            as Map<String, dynamic>)['display_name'],
        'Android Auto Key',
      );
      expect(
        requests.any(
          (request) =>
              request.url.path.endsWith('/desktop-key/secret') ||
              request.url.path.endsWith('/android-one-time-key/secret'),
        ),
        isFalse,
      );
    },
  );

  test(
    'console service derives local config server fallback from console host',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      Future<String> prepareConfigServer(String consoleBaseUrl) async {
        final service = ConsoleAuthService(
          tokenStore: OAuthTokenStore(preferences),
          consoleBaseUrl: consoleBaseUrl,
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/v1/releases/latest') {
              return _jsonResponse({
                'stable': {'version': 'v2.6.4'},
                'web_config_server_url': '',
              });
            }
            if (request.url.path ==
                '/api/v1/tenants/tenant-1/device-enrollment-keys') {
              if (request.method == 'GET') {
                return _jsonResponse([]);
              }
              return _jsonResponse({'bootstrap_token': 'bootstrap-token'}, 201);
            }
            return http.Response('{}', 404);
          }),
        );

        final bootstrap = await service.prepareCoreBootstrap(
          accessToken: 'token',
          workspaceId: 'tenant-1',
        );
        return bootstrap.configServer;
      }

      expect(
        await prepareConfigServer('http://10.147.223.128:14173'),
        'tcp://10.147.223.128:22020',
      );
      expect(
        await prepareConfigServer('https://api.console.easytier.net'),
        'tcp://api.console.easytier.net:22020',
      );
    },
  );

  test('console service reports invalid auth during bootstrap', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final service = ConsoleAuthService(
      tokenStore: OAuthTokenStore(preferences),
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/releases/latest') {
          return _jsonResponse({
            'stable': {'version': 'v2.6.4'},
            'web_config_server_url': 'tcp://config.test:22020',
          });
        }
        if (request.url.path ==
            '/api/v1/tenants/tenant-1/device-enrollment-keys') {
          return _jsonResponse({'message': 'unauthorized'}, 401);
        }
        return http.Response('{}', 404);
      }),
    );

    await expectLater(
      service.prepareCoreBootstrap(
        accessToken: 'expired-token',
        workspaceId: 'tenant-1',
      ),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          '当前登录态已失效，请重新登录。',
        ),
      ),
    );
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

void _expectTrafficSparklineWindow(
  WidgetTester tester,
  List<double> expectedXs,
) {
  final chart = tester.widget<LineChart>(find.byType(LineChart));

  expect(chart.duration, Duration.zero);
  expect(chart.data.minX, 0);
  expect(chart.data.maxX, 29);
  expect(chart.data.lineBarsData.length, greaterThanOrEqualTo(2));

  for (final line in chart.data.lineBarsData.take(2)) {
    final xs = line.spots.map((spot) => spot.x).toList(growable: false);
    expect(xs, expectedXs);
    expect(xs.last, 29);
  }
}

void _expectTrafficChartAnimations(WidgetTester tester) {
  for (final chart in tester.widgetList<LineChart>(find.byType(LineChart))) {
    if (chart.data.titlesData.show) {
      expect(chart.duration, greaterThan(Duration.zero));
    } else {
      expect(chart.duration, Duration.zero);
    }
  }
}

void _expectTrafficChartYScalesFixed(WidgetTester tester) {
  const fixedScales = <double>[
    1024,
    10 * 1024,
    100 * 1024,
    1024 * 1024,
    10 * 1024 * 1024,
    100 * 1024 * 1024,
    1024 * 1024 * 1024,
    10 * 1024 * 1024 * 1024,
    100 * 1024 * 1024 * 1024,
    1024 * 1024 * 1024 * 1024,
  ];

  for (final chart in tester.widgetList<LineChart>(find.byType(LineChart))) {
    expect(fixedScales, contains(chart.data.maxY));
  }
}

void _expectDetailedTrafficChartMaxX(WidgetTester tester, double expectedMaxX) {
  final detailedCharts = tester
      .widgetList<LineChart>(find.byType(LineChart))
      .where((chart) => chart.data.titlesData.show)
      .toList(growable: false);

  expect(detailedCharts, hasLength(1));
  expect(detailedCharts.single.data.maxX, expectedMaxX);
}

Finder _trafficTimeLabels() {
  final timePattern = RegExp(r'^\d{2}:\d{2}:\d{2}$');
  return find.byWidgetPredicate(
    (widget) => widget is Text && timePattern.hasMatch(widget.data ?? ''),
  );
}

void _expectTextSingleLine(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  expect(text.maxLines, 1);
  expect(text.softWrap, isFalse);
  expect(text.overflow, TextOverflow.visible);
}

void _expectTrafficTimeLabelsFitInside(WidgetTester tester) {
  final timePattern = RegExp(r'^\d{2}:\d{2}:\d{2}$');
  final timeTitleWidgets = tester
      .widgetList<SideTitleWidget>(find.byType(SideTitleWidget))
      .where((widget) {
        final child = widget.child;
        return child is Text && timePattern.hasMatch(child.data ?? '');
      })
      .toList(growable: false);

  expect(timeTitleWidgets, isNotEmpty);
  for (final widget in timeTitleWidgets) {
    expect(widget.fitInside.enabled, isTrue);
  }
}

void _expectTrafficXAxisLabelsOutsideGraph(WidgetTester tester) {
  final detailedCharts = tester
      .widgetList<LineChart>(find.byType(LineChart))
      .where((chart) => chart.data.titlesData.show)
      .toList(growable: false);

  expect(detailedCharts, isNotEmpty);
  for (final chart in detailedCharts) {
    final bottomTitles = chart.data.titlesData.bottomTitles;
    expect(bottomTitles.sideTitleAlignment, SideTitleAlignment.outside);
    expect(bottomTitles.sideTitles.reservedSize, greaterThanOrEqualTo(24));
  }
}

bool _hasSelectionAreaAncestor(WidgetTester tester, Finder finder) {
  final element = tester.element(finder);
  var found = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is SelectionContainer && widget.registrar == null) {
      found = false;
      return false;
    }
    if (widget is SelectionArea) {
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

Future<void> _openSettingsFromUserMenu(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(FAvatar), matching: find.text('T')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('user-menu-settings')));
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

class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  int launchCount = 0;

  @override
  Null get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchCount++;
    return true;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launchCount++;
    return true;
  }
}

class _LoginFlowAuthService implements AuthService {
  int startDeviceAuthCount = 0;
  int completeDeviceAuthCount = 0;

  @override
  Future<AuthSession?> restoreSession() async {
    return null;
  }

  @override
  Future<DeviceAuthInfo> startDeviceAuth() async {
    startDeviceAuthCount++;
    return const DeviceAuthInfo(
      deviceCode: 'device-code',
      userCode: 'USER-CODE',
      verificationUri: 'https://auth.console.easytier.net/login/oauth/device',
      verificationUriComplete:
          'https://auth.console.easytier.net/login/oauth/device/test-code',
      expiresIn: 600,
      interval: 5,
    );
  }

  @override
  Future<AuthSession> completeDeviceAuth(DeviceAuthInfo info) async {
    completeDeviceAuthCount++;
    return AuthSession(
      user: const ConsoleUser(
        email: 'tester@example.com',
        displayName: 'Test User',
        workspaces: <ConsoleWorkspace>[
          ConsoleWorkspace(id: 'tenant-1', name: '涓汉绌洪棿'),
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
  Future<void> logout() async {}

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
  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  }) async {
    return const <ManagedDevice>[];
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
  Future<NetworkSubnetRouteList> fetchNetworkSubnetRoutes({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    return const NetworkSubnetRouteList(
      routes: <NetworkSubnetRoute>[],
      allowedProxyCidrs: <String>[],
      quotaLimit: 0,
      quotaUsed: 0,
    );
  }

  @override
  Future<NodeInstanceConfigView> fetchNodeConfig({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  }) async {
    return _emptyNodeConfigView();
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
    return const CoreBootstrapConfig(
      bootstrapToken: 'bootstrap-token',
      version: 'v1.0.0',
      configServer: 'tcp://api.console.easytier.net:22020',
    );
  }
}

NodeInstanceConfigView _emptyNodeConfigView() {
  return const NodeInstanceConfigView(
    defaults: NodeInstanceConfigSettings(),
    overrides: NodeInstanceConfigSettings(),
    effective: NodeInstanceConfigSettings(),
    configScope: '',
    applyStatus: '',
    driftStatus: '',
  );
}

class _FakeAuthService implements AuthService {
  _FakeAuthService({
    List<ConsoleNetwork> networks = const <ConsoleNetwork>[],
    this.managedDevices = const <ManagedDevice>[],
    Map<String, List<NetworkDevice>> networkDevices =
        const <String, List<NetworkDevice>>{},
    Map<String, NetworkSubnetRouteList> subnetRoutes =
        const <String, NetworkSubnetRouteList>{},
    Map<String, List<Object>> subnetRouteFailures =
        const <String, List<Object>>{},
    Map<String, NodeInstanceConfigView> nodeConfigs =
        const <String, NodeInstanceConfigView>{},
    this.attachDeviceDelay,
    this.removeNetworkNodeDelay,
  }) : networks = List<ConsoleNetwork>.of(networks),
       networkDevices = Map<String, List<NetworkDevice>>.from(networkDevices),
       subnetRoutes = Map<String, NetworkSubnetRouteList>.from(subnetRoutes),
       subnetRouteFailures = subnetRouteFailures.map(
         (key, value) => MapEntry(key, List<Object>.of(value)),
       ),
       nodeConfigs = Map<String, NodeInstanceConfigView>.from(nodeConfigs);

  final List<ConsoleNetwork> networks;
  final List<ManagedDevice> managedDevices;
  final Map<String, List<NetworkDevice>> networkDevices;
  final Map<String, NetworkSubnetRouteList> subnetRoutes;
  final Map<String, List<Object>> subnetRouteFailures;
  final Map<String, NodeInstanceConfigView> nodeConfigs;
  final Future<void>? attachDeviceDelay;
  final Future<void>? removeNetworkNodeDelay;
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
    subnetRoutes[network.id] = const NetworkSubnetRouteList(
      routes: <NetworkSubnetRoute>[],
      allowedProxyCidrs: <String>[],
      quotaLimit: 0,
      quotaUsed: 0,
    );
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
    subnetRoutes.remove(networkId);
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
  Future<NetworkSubnetRouteList> fetchNetworkSubnetRoutes({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    final failures = subnetRouteFailures[networkId];
    if (failures != null && failures.isNotEmpty) {
      throw failures.removeAt(0);
    }
    return subnetRoutes[networkId] ??
        const NetworkSubnetRouteList(
          routes: <NetworkSubnetRoute>[],
          allowedProxyCidrs: <String>[],
          quotaLimit: 0,
          quotaUsed: 0,
        );
  }

  @override
  Future<NodeInstanceConfigView> fetchNodeConfig({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  }) async {
    return nodeConfigs[nodeId] ?? _emptyNodeConfigView();
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
    final delay = attachDeviceDelay;
    if (delay != null) {
      await delay;
    }
    attachedNetworkIds.add(networkId);
    final device = managedDevices.firstWhere((item) => item.id == deviceId);
    networkDevices[networkId] = <NetworkDevice>[
      ...(networkDevices[networkId] ?? const <NetworkDevice>[]),
      NetworkDevice(
        id: 'node-${networkId.substring(networkId.length - 1)}',
        name: device.displayLabel,
        online: true,
        hostname: device.hostname,
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
    final delay = removeNetworkNodeDelay;
    if (delay != null) {
      await delay;
    }
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
    this.instanceRunning = true,
    this.trafficSamples = const <Map<String, CoreNetworkTrafficTotals>>[],
    this.peerSamples = const <Map<String, CorePeerStatus>>[],
    this.peerError,
  });

  final String? machineId;
  final bool instanceRunning;
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
  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    return instanceRunning;
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
