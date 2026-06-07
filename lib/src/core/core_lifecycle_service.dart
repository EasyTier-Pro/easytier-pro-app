import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../auth/console_auth_service.dart';
import 'core_peer_status.dart';
import '../logging/app_logger.dart';

part 'core_lifecycle_models.dart';
part 'core_platform_runtime.dart';
part 'desktop_core_runtime.dart';
part 'android_core_runtime.dart';

class CoreLifecycleService {
  CoreLifecycleService({
    required this.authService,
    CorePlatformRuntime? runtime,
  }) : status = ValueNotifier<CoreRunStatus>(CoreRunStatus.signedOut) {
    _runtime = runtime ?? CorePlatformRuntime.current(this);
    _runtimeEvents = _runtime.events.listen(_handleRuntimeEvent);
  }

  final AuthService authService;
  final ValueNotifier<CoreRunStatus> status;
  final AppLogger _logger = AppLogger.instance;

  late final CorePlatformRuntime _runtime;
  late final StreamSubscription<CoreRuntimeEvent> _runtimeEvents;
  AuthSession? _session;
  Future<void> _serial = Future<void>.value();
  String? _cliPath;

  Duration get networkTrafficPollInterval =>
      _runtime.networkTrafficPollInterval;

  Duration get peerStatusPollInterval => _runtime.peerStatusPollInterval;

  Future<void> bindSession(AuthSession session) {
    return _enqueue(() async {
      final previousWorkspace = _session?.user.currentWorkspace?.id;
      final nextWorkspace = session.user.currentWorkspace?.id;
      final workspaceChanged =
          previousWorkspace != null &&
          nextWorkspace != null &&
          previousWorkspace != nextWorkspace;

      _session = session;
      _logger.info(
        'core',
        'Binding session',
        context: {
          'workspace_changed': workspaceChanged,
          'previous_workspace': previousWorkspace,
          'next_workspace': nextWorkspace,
        },
      );
      if (workspaceChanged) {
        status.value = const CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: '工作区变更，正在重建连接引擎...',
        );
      }
      await _ensureRunning(forceReinstall: workspaceChanged);
    });
  }

  Future<void> onLogout() {
    return _enqueue(() async {
      _session = null;
      _logger.info('core', 'Logout flow: stopping local engine binding');
      status.value = const CoreRunStatus(
        phase: CoreRunPhase.repairing,
        message: '正在停止连接引擎...',
      );
      try {
        await _runtime.stop();
        _logger.info(
          'core',
          'Logout cleanup completed',
          context: {'runtime': _runtime.runtimeType.toString()},
        );
        status.value = CoreRunStatus.signedOut;
      } catch (error) {
        _logger.error(
          'core',
          'Logout cleanup failed',
          context: {'error': error.toString()},
        );
        status.value = CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '退出登录后卸载失败',
          lastError: _normalizeError(error),
        );
      }
    });
  }

  Future<void> repair() {
    return _enqueue(() async {
      final session = _session;
      if (session == null) {
        _logger.warn('core', 'Repair requested without active session');
        status.value = CoreRunStatus.signedOut;
        return;
      }
      _logger.info('core', 'Manual repair requested');
      await _ensureRunning(forceReinstall: true);
    });
  }

  Future<void> dispose() async {
    await _runtimeEvents.cancel();
    await _runtime.dispose();
    status.dispose();
  }

  Future<void> repairWithElevation() {
    return _enqueue(() async {
      final session = _session;
      if (session == null) {
        _logger.warn(
          'core',
          'Elevation repair requested without active session',
        );
        status.value = CoreRunStatus.signedOut;
        return;
      }
      if (!_runtime.supportsElevationRepair) {
        _logger.warn(
          'core',
          'Elevation repair is not supported by current runtime',
          context: {'runtime': _runtime.runtimeType.toString()},
        );
        await _ensureRunning(forceReinstall: true);
        return;
      }

      final workspace = session.user.currentWorkspace;
      if (workspace == null) {
        status.value = const CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '当前账号未绑定工作区',
        );
        return;
      }

      status.value = const CoreRunStatus(
        phase: CoreRunPhase.repairing,
        message: '正在以管理员身份安装连接引擎...',
      );
      _logger.info('core', 'Elevation repair requested');

      try {
        final bootstrap = await authService.prepareCoreBootstrap(
          accessToken: session.tokenSet.accessToken,
          workspaceId: workspace.id,
        );

        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final inputFile = File(
          '${tempDir.path}${Platform.pathSeparator}et_bootstrap_$timestamp.json',
        );
        final outputFile = File(
          '${tempDir.path}${Platform.pathSeparator}et_output_$timestamp.json',
        );
        final errorFile = File(
          '${tempDir.path}${Platform.pathSeparator}et_error_$timestamp.json',
        );
        final batFile = File(
          '${tempDir.path}${Platform.pathSeparator}et_elevated_$timestamp.bat',
        );

        final request = {
          'bootstrap_token': bootstrap.bootstrapToken,
          'version': bootstrap.version,
          'config_server': bootstrap.configServer,
        };
        await inputFile.writeAsString(jsonEncode(request), encoding: utf8);

        final installerPath = _resolveInstallerExecutable();
        final installerDir = File(installerPath).parent.path;
        final batContent =
            '''@echo off
chcp 65001 >nul
cd /d "$installerDir"
"$installerPath" desktop install --json < "${inputFile.path}" > "${outputFile.path}" 2> "${errorFile.path}"
''';
        await batFile.writeAsString(batContent, encoding: utf8);

        _logger.info(
          'core.desktop',
          'Launching elevated installer via PowerShell',
          context: {'bat_file': batFile.path, 'installer': installerPath},
        );

        final powershellResult = await _runElevatedWithPowerShell(batFile.path);
        _logger.info(
          'core.desktop',
          'Elevated installer process completed',
          context: {
            'exit_code': powershellResult,
            'output_exists': outputFile.existsSync(),
            'error_exists': errorFile.existsSync(),
          },
        );

        if (outputFile.existsSync()) {
          final outputText = await outputFile.readAsString();
          final lines = const LineSplitter().convert(outputText);
          final events = lines
              .where((line) => line.trim().isNotEmpty)
              .map((line) {
                try {
                  final decoded = jsonDecode(line);
                  if (decoded is Map<String, dynamic>) {
                    return decoded;
                  }
                } catch (_) {
                  // ignore
                }
                return null;
              })
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);

          if (events.isNotEmpty) {
            final errorEvent = events.firstWhere(
              (event) => event['event'] == 'error',
              orElse: () => const <String, dynamic>{},
            );
            if (errorEvent.isNotEmpty) {
              final data =
                  errorEvent['data'] as Map<String, dynamic>? ?? const {};
              throw StateError(data['message']?.toString() ?? '提权安装返回错误');
            }

            for (var index = events.length - 1; index >= 0; index--) {
              final event = events[index];
              if (event['event'] == 'finished') {
                final machineId = parseMachineIdFromDesktopEvent(event);
                _rememberCliPath(parseCliPathFromDesktopEvent(event));
                _logger.info(
                  'core',
                  'Elevated install completed',
                  context: {'machine_id': machineId ?? ''},
                );
                status.value = CoreRunStatus(
                  phase: CoreRunPhase.running,
                  message: machineId == null || machineId.isEmpty
                      ? '连接引擎运行中'
                      : '本机设备已就绪',
                  machineId: machineId,
                  details: 'EasyTier ${bootstrap.version}',
                );
                await _cleanupElevationTempFiles([
                  inputFile,
                  outputFile,
                  errorFile,
                  batFile,
                ]);
                return;
              }
            }
          }
        }

        final errorText = errorFile.existsSync()
            ? await errorFile.readAsString()
            : '';
        if (errorText.isNotEmpty) {
          throw StateError(errorText);
        }
        throw StateError('提权安装没有返回有效结果');
      } catch (error) {
        _logger.error(
          'core',
          'Elevation repair failed',
          context: {'error': error.toString()},
        );
        if (error is _ElevationRequiredException) {
          status.value = const CoreRunStatus(
            phase: CoreRunPhase.needsElevation,
            message: '需要管理员权限以安装连接引擎',
            lastError: '创建虚拟网卡需要提升权限',
          );
          return;
        }
        status.value = CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '连接引擎启动失败',
          lastError: _normalizeError(error),
        );
      }
    });
  }

  Future<int> _runElevatedWithPowerShell(String batPath) async {
    final args = [
      '-Command',
      'Start-Process -FilePath "cmd.exe" -ArgumentList \'/c\',"$batPath" -Verb runAs -Wait',
    ];

    final executables = ['powershell.exe', 'pwsh.exe'];

    for (final exe in executables) {
      try {
        final result = await Process.run(exe, args);
        _logger.debug(
          'core.desktop',
          'PowerShell elevation attempt',
          context: {
            'executable': exe,
            'exit_code': result.exitCode,
            'stderr': result.stderr.toString().trim(),
          },
        );
        return result.exitCode;
      } on ProcessException catch (e) {
        _logger.warn(
          'core.desktop',
          'PowerShell executable not available',
          context: {'executable': exe, 'error': e.toString()},
        );
        continue;
      }
    }

    throw StateError('找不到可用的 PowerShell 来执行提权操作');
  }

  Future<void> _cleanupElevationTempFiles(List<File> files) async {
    for (final file in files) {
      try {
        if (file.existsSync()) {
          await file.delete();
        }
      } catch (_) {
        // ignore cleanup errors
      }
    }
  }

  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    return _runtime.readNetworkTrafficTotals();
  }

  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    return _runtime.isNetworkInstanceRunning(runtimeNetworkName);
  }

  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async {
    return _runtime.readNetworkPeerStatuses(runtimeNetworkName);
  }

  static bool _isInstanceNotReadyMessage(String message) {
    final lower = message.toLowerCase();
    return lower.contains('no running instances found') ||
        lower.contains('no instance matches') ||
        lower.contains('no instance');
  }

  Future<void> _ensureRunning({required bool forceReinstall}) async {
    final session = _session;
    if (session == null) {
      status.value = CoreRunStatus.signedOut;
      return;
    }
    if (session.tokenSet.isExpired) {
      await _stopRuntimeForAuthInvalid(const AuthException('当前登录态已失效，请重新登录。'));
      return;
    }
    final workspace = session.user.currentWorkspace;
    if (workspace == null) {
      _logger.error('core', 'No workspace available for lifecycle binding');
      if (status.value.phase != CoreRunPhase.signedOut) {
        await _stopRuntimeForMissingWorkspace();
      }
      status.value = const CoreRunStatus(
        phase: CoreRunPhase.error,
        message: '当前账号未绑定工作区',
      );
      return;
    }

    status.value = const CoreRunStatus(
      phase: CoreRunPhase.checking,
      message: '正在检查连接引擎状态...',
    );
    _logger.info(
      'core',
      'Ensure running start',
      context: {
        'force_reinstall': forceReinstall,
        'workspace_id': workspace.id,
      },
    );

    try {
      final bootstrap = await authService.prepareCoreBootstrap(
        accessToken: session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );
      if (!forceReinstall) {
        final runtimeStatus = await _runtime.readStatus(bootstrap);
        final machineId = runtimeStatus?.machineId;
        if (runtimeStatus != null &&
            runtimeStatus.phase == CoreRunPhase.running &&
            machineId != null &&
            machineId.isNotEmpty) {
          _logger.info(
            'core',
            'Existing runtime service is ready',
            context: {
              'machine_id': machineId,
              'runtime': _runtime.runtimeType.toString(),
            },
          );
          status.value = runtimeStatus.toStatus();
          return;
        }
      }
      if (forceReinstall) {
        status.value = CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: '正在重装连接引擎...',
        );
      } else {
        status.value = const CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: '正在检查并应用连接引擎配置...',
        );
      }

      final result = await _runtime.ensureRunning(
        bootstrap,
        forceReinstall: forceReinstall,
      );
      _logger.info(
        'core',
        'Runtime ensure completed',
        context: {
          'force_reinstall': forceReinstall,
          'runtime': _runtime.runtimeType.toString(),
          'phase': result.phase.name,
          'machine_id': result.machineId ?? '',
        },
      );
      status.value = result.toStatus();
    } catch (error) {
      _logger.error(
        'core',
        'Ensure running failed',
        context: {'error': error.toString()},
      );
      if (_isAuthInvalidError(error)) {
        await _stopRuntimeForAuthInvalid(error);
        return;
      }
      if (error is _ElevationRequiredException) {
        status.value = const CoreRunStatus(
          phase: CoreRunPhase.needsElevation,
          message: '需要管理员权限以安装连接引擎',
          lastError: '创建虚拟网卡需要提升权限',
        );
        return;
      }
      status.value = CoreRunStatus(
        phase: CoreRunPhase.error,
        message: '连接引擎启动失败',
        lastError: _normalizeError(error),
      );
    }
  }

  Future<void> _stopRuntimeForMissingWorkspace() async {
    try {
      await _runtime.stop();
      _logger.info(
        'core',
        'Stopped runtime because the active session has no workspace',
      );
    } catch (error) {
      _logger.warn(
        'core',
        'Failed to stop runtime after workspace became unavailable',
        context: {'error': error.toString()},
      );
    }
  }

  Future<void> _stopRuntimeForAuthInvalid(Object error) async {
    try {
      await _runtime.stop();
      _logger.info(
        'core',
        'Stopped runtime because the auth session is invalid',
      );
    } catch (stopError) {
      _logger.warn(
        'core',
        'Failed to stop runtime after auth became invalid',
        context: {'error': stopError.toString()},
      );
    }
    status.value = CoreRunStatus(
      phase: CoreRunPhase.error,
      message: '登录态已失效，连接已停止',
      lastError: _normalizeError(error),
    );
  }

  bool _isAuthInvalidError(Object error) {
    if (error is! AuthException) {
      return false;
    }
    final message = _normalizeError(error);
    return message.contains('登录态已失效') ||
        message.contains('请重新登录') ||
        message.toLowerCase().contains('unauthorized');
  }

  Future<_DesktopCoreStatus?> _tryReadDesktopStatus(
    CoreBootstrapConfig bootstrap,
  ) async {
    try {
      final event = await _desktopCommand('status', {
        'bootstrap_token': bootstrap.bootstrapToken,
        'version': bootstrap.version,
        'config_server': bootstrap.configServer,
      });
      final desktopStatus = _DesktopCoreStatus.fromEvent(event);
      _rememberCliPath(desktopStatus.cliPath);
      _logger.info(
        'core.desktop',
        'Desktop status loaded',
        context: {
          'ready': desktopStatus.ready,
          'installed': desktopStatus.installed,
          'running': desktopStatus.running,
          'machine_id': desktopStatus.machineId ?? '',
          'version': desktopStatus.version ?? '',
        },
      );
      return desktopStatus;
    } catch (error) {
      if (error is _ElevationRequiredException) {
        rethrow;
      }
      _logger.warn(
        'core.desktop',
        'Desktop status unavailable, falling back to install',
        context: {'error': error.toString()},
      );
      return null;
    }
  }

  Future<Map<String, dynamic>> _desktopCommand(
    String command,
    Map<String, Object?> request,
  ) async {
    final executable = _resolveInstallerExecutable();
    _logger.info(
      'core.desktop',
      'Executing desktop command',
      context: {'command': command, 'executable': executable},
    );
    late final Process process;
    try {
      process = await Process.start(executable, ['desktop', command, '--json']);
    } on ProcessException catch (e) {
      if (_isElevationRequired(0, e.message)) {
        throw _ElevationRequiredException(e.message);
      }
      rethrow;
    }

    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();

    process.stdin.writeln(jsonEncode(request));
    await process.stdin.close();

    final exitCode = await process.exitCode.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        process.kill();
        _logger.error(
          'core.desktop',
          'Desktop command timeout',
          context: {'command': command},
        );
        throw TimeoutException('desktop 命令执行超时');
      },
    );
    final outputLines = await stdoutFuture;
    final stderrLines = await stderrFuture;

    final events = outputLines
        .where((line) => line.trim().isNotEmpty)
        .map((line) {
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map<String, dynamic>) {
              return decoded;
            }
          } catch (_) {
            // Ignore malformed lines and rely on process exit and stderr.
          }
          return null;
        })
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);

    if (events.isNotEmpty) {
      final errorEvent = events.firstWhere(
        (event) => event['event'] == 'error',
        orElse: () => const <String, dynamic>{},
      );
      if (errorEvent.isNotEmpty) {
        final data = errorEvent['data'] as Map<String, dynamic>? ?? const {};
        _logger.error(
          'core.desktop',
          'Desktop command returned error event',
          context: {'command': command, 'event': data},
        );
        throw StateError(data['message']?.toString() ?? 'desktop 命令执行失败');
      }
    }

    if (exitCode != 0) {
      final stderrText = stderrLines.join('\n').trim();
      _logger.error(
        'core.desktop',
        'Desktop command failed',
        context: {
          'command': command,
          'exit_code': exitCode,
          'stderr': stderrText,
        },
      );
      if (_isElevationRequired(exitCode, stderrText)) {
        throw _ElevationRequiredException(stderrText);
      }
      throw StateError(
        stderrText.isEmpty
            ? 'desktop $command 执行失败 (exit=$exitCode)'
            : stderrText,
      );
    }

    for (var index = events.length - 1; index >= 0; index--) {
      final event = events[index];
      if (event['event'] == 'finished') {
        _logger.info(
          'core.desktop',
          'Desktop command finished',
          context: {'command': command, 'exit_code': exitCode},
        );
        return event;
      }
    }

    throw StateError('desktop 命令没有返回 finished 事件');
  }

  @visibleForTesting
  static String? parseMachineIdFromDesktopEvent(Map<String, dynamic> event) {
    final data = event['data'];
    if (data is! Map<String, dynamic>) {
      return null;
    }
    final machineId = data['machine_id']?.toString().trim() ?? '';
    return machineId.isEmpty ? null : machineId;
  }

  @visibleForTesting
  static String? parseCliPathFromDesktopEvent(Map<String, dynamic> event) {
    final data = event['data'];
    if (data is! Map<String, dynamic>) {
      return null;
    }
    final cliPath = data['cli_path']?.toString().trim() ?? '';
    return cliPath.isEmpty ? null : cliPath;
  }

  @visibleForTesting
  static Map<String, CoreNetworkTrafficTotals>
  parseNetworkTrafficTotalsFromJson(String output, {DateTime? sampledAt}) {
    final decoded = jsonDecode(output);
    final items = _extractMetricItems(decoded);

    final collected = <String, _MutableNetworkTrafficTotals>{};
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final metricName = item['name']?.toString().trim() ?? '';
      if (metricName != 'traffic_bytes_self_rx' &&
          metricName != 'traffic_bytes_self_tx') {
        continue;
      }

      final labels = item['labels'];
      if (labels is! Map<String, dynamic>) {
        continue;
      }
      final runtimeNetworkName =
          labels['network_name']?.toString().trim() ?? '';
      if (runtimeNetworkName.isEmpty || runtimeNetworkName == '__access__') {
        continue;
      }

      final value = _readInt(item['value']);
      if (value == null) {
        continue;
      }

      final totals = collected.putIfAbsent(
        runtimeNetworkName,
        _MutableNetworkTrafficTotals.new,
      );
      if (metricName == 'traffic_bytes_self_rx') {
        totals.downloadBytes = value;
        totals.hasDownloadBytes = true;
      } else {
        totals.uploadBytes = value;
        totals.hasUploadBytes = true;
      }
    }

    final sampleTime = sampledAt ?? DateTime.now();
    return collected.map((runtimeNetworkName, totals) {
      return MapEntry(
        runtimeNetworkName,
        CoreNetworkTrafficTotals(
          runtimeNetworkName: runtimeNetworkName,
          downloadBytes: totals.hasDownloadBytes ? totals.downloadBytes : 0,
          uploadBytes: totals.hasUploadBytes ? totals.uploadBytes : 0,
          sampledAt: sampleTime,
        ),
      );
    });
  }

  static List<dynamic> _extractMetricItems(Object? decoded) {
    if (decoded is! List<dynamic>) {
      throw const FormatException('easytier-cli stats JSON must be an array');
    }

    final items = <dynamic>[];
    for (final item in decoded) {
      if (item is Map<String, dynamic> && item['result'] is List<dynamic>) {
        items.addAll(item['result'] as List<dynamic>);
      } else {
        items.add(item);
      }
    }
    return items;
  }

  @visibleForTesting
  static Map<String, CorePeerStatus> parseNetworkPeerStatusesFromJson(
    String output,
  ) {
    return parseCorePeerStatusesFromJson(output);
  }

  static int? _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return num.tryParse(text)?.toInt();
  }

  void _rememberCliPath(String? cliPath) {
    final value = cliPath?.trim();
    if (value == null || value.isEmpty) {
      return;
    }
    _cliPath = value;
  }

  String _resolveInstallerExecutable() {
    final bundledCandidates = _bundledInstallerCandidates();
    final bundled = _firstExistingFile(bundledCandidates);
    if (bundled != null) {
      return bundled;
    }

    final override = Platform.environment['EASYTIER_INSTALLER_PATH'];
    if (!kReleaseMode && override != null && override.trim().isNotEmpty) {
      return override;
    }

    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        final candidate =
            '$localAppData\\easytier-pro-installer\\easytier-pro-installer.exe';
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
      return 'easytier-pro-installer.exe';
    }

    final unixCandidates = <String>[
      '${Platform.environment['HOME'] ?? ''}/.local/share/easytier-pro-installer/easytier-pro-installer',
      '/usr/local/bin/easytier-pro-installer',
      'easytier-pro-installer',
    ];
    final unixResolved = _firstExistingFile(unixCandidates);
    if (unixResolved != null) {
      return unixResolved;
    }

    return 'easytier-pro-installer';
  }

  String _resolveCliExecutable() {
    final override = Platform.environment['EASYTIER_CLI_PATH'];
    final candidates = <String>[
      if (_cliPath != null && _cliPath!.trim().isNotEmpty) _cliPath!.trim(),
      if (override != null && override.trim().isNotEmpty) override.trim(),
      ..._bundledCliCandidates(),
      Platform.isWindows ? 'easytier-cli.exe' : 'easytier-cli',
    ];
    return _firstExistingFile(candidates) ??
        (Platform.isWindows ? 'easytier-cli.exe' : 'easytier-cli');
  }

  List<String> _bundledInstallerCandidates() {
    final executableFile = File(Platform.resolvedExecutable);
    final executableDir = executableFile.parent;

    if (Platform.isWindows) {
      return <String>[
        _joinPath(executableDir.path, 'easytier-pro-installer.exe'),
        _joinPath(
          executableDir.path,
          'resources',
          'easytier-pro-installer.exe',
        ),
      ];
    }

    if (Platform.isMacOS) {
      final macOsDir = executableDir;
      final contentsDir = macOsDir.parent;
      return <String>[
        _joinPath(macOsDir.path, 'easytier-pro-installer'),
        _joinPath(contentsDir.path, 'Resources', 'easytier-pro-installer'),
      ];
    }

    return <String>[
      _joinPath(executableDir.path, 'easytier-pro-installer'),
      _joinPath(executableDir.path, 'lib', 'easytier-pro-installer'),
    ];
  }

  List<String> _bundledCliCandidates() {
    final executableFile = File(Platform.resolvedExecutable);
    final executableDir = executableFile.parent;

    if (Platform.isWindows) {
      return <String>[
        _joinPath(executableDir.path, 'easytier-cli.exe'),
        _joinPath(executableDir.path, 'resources', 'easytier-cli.exe'),
      ];
    }

    if (Platform.isMacOS) {
      final macOsDir = executableDir;
      final contentsDir = macOsDir.parent;
      return <String>[
        _joinPath(macOsDir.path, 'easytier-cli'),
        _joinPath(contentsDir.path, 'Resources', 'easytier-cli'),
      ];
    }

    return <String>[
      _joinPath(executableDir.path, 'easytier-cli'),
      _joinPath(executableDir.path, 'lib', 'easytier-cli'),
    ];
  }

  String? _firstExistingFile(Iterable<String> candidates) {
    for (final candidate in candidates) {
      if (candidate.isEmpty) {
        continue;
      }
      if (!candidate.contains(Platform.pathSeparator)) {
        return candidate;
      }
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  String _joinPath(String base, String segment1, [String? segment2]) {
    final buffer = StringBuffer(base);
    if (!base.endsWith(Platform.pathSeparator)) {
      buffer.write(Platform.pathSeparator);
    }
    buffer.write(segment1);
    if (segment2 != null && segment2.isNotEmpty) {
      if (!segment1.endsWith(Platform.pathSeparator)) {
        buffer.write(Platform.pathSeparator);
      }
      buffer.write(segment2);
    }
    return buffer.toString();
  }

  static bool _isElevationRequired(int exitCode, String stderrText) {
    if (exitCode == 740) {
      return true;
    }
    final text = stderrText.toLowerCase();
    return text.contains('请求的操作需要提升') ||
        text.contains('elevation required') ||
        text.contains('requires elevation');
  }

  String _normalizeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }

  void _handleRuntimeEvent(CoreRuntimeEvent event) {
    _logger.debug(
      'core.runtime',
      'Runtime event received',
      context: {'type': event.type, ...event.data},
    );
    if (event.type == CoreRuntimeEventTypes.vpnStarted) {
      final payload = _runtimeEventPayload(event);
      final addresses = payload['addresses'] ?? const <String>[];
      final routes = payload['routes'] ?? const <String>[];
      final builderAddresses =
          payload['builderAddresses'] ??
          payload['builder_addresses'] ??
          const <String>[];
      final builderRoutes =
          payload['builderRoutes'] ??
          payload['builder_routes'] ??
          const <String>[];
      final builderDisallowedApplications =
          payload['builderDisallowedApplications'] ??
          payload['builder_disallowed_applications'] ??
          const <String>[];
      final ignoredDisallowedApplications =
          payload['ignoredDisallowedApplications'] ??
          payload['ignored_disallowed_applications'] ??
          const <String>[];
      final disallowedApplications =
          payload['disallowedApplications'] ??
          payload['disallowed_applications'] ??
          const <String>[];
      _logger.info(
        'core.vpn',
        'Android VPN established',
        context: {
          'instance_name':
              payload['instanceName'] ?? payload['instance_name'] ?? '',
          'tun_fd': payload['fd'] ?? payload['tunFd'] ?? '',
          'addresses': addresses,
          'address_count':
              payload['addressCount'] ?? _payloadListLength(addresses),
          'routes': routes,
          'route_count': payload['routeCount'] ?? _payloadListLength(routes),
          'dns': payload['dns'] ?? payload['dnsServers'] ?? const <String>[],
          'builder_addresses': builderAddresses,
          'builder_address_count':
              payload['builderAddressCount'] ??
              _payloadListLength(builderAddresses),
          'builder_routes': builderRoutes,
          'builder_route_count':
              payload['builderRouteCount'] ?? _payloadListLength(builderRoutes),
          'builder_dns':
              payload['builderDnsServers'] ??
              payload['builder_dns_servers'] ??
              const <String>[],
          'disallowed_applications': disallowedApplications,
          'disallowed_application_count':
              payload['disallowedApplicationCount'] ??
              _payloadListLength(disallowedApplications),
          'builder_disallowed_applications': builderDisallowedApplications,
          'builder_disallowed_application_count':
              payload['builderDisallowedApplicationCount'] ??
              _payloadListLength(builderDisallowedApplications),
          'ignored_disallowed_applications': ignoredDisallowedApplications,
          'ignored_disallowed_application_count':
              payload['ignoredDisallowedApplicationCount'] ??
              _payloadListLength(ignoredDisallowedApplications),
          'package_name':
              payload['packageName'] ?? payload['package_name'] ?? '',
          'self_disallowed':
              payload['selfDisallowed'] ?? payload['self_disallowed'] ?? '',
          'builder_self_disallowed':
              payload['builderSelfDisallowed'] ??
              payload['builder_self_disallowed'] ??
              '',
        },
      );
      _restoreRunningStatusAfterVpnRecovery();
    }
    if (event.type == CoreRuntimeEventTypes.vpnConfigRefreshed) {
      final payload = _runtimeEventPayload(event);
      _logger.info(
        'core.vpn',
        'Android VPN config refresh requested',
        context: {
          'instance_name':
              payload['instanceName'] ?? payload['instance_name'] ?? '',
          'addresses': payload['addresses'] ?? const <String>[],
          'routes': payload['routes'] ?? const <String>[],
          'dns': payload['dns'] ?? payload['dnsServers'] ?? const <String>[],
        },
      );
    }
    if (event.type == CoreRuntimeEventTypes.vpnStopped) {
      final payload = _runtimeEventPayload(event);
      final stopReason = payload['reason']?.toString().trim() ?? '';
      _logger.info(
        'core.vpn',
        'Android VPN stopped',
        context: {
          'instance_name':
              payload['instanceName'] ?? payload['instance_name'] ?? '',
          'fd': payload['fd'] ?? '',
          'reason': stopReason,
        },
      );
      if (stopReason == 'service_destroyed') {
        _reconnectAfterRuntimeStopIfNeeded();
        return;
      }
    }
    if (event.type == CoreRuntimeEventTypes.configServerStarted) {
      final payload = _runtimeEventPayload(event);
      _logger.info(
        'core.runtime',
        'Android config server client started',
        context: {
          'hostname': payload['hostname'] ?? '',
          'already_started':
              payload['alreadyStarted'] ?? payload['already_started'] ?? false,
        },
      );
    }
    if (event.type == CoreRuntimeEventTypes.configServerStopped) {
      final payload = _runtimeEventPayload(event);
      _logger.info(
        'core.runtime',
        'Android config server client stopped',
        context: {'reason': payload['reason'] ?? ''},
      );
    }
    if (event.type == CoreRuntimeEventTypes.vpnPermissionGranted &&
        _session != null &&
        status.value.phase == CoreRunPhase.needsVpnPermission) {
      unawaited(
        _enqueue(() async {
          await _ensureRunning(forceReinstall: false);
        }),
      );
      return;
    }
    if (event.type == CoreRuntimeEventTypes.vpnPermissionDenied &&
        _session != null) {
      final current = status.value;
      status.value = CoreRunStatus(
        phase: CoreRunPhase.needsVpnPermission,
        message: '需要授权 VPN 连接',
        lastError: '用户已拒绝 Android VPN 授权，请重新授权后继续。',
        machineId: current.machineId,
        details: current.details,
      );
      return;
    }
    if (event.type == CoreRuntimeEventTypes.configServerStopped) {
      final payload = _runtimeEventPayload(event);
      final stopReason = payload['reason']?.toString().trim() ?? '';
      if (_isIntentionalAndroidRuntimeStop(stopReason)) {
        status.value = CoreRunStatus(
          phase: CoreRunPhase.stopped,
          message: stopReason == 'revoked' ? 'VPN 已由系统断开' : '连接已断开',
          machineId: status.value.machineId,
          details: status.value.details,
        );
        return;
      }
      _reconnectAfterRuntimeStopIfNeeded();
      return;
    }
    if (event.type == CoreRuntimeEventTypes.error) {
      final payload = _runtimeEventPayload(event);
      final message = payload['error']?.toString().trim() ?? '';
      _logger.error(
        'core.runtime',
        'Android runtime error',
        context: {
          'error': message,
          'action': payload['action'] ?? '',
          'instance_name':
              payload['instanceName'] ?? payload['instance_name'] ?? '',
          'addresses': payload['addresses'] ?? const <String>[],
          'address_count':
              payload['addressCount'] ??
              _payloadListLength(payload['addresses']),
          'routes': payload['routes'] ?? const <String>[],
          'route_count':
              payload['routeCount'] ?? _payloadListLength(payload['routes']),
          'dns': payload['dns'] ?? payload['dnsServers'] ?? const <String>[],
          'disallowed_applications':
              payload['disallowedApplications'] ??
              payload['disallowed_applications'] ??
              const <String>[],
          'package_name':
              payload['packageName'] ?? payload['package_name'] ?? '',
          'self_disallowed':
              payload['selfDisallowed'] ?? payload['self_disallowed'] ?? '',
        },
      );
      if (message.isNotEmpty) {
        status.value = CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '连接引擎运行异常',
          lastError: message,
          machineId: status.value.machineId,
          details: status.value.details,
        );
      }
    }
  }

  bool _isIntentionalAndroidRuntimeStop(String reason) {
    return reason == 'user_disconnect' || reason == 'revoked';
  }

  void _reconnectAfterRuntimeStopIfNeeded() {
    if (!_shouldReconnectAfterRuntimeStop()) {
      return;
    }
    _logger.warn(
      'core.runtime',
      'Android runtime stopped while session is active; reconnecting',
    );
    status.value = CoreRunStatus(
      phase: CoreRunPhase.repairing,
      message: '控制面连接已断开，正在重新连接...',
      machineId: status.value.machineId,
      details: status.value.details,
    );
    unawaited(
      _enqueue(() async {
        await _ensureRunning(forceReinstall: false);
      }),
    );
  }

  int _payloadListLength(Object? value) {
    if (value is Iterable) {
      return value.length;
    }
    return value == null ? 0 : 1;
  }

  void _restoreRunningStatusAfterVpnRecovery() {
    if (_session == null) {
      return;
    }
    final current = status.value;
    if (current.phase != CoreRunPhase.error &&
        current.phase != CoreRunPhase.needsVpnPermission) {
      return;
    }
    status.value = CoreRunStatus(
      phase: CoreRunPhase.running,
      message: 'Android 连接引擎运行中',
      machineId: current.machineId,
      details: current.details,
    );
  }

  bool _shouldReconnectAfterRuntimeStop() {
    if (_session == null) {
      return false;
    }
    return switch (status.value.phase) {
      CoreRunPhase.running || CoreRunPhase.needsVpnPermission => true,
      CoreRunPhase.signedOut ||
      CoreRunPhase.stopped ||
      CoreRunPhase.checking ||
      CoreRunPhase.repairing ||
      CoreRunPhase.error ||
      CoreRunPhase.needsElevation => false,
    };
  }

  Map<String, Object?> _runtimeEventPayload(CoreRuntimeEvent event) {
    final payload = event.data['payload'];
    return payload is Map ? _stringObjectMap(payload) : event.data;
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _serial = _serial.then(
      (_) => action(),
      onError: (error, stackTrace) => action(),
    );
    return _serial;
  }
}
