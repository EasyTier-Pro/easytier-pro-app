part of 'core_lifecycle_service.dart';

class DesktopCoreRuntime extends CorePlatformRuntime {
  DesktopCoreRuntime(this._owner);

  final CoreLifecycleService _owner;

  @override
  bool get supportsElevationRepair =>
      CoreLifecycleService.supportsDesktopElevationRepairForPlatform(
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
      );

  @override
  Future<CoreRuntimeStartResult?> readStatus(
    CoreBootstrapConfig bootstrap,
  ) async {
    final desktopStatus = await _owner._tryReadDesktopStatus(bootstrap);
    final machineId = desktopStatus?.machineId;
    if (desktopStatus?.ready == true &&
        machineId != null &&
        machineId.isNotEmpty) {
      return CoreRuntimeStartResult(
        phase: CoreRunPhase.running,
        message: '本机设备已就绪',
        machineId: machineId,
        details: 'EasyTier ${desktopStatus?.version ?? bootstrap.version}',
      );
    }
    return null;
  }

  @override
  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  }) async {
    if (forceReinstall) {
      try {
        await _owner._desktopCommand('uninstall', const {'purge': false});
      } catch (error) {
        if (error is _ElevationRequiredException) {
          rethrow;
        }
        _owner._logger.warn(
          'core',
          'Forced reinstall pre-uninstall failed, continuing install',
          context: {'error': error.toString()},
        );
      }
    }

    final installEvent = await _owner._desktopCommand('install', {
      'bootstrap_token': bootstrap.bootstrapToken,
      'version': bootstrap.version,
      'config_server': bootstrap.configServer,
    });
    final machineId = CoreLifecycleService.parseMachineIdFromDesktopEvent(
      installEvent,
    );
    _owner._rememberCliPath(
      CoreLifecycleService.parseCliPathFromDesktopEvent(installEvent),
    );
    _owner._logger.info(
      'core',
      'Desktop install completed',
      context: {
        'force_reinstall': forceReinstall,
        'machine_id': machineId ?? '',
        'event': installEvent['data']?.toString() ?? '',
      },
    );

    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: machineId == null || machineId.isEmpty ? '连接引擎运行中' : '本机设备已就绪',
      machineId: machineId,
      details: 'EasyTier ${bootstrap.version}',
    );
  }

  @override
  Future<void> stop() async {
    await _owner._desktopCommand('uninstall', const {'purge': false});
    _owner._cliPath = null;
  }

  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    final cliExecutable = _owner._resolveCliExecutable();
    _owner._logger.debug(
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
      _owner._logger.warn(
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

    final totals = CoreLifecycleService.parseNetworkTrafficTotalsFromJson(
      stdoutText,
    );
    _owner._logger.debug(
      'core.stats',
      'EasyTier traffic stats parsed',
      context: {'network_names': totals.keys.join(','), 'count': totals.length},
    );
    return totals;
  }

  @override
  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    final instanceName = runtimeNetworkName.trim();
    if (instanceName.isEmpty) {
      return false;
    }

    final cliExecutable = _owner._resolveCliExecutable();
    _owner._logger.debug(
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
      _owner._logger.debug(
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
    if (CoreLifecycleService._isInstanceNotReadyMessage(message)) {
      _owner._logger.warn(
        'core.instance',
        'EasyTier network instance is not ready',
        context: {'instance_name': instanceName, 'error': message},
      );
      return false;
    }

    _owner._logger.warn(
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

  @override
  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async {
    final instanceName = runtimeNetworkName.trim();
    if (instanceName.isEmpty) {
      return const <String, CorePeerStatus>{};
    }

    final cliExecutable = _owner._resolveCliExecutable();
    _owner._logger.debug(
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
      _owner._logger.warn(
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

    return CoreLifecycleService.parseNetworkPeerStatusesFromJson(stdoutText);
  }
}
