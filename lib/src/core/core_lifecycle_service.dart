import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/console_auth_service.dart';
import 'core_peer_status.dart';
import '../logging/app_logger.dart';

part 'core_lifecycle_models.dart';

class CoreLifecycleService {
  CoreLifecycleService({required this.authService})
    : status = ValueNotifier<CoreRunStatus>(CoreRunStatus.signedOut);

  final AuthService authService;
  final ValueNotifier<CoreRunStatus> status;
  final AppLogger _logger = AppLogger.instance;

  AuthSession? _session;
  Future<void> _serial = Future<void>.value();
  String? _cliPath;

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
      _logger.info('core', 'Logout flow: uninstalling local engine binding');
      status.value = const CoreRunStatus(
        phase: CoreRunPhase.repairing,
        message: '正在卸载连接引擎...',
      );
      try {
        await _desktopCommand('uninstall', const {'purge': false});
        _cliPath = null;
        _logger.info(
          'core',
          'Logout cleanup completed',
          context: const {'uninstall_requested': true},
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
      if (!Platform.isWindows) {
        _logger.warn('core', 'Elevation repair is only supported on Windows');
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
    final cliExecutable = _resolveCliExecutable();
    _logger.debug(
      'core.stats',
      'Reading EasyTier traffic stats',
      context: {'executable': cliExecutable},
    );

    final process = await Process.start(cliExecutable, ['-o', 'json', 'stats']);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        throw TimeoutException('easytier-cli stats 执行超时');
      },
    );
    final stdoutText = await stdoutFuture;
    final stderrText = (await stderrFuture).trim();

    if (exitCode != 0) {
      _logger.warn(
        'core.stats',
        'EasyTier traffic stats failed',
        context: {'exit_code': exitCode, 'stderr': stderrText},
      );
      throw StateError(
        stderrText.isEmpty
            ? 'easytier-cli stats 执行失败 (exit=$exitCode)'
            : stderrText,
      );
    }

    final totals = parseNetworkTrafficTotalsFromJson(stdoutText);
    _logger.debug(
      'core.stats',
      'EasyTier traffic stats parsed',
      context: {'network_names': totals.keys.join(','), 'count': totals.length},
    );
    return totals;
  }

  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    final instanceName = runtimeNetworkName.trim();
    if (instanceName.isEmpty) {
      return false;
    }

    final cliExecutable = _resolveCliExecutable();
    _logger.debug(
      'core.instance',
      'Checking EasyTier network instance',
      context: {'executable': cliExecutable, 'instance_name': instanceName},
    );

    final process = await Process.start(cliExecutable, [
      '-o',
      'json',
      '--instance-name',
      instanceName,
      'node',
      'info',
    ]);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        throw TimeoutException('easytier-cli node info 执行超时');
      },
    );
    final stdoutText = (await stdoutFuture).trim();
    final stderrText = (await stderrFuture).trim();

    if (exitCode == 0) {
      _logger.debug(
        'core.instance',
        'EasyTier network instance is running',
        context: {
          'instance_name': instanceName,
          'output_length': stdoutText.length,
        },
      );
      return true;
    }

    final message = stderrText.isEmpty
        ? 'easytier-cli node info 执行失败 (exit=$exitCode)'
        : stderrText;
    if (_isInstanceNotReadyMessage(message)) {
      _logger.warn(
        'core.instance',
        'EasyTier network instance is not ready',
        context: {'instance_name': instanceName, 'error': message},
      );
      return false;
    }

    _logger.warn(
      'core.instance',
      'EasyTier network instance check failed',
      context: {
        'instance_name': instanceName,
        'exit_code': exitCode,
        'stderr': stderrText,
      },
    );
    throw StateError(message);
  }

  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async {
    final instanceName = runtimeNetworkName.trim();
    if (instanceName.isEmpty) {
      return const <String, CorePeerStatus>{};
    }

    final cliExecutable = _resolveCliExecutable();
    _logger.debug(
      'core.peer',
      'Reading EasyTier peer status',
      context: {'executable': cliExecutable, 'instance_name': instanceName},
    );

    final process = await Process.start(cliExecutable, [
      '-o',
      'json',
      '--instance-name',
      instanceName,
      'peer',
    ]);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        throw TimeoutException('easytier-cli peer 执行超时');
      },
    );
    final stdoutText = await stdoutFuture;
    final stderrText = (await stderrFuture).trim();

    if (exitCode != 0) {
      _logger.warn(
        'core.peer',
        'EasyTier peer status failed',
        context: {
          'instance_name': instanceName,
          'exit_code': exitCode,
          'stderr': stderrText,
        },
      );
      throw StateError(
        stderrText.isEmpty
            ? 'easytier-cli peer 执行失败 (exit=$exitCode)'
            : stderrText,
      );
    }

    return parseNetworkPeerStatusesFromJson(stdoutText);
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
    final workspace = session.user.currentWorkspace;
    if (workspace == null) {
      _logger.error('core', 'No workspace available for lifecycle binding');
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
        final desktopStatus = await _tryReadDesktopStatus(bootstrap);
        final machineId = desktopStatus?.machineId;
        if (desktopStatus?.ready == true &&
            machineId != null &&
            machineId.isNotEmpty) {
          _logger.info(
            'core',
            'Existing desktop service is ready',
            context: {
              'machine_id': machineId,
              'version': desktopStatus?.version ?? '',
              'service_state': desktopStatus?.serviceState ?? '',
            },
          );
          status.value = CoreRunStatus(
            phase: CoreRunPhase.running,
            message: '本机设备已就绪',
            machineId: machineId,
            details: 'EasyTier ${desktopStatus?.version ?? bootstrap.version}',
          );
          return;
        }
      }
      if (forceReinstall) {
        status.value = CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: '正在重装连接引擎...',
        );
        try {
          await _desktopCommand('uninstall', const {'purge': false});
        } catch (error) {
          _logger.warn(
            'core',
            'Forced reinstall pre-uninstall failed, continuing install',
            context: {'error': error.toString()},
          );
        }
      } else {
        status.value = const CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: '正在检查并应用连接引擎配置...',
        );
      }

      final installEvent = await _desktopCommand('install', {
        'bootstrap_token': bootstrap.bootstrapToken,
        'version': bootstrap.version,
        'config_server': bootstrap.configServer,
      });
      final machineId = parseMachineIdFromDesktopEvent(installEvent);
      _rememberCliPath(parseCliPathFromDesktopEvent(installEvent));
      _logger.info(
        'core',
        'Desktop install completed',
        context: {
          'force_reinstall': forceReinstall,
          'machine_id': machineId ?? '',
          'event': installEvent['data']?.toString() ?? '',
        },
      );

      status.value = CoreRunStatus(
        phase: CoreRunPhase.running,
        message: machineId == null || machineId.isEmpty ? '连接引擎运行中' : '本机设备已就绪',
        machineId: machineId,
        details: 'EasyTier ${bootstrap.version}',
      );
    } catch (error) {
      _logger.error(
        'core',
        'Ensure running failed',
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

  Future<void> _enqueue(Future<void> Function() action) {
    _serial = _serial.then(
      (_) => action(),
      onError: (error, stackTrace) => action(),
    );
    return _serial;
  }
}
