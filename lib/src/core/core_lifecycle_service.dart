import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/console_auth_service.dart';
import '../logging/app_logger.dart';

enum CoreRunPhase { signedOut, checking, repairing, running, error }

class _DesktopCoreStatus {
  const _DesktopCoreStatus({
    required this.ready,
    required this.installed,
    required this.running,
    this.machineId,
    this.version,
    this.serviceState,
    this.cliPath,
  });

  final bool ready;
  final bool installed;
  final bool running;
  final String? machineId;
  final String? version;
  final String? serviceState;
  final String? cliPath;

  static _DesktopCoreStatus fromEvent(Map<String, dynamic> event) {
    final data = event['data'];
    final values = data is Map<String, dynamic>
        ? data
        : const <String, dynamic>{};
    return _DesktopCoreStatus(
      ready: _readBool(values['ready']),
      installed: _readBool(values['installed']),
      running: _readBool(values['running']),
      machineId: _readString(values['machine_id']),
      version: _readString(values['version']),
      serviceState: _readString(values['service_state']),
      cliPath: _readString(values['cli_path']),
    );
  }

  static bool _readBool(Object? value) {
    if (value is bool) {
      return value;
    }
    final text = value?.toString().toLowerCase().trim();
    return text == 'true' || text == '1';
  }

  static String? _readString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class CoreNetworkTrafficTotals {
  const CoreNetworkTrafficTotals({
    required this.runtimeNetworkName,
    required this.downloadBytes,
    required this.uploadBytes,
    required this.sampledAt,
  });

  final String runtimeNetworkName;
  final int downloadBytes;
  final int uploadBytes;
  final DateTime sampledAt;
}

class _MutableNetworkTrafficTotals {
  int downloadBytes = 0;
  int uploadBytes = 0;
  bool hasDownloadBytes = false;
  bool hasUploadBytes = false;
}

class CoreRunStatus {
  const CoreRunStatus({
    required this.phase,
    required this.message,
    this.lastError,
    this.machineId,
    this.details,
  });

  final CoreRunPhase phase;
  final String message;
  final String? lastError;
  final String? machineId;
  final String? details;

  bool get isRunning => phase == CoreRunPhase.running;

  static const CoreRunStatus signedOut = CoreRunStatus(
    phase: CoreRunPhase.signedOut,
    message: '未登录',
  );
}

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
      throw StateError(
        stderrText.isEmpty
            ? 'easytier-cli stats 执行失败 (exit=$exitCode)'
            : stderrText,
      );
    }

    return parseNetworkTrafficTotalsFromJson(stdoutText);
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
    final process = await Process.start(executable, [
      'desktop',
      command,
      '--json',
    ]);

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
    if (decoded is! List<dynamic>) {
      throw const FormatException('easytier-cli stats JSON 必须是数组');
    }

    final collected = <String, _MutableNetworkTrafficTotals>{};
    for (final item in decoded) {
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
