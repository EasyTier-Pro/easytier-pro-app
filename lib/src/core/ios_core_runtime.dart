part of 'core_lifecycle_service.dart';

class IosCoreRuntime extends CorePlatformRuntime {
  IosCoreRuntime({MethodChannel? methodChannel, EventChannel? eventChannel})
    : _methodChannel =
          methodChannel ??
          const MethodChannel('net.easytier.pro/core_runtime') {
    _nativeEvents =
        (eventChannel ??
                const EventChannel('net.easytier.pro/core_runtime_events'))
            .receiveBroadcastStream()
            .listen(
              (value) {
                final event = CoreJsonValue.readMap(value);
                if (event != null) {
                  _events.add(
                    CoreRuntimeEvent(
                      type: event['type']?.toString() ?? '',
                      data: {...event, 'platform': 'iOS'},
                    ),
                  );
                }
              },
              onError: (Object error) => _events.add(
                CoreRuntimeEvent(
                  type: CoreRuntimeEventTypes.error,
                  data: {'error': error.toString(), 'platform': 'iOS'},
                ),
              ),
            );
  }

  final MethodChannel _methodChannel;
  final _events = StreamController<CoreRuntimeEvent>.broadcast();
  late final StreamSubscription<dynamic> _nativeEvents;

  @override
  Stream<CoreRuntimeEvent> get events => _events.stream;

  @override
  Future<CoreRuntimeStartResult?> readStatus(
    CoreBootstrapConfig bootstrap,
  ) async {
    final status = await _methodChannel.invokeMapMethod<String, Object?>(
      'readStatus',
      {
        'url': _configServerUrl(bootstrap),
        'token': bootstrap.bootstrapToken.trim(),
      },
    );
    return status?['running'] == true ? _startResult(status!) : null;
  }

  @override
  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  }) async {
    final machineId = await _methodChannel.invokeMethod<String>('getMachineId');
    final hostname = await _methodChannel.invokeMethod<String>('getHostname');
    if (machineId == null || machineId.isEmpty) {
      throw StateError('iOS machineId 为空');
    }
    try {
      final status = await _methodChannel
          .invokeMapMethod<String, Object?>('ensureRunning', {
            'url': _configServerUrl(bootstrap),
            'token': bootstrap.bootstrapToken.trim(),
            'hostname': hostname ?? 'iPhone',
            'forceReinstall': forceReinstall,
          });
      if (status?['running'] != true) {
        throw StateError('iOS VPN 扩展未运行');
      }
      return _startResult(status!);
    } on PlatformException catch (error) {
      if (error.code != 'VPN_PERMISSION_DENIED') rethrow;
      return CoreRuntimeStartResult(
        phase: CoreRunPhase.needsVpnPermission,
        message: '需要授权 VPN 连接',
        machineId: machineId,
        lastError: error.message,
      );
    }
  }

  String _configServerUrl(CoreBootstrapConfig bootstrap) {
    final base = Uri.parse(bootstrap.configServer.trim());
    return base
        .replace(
          pathSegments: [
            ...base.pathSegments.where((segment) => segment.isNotEmpty),
            bootstrap.bootstrapToken.trim(),
          ],
        )
        .toString();
  }

  CoreRuntimeStartResult _startResult(Map<String, Object?> status) {
    final version = status['core_version']?.toString() ?? '';
    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: 'iOS 连接引擎运行中',
      machineId: status['machine_id']?.toString(),
      details: version.isEmpty ? null : 'EasyTier $version',
      coreVersion: version.isEmpty ? null : version,
    );
  }

  @override
  Future<String?> readInstalledVersion() async {
    final status = await _methodChannel.invokeMapMethod<String, Object?>(
      'readStatus',
    );
    return status?['core_version']?.toString();
  }

  @override
  Future<void> stop() => _methodChannel.invokeMethod<void>('stopRuntime');

  @override
  Future<void> beginNetworkConnection() =>
      _methodChannel.invokeMethod<void>('beginNetworkConnection');

  @override
  Future<String?> waitForNetworkConnection(
    String runtimeNetworkName, {
    required Future<String?> Function() readInstanceId,
  }) async {
    final networkName = runtimeNetworkName.trim();
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    Duration remainingTime() {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw StateError('等待网络连接超时。');
      }
      return remaining;
    }

    Map<String, Object?>? after;
    while (true) {
      final remaining = remainingTime();
      final candidate = await _methodChannel
          .invokeMapMethod<String, Object?>('waitForNetworkConnection', {
            'networkName': networkName,
            'timeoutSeconds': remaining.inMilliseconds / 1000,
            'after': ?after,
          });
      if (candidate == null) throw StateError('iOS 未返回网络连接状态。');

      // The join response identifies a console node before its runtime is
      // allocated. Resolve that node only after a native readiness wakeup.
      final lookupTime = remainingTime();
      final instanceId = (await readInstanceId().timeout(lookupTime))?.trim();
      if (instanceId != null && instanceId.isNotEmpty) {
        // The extension may have changed while the console request was in
        // flight. Finish only if its current data path belongs to this node.
        final statusTime = remainingTime();
        final current = await _methodChannel
            .invokeMapMethod<String, Object?>('readStatus')
            .timeout(statusTime);
        if (current?['running'] == true &&
            current?['vpn_ready'] == true &&
            current?['network_name'] == networkName &&
            current?['instance_id'] == instanceId) {
          return current?['virtual_ipv4']?.toString();
        }
      }
      // Reuse the native session/event cursor so a rejected old instance
      // waits for a notification instead of immediately satisfying the wait.
      after = {
        'session_id': candidate['session_id'],
        'event_id': candidate['event_id'],
      };
    }
  }

  @override
  Future<void> endNetworkConnection() =>
      _methodChannel.invokeMethod<void>('endNetworkConnection');

  Future<Map<String, Object?>> _snapshot() async {
    final json = await _methodChannel.invokeMethod<String>(
      'collectNetworkInfos',
    );
    return CoreJsonValue.readMap(json) ?? const {};
  }

  Map<String, Object?>? _instance(
    Map<String, Object?> snapshot,
    String runtimeNetworkName,
  ) {
    if (runtimeNetworkName.trim().isEmpty ||
        snapshot['network_name'] != runtimeNetworkName.trim()) {
      return null;
    }
    final instances = CoreJsonValue.readMap(snapshot['instances']);
    return CoreJsonValue.readMap(instances?[snapshot['instance_name']]);
  }

  @override
  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    final snapshot = await _snapshot();
    return snapshot['vpn_ready'] == true &&
        _instance(snapshot, runtimeNetworkName)?['running'] == true;
  }

  @override
  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async {
    final snapshot = await _snapshot();
    final instance = _instance(snapshot, runtimeNetworkName);
    if (snapshot['vpn_ready'] != true ||
        instance == null ||
        instance['running'] != true) {
      throw StateError('no instance matches $runtimeNetworkName');
    }
    final peers = parseCorePeerStatusesFromJson(
      jsonEncode(instance['peer_route_pairs'] ?? const []),
    );
    final local = parseCoreLocalPeerStatusFromNodeInfoJson(
      jsonEncode(instance['my_node_info'] ?? const {}),
    );
    if (local != null) peers[local.ipv4] = local;
    return peers;
  }

  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    final snapshot = await _snapshot();
    final name = snapshot['network_name']?.toString() ?? '';
    if (snapshot['vpn_ready'] != true ||
        name.isEmpty ||
        _instance(snapshot, name)?['running'] != true) {
      return const {};
    }
    final json = await _methodChannel.invokeMethod<String>('callJsonRpc', {
      'serviceName': 'api.instance.StatsRpcService',
      'methodName': 'get_stats',
      'payloadJson': jsonEncode({
        'instance': {
          'instance_selector': {'name': snapshot['instance_name']},
        },
      }),
    });
    final stats = CoreJsonValue.readMap(json) ?? const {};
    final totals = _parseNetworkTrafficTotals(
      CoreJsonValue.readList(stats['metrics']),
      defaultRuntimeNetworkName: name,
    );
    return {name: ?totals[name]};
  }

  @override
  Future<void> dispose() async {
    await _nativeEvents.cancel();
    await _events.close();
  }
}
