import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_peer_status.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:easytier_pro_app/src/logging/app_logger.dart';
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

    test('clears engine version status when workspace switch fails', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.3';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      expect(
        service.engineVersionStatus.value.relation,
        CoreEngineVersionRelation.updateAvailable,
      );

      runtime.ensureRunningError = StateError('install failed');
      await service.bindSession(_session('tenant-2'));

      expect(service.status.value.phase, CoreRunPhase.error);
      expect(
        service.engineVersionStatus.value.relation,
        CoreEngineVersionRelation.unknown,
      );
      expect(service.engineVersionStatus.value.installedVersion, isNull);
      expect(service.engineVersionStatus.value.consoleVersion, isNull);
    });

    test('binds token connection without workspace bootstrap', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindTokenConnection(
        TokenConnectionProfile(
          bootstrapToken: 'device-token',
          configServer: 'tcp://127.0.0.1:22020',
          displayName: 'token profile',
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      expect(authService.prepareBootstrapCount, 0);
      expect(authService.fetchVersionCount, 1);
      expect(authService.workspaceIds, isEmpty);
      expect(runtime.ensureRunningCount, 1);
      expect(runtime.forceReinstallValues, [false]);
      expect(service.status.value.phase, CoreRunPhase.running);
      expect(service.status.value.machineId, 'machine-1');
    });

    test(
      'token connection uses release config server for default profiles',
      () async {
        final authService = _LifecycleAuthService()
          ..bootstrapConfigServer = 'tcp://et-web.console.easytier.net:22020';
        final runtime = _LifecycleRuntime();
        final service = CoreLifecycleService(
          authService: authService,
          runtime: runtime,
        );
        addTearDown(service.dispose);

        await service.bindTokenConnection(
          TokenConnectionProfile(
            bootstrapToken: 'device-token',
            configServer: 'tcp://api.console.easytier.net:22020',
            displayName: 'token profile',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );

        expect(authService.prepareBootstrapCount, 0);
        expect(
          runtime.ensureRunningBootstraps.single.configServer,
          'tcp://et-web.console.easytier.net:22020',
        );
      },
    );

    test('repair rebuilds active token connection', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindTokenConnection(
        TokenConnectionProfile(
          bootstrapToken: 'device-token',
          configServer: 'tcp://127.0.0.1:22020',
          displayName: 'token profile',
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await service.repair();

      expect(authService.prepareBootstrapCount, 0);
      expect(authService.fetchVersionCount, 2);
      expect(runtime.ensureRunningCount, 2);
      expect(runtime.forceReinstallValues, [false, true]);
      expect(service.status.value.phase, CoreRunPhase.running);
    });
  });

  group('CoreLifecycleService engine version', () {
    test('desktop peer status reads verbose peer routes', () async {
      final owner = CoreLifecycleService(
        authService: _LifecycleAuthService(),
        runtime: _LifecycleRuntime(),
      );
      addTearDown(owner.dispose);

      var recordedArguments = const <String>[];
      final process = _VersionProbeProcess();
      final runtime = DesktopCoreRuntime(
        owner,
        processStarter: (_, arguments) async {
          recordedArguments = List<String>.of(arguments);
          scheduleMicrotask(
            () => process.complete(exitCode: 0, stdoutText: '[]'),
          );
          return process;
        },
      );

      final statuses = await runtime.readNetworkPeerStatuses('network-a');

      expect(statuses, isEmpty);
      expect(recordedArguments, [
        '-v',
        '-o',
        'json',
        '--instance-name',
        'network-a',
        'peer',
      ]);
    });

    test('desktop version probe sends sigkill on POSIX timeout', () async {
      final owner = CoreLifecycleService(
        authService: _LifecycleAuthService(),
        runtime: _LifecycleRuntime(),
      );
      addTearDown(owner.dispose);

      final process = _VersionProbeProcess(terminateOnSigterm: false);
      final runtime = DesktopCoreRuntime(
        owner,
        processStarter: (_, _) async => process,
        isWindows: false,
        versionProbeTimeout: const Duration(milliseconds: 1),
        versionProbeTerminateTimeout: const Duration(milliseconds: 1),
      );

      final version = await runtime.readInstalledVersion();

      expect(version, isNull);
      expect(process.killSignals, [
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      expect(process.exited, isTrue);
    });

    test('desktop version probe uses taskkill on Windows timeout', () async {
      final owner = CoreLifecycleService(
        authService: _LifecycleAuthService(),
        runtime: _LifecycleRuntime(),
      );
      addTearDown(owner.dispose);

      final forcedPids = <int>[];
      final process = _VersionProbeProcess(terminateOnSigterm: false);
      final runtime = DesktopCoreRuntime(
        owner,
        processStarter: (_, _) async => process,
        windowsProcessTreeKiller: (pid) async {
          forcedPids.add(pid);
          process.complete(exitCode: -1);
          return 0;
        },
        isWindows: true,
        versionProbeTimeout: const Duration(milliseconds: 1),
        versionProbeTerminateTimeout: const Duration(milliseconds: 1),
      );

      final version = await runtime.readInstalledVersion();

      expect(version, isNull);
      expect(process.killSignals, [ProcessSignal.sigterm]);
      expect(forcedPids, [4242]);
      expect(process.exited, isTrue);
    });

    test('compares normalized core versions', () {
      expect(CoreLifecycleService.compareCoreVersions('v2.6.3', '2.6.4'), -1);
      expect(
        CoreLifecycleService.compareCoreVersions('EasyTier 2.6.4', 'v2.6.4'),
        0,
      );
      expect(CoreLifecycleService.compareCoreVersions('v2.7.0', 'v2.6.4'), 1);
      expect(
        CoreLifecycleService.compareCoreVersions('unknown', 'v2.6.4'),
        isNull,
      );
    });

    test('publishes update available when console version is newer', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.3';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      final versionStatus = service.engineVersionStatus.value;
      expect(versionStatus.relation, CoreEngineVersionRelation.updateAvailable);
      expect(versionStatus.installedVersion, 'v2.6.3');
      expect(versionStatus.consoleVersion, 'v2.6.4');
      expect(runtime.ensureRunningCount, 0);
    });

    test('repair publishes current console version after reinstall', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.3';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      expect(
        service.engineVersionStatus.value.relation,
        CoreEngineVersionRelation.updateAvailable,
      );

      await service.repair();

      final versionStatus = service.engineVersionStatus.value;
      expect(versionStatus.relation, CoreEngineVersionRelation.current);
      expect(versionStatus.installedVersion, 'v2.6.4');
      expect(versionStatus.consoleVersion, 'v2.6.4');
      expect(runtime.ensureRunningCount, 1);
    });

    test('version check uses read-only console version lookup', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.4';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      authService.bootstrapVersion = '2.6.5';
      runtime.installedVersion = '2.6.4';
      await service.checkEngineVersion();

      final versionStatus = service.engineVersionStatus.value;
      expect(authService.prepareBootstrapCount, 1);
      expect(authService.fetchVersionCount, 1);
      expect(versionStatus.relation, CoreEngineVersionRelation.updateAvailable);
      expect(versionStatus.installedVersion, 'v2.6.4');
      expect(versionStatus.consoleVersion, 'v2.6.5');
    });

    test('version check does not reuse stale installed version', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.3';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      expect(
        service.engineVersionStatus.value.relation,
        CoreEngineVersionRelation.updateAvailable,
      );

      authService.bootstrapVersion = '2.6.5';
      runtime.connected = false;
      await service.checkEngineVersion();

      final versionStatus = service.engineVersionStatus.value;
      expect(versionStatus.relation, CoreEngineVersionRelation.unknown);
      expect(versionStatus.installedVersion, isNull);
      expect(versionStatus.consoleVersion, 'v2.6.5');
    });

    test('version check does not block repair lifecycle action', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.4';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      authService.versionCompleter = Completer<String>();
      unawaited(service.checkEngineVersion());
      await Future<void>.delayed(Duration.zero);

      final repair = service.repair();
      await repair.timeout(const Duration(seconds: 1));

      expect(runtime.ensureRunningCount, 1);
      authService.versionCompleter!.complete('2.6.4');
      await service.checkEngineVersion();
    });

    test(
      'pending version check is ignored after repair publishes version',
      () async {
        final authService = _LifecycleAuthService();
        final runtime = _LifecycleRuntime()
          ..connected = true
          ..installedVersion = '2.6.3';
        final service = CoreLifecycleService(
          authService: authService,
          runtime: runtime,
          engineVersionCheckInterval: Duration.zero,
        );
        addTearDown(service.dispose);

        await service.bindSession(_session('tenant-1'));

        final staleVersion = Completer<String>();
        authService.versionCompleter = staleVersion;
        final check = service.checkEngineVersion();
        await Future<void>.delayed(Duration.zero);

        authService.versionCompleter = null;
        await service.repair();
        staleVersion.complete('2.6.5');
        await check;

        final versionStatus = service.engineVersionStatus.value;
        expect(versionStatus.relation, CoreEngineVersionRelation.current);
        expect(versionStatus.installedVersion, 'v2.6.4');
        expect(versionStatus.consoleVersion, 'v2.6.4');
      },
    );

    test('version check started during repair is ignored', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.3';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      final repairGate = Completer<void>();
      runtime.ensureRunningCompleter = repairGate;
      final repair = service.repair();
      await _waitUntil(() => runtime.ensureRunningCount == 1);

      final staleVersion = Completer<String>();
      authService.versionCompleter = staleVersion;
      final check = service.checkEngineVersion();
      await Future<void>.delayed(Duration.zero);

      repairGate.complete();
      await repair;
      staleVersion.complete('2.6.5');
      await check;

      final versionStatus = service.engineVersionStatus.value;
      expect(versionStatus.relation, CoreEngineVersionRelation.current);
      expect(versionStatus.installedVersion, 'v2.6.4');
      expect(versionStatus.consoleVersion, 'v2.6.4');
    });

    test('pending version check is ignored after logout', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.4';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      final staleVersion = Completer<String>();
      authService.versionCompleter = staleVersion;
      final check = service.checkEngineVersion();
      await Future<void>.delayed(Duration.zero);

      await service.onLogout();
      authService.versionCompleter!.complete('2.6.5');
      await check;

      expect(
        service.engineVersionStatus.value.relation,
        CoreEngineVersionRelation.unknown,
      );
      expect(service.engineVersionStatus.value.consoleVersion, isNull);
    });

    test('pending version check is ignored after workspace switch', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.4';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      final staleVersion = Completer<String>();
      authService.versionCompleter = staleVersion;
      final check = service.checkEngineVersion();
      await Future<void>.delayed(Duration.zero);

      authService.versionCompleter = null;
      authService.bootstrapVersion = '2.6.4';
      await service.bindSession(_session('tenant-2'));

      staleVersion.complete('2.6.5');
      await check;

      final versionStatus = service.engineVersionStatus.value;
      expect(versionStatus.relation, CoreEngineVersionRelation.current);
      expect(versionStatus.installedVersion, 'v2.6.4');
      expect(versionStatus.consoleVersion, 'v2.6.4');
    });

    test('timed out version check cannot publish late result', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.4';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
        engineVersionCheckTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      authService.bootstrapVersion = '2.6.5';
      authService.versionCompleter = Completer<String>();
      await service.checkEngineVersion();

      authService.versionCompleter!.complete('2.6.5');
      await Future<void>.delayed(Duration.zero);

      final versionStatus = service.engineVersionStatus.value;
      expect(versionStatus.relation, CoreEngineVersionRelation.current);
      expect(versionStatus.installedVersion, 'v2.6.4');
      expect(versionStatus.consoleVersion, 'v2.6.4');
    });

    test('old timeout does not invalidate newer version check', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime()
        ..connected = true
        ..installedVersion = '2.6.4';
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
        engineVersionCheckInterval: Duration.zero,
        engineVersionCheckTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));

      final oldVersion = Completer<String>();
      authService.bootstrapVersion = '2.6.5';
      authService.versionCompleter = oldVersion;
      await service.checkEngineVersion();

      authService.versionCompleter = null;
      authService.bootstrapVersion = '2.6.4';
      await service.checkEngineVersion();

      oldVersion.complete('2.6.5');
      await Future<void>.delayed(Duration.zero);

      final versionStatus = service.engineVersionStatus.value;
      expect(versionStatus.relation, CoreEngineVersionRelation.current);
      expect(versionStatus.installedVersion, 'v2.6.4');
      expect(versionStatus.consoleVersion, 'v2.6.4');
    });
  });

  group('CoreLifecycleService elevation repair', () {
    test('supports desktop elevation on Windows and macOS', () {
      expect(
        CoreLifecycleService.supportsDesktopElevationRepairForPlatform(
          isWindows: true,
          isMacOS: false,
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.supportsDesktopElevationRepairForPlatform(
          isWindows: false,
          isMacOS: true,
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.supportsDesktopElevationRepairForPlatform(
          isWindows: false,
          isMacOS: false,
        ),
        isFalse,
      );
    });

    test('detects desktop elevation errors', () {
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(740, ''),
        isTrue,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'elevation required',
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'install failed: Permission denied',
        ),
        isFalse,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'install failed: Permission denied',
          includeUnixPermissionErrors: true,
        ),
        isFalse,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'install failed: Permission denied: /usr/local/easytier',
          includeUnixPermissionErrors: true,
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'Operation not permitted',
          includeUnixPermissionErrors: true,
        ),
        isFalse,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'Operation not permitted: /Library/LaunchDaemons/net.easytier.plist',
          includeUnixPermissionErrors: true,
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'desktop install must be run as root',
          includeUnixPermissionErrors: true,
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          '无法写入 /usr/local/easytier',
        ),
        isFalse,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          '无法写入 /usr/local/easytier',
          includeUnixPermissionErrors: true,
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'failed to write /usr/local/easytier',
          includeUnixPermissionErrors: true,
        ),
        isTrue,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'config server returned access denied',
          includeUnixPermissionErrors: true,
        ),
        isFalse,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'config server returned: permission denied',
          includeUnixPermissionErrors: true,
        ),
        isFalse,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'config server returned: failed to write policy',
          includeUnixPermissionErrors: true,
        ),
        isFalse,
      );
      expect(
        CoreLifecycleService.isElevationRequiredForDesktopCommand(
          1,
          'failed to read bootstrap config',
        ),
        isFalse,
      );
    });

    test('falls back to force repair when runtime cannot elevate', () async {
      final authService = _LifecycleAuthService();
      final runtime = _LifecycleRuntime();
      final service = CoreLifecycleService(
        authService: authService,
        runtime: runtime,
      );
      addTearDown(service.dispose);

      await service.bindSession(_session('tenant-1'));
      await service.repairWithElevation();

      expect(runtime.ensureRunningCount, 2);
      expect(runtime.forceReinstallValues, [false, true]);
      expect(service.status.value.phase, CoreRunPhase.running);
    });

    test(
      'pending version check is ignored after elevated repair publishes version',
      () async {
        final authService = _LifecycleAuthService();
        final runtime = _LifecycleRuntime()
          ..connected = true
          ..installedVersion = '2.6.3'
          ..supportsElevationRepairValue = true;
        final service = CoreLifecycleService(
          authService: authService,
          runtime: runtime,
          engineVersionCheckInterval: Duration.zero,
          elevatedRepairRunner: (bootstrap) async {
            return const <String, dynamic>{
              'event': 'finished',
              'data': <String, dynamic>{
                'machine_id': 'machine-1',
                'cli_path': '/usr/local/bin/easytier-cli',
              },
            };
          },
        );
        addTearDown(service.dispose);

        await service.bindSession(_session('tenant-1'));
        expect(
          service.engineVersionStatus.value.relation,
          CoreEngineVersionRelation.updateAvailable,
        );

        final staleVersion = Completer<String>();
        authService.versionCompleter = staleVersion;
        final check = service.checkEngineVersion();
        await Future<void>.delayed(Duration.zero);

        await service.repairWithElevation();
        staleVersion.complete('2.6.5');
        await check;

        final versionStatus = service.engineVersionStatus.value;
        expect(versionStatus.relation, CoreEngineVersionRelation.current);
        expect(versionStatus.installedVersion, 'v2.6.4');
        expect(versionStatus.consoleVersion, 'v2.6.4');
      },
    );
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

    test(
      'reconnects after Android service is destroyed by the system',
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
              'payload': {'reason': 'service_destroyed'},
            },
          ),
        );

        await _waitUntil(() => runtime.ensureRunningCount == 2);
        expect(authService.prepareBootstrapCount, 2);
        expect(service.status.value.phase, CoreRunPhase.running);
        expect(service.status.value.machineId, 'machine-1');
      },
    );

    test(
      'reconnects when Android VPN stop is the only service destroy signal',
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
            type: CoreRuntimeEventTypes.vpnStopped,
            data: {
              'payload': {'reason': 'service_destroyed'},
            },
          ),
        );

        await _waitUntil(() => runtime.ensureRunningCount == 2);
        expect(authService.prepareBootstrapCount, 2);
        expect(service.status.value.phase, CoreRunPhase.running);
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
              'builderRoutes': ['10.10.0.0/24'],
              'builderDisallowedApplications': ['net.easytier.pro'],
              'ignoredDisallowedApplications': ['com.example.missing'],
              'builderSelfDisallowed': true,
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
      final entry = AppLogger.instance.recentSnapshot.lastWhere(
        (entry) => entry.message == 'Android VPN established',
      );
      expect(entry.context['routes'], ['10.10.0.0/24']);
      expect(entry.context['builder_routes'], ['10.10.0.0/24']);
      expect(entry.context['builder_disallowed_applications'], [
        'net.easytier.pro',
      ]);
      expect(entry.context['ignored_disallowed_applications'], [
        'com.example.missing',
      ]);
      expect(entry.context['builder_self_disallowed'], isTrue);
    });

    test(
      'reports Android VPN permission denial as an authorization state',
      () async {
        final authService = _LifecycleAuthService();
        final runtime = _LifecycleRuntime();
        final service = CoreLifecycleService(
          authService: authService,
          runtime: runtime,
        );
        addTearDown(service.dispose);

        await service.bindSession(_session('tenant-1'));
        service.status.value = const CoreRunStatus(
          phase: CoreRunPhase.needsVpnPermission,
          message: '需要授权 VPN 连接',
          machineId: 'machine-1',
          details: 'EasyTier 2.6.4',
        );

        runtime.emit(
          const CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.vpnPermissionDenied,
            data: {
              'payload': {'granted': false},
            },
          ),
        );
        await _waitUntil(
          () => service.status.value.lastError?.contains('拒绝') == true,
        );

        expect(service.status.value.phase, CoreRunPhase.needsVpnPermission);
        expect(service.status.value.machineId, 'machine-1');
        expect(service.status.value.details, 'EasyTier 2.6.4');
      },
    );

    test('logs Android runtime errors with VPN diagnostic payload', () async {
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
          data: {
            'payload': {
              'error': 'Android VPN 缺少虚拟 IP 配置',
              'action': 'net.easytier.pro.action.START_VPN',
              'instanceName': 'network-a',
              'routes': ['10.10.0.0/24', '192.168.50.0/24'],
              'disallowedApplications': ['net.easytier.pro'],
              'selfDisallowed': true,
            },
          },
        ),
      );

      await _waitUntil(
        () => AppLogger.instance.recentSnapshot.any(
          (entry) =>
              entry.message == 'Android runtime error' &&
              entry.context['error'] == 'Android VPN 缺少虚拟 IP 配置',
        ),
      );
      final entry = AppLogger.instance.recentSnapshot.lastWhere(
        (entry) =>
            entry.message == 'Android runtime error' &&
            entry.context['error'] == 'Android VPN 缺少虚拟 IP 配置',
      );

      expect(entry.scope, 'core.runtime');
      expect(entry.context['action'], 'net.easytier.pro.action.START_VPN');
      expect(entry.context['instance_name'], 'network-a');
      expect(entry.context['routes'], ['10.10.0.0/24', '192.168.50.0/24']);
      expect(entry.context['route_count'], 2);
      expect(entry.context['disallowed_applications'], ['net.easytier.pro']);
      expect(entry.context['self_disallowed'], isTrue);
      expect(service.status.value.phase, CoreRunPhase.error);
    });

    test(
      'keeps Android instance-not-found runtime errors transitional',
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
            data: {
              'payload': {
                'error': 'Instance Not Found RPC ERROR',
                'instanceName': 'network-a',
              },
            },
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(service.status.value.phase, CoreRunPhase.running);
        expect(service.status.value.machineId, 'machine-1');
      },
    );

    test(
      'logs repeated Android config server starts as already started',
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
            type: CoreRuntimeEventTypes.configServerStarted,
            data: {
              'payload': {'hostname': 'android-phone', 'alreadyStarted': true},
            },
          ),
        );

        await _waitUntil(
          () => AppLogger.instance.recentSnapshot.any(
            (entry) =>
                entry.message == 'Android config server client started' &&
                entry.context['already_started'] == true,
          ),
        );
        final entry = AppLogger.instance.recentSnapshot.lastWhere(
          (entry) =>
              entry.message == 'Android config server client started' &&
              entry.context['already_started'] == true,
        );

        expect(entry.context['hostname'], 'android-phone');
      },
    );

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
  var installedVersion = '2.6.4';
  Object? ensureRunningError;
  Completer<void>? ensureRunningCompleter;
  var supportsElevationRepairValue = false;
  final forceReinstallValues = <bool>[];
  final ensureRunningBootstraps = <CoreBootstrapConfig>[];

  @override
  Stream<CoreRuntimeEvent> get events => _events.stream;

  @override
  bool get supportsElevationRepair => supportsElevationRepairValue;

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
    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: '连接引擎运行中',
      machineId: 'machine-1',
      details: 'EasyTier $installedVersion',
      coreVersion: installedVersion,
    );
  }

  @override
  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  }) async {
    ensureRunningCount++;
    forceReinstallValues.add(forceReinstall);
    ensureRunningBootstraps.add(bootstrap);
    final completer = ensureRunningCompleter;
    if (completer != null) {
      await completer.future;
    }
    final error = ensureRunningError;
    if (error != null) {
      throw error;
    }
    connected = true;
    installedVersion = bootstrap.version;
    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: '连接引擎运行中',
      machineId: 'machine-1',
      details: 'EasyTier $installedVersion',
      coreVersion: installedVersion,
    );
  }

  @override
  Future<String?> readInstalledVersion() async {
    return connected ? installedVersion : null;
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

class _VersionProbeProcess implements Process {
  _VersionProbeProcess({this.terminateOnSigterm = true});

  final bool terminateOnSigterm;
  final killSignals = <ProcessSignal>[];
  final _exitCode = Completer<int>();
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _stdin = StreamController<List<int>>();

  bool get exited => _exitCode.isCompleted;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 4242;

  @override
  IOSink get stdin => IOSink(_stdin.sink);

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killSignals.add(signal);
    final shouldExit = signal == ProcessSignal.sigkill || terminateOnSigterm;
    if (shouldExit) {
      complete(exitCode: -1);
    }
    return true;
  }

  void complete({
    required int exitCode,
    String stdoutText = '',
    String stderrText = '',
  }) {
    if (_exitCode.isCompleted) {
      return;
    }
    if (stdoutText.isNotEmpty) {
      _stdout.add(utf8.encode(stdoutText));
    }
    if (stderrText.isNotEmpty) {
      _stderr.add(utf8.encode(stderrText));
    }
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    unawaited(_stdin.close());
    _exitCode.complete(exitCode);
  }
}

class _LifecycleAuthService implements AuthService {
  var prepareBootstrapCount = 0;
  var fetchVersionCount = 0;
  var bootstrapVersion = '2.6.4';
  var bootstrapConfigServer = 'tcp://127.0.0.1:22020';
  Completer<String>? versionCompleter;
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
    return const NodeInstanceConfigView(
      defaults: NodeInstanceConfigSettings(),
      overrides: NodeInstanceConfigSettings(),
      effective: NodeInstanceConfigSettings(),
      configScope: '',
      applyStatus: '',
      driftStatus: '',
    );
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
  Future<String> fetchRecommendedCoreVersion({
    required String accessToken,
    required String workspaceId,
  }) async {
    fetchVersionCount++;
    workspaceIds.add(workspaceId);
    final error = bootstrapError;
    if (error != null) {
      throw error;
    }
    final completer = versionCompleter;
    if (completer != null) {
      return completer.future;
    }
    return bootstrapVersion;
  }

  @override
  Future<String> fetchLatestCoreVersion() async {
    fetchVersionCount++;
    final error = bootstrapError;
    if (error != null) {
      throw error;
    }
    final completer = versionCompleter;
    if (completer != null) {
      return completer.future;
    }
    return bootstrapVersion;
  }

  @override
  Future<CoreBootstrapDefaults> fetchCoreBootstrapDefaults() async {
    fetchVersionCount++;
    final error = bootstrapError;
    if (error != null) {
      throw error;
    }
    final completer = versionCompleter;
    if (completer != null) {
      return CoreBootstrapDefaults(
        version: await completer.future,
        configServer: bootstrapConfigServer,
      );
    }
    return CoreBootstrapDefaults(
      version: bootstrapVersion,
      configServer: bootstrapConfigServer,
    );
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
    return CoreBootstrapConfig(
      bootstrapToken: 'bootstrap-token',
      version: bootstrapVersion,
      configServer: bootstrapConfigServer,
    );
  }

  @override
  Future<void> logout() async {}
}
