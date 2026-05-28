import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
      _logger.info('core', 'Binding session', context: {
        'workspace_changed': workspaceChanged,
        'previous_workspace': previousWorkspace,
        'next_workspace': nextWorkspace,
      });
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
        final snapshot = await _status();
        if (snapshot.installed) {
          await _desktopCommand('uninstall', const {'purge': false});
        }
        _logger.info('core', 'Logout cleanup completed', context: {
          'installed_before_cleanup': snapshot.installed,
        });
        status.value = CoreRunStatus.signedOut;
      } catch (error) {
        _logger.error('core', 'Logout cleanup failed', context: {
          'error': error.toString(),
        });
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
    _logger.info('core', 'Ensure running start', context: {
      'force_reinstall': forceReinstall,
      'workspace_id': workspace.id,
    });

    try {
      final bootstrap = await authService.prepareCoreBootstrap(
        accessToken: session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );
      final expectedFingerprint = _fingerprintForToken(
        bootstrap.bootstrapToken,
      );
      var snapshot = await _status();

      final mismatch =
          snapshot.currentBootstrapFingerprint != null &&
          snapshot.currentBootstrapFingerprint != expectedFingerprint;
      final shouldReinstall =
          forceReinstall ||
          !snapshot.installed ||
          !snapshot.serviceRunning ||
          mismatch ||
          snapshot.currentBootstrapFingerprint == null;
      _logger.info('core', 'Status evaluated', context: {
        'installed': snapshot.installed,
        'service_running': snapshot.serviceRunning,
        'fingerprint_mismatch': mismatch,
        'should_reinstall': shouldReinstall,
      });

      if (shouldReinstall) {
        status.value = CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: mismatch ? '身份已变更，正在重装连接引擎...' : '正在修复连接引擎...',
        );

        if (snapshot.installed) {
          await _desktopCommand('uninstall', const {'purge': false});
        }
        await _desktopCommand('install', {
          'bootstrap_token': bootstrap.bootstrapToken,
          'version': bootstrap.version,
          'config_server': bootstrap.configServer,
        });
        snapshot = await _status();
      }

      if (snapshot.installed &&
          snapshot.serviceRunning &&
          snapshot.currentBootstrapFingerprint == expectedFingerprint) {
        _logger.info('core', 'Engine running and fingerprint matched');
        status.value = CoreRunStatus(
          phase: CoreRunPhase.running,
          message: '连接引擎运行中',
        );
        return;
      }

      status.value = CoreRunStatus(
        phase: CoreRunPhase.error,
        message: '连接引擎状态异常',
        lastError: '服务运行状态或身份指纹不一致',
      );
      _logger.error('core', 'Engine status invalid after repair', context: {
        'installed': snapshot.installed,
        'service_running': snapshot.serviceRunning,
      });
    } catch (error) {
      _logger.error('core', 'Ensure running failed', context: {
        'error': error.toString(),
      });
      status.value = CoreRunStatus(
        phase: CoreRunPhase.error,
        message: '连接引擎启动失败',
        lastError: _normalizeError(error),
      );
    }
  }

  Future<_CoreStatusSnapshot> _status() async {
    final event = await _desktopCommand('status', const <String, Object?>{});
    final data = event['data'] as Map<String, dynamic>? ?? const {};
    return _CoreStatusSnapshot(
      installed: data['installed'] == true,
      serviceRunning: data['service_running'] == true,
      currentBootstrapFingerprint: data['current_bootstrap_fingerprint']
          ?.toString(),
    );
  }

  Future<Map<String, dynamic>> _desktopCommand(
    String command,
    Map<String, Object?> request,
  ) async {
    final executable = _resolveInstallerExecutable();
    _logger.info('core.desktop', 'Executing desktop command', context: {
      'command': command,
      'executable': executable,
    });
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
        _logger.error('core.desktop', 'Desktop command timeout', context: {
          'command': command,
        });
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
        _logger.error('core.desktop', 'Desktop command returned error event', context: {
          'command': command,
          'event': data,
        });
        throw StateError(data['message']?.toString() ?? 'desktop 命令执行失败');
      }
    }

    if (exitCode != 0) {
      final stderrText = stderrLines.join('\n').trim();
      _logger.error('core.desktop', 'Desktop command failed', context: {
        'command': command,
        'exit_code': exitCode,
        'stderr': stderrText,
      });
      throw StateError(
        stderrText.isEmpty
            ? 'desktop $command 执行失败 (exit=$exitCode)'
            : stderrText,
      );
    }

    for (var index = events.length - 1; index >= 0; index--) {
      final event = events[index];
      if (event['event'] == 'finished') {
        _logger.info('core.desktop', 'Desktop command finished', context: {
          'command': command,
          'exit_code': exitCode,
        });
        return event;
      }
    }

    throw StateError('desktop 命令没有返回 finished 事件');
  }

  String _resolveInstallerExecutable() {
    final override = Platform.environment['EASYTIER_INSTALLER_PATH'];
    if (override != null && override.trim().isNotEmpty) {
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
    for (final candidate in unixCandidates) {
      if (candidate.isEmpty) {
        continue;
      }
      if (!candidate.contains('/')) {
        return candidate;
      }
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    return 'easytier-pro-installer';
  }

  String _fingerprintForToken(String token) {
    final digest = sha256.convert(utf8.encode(token));
    return digest.bytes
        .take(16)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
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

class _CoreStatusSnapshot {
  const _CoreStatusSnapshot({
    required this.installed,
    required this.serviceRunning,
    required this.currentBootstrapFingerprint,
  });

  final bool installed;
  final bool serviceRunning;
  final String? currentBootstrapFingerprint;
}
