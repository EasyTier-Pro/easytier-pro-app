import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/console_auth_service.dart';
import '../logging/app_logger.dart';

enum CoreRunPhase { signedOut, checking, repairing, running, error }

class CoreRunStatus {
  const CoreRunStatus({
    required this.phase,
    required this.message,
    this.lastError,
  });

  final CoreRunPhase phase;
  final String message;
  final String? lastError;

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
      _logger.info(
        'core',
        'Desktop install completed',
        context: {
          'force_reinstall': forceReinstall,
          'event': installEvent['data']?.toString() ?? '',
        },
      );

      status.value = const CoreRunStatus(
        phase: CoreRunPhase.running,
        message: '连接引擎运行中',
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
