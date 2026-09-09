import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../auth/console_auth_service.dart';
import '../logging/app_logger.dart';
import '../telemetry/app_client_reporter.dart';
import 'core_json_value.dart';
import 'core_peer_status.dart';

part 'core_lifecycle_models.dart';
part 'core_platform_runtime.dart';
part 'desktop_core_runtime.dart';
part 'android_core_runtime.dart';

@visibleForTesting
typedef CoreElevatedDesktopCommandRunner =
    Future<Map<String, dynamic>> Function(
      String command,
      Map<String, Object?> request,
    );

class _ElevatedDesktopCommandRequest {
  const _ElevatedDesktopCommandRequest(this.command, this.request);

  final String command;
  final Map<String, Object?> request;
}

class _ElevatedDesktopCommandFile {
  const _ElevatedDesktopCommandFile({
    required this.command,
    required this.inputFile,
    required this.outputFile,
    required this.errorFile,
    required this.exitFile,
  });

  final String command;
  final File inputFile;
  final File outputFile;
  final File errorFile;
  final File exitFile;
}

class _ElevatedDesktopCommandFailure implements Exception {
  const _ElevatedDesktopCommandFailure(
    this.command,
    this.cause,
    this.stackTrace,
  );

  final String command;
  final Object cause;
  final StackTrace stackTrace;

  @override
  String toString() => cause.toString();
}

class CoreLifecycleService {
  static const String _needsElevationRepairMessage = '管理员权限修复/重试';

  CoreLifecycleService({
    required this.authService,
    CorePlatformRuntime? runtime,
    this.appClientReporter,
    @visibleForTesting
    CoreElevatedDesktopCommandRunner? elevatedDesktopCommandRunner,
    this.engineVersionCheckInterval = const Duration(hours: 1),
    this.engineVersionCheckTimeout = const Duration(seconds: 20),
  }) : status = ValueNotifier<CoreRunStatus>(CoreRunStatus.signedOut),
       engineVersionStatus = ValueNotifier<CoreEngineVersionStatus>(
         CoreEngineVersionStatus.unknown,
       ) {
    _elevatedDesktopCommandRunner = elevatedDesktopCommandRunner;
    _runtime = runtime ?? CorePlatformRuntime.current(this);
    _runtimeEvents = _runtime.events.listen(_handleRuntimeEvent);
  }

  final AuthService authService;
  final ValueNotifier<CoreRunStatus> status;
  final ValueNotifier<CoreEngineVersionStatus> engineVersionStatus;
  final AppLogger _logger = AppLogger.instance;
  final AppClientReporter? appClientReporter;
  final Duration engineVersionCheckInterval;
  final Duration engineVersionCheckTimeout;

  late final CorePlatformRuntime _runtime;
  late final StreamSubscription<CoreRuntimeEvent> _runtimeEvents;
  AuthSession? _session;
  TokenConnectionProfile? _tokenConnectionProfile;
  Future<void> _serial = Future<void>.value();
  String? _cliPath;
  Timer? _engineVersionCheckTimer;
  Future<void>? _engineVersionCheckInFlight;
  int _engineVersionCheckGeneration = 0;
  int _engineVersionCheckPauseDepth = 0;
  late final CoreElevatedDesktopCommandRunner? _elevatedDesktopCommandRunner;

  bool get _engineVersionChecksPaused => _engineVersionCheckPauseDepth > 0;

  Duration get networkTrafficPollInterval =>
      _runtime.networkTrafficPollInterval;

  Duration get peerStatusPollInterval => _runtime.peerStatusPollInterval;

  Future<void> bindSession(AuthSession session) {
    return _enqueue(() async {
      final previousWorkspace = _session?.user.currentWorkspace?.id;
      final nextWorkspace = session.user.currentWorkspace?.id;
      final versionScopeChanged =
          _engineVersionScopeForSession(_session) !=
          _engineVersionScopeForSession(session);
      final workspaceChanged =
          previousWorkspace != null &&
          nextWorkspace != null &&
          previousWorkspace != nextWorkspace;

      _session = session;
      _tokenConnectionProfile = null;
      _invalidateEngineVersionChecks();
      if (versionScopeChanged) {
        engineVersionStatus.value = CoreEngineVersionStatus.unknown;
      }
      _logger.info(
        'core',
        'Binding session',
        context: {
          'workspace_changed': workspaceChanged,
          'previous_workspace': previousWorkspace,
          'next_workspace': nextWorkspace,
        },
      );
      _reportSessionEstablished(session);
      if (workspaceChanged) {
        status.value = const CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: '工作区变更，正在重建连接引擎...',
        );
      }
      await _ensureRunning(forceReinstall: workspaceChanged);
      if (_session?.user.currentWorkspace != null) {
        _startEngineVersionCheckTimer();
      }
    });
  }

  Future<void> onLogout() {
    return _enqueue(() async {
      _session = null;
      _tokenConnectionProfile = null;
      _invalidateEngineVersionChecks();
      _stopEngineVersionCheckTimer();
      engineVersionStatus.value = CoreEngineVersionStatus.unknown;
      _logger.info('core', 'Logout flow: stopping local engine binding');
      status.value = const CoreRunStatus(
        phase: CoreRunPhase.repairing,
        message: '正在停止连接引擎...',
      );
      try {
        await _stopRuntimeAllowingElevation(
          elevatedStatusMessage: '正在以管理员身份停止连接引擎...',
          elevatedLogMessage: 'Elevated logout cleanup requested',
        );
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

  Future<void> stopRuntimeForUserExit() {
    return _enqueue(() async {
      _invalidateEngineVersionChecks();
      _stopEngineVersionCheckTimer();
      _logger.info('core', 'User exit requested runtime stop');
      final current = status.value;
      status.value = CoreRunStatus(
        phase: CoreRunPhase.repairing,
        message: '正在停止后台服务...',
        machineId: current.machineId,
        details: current.details,
      );
      try {
        await _stopRuntimeAllowingElevation(
          elevatedStatusMessage: '正在以管理员身份停止后台服务...',
          elevatedLogMessage: 'Elevated user exit cleanup requested',
        );
        _logger.info(
          'core',
          'Runtime stopped for user exit',
          context: {'runtime': _runtime.runtimeType.toString()},
        );
        engineVersionStatus.value = CoreEngineVersionStatus.unknown;
        status.value = CoreRunStatus(
          phase: CoreRunPhase.stopped,
          message: '后台服务已停止',
          machineId: current.machineId,
          details: current.details,
        );
      } catch (error) {
        final message = _normalizeError(error);
        _logger.error(
          'core',
          'Runtime stop for user exit failed',
          context: {'error': message},
        );
        status.value = CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '后台服务停止失败',
          lastError: message,
          machineId: current.machineId,
          details: current.details,
        );
        rethrow;
      }
    });
  }

  Future<void> _stopRuntimeAllowingElevation({
    required String elevatedStatusMessage,
    required String elevatedLogMessage,
  }) async {
    try {
      await _runtime.stop();
    } catch (error) {
      if (error is _ElevationRequiredException) {
        await _stopRuntimeWithElevation(
          statusMessage: elevatedStatusMessage,
          logMessage: elevatedLogMessage,
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _stopRuntimeWithElevation({
    required String statusMessage,
    required String logMessage,
  }) async {
    status.value = CoreRunStatus(
      phase: CoreRunPhase.repairing,
      message: statusMessage,
    );
    _logger.info('core', logMessage);

    await _runElevatedDesktopCommand('uninstall', const {'purge': false});
    _cliPath = null;
    _logger.info(
      'core',
      'Elevated runtime stop completed',
      context: {'runtime': _runtime.runtimeType.toString()},
    );
  }

  Future<void> repair() {
    return _enqueue(() async {
      final session = _session;
      if (session == null) {
        final profile = _tokenConnectionProfile;
        if (profile != null) {
          _logger.info('core', 'Manual token connection repair requested');
          _invalidateEngineVersionChecks();
          await _ensureTokenConnection(forceReinstall: true);
          return;
        }
        _logger.warn('core', 'Repair requested without active connection');
        status.value = CoreRunStatus.signedOut;
        engineVersionStatus.value = CoreEngineVersionStatus.unknown;
        return;
      }
      _logger.info('core', 'Manual repair requested');
      _invalidateEngineVersionChecks();
      await _ensureRunning(forceReinstall: true);
    });
  }

  Future<void> dispose() async {
    _invalidateEngineVersionChecks();
    _stopEngineVersionCheckTimer();
    await _runtimeEvents.cancel();
    await _runtime.dispose();
    engineVersionStatus.dispose();
    status.dispose();
  }

  Future<void> checkEngineVersion() {
    return _startEngineVersionCheck();
  }

  Future<void> bindTokenConnection(TokenConnectionProfile profile) {
    return _enqueue(() async {
      _session = null;
      _tokenConnectionProfile = profile;
      _invalidateEngineVersionChecks();
      _stopEngineVersionCheckTimer();
      engineVersionStatus.value = CoreEngineVersionStatus.unknown;
      _logger.info(
        'core',
        'Binding token connection',
        context: {
          'display_name': profile.effectiveDisplayName,
          'config_server': _redactConfigServer(profile.configServer),
        },
      );
      await _ensureTokenConnection(forceReinstall: false);
      _startEngineVersionCheckTimer();
    });
  }

  Future<void> repairWithElevation() {
    return _enqueue(() async {
      _pauseEngineVersionChecks();
      try {
        final session = _session;
        final profile = _tokenConnectionProfile;
        if (session == null && profile == null) {
          _logger.warn(
            'core',
            'Elevation repair requested without active connection',
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
          if (session != null) {
            await _ensureRunning(forceReinstall: true);
          } else {
            await _ensureTokenConnection(forceReinstall: true);
          }
          return;
        }

        if (session != null && session.user.currentWorkspace == null) {
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
        _logger.info(
          'core',
          'Elevation repair requested',
          context: {'connection_mode': session == null ? 'token' : 'account'},
        );

        var elevatedUninstallRequested = false;
        try {
          final CoreBootstrapConfig bootstrap;
          if (session != null) {
            final workspace = session.user.currentWorkspace!;
            bootstrap = await authService.prepareCoreBootstrap(
              accessToken: session.tokenSet.accessToken,
              workspaceId: workspace.id,
            );
          } else {
            final defaults = await authService.fetchCoreBootstrapDefaults();
            bootstrap = profile!.toBootstrap(
              version: defaults.version,
              configServerOverride: _tokenConfigServerOverride(
                configured: profile.configServer,
                releaseConfigServer: defaults.configServer,
              ),
            );
          }
          final request = {
            'bootstrap_token': bootstrap.bootstrapToken,
            'version': bootstrap.version,
            'config_server': bootstrap.configServer,
          };
          final shouldUninstall = await _runtime
              .shouldUninstallBeforeElevatedInstall(bootstrap);
          elevatedUninstallRequested = shouldUninstall;
          if (shouldUninstall) {
            status.value = const CoreRunStatus(
              phase: CoreRunPhase.repairing,
              message: '正在以管理员身份重建连接引擎...',
            );
            _logger.info(
              'core',
              'Elevated repair will uninstall existing desktop service first',
            );
          }

          final commands = <_ElevatedDesktopCommandRequest>[
            if (shouldUninstall)
              const _ElevatedDesktopCommandRequest('uninstall', {
                'purge': false,
              }),
            _ElevatedDesktopCommandRequest('install', request),
          ];
          final events = await _runElevatedDesktopCommands(commands);
          if (shouldUninstall) {
            _cliPath = null;
            _logger.info('core', 'Elevated pre-install uninstall completed');
          }
          final event = events.last;
          _completeElevatedInstall(
            session: session,
            bootstrap: bootstrap,
            event: event,
            tokenConnection: session == null,
          );
        } on _ElevatedDesktopCommandFailure catch (error) {
          final cause = error.cause;
          _logger.error(
            'core',
            error.command == 'uninstall'
                ? 'Elevated pre-install uninstall failed'
                : 'Elevation repair failed',
            context: {'error': cause.toString()},
          );
          if (elevatedUninstallRequested && error.command != 'uninstall') {
            _cliPath = null;
            _logger.info(
              'core',
              'Elevated pre-install uninstall completed before install failure',
            );
          }
          status.value = CoreRunStatus(
            phase: CoreRunPhase.needsElevation,
            message: _needsElevationRepairMessage,
            lastError: cause is _ElevationRequiredException
                ? _elevationLastError(cause)
                : _normalizeError(cause),
          );
        } catch (error) {
          _logger.error(
            'core',
            'Elevation repair failed',
            context: {'error': error.toString()},
          );
          if (error is _ElevationRequiredException) {
            status.value = CoreRunStatus(
              phase: CoreRunPhase.needsElevation,
              message: _needsElevationRepairMessage,
              lastError: _elevationLastError(error),
            );
            return;
          }
          status.value = CoreRunStatus(
            phase: CoreRunPhase.error,
            message: '连接引擎启动失败',
            lastError: _normalizeError(error),
          );
        }
      } finally {
        _resumeEngineVersionChecks();
      }
    });
  }

  void _completeElevatedInstall({
    required AuthSession? session,
    required CoreBootstrapConfig bootstrap,
    required Map<String, dynamic> event,
    required bool tokenConnection,
  }) {
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
          : tokenConnection
          ? '令牌连接已建立'
          : '本机设备已就绪',
      machineId: machineId,
      details: 'EasyTier ${bootstrap.version}',
    );
    _publishEngineVersionStatus(
      installedVersion: bootstrap.version,
      consoleVersion: bootstrap.version,
    );
    if (session != null) {
      _reportMachineReady(session, machineId);
    }
  }

  Future<Map<String, dynamic>> _runElevatedDesktopCommand(
    String command,
    Map<String, Object?> request,
  ) async {
    try {
      final events = await _runElevatedDesktopCommands([
        _ElevatedDesktopCommandRequest(command, request),
      ]);
      return events.single;
    } on _ElevatedDesktopCommandFailure catch (error) {
      Error.throwWithStackTrace(error.cause, error.stackTrace);
    }
  }

  Future<List<Map<String, dynamic>>> _runElevatedDesktopCommands(
    List<_ElevatedDesktopCommandRequest> requests,
  ) async {
    if (requests.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    for (final request in requests) {
      if (request.command != 'install' && request.command != 'uninstall') {
        throw ArgumentError.value(
          request.command,
          'command',
          '不支持的提权 desktop 命令',
        );
      }
    }

    final elevatedRunner = _elevatedDesktopCommandRunner;
    if (elevatedRunner != null) {
      final events = <Map<String, dynamic>>[];
      for (final request in requests) {
        try {
          final event = await elevatedRunner(request.command, request.request);
          _validateElevatedDesktopCommandEvent(request.command, event);
          events.add(event);
        } catch (error, stackTrace) {
          throw _ElevatedDesktopCommandFailure(
            request.command,
            error,
            stackTrace,
          );
        }
      }
      return events;
    }

    File? commandFile;
    Directory? elevationTempDir;
    final tempFiles = <File>[];
    final commandFiles = <_ElevatedDesktopCommandFile>[];
    try {
      elevationTempDir = await Directory.systemTemp.createTemp(
        'easytier_pro_elevated_',
      );
      await _restrictOwnerOnlyPermissions(
        elevationTempDir,
        ownerExecutable: true,
      );
      for (var index = 0; index < requests.length; index += 1) {
        final request = requests[index];
        final inputFile = File(
          _joinPath(elevationTempDir.path, 'request_$index.json'),
        );
        final outputFile = File(
          _joinPath(elevationTempDir.path, 'output_$index.json'),
        );
        final errorFile = File(
          _joinPath(elevationTempDir.path, 'error_$index.json'),
        );
        final exitFile = File(_joinPath(elevationTempDir.path, 'exit_$index'));
        await inputFile.writeAsString(
          jsonEncode(request.request),
          encoding: utf8,
        );
        await _restrictOwnerOnlyPermissions(inputFile);
        tempFiles.addAll([inputFile, outputFile, errorFile, exitFile]);
        commandFiles.add(
          _ElevatedDesktopCommandFile(
            command: request.command,
            inputFile: inputFile,
            outputFile: outputFile,
            errorFile: errorFile,
            exitFile: exitFile,
          ),
        );
      }

      final installerPath = _resolveInstallerExecutable();
      commandFile = await _writeElevatedDesktopCommandFile(
        commands: commandFiles,
        tempDir: elevationTempDir,
        installerPath: installerPath,
      );

      final commandNames = requests.map((request) => request.command).join(',');
      _logger.info(
        'core.desktop',
        'Launching elevated desktop command',
        context: {
          'command': commandNames,
          'command_file': commandFile.path,
          'installer': installerPath,
          'platform': Platform.operatingSystem,
        },
      );

      final elevationResult = await _runElevatedInstaller(commandFile.path);
      _logger.info(
        'core.desktop',
        'Elevated desktop command process completed',
        context: {
          'command': commandNames,
          'exit_code': elevationResult,
          'output_exists': commandFiles.every(
            (command) => command.outputFile.existsSync(),
          ),
          'error_exists': commandFiles.every(
            (command) => command.errorFile.existsSync(),
          ),
          'exit_exists': commandFiles.every(
            (command) => command.exitFile.existsSync(),
          ),
        },
      );

      final events = <Map<String, dynamic>>[];
      for (final command in commandFiles) {
        try {
          final exitCode = await _readElevatedDesktopCommandExitCode(
            command.exitFile,
          );
          final event = await _readElevatedDesktopCommandResult(
            command.command,
            command.outputFile,
            command.errorFile,
          );
          if (exitCode != null && exitCode != 0) {
            throw StateError('提权 ${command.command} 执行失败 (exit=$exitCode)');
          }
          if (exitCode == null && elevationResult != 0) {
            throw StateError(
              '提权 ${command.command} 执行状态缺失 (exit=$elevationResult)',
            );
          }
          events.add(event);
        } catch (error, stackTrace) {
          throw _ElevatedDesktopCommandFailure(
            command.command,
            error,
            stackTrace,
          );
        }
      }
      if (elevationResult != 0) {
        throw _ElevatedDesktopCommandFailure(
          requests.last.command,
          StateError('提权命令执行失败 (exit=$elevationResult)'),
          StackTrace.current,
        );
      }
      return events;
    } finally {
      await _cleanupElevationTempFiles([...tempFiles, ?commandFile]);
      await _cleanupElevationTempDirectory(elevationTempDir);
    }
  }

  Future<Map<String, dynamic>> _readElevatedDesktopCommandResult(
    String command,
    File outputFile,
    File errorFile,
  ) async {
    if (outputFile.existsSync()) {
      final outputText = await outputFile.readAsString();
      final events = _parseDesktopCommandEvents(outputText);

      if (events.isNotEmpty) {
        final errorEvent = events.firstWhere(
          (event) => event['event'] == 'error',
          orElse: () => const <String, dynamic>{},
        );
        if (errorEvent.isNotEmpty) {
          _throwElevatedDesktopErrorEvent(errorEvent);
        }

        for (var index = events.length - 1; index >= 0; index--) {
          final event = events[index];
          if (event['event'] == 'finished') {
            return event;
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
    throw StateError('提权 $command 没有返回有效结果');
  }

  Future<int?> _readElevatedDesktopCommandExitCode(File exitFile) async {
    if (!exitFile.existsSync()) {
      return null;
    }
    final text = (await exitFile.readAsString()).trim();
    if (text.isEmpty) {
      return null;
    }
    final exitCode = int.tryParse(text);
    if (exitCode == null) {
      throw StateError('提权命令返回了无效退出码: $text');
    }
    return exitCode;
  }

  void _validateElevatedDesktopCommandEvent(
    String command,
    Map<String, dynamic> event,
  ) {
    if (event['event'] == 'error') {
      _throwElevatedDesktopErrorEvent(event);
    }
    if (event['event'] != 'finished') {
      throw StateError('提权 $command 没有返回有效结果');
    }
  }

  void _throwElevatedDesktopErrorEvent(Map<String, dynamic> event) {
    final data = event['data'] as Map<String, dynamic>? ?? const {};
    final message = data['message']?.toString() ?? '提权操作返回错误';
    if (_isElevationRequired(0, message, includeUnixPermissionErrors: true)) {
      throw _ElevationRequiredException(message);
    }
    throw StateError(message);
  }

  List<Map<String, dynamic>> _parseDesktopCommandEvents(String outputText) {
    final lines = const LineSplitter().convert(outputText);
    return lines
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
  }

  Future<File> _writeElevatedDesktopCommandFile({
    required List<_ElevatedDesktopCommandFile> commands,
    required Directory tempDir,
    required String installerPath,
  }) async {
    if (Platform.isWindows) {
      final batFile = File(_joinPath(tempDir.path, 'elevated.bat'));
      final validatorFile = File(
        _joinPath(tempDir.path, 'validate_output.ps1'),
      );
      await validatorFile.writeAsString(
        _windowsElevatedOutputValidatorScript,
        encoding: utf8,
      );
      await _restrictOwnerOnlyPermissions(validatorFile);
      final installerDir = File(installerPath).parent.path;
      final buffer = StringBuffer('''@echo off
chcp 65001 >nul
set "POWERSHELL_EXE=%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
if not exist "%POWERSHELL_EXE%" set "POWERSHELL_EXE=powershell.exe"
cd /d "$installerDir"
''');
      for (final command in commands) {
        buffer.writeln(
          '"$installerPath" desktop ${command.command} --json < '
          '"${command.inputFile.path}" > "${command.outputFile.path}" '
          '2> "${command.errorFile.path}"',
        );
        buffer.writeln('set "EASYTIER_COMMAND_EXIT=%ERRORLEVEL%"');
        buffer.writeln(
          '> "${command.exitFile.path}" echo %EASYTIER_COMMAND_EXIT%',
        );
        buffer.writeln(
          'if not "%EASYTIER_COMMAND_EXIT%"=="0" '
          'exit /b %EASYTIER_COMMAND_EXIT%',
        );
        buffer.writeln(
          '"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File '
          '"${validatorFile.path}" '
          '"${command.outputFile.path}"',
        );
        buffer.writeln('if errorlevel 1 exit /b %errorlevel%');
      }
      await batFile.writeAsString(buffer.toString(), encoding: utf8);
      return batFile;
    }

    if (Platform.isMacOS) {
      final scriptFile = File(_joinPath(tempDir.path, 'elevated.sh'));
      for (final command in commands) {
        await command.outputFile.writeAsString('', encoding: utf8);
        await _restrictOwnerOnlyPermissions(command.outputFile);
        await command.errorFile.writeAsString('', encoding: utf8);
        await _restrictOwnerOnlyPermissions(command.errorFile);
        await command.exitFile.writeAsString('', encoding: utf8);
        await _restrictOwnerOnlyPermissions(command.exitFile);
      }

      final installerDir = File(installerPath).parent.path;
      final buffer = StringBuffer('''#!/bin/sh
set -eu
check_desktop_output() {
  output_file=\$1
  if /usr/bin/grep -Eq '"event"[[:space:]]*:[[:space:]]*"error"' "\$output_file"; then
    return 2
  fi
  if ! /usr/bin/grep -Eq '"event"[[:space:]]*:[[:space:]]*"finished"' "\$output_file"; then
    return 3
  fi
}
run_desktop_command() {
  command_name=\$1
  input_file=\$2
  output_file=\$3
  error_file=\$4
  exit_file=\$5
  set +e
  "\$installer_path" desktop "\$command_name" --json < "\$input_file" > "\$output_file" 2> "\$error_file"
  command_exit=\$?
  set -e
  printf '%s\\n' "\$command_exit" > "\$exit_file"
  if [ "\$command_exit" -ne 0 ]; then
    return "\$command_exit"
  fi
  check_desktop_output "\$output_file"
}
installer_path=${_quotePosixShellArgument(installerPath)}
cd ${_quotePosixShellArgument(installerDir)}
''');
      for (final command in commands) {
        buffer.writeln(
          'run_desktop_command '
          '${_quotePosixShellArgument(command.command)} '
          '${_quotePosixShellArgument(command.inputFile.path)} '
          '${_quotePosixShellArgument(command.outputFile.path)} '
          '${_quotePosixShellArgument(command.errorFile.path)} '
          '${_quotePosixShellArgument(command.exitFile.path)}',
        );
      }
      await scriptFile.writeAsString(buffer.toString(), encoding: utf8);
      await _restrictOwnerOnlyPermissions(scriptFile);
      return scriptFile;
    }

    throw StateError('当前平台不支持提权操作');
  }

  static const String _windowsElevatedOutputValidatorScript = r'''
param(
  [Parameter(Mandatory=$true)]
  [string]$OutputFile
)

$ErrorActionPreference = 'Stop'
$finished = $false

foreach ($line in [System.IO.File]::ReadLines($OutputFile)) {
  if ([string]::IsNullOrWhiteSpace($line)) {
    continue
  }

  try {
    $event = $line | ConvertFrom-Json
  } catch {
    continue
  }

  if ($event.event -eq 'error') {
    exit 2
  }

  if ($event.event -eq 'finished') {
    $finished = $true
  }
}

if ($finished) {
  exit 0
}

exit 3
''';

  Future<int> _runElevatedInstaller(String commandPath) {
    if (Platform.isWindows) {
      return _runElevatedWithPowerShell(commandPath);
    }
    if (Platform.isMacOS) {
      return _runElevatedWithAppleScript(commandPath);
    }
    throw StateError('当前平台不支持提权操作');
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

  Future<int> _runElevatedWithAppleScript(String scriptPath) async {
    final appleScript =
        'do shell script ("/bin/sh " & quoted form of ${_quoteAppleScriptString(scriptPath)}) with administrator privileges';
    try {
      final result = await Process.run('/usr/bin/osascript', [
        '-e',
        appleScript,
      ]);
      final stderr = result.stderr.toString().trim();
      final stdout = result.stdout.toString().trim();
      _logger.debug(
        'core.desktop',
        'AppleScript elevation attempt',
        context: {
          'exit_code': result.exitCode,
          'stdout': stdout,
          'stderr': stderr,
        },
      );
      if (result.exitCode != 0) {
        final message = stderr.isEmpty ? stdout : stderr;
        if (_isMacOsAuthorizationCanceled(message)) {
          throw const _ElevationRequiredException('用户取消了管理员授权');
        }
      }
      return result.exitCode;
    } on ProcessException catch (e) {
      throw StateError('找不到 osascript 来执行 macOS 提权操作: ${e.message}');
    }
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

  Future<void> _cleanupElevationTempDirectory(Directory? directory) async {
    if (directory == null) {
      return;
    }
    try {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // ignore cleanup errors
    }
  }

  Future<void> _restrictOwnerOnlyPermissions(
    FileSystemEntity entity, {
    bool ownerExecutable = false,
  }) async {
    if (Platform.isWindows) {
      return;
    }
    try {
      final result = await Process.run('/bin/chmod', [
        ownerExecutable ? '700' : '600',
        entity.path,
      ]);
      if (result.exitCode != 0) {
        _logger.warn(
          'core.desktop',
          'Failed to restrict elevation temp permissions',
          context: {
            'path': entity.path,
            'exit_code': result.exitCode,
            'stderr': result.stderr.toString().trim(),
          },
        );
      }
    } on ProcessException catch (error) {
      _logger.warn(
        'core.desktop',
        'chmod unavailable for elevation temp permissions',
        context: {'path': entity.path, 'error': error.toString()},
      );
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
    return filterCredentialPeerStatuses(
      await _runtime.readNetworkPeerStatuses(runtimeNetworkName),
    );
  }

  static bool _isInstanceNotReadyMessage(String message) {
    final lower = message.toLowerCase();
    return lower.contains('no running instances found') ||
        lower.contains('instance not found') ||
        lower.contains('no instance matches') ||
        lower.contains('no instance');
  }

  Future<void> _ensureRunning({required bool forceReinstall}) async {
    _pauseEngineVersionChecks();
    try {
      final session = _session;
      if (session == null) {
        status.value = CoreRunStatus.signedOut;
        engineVersionStatus.value = CoreEngineVersionStatus.unknown;
        return;
      }
      if (session.tokenSet.isExpired) {
        await _stopRuntimeForAuthInvalid(
          const AuthException('当前登录态已失效，请重新登录。'),
        );
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
        engineVersionStatus.value = CoreEngineVersionStatus.unknown;
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
          if (runtimeStatus != null) {
            _publishEngineVersionStatus(
              installedVersion: _coreVersionFromResult(runtimeStatus),
              consoleVersion: bootstrap.version,
            );
            _reportMachineReady(session, machineId);
            if (runtimeStatus.phase == CoreRunPhase.running &&
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
        _publishEngineVersionStatus(
          installedVersion: _coreVersionFromResult(result) ?? bootstrap.version,
          consoleVersion: bootstrap.version,
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
        _reportMachineReady(session, result.machineId);
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
          status.value = CoreRunStatus(
            phase: CoreRunPhase.needsElevation,
            message: _needsElevationRepairMessage,
            lastError: _elevationLastError(error),
          );
          return;
        }
        status.value = CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '连接引擎启动失败',
          lastError: _normalizeError(error),
        );
      }
    } finally {
      _resumeEngineVersionChecks();
    }
  }

  Future<void> _ensureTokenConnection({required bool forceReinstall}) async {
    _pauseEngineVersionChecks();
    try {
      final profile = _tokenConnectionProfile;
      if (profile == null) {
        status.value = CoreRunStatus.signedOut;
        engineVersionStatus.value = CoreEngineVersionStatus.unknown;
        return;
      }

      status.value = const CoreRunStatus(
        phase: CoreRunPhase.checking,
        message: '正在检查令牌连接状态...',
      );
      _logger.info(
        'core',
        'Ensure token connection start',
        context: {
          'force_reinstall': forceReinstall,
          'config_server': _redactConfigServer(profile.configServer),
        },
      );

      try {
        final defaults = await authService.fetchCoreBootstrapDefaults();
        final bootstrap = profile.toBootstrap(
          version: defaults.version,
          configServerOverride: _tokenConfigServerOverride(
            configured: profile.configServer,
            releaseConfigServer: defaults.configServer,
          ),
        );
        if (!forceReinstall) {
          final runtimeStatus = await _runtime.readStatus(bootstrap);
          final machineId = runtimeStatus?.machineId;
          if (runtimeStatus != null) {
            _publishEngineVersionStatus(
              installedVersion: _coreVersionFromResult(runtimeStatus),
              consoleVersion: bootstrap.version,
            );
            if (runtimeStatus.phase == CoreRunPhase.running &&
                machineId != null &&
                machineId.isNotEmpty) {
              _logger.info(
                'core',
                'Existing token runtime service is ready',
                context: {
                  'machine_id': machineId,
                  'runtime': _runtime.runtimeType.toString(),
                },
              );
              status.value = runtimeStatus.toStatus();
              return;
            }
          }
        }

        status.value = CoreRunStatus(
          phase: CoreRunPhase.repairing,
          message: forceReinstall ? '正在重建令牌连接...' : '正在建立令牌连接...',
        );

        final result = await _runtime.ensureRunning(
          bootstrap,
          forceReinstall: forceReinstall,
        );
        _publishEngineVersionStatus(
          installedVersion: _coreVersionFromResult(result) ?? bootstrap.version,
          consoleVersion: bootstrap.version,
        );
        _logger.info(
          'core',
          'Token runtime ensure completed',
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
          'Ensure token connection failed',
          context: {'error': error.toString()},
        );
        if (error is _ElevationRequiredException) {
          status.value = CoreRunStatus(
            phase: CoreRunPhase.needsElevation,
            message: _needsElevationRepairMessage,
            lastError: _elevationLastError(error),
          );
          return;
        }
        status.value = CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '令牌连接启动失败',
          lastError: _normalizeError(error),
        );
      }
    } finally {
      _resumeEngineVersionChecks();
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
    engineVersionStatus.value = CoreEngineVersionStatus.unknown;
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

  Future<void> _startEngineVersionCheck() {
    if (_engineVersionChecksPaused) {
      return Future<void>.value();
    }
    final inFlight = _engineVersionCheckInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<void> tracked;
    final current = _refreshEngineVersionStatus()
        .timeout(engineVersionCheckTimeout)
        .catchError((Object error, StackTrace stack) {
          if (error is TimeoutException &&
              identical(_engineVersionCheckInFlight, tracked)) {
            _invalidateEngineVersionChecks();
          }
          _logger.warn(
            'core.version',
            'Core engine version check failed',
            context: {'error': error.toString()},
          );
        });
    tracked = current.whenComplete(() {
      if (identical(_engineVersionCheckInFlight, tracked)) {
        _engineVersionCheckInFlight = null;
      }
    });
    _engineVersionCheckInFlight = tracked;
    return tracked;
  }

  Future<void> _refreshEngineVersionStatus() async {
    final generation = _engineVersionCheckGeneration;
    final session = _session;
    if (session == null) {
      final profile = _tokenConnectionProfile;
      if (profile == null) {
        engineVersionStatus.value = CoreEngineVersionStatus.unknown;
        return;
      }
      final defaults = await authService.fetchCoreBootstrapDefaults();
      final installedVersion = await _runtime.readInstalledVersion();
      if (!_isCurrentTokenEngineVersionCheck(
        generation: generation,
        profile: profile,
      )) {
        _logger.debug(
          'core.version',
          'Ignoring stale token core engine version check result',
        );
        return;
      }
      _publishEngineVersionStatus(
        installedVersion: installedVersion,
        consoleVersion: defaults.version,
      );
      _logger.info(
        'core.version',
        'Token core engine version checked',
        context: {
          'installed_version': engineVersionStatus.value.installedVersion ?? '',
          'console_version': engineVersionStatus.value.consoleVersion ?? '',
          'relation': engineVersionStatus.value.relation.name,
        },
      );
      return;
    }
    if (session.tokenSet.isExpired) {
      _logger.warn(
        'core.version',
        'Skipping version check for expired session',
      );
      return;
    }
    final workspace = session.user.currentWorkspace;
    if (workspace == null) {
      engineVersionStatus.value = CoreEngineVersionStatus.unknown;
      return;
    }

    final consoleVersion = await authService.fetchRecommendedCoreVersion(
      accessToken: session.tokenSet.accessToken,
      workspaceId: workspace.id,
    );
    final installedVersion = await _runtime.readInstalledVersion();
    if (!_isCurrentEngineVersionCheck(
      generation: generation,
      session: session,
      workspaceId: workspace.id,
    )) {
      _logger.debug(
        'core.version',
        'Ignoring stale core engine version check result',
      );
      return;
    }
    _publishEngineVersionStatus(
      installedVersion: installedVersion,
      consoleVersion: consoleVersion,
    );
    _logger.info(
      'core.version',
      'Core engine version checked',
      context: {
        'installed_version': engineVersionStatus.value.installedVersion ?? '',
        'console_version': engineVersionStatus.value.consoleVersion ?? '',
        'relation': engineVersionStatus.value.relation.name,
      },
    );
  }

  void _startEngineVersionCheckTimer() {
    if (engineVersionCheckInterval <= Duration.zero ||
        _engineVersionCheckTimer != null) {
      return;
    }

    _engineVersionCheckTimer = Timer.periodic(
      engineVersionCheckInterval,
      (_) => unawaited(checkEngineVersion()),
    );
  }

  void _stopEngineVersionCheckTimer() {
    _engineVersionCheckTimer?.cancel();
    _engineVersionCheckTimer = null;
  }

  void _invalidateEngineVersionChecks() {
    _engineVersionCheckGeneration++;
    _engineVersionCheckInFlight = null;
  }

  void _pauseEngineVersionChecks() {
    _engineVersionCheckPauseDepth++;
    _invalidateEngineVersionChecks();
  }

  void _resumeEngineVersionChecks() {
    if (_engineVersionCheckPauseDepth <= 0) {
      return;
    }
    _engineVersionCheckPauseDepth--;
    if (_engineVersionCheckPauseDepth == 0) {
      _invalidateEngineVersionChecks();
    }
  }

  String? _engineVersionScopeForSession(AuthSession? session) {
    final workspaceId = session?.user.currentWorkspace?.id;
    if (session == null || workspaceId == null) {
      return null;
    }
    return '${session.user.email}\n$workspaceId';
  }

  bool _isCurrentEngineVersionCheck({
    required int generation,
    required AuthSession session,
    required String workspaceId,
  }) {
    final currentSession = _session;
    return generation == _engineVersionCheckGeneration &&
        identical(currentSession, session) &&
        currentSession?.user.currentWorkspace?.id == workspaceId;
  }

  bool _isCurrentTokenEngineVersionCheck({
    required int generation,
    required TokenConnectionProfile profile,
  }) {
    return generation == _engineVersionCheckGeneration &&
        _session == null &&
        identical(_tokenConnectionProfile, profile);
  }

  void _publishEngineVersionStatus({
    required String? installedVersion,
    required String? consoleVersion,
  }) {
    final relation = _coreEngineVersionRelation(
      installedVersion: installedVersion,
      consoleVersion: consoleVersion,
    );
    engineVersionStatus.value = CoreEngineVersionStatus(
      relation: relation,
      installedVersion: normalizeCoreVersionForDisplay(installedVersion),
      consoleVersion: normalizeCoreVersionForDisplay(consoleVersion),
      checkedAt: DateTime.now(),
    );
  }

  CoreEngineVersionRelation _coreEngineVersionRelation({
    required String? installedVersion,
    required String? consoleVersion,
  }) {
    final comparison = compareCoreVersions(installedVersion, consoleVersion);
    if (comparison == null) {
      return CoreEngineVersionRelation.unknown;
    }
    if (comparison < 0) {
      return CoreEngineVersionRelation.updateAvailable;
    }
    if (comparison > 0) {
      return CoreEngineVersionRelation.aheadOfConsole;
    }
    return CoreEngineVersionRelation.current;
  }

  String? _coreVersionFromResult(CoreRuntimeStartResult result) {
    final explicit = result.coreVersion?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    return _extractCoreVersion(result.details);
  }

  String? _tokenConfigServerOverride({
    required String configured,
    required String releaseConfigServer,
  }) {
    final release = releaseConfigServer.trim();
    if (release.isEmpty) {
      return null;
    }
    if (isDefaultConfigServerUrlForConsoleBaseUrl(
      configured,
      defaultConsoleBaseUrl,
    )) {
      return release;
    }
    return null;
  }

  void _reportSessionEstablished(AuthSession session) {
    final reporter = appClientReporter;
    if (reporter == null) {
      return;
    }
    unawaited(reporter.reportSessionEstablished(session));
  }

  void _reportMachineReady(AuthSession session, String? machineId) {
    final reporter = appClientReporter;
    if (reporter == null) {
      return;
    }
    unawaited(reporter.reportMachineReady(session, machineId));
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
      if (desktopStatus.hasInstallArtifacts) {
        _rememberCliPath(desktopStatus.cliPath);
      } else {
        _cliPath = null;
      }
      _logger.info(
        'core.desktop',
        'Desktop status loaded',
        context: {
          'ready': desktopStatus.ready,
          'installed': desktopStatus.installed,
          'running': desktopStatus.running,
          'binaries_present': desktopStatus.binariesPresent,
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
      final message = _cleanProcessErrorMessage(e.message);
      if (_isElevationRequired(0, message)) {
        throw _ElevationRequiredException(message);
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
        final message = data['message']?.toString() ?? 'desktop 命令执行失败';
        _logger.error(
          'core.desktop',
          'Desktop command returned error event',
          context: {'command': command, 'event': data},
        );
        final needsElevation =
            _shouldTreatDesktopCommandFailureAsElevation(command) ||
            _isElevationRequired(
              0,
              message,
              includeUnixPermissionErrors:
                  _shouldTreatUnixPermissionAsElevation(command),
            );
        if (needsElevation) {
          throw _ElevationRequiredException(message);
        }
        throw StateError(message);
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
      final message = stderrText.isEmpty
          ? 'desktop $command 执行失败 (exit=$exitCode)'
          : stderrText;
      final needsElevation =
          _shouldTreatDesktopCommandFailureAsElevation(command) ||
          _isElevationRequired(
            exitCode,
            stderrText,
            includeUnixPermissionErrors:
                _shouldTreatUnixPermissionAsElevation(command),
          );
      if (needsElevation) {
        throw _ElevationRequiredException(message);
      }
      throw StateError(message);
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
  static bool desktopStatusHasInstallArtifactsForTesting(
    Map<String, dynamic> event,
  ) {
    return _DesktopCoreStatus.fromEvent(event).hasInstallArtifacts;
  }

  static bool supportsDesktopElevationRepairForPlatform({
    required bool isWindows,
    required bool isMacOS,
  }) {
    return isWindows || isMacOS;
  }

  @visibleForTesting
  static bool isElevationRequiredForDesktopCommand(
    int exitCode,
    String stderrText, {
    bool includeUnixPermissionErrors = false,
  }) {
    return _isElevationRequired(
      exitCode,
      stderrText,
      includeUnixPermissionErrors: includeUnixPermissionErrors,
    );
  }

  @visibleForTesting
  static Object elevationRequiredForTesting(String message) {
    return _ElevationRequiredException(message);
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

  bool _rememberedCliPathExists() {
    return _isExistingFilePath(_cliPath);
  }

  @visibleForTesting
  static bool isExistingFilePathForTesting(String? path) {
    return _isExistingFilePath(path);
  }

  static bool _isExistingFilePath(String? path) {
    final value = path?.trim();
    if (value == null || value.isEmpty) {
      return false;
    }
    if (!value.contains(Platform.pathSeparator)) {
      return false;
    }
    return File(value).existsSync();
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

  static bool _isElevationRequired(
    int exitCode,
    String stderrText, {
    bool includeUnixPermissionErrors = false,
  }) {
    if (exitCode == 740) {
      return true;
    }
    final text = stderrText.toLowerCase();
    if (text.contains('请求的操作需要提升') ||
        text.contains('elevation required') ||
        text.contains('requires elevation')) {
      return true;
    }
    if (!includeUnixPermissionErrors) {
      return false;
    }
    return text.contains('must be run as root') ||
        text.contains('requires root') ||
        text.contains('administrator privileges') ||
        text.contains('卸载服务失败') ||
        text.contains('failed to uninstall service') ||
        _isProtectedInstallPathPermissionError(text);
  }

  static bool _isProtectedInstallPathPermissionError(String text) {
    final mentionsProtectedPath =
        text.contains('/usr/local/easytier') ||
        text.contains('/usr/local/bin/easytier') ||
        text.contains('/library/launchdaemons') ||
        text.contains('/library/privilegedhelpertools');
    if (!mentionsProtectedPath) {
      return false;
    }
    return text.contains('permission denied') ||
        text.contains('operation not permitted') ||
        text.contains('os error 13') ||
        text.contains('eacces') ||
        text.contains('failed to write') ||
        text.contains('cannot write') ||
        text.contains('unable to write') ||
        text.contains('无法写入') ||
        text.contains('不能写入') ||
        text.contains('写入失败');
  }

  @visibleForTesting
  static bool shouldTreatDesktopCommandFailureAsElevationForTesting(
    String command, {
    required bool isWindows,
    required bool isMacOS,
  }) {
    return _shouldTreatDesktopCommandFailureAsElevation(
      command,
      isWindows: isWindows,
      isMacOS: isMacOS,
    );
  }

  static bool _shouldTreatDesktopCommandFailureAsElevation(
    String command, {
    bool? isWindows,
    bool? isMacOS,
  }) {
    if (command != 'install' && command != 'uninstall') {
      return false;
    }
    return supportsDesktopElevationRepairForPlatform(
      isWindows: isWindows ?? Platform.isWindows,
      isMacOS: isMacOS ?? Platform.isMacOS,
    );
  }

  @visibleForTesting
  static bool shouldTreatUnixPermissionAsElevationForTesting(
    String command, {
    required bool isMacOS,
  }) {
    return _shouldTreatUnixPermissionAsElevation(command, isMacOS: isMacOS);
  }

  static bool _shouldTreatUnixPermissionAsElevation(
    String command, {
    bool? isMacOS,
  }) {
    if (!(isMacOS ?? Platform.isMacOS)) {
      return false;
    }
    return command == 'install' ||
        command == 'uninstall' ||
        command == 'status';
  }

  static bool _isMacOsAuthorizationCanceled(String message) {
    final text = message.toLowerCase();
    return text.contains('(-128)') ||
        text.contains('user canceled') ||
        text.contains('user cancelled') ||
        text.contains('用户取消') ||
        text.contains('用户已取消');
  }

  static String _elevationLastError(_ElevationRequiredException error) {
    final message = _cleanProcessErrorMessage(error.message.trim());
    return message.isEmpty ? '安装连接引擎需要管理员权限' : message;
  }

  static String _quoteAppleScriptString(String value) {
    final escaped = value.replaceAll('\\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static String _quotePosixShellArgument(String value) {
    if (value.isEmpty) {
      return "''";
    }
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  static String _redactConfigServer(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme) {
      return '<configured>';
    }
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  String _normalizeError(Object error) {
    return _cleanProcessErrorMessage(
      error.toString().replaceFirst('Exception: ', ''),
    );
  }

  @visibleForTesting
  static int? compareCoreVersions(
    String? installedVersion,
    String? consoleVersion,
  ) {
    final installed = _parseCoreVersion(installedVersion);
    final console = _parseCoreVersion(consoleVersion);
    if (installed == null || console == null) {
      return null;
    }

    final maxLength = installed.length > console.length
        ? installed.length
        : console.length;
    for (var index = 0; index < maxLength; index++) {
      final left = index < installed.length ? installed[index] : 0;
      final right = index < console.length ? console[index] : 0;
      if (left < right) {
        return -1;
      }
      if (left > right) {
        return 1;
      }
    }
    return 0;
  }

  @visibleForTesting
  static String? normalizeCoreVersionForDisplay(String? version) {
    final extracted = _extractCoreVersion(version);
    if (extracted == null) {
      return null;
    }
    return extracted.replaceFirst(RegExp(r'^[vV]?'), 'v');
  }

  static String? _extractCoreVersion(String? version) {
    final text = version?.trim() ?? '';
    if (text.isEmpty) {
      return null;
    }
    final match = RegExp(
      r'[vV]?(\d+(?:\.\d+){0,3}(?:[-+][0-9A-Za-z.-]+)?)',
    ).firstMatch(text);
    return match?.group(0)?.trim();
  }

  static List<int>? _parseCoreVersion(String? version) {
    final extracted = _extractCoreVersion(version);
    if (extracted == null) {
      return null;
    }
    final numeric = extracted
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[-+]'))
        .first;
    final parts = numeric.split('.');
    final values = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null) {
        return null;
      }
      values.add(value);
    }
    return values;
  }

  static String _cleanProcessErrorMessage(String message) {
    // Dart's ProcessException on Windows appends runtime source paths like:
    // "请求的操作需要提升。 (at ../../../flutter/third_party/dart/runtime/bin/process_win.cc:577)"
    return message.replaceAllMapped(
      RegExp(r'\s*\(at\s+\.\./[^)]+\.cc:\d+\)\s*$'),
      (_) => '',
    );
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
          'allow_bypass':
              payload['allowBypass'] ?? payload['allow_bypass'] ?? '',
          'builder_allow_bypass':
              payload['builderAllowBypass'] ??
              payload['builder_allow_bypass'] ??
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
        _hasActiveConnection &&
        status.value.phase == CoreRunPhase.needsVpnPermission) {
      unawaited(
        _enqueue(() async {
          await _ensureActiveConnection(forceReinstall: false);
        }),
      );
      return;
    }
    if (event.type == CoreRuntimeEventTypes.vpnPermissionDenied &&
        _hasActiveConnection) {
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
      if (_isInstanceNotReadyMessage(message)) {
        _logger.warn(
          'core.runtime',
          'Android runtime instance is not ready',
          context: {
            'error': message,
            'instance_name':
                payload['instanceName'] ?? payload['instance_name'] ?? '',
          },
        );
        return;
      }
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
        await _ensureActiveConnection(forceReinstall: false);
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
    if (!_hasActiveConnection) {
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
    if (!_hasActiveConnection) {
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

  bool get _hasActiveConnection =>
      _session != null || _tokenConnectionProfile != null;

  Future<void> _ensureActiveConnection({required bool forceReinstall}) {
    if (_session != null) {
      return _ensureRunning(forceReinstall: forceReinstall);
    }
    return _ensureTokenConnection(forceReinstall: forceReinstall);
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
