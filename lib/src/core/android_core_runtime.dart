part of 'core_lifecycle_service.dart';

class AndroidCoreRuntime extends CorePlatformRuntime {
  AndroidCoreRuntime({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    @visibleForTesting Duration? vpnRouteRefreshFastInterval,
    @visibleForTesting Duration? vpnRouteRefreshSteadyInterval,
    @visibleForTesting int? vpnRouteRefreshFastLimit,
  }) : _methodChannel = methodChannel ?? const MethodChannel(_methodName),
       _eventChannel = eventChannel ?? const EventChannel(_eventName),
       _vpnRouteRefreshFastInterval =
           vpnRouteRefreshFastInterval ?? _androidVpnRouteRefreshFastInterval,
       _vpnRouteRefreshSteadyInterval =
           vpnRouteRefreshSteadyInterval ??
           _androidVpnRouteRefreshSteadyInterval,
       _vpnRouteRefreshFastLimit =
           vpnRouteRefreshFastLimit ?? _androidVpnRouteRefreshFastLimit {
    _nativeEvents = _eventChannel.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (Object error) {
        _events.add(
          CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.error,
            data: {'error': error.toString()},
          ),
        );
      },
    );
  }

  static const String _methodName = 'net.easytier.pro/core_runtime';
  static const String _eventName = 'net.easytier.pro/core_runtime_events';
  static const int _instanceListMaxLength = 64;
  static const String _peerManageRpcService =
      'api.instance.PeerManageRpcService';
  static const String _statsRpcService = 'api.instance.StatsRpcService';
  static const Duration _androidTrafficPollInterval = Duration(seconds: 2);
  static const Duration _androidPeerStatusPollInterval = Duration(seconds: 5);
  static const Duration _androidVpnRouteRefreshFastInterval = Duration(
    seconds: 3,
  );
  static const Duration _androidVpnRouteRefreshSteadyInterval = Duration(
    seconds: 5,
  );
  static const int _androidVpnRouteRefreshFastLimit = 20;
  static const Duration _androidVpnStartMissingInstanceRetryDelay = Duration(
    seconds: 1,
  );
  static const int _androidVpnStartMissingInstanceRetryLimit = 3;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Duration _vpnRouteRefreshFastInterval;
  final Duration _vpnRouteRefreshSteadyInterval;
  final int _vpnRouteRefreshFastLimit;
  final StreamController<CoreRuntimeEvent> _events =
      StreamController<CoreRuntimeEvent>.broadcast();

  late final StreamSubscription<dynamic> _nativeEvents;
  Timer? _activeVpnRefreshTimer;
  Future<void> _vpnSerial = Future<void>.value();
  final Map<String, Map<String, Object?>> _pendingVpnPayloads =
      <String, Map<String, Object?>>{};
  final Map<String, String> _instanceIdsByRuntimeName = <String, String>{};
  final Map<String, String> _instanceNamesByRuntimeName = <String, String>{};
  String? _activeVpnInstanceName;
  String? _activeVpnInstanceId;
  String? _activeVpnConfigSignature;
  String? _pendingVpnStartInstanceName;
  Map<String, Object?>? _activeVpnFallbackConfig;
  int _activeVpnRefreshCount = 0;
  bool _vpnPrepared = false;
  bool _disposed = false;

  @override
  Stream<CoreRuntimeEvent> get events => _events.stream;

  @override
  Duration get networkTrafficPollInterval => _androidTrafficPollInterval;

  @override
  Duration get peerStatusPollInterval => _androidPeerStatusPollInterval;

  @override
  Future<CoreRuntimeStartResult?> readStatus(
    CoreBootstrapConfig bootstrap,
  ) async {
    if (!_vpnPrepared) {
      return null;
    }
    try {
      final machineId = await _getMachineId();
      final connected =
          await _methodChannel.invokeMethod<bool>(
            'isConfigServerClientConnected',
          ) ??
          false;
      if (!connected) {
        return null;
      }
      return CoreRuntimeStartResult(
        phase: CoreRunPhase.running,
        message: 'Android 连接引擎运行中',
        machineId: machineId,
        details: 'EasyTier ${bootstrap.version}',
      );
    } on PlatformException catch (error) {
      if (error.code == 'JNI_UNAVAILABLE') {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  }) async {
    if (forceReinstall) {
      await stop();
    }

    final machineId = await _getMachineId();
    final hostname = await _getHostname();
    final fullUrl = buildConfigServerClientUrl(
      bootstrap.configServer,
      bootstrap.bootstrapToken,
    );

    await _prepareNotifications();

    await _methodChannel.invokeMethod<void>('startConfigServerClient', {
      'url': fullUrl,
      'hostname': hostname,
      'machineId': machineId,
      'secureMode': true,
    });

    final vpnPrepared = await _prepareVpn();
    _vpnPrepared = vpnPrepared;
    if (!vpnPrepared) {
      return CoreRuntimeStartResult(
        phase: CoreRunPhase.needsVpnPermission,
        message: '需要授权 VPN 连接',
        machineId: machineId,
        details: 'EasyTier ${bootstrap.version}',
        lastError: 'Android 需要用户授权后才能建立虚拟网卡',
      );
    }
    unawaited(_startPendingVpns());

    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: 'Android 连接引擎运行中',
      machineId: machineId,
      details: 'EasyTier ${bootstrap.version}',
    );
  }

  @override
  Future<void> stop() async {
    _vpnPrepared = false;
    _cancelActiveVpnRefresh();
    _pendingVpnPayloads.clear();
    _instanceIdsByRuntimeName.clear();
    _instanceNamesByRuntimeName.clear();
    _activeVpnInstanceName = null;
    _activeVpnInstanceId = null;
    _activeVpnConfigSignature = null;
    _pendingVpnStartInstanceName = null;
    _activeVpnFallbackConfig = null;
    await _methodChannel.invokeMethod<void>('stopRuntime');
  }

  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    final sampledAt = DateTime.now();
    final totals = <String, CoreNetworkTrafficTotals>{};

    final instances = await _listInstances();
    for (final instanceName in instances.keys) {
      final Map<String, Object?> response;
      try {
        response = await _callJsonRpcMap(
          _statsRpcService,
          'get_stats',
          payload: _jsonRpcInstancePayload(instanceName),
        );
      } on Object catch (error) {
        if (_isAndroidInstanceNotFoundError(error)) {
          _forgetInstanceAliases(
            instanceId: instances[instanceName] ?? '',
            instanceName: instanceName,
            runtimeNetworkName: '',
          );
          continue;
        }
        rethrow;
      }
      final runtimeNetworkName = _runtimeNameForInstanceName(
        instanceName,
        instances[instanceName],
      );
      final parsed = _trafficTotalsFromJsonRpcStats(
        response,
        defaultRuntimeNetworkName: runtimeNetworkName,
        sampledAt: sampledAt,
      );
      for (final entry in parsed.entries) {
        totals[entry.key] = entry.value;
      }
    }

    if (totals.isNotEmpty) {
      return totals;
    }

    final snapshot = await _readNetworkInfoSnapshot();
    for (final instance in snapshot.instances.values) {
      if (!instance.running) {
        continue;
      }
      final traffic = _trafficTotalsFromPeers(instance.peers);
      if (traffic == null) {
        continue;
      }
      final runtimeNetworkName = _runtimeNameForInstance(instance);
      totals[runtimeNetworkName] = CoreNetworkTrafficTotals(
        runtimeNetworkName: runtimeNetworkName,
        downloadBytes: traffic.downloadBytes,
        uploadBytes: traffic.uploadBytes,
        sampledAt: sampledAt,
      );
    }
    return totals;
  }

  @override
  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    final instanceName = runtimeNetworkName.trim();
    if (instanceName.isEmpty) {
      return false;
    }
    final snapshot = await _readNetworkInfoSnapshot();
    return _instanceMatchingRuntimeName(snapshot, instanceName)?.running ??
        false;
  }

  @override
  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  ) async {
    final instanceName = runtimeNetworkName.trim();
    if (instanceName.isEmpty) {
      return const <String, CorePeerStatus>{};
    }

    final snapshot = await _readNetworkInfoSnapshot();
    final instance = _instanceMatchingRuntimeName(snapshot, instanceName);
    if (instance == null || !instance.running) {
      throw StateError('no instance matches $instanceName');
    }

    final statuses = <String, CorePeerStatus>{};
    for (final peer in instance.peers) {
      final status = CorePeerStatus.fromJson(_normalizeAndroidPeer(peer));
      if (status.ipv4.isNotEmpty) {
        statuses[status.ipv4] = status;
      }
    }
    return statuses;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _cancelActiveVpnRefresh();
    _pendingVpnStartInstanceName = null;
    try {
      await _vpnSerial;
    } catch (_) {
      // Errors from the serial queue are surfaced through runtime events while
      // the runtime is alive. During disposal there may be no listener left.
    }
    await _nativeEvents.cancel();
    await _events.close();
  }

  Future<String> _getMachineId() async {
    final value = await _methodChannel.invokeMethod<String>('getMachineId');
    final machineId = value?.trim() ?? '';
    if (machineId.isEmpty) {
      throw StateError('Android machineId 为空');
    }
    return machineId;
  }

  Future<String> _getHostname() async {
    final value = await _methodChannel.invokeMethod<String>('getHostname');
    final hostname = value?.trim();
    if (hostname != null && hostname.isNotEmpty) {
      return hostname;
    }
    return Platform.localHostname.trim().isEmpty
        ? 'android-device'
        : Platform.localHostname.trim();
  }

  Future<void> _prepareNotifications() async {
    try {
      await _methodChannel.invokeMethod<bool>('prepareNotifications');
    } on PlatformException catch (error) {
      if (error.code != 'NOTIFICATION_PERMISSION_PENDING') {
        rethrow;
      }
    } on MissingPluginException {
      return;
    }
  }

  Future<bool> _prepareVpn() async {
    try {
      return await _methodChannel.invokeMethod<bool>('prepareVpn') ?? false;
    } on PlatformException catch (error) {
      if (error.code == 'VPN_PERMISSION_PENDING') {
        return false;
      }
      rethrow;
    }
  }

  Future<AndroidNetworkInfoSnapshot> _readNetworkInfoSnapshot() async {
    final listedInstances = await _listInstances();
    final instances = <String, AndroidNetworkInstanceInfo>{};
    for (final instanceName in listedInstances.keys) {
      final instance = await _readJsonRpcNetworkInstance(
        instanceName,
        instanceId: listedInstances[instanceName],
      );
      instances[instance.name] = instance;
    }
    return AndroidNetworkInfoSnapshot(Map.unmodifiable(instances));
  }

  Future<void> _ignoreMissingJni(Future<void> future) async {
    try {
      await future;
    } on PlatformException catch (error) {
      if (error.code != 'JNI_UNAVAILABLE') {
        rethrow;
      }
    }
  }

  Future<Map<String, String>> _listInstances() async {
    final value = await _methodChannel.invokeMethod<String>('listInstances', {
      'maxLength': _instanceListMaxLength,
    });
    final decoded = _readMap(value);
    if (decoded == null) {
      return const <String, String>{};
    }
    final instances = <String, String>{};
    for (final entry in decoded.entries) {
      final name = entry.key.trim();
      final id = _readString(entry.value);
      if (name.isNotEmpty) {
        instances[name] = id;
      }
    }
    return Map.unmodifiable(instances);
  }

  Future<Map<String, Object?>> _callJsonRpcMap(
    String serviceName,
    String methodName, {
    Map<String, Object?> payload = const <String, Object?>{},
    String domainName = '',
  }) async {
    final value = await _methodChannel.invokeMethod<String>('callJsonRpc', {
      'serviceName': serviceName,
      'methodName': methodName,
      'domainName': domainName,
      'payloadJson': jsonEncode(payload),
    });
    return _readMap(value) ?? const <String, Object?>{};
  }

  static Map<String, Object?> _jsonRpcInstancePayload(String instanceName) {
    return <String, Object?>{
      'instance': <String, Object?>{
        'instance_selector': <String, Object?>{'name': instanceName},
      },
    };
  }

  void _handleNativeEvent(Object? event) {
    if (_disposed) {
      return;
    }
    final runtimeEvent = _runtimeEventFromNative(event);
    _events.add(runtimeEvent);
    if (runtimeEvent.type == CoreRuntimeEventTypes.vpnPermissionGranted) {
      _vpnPrepared = true;
      unawaited(_startPendingVpns());
    }
    if (runtimeEvent.type == CoreRuntimeEventTypes.vpnPermissionDenied) {
      _vpnPrepared = false;
    }
    if (runtimeEvent.type == CoreRuntimeEventTypes.vpnStarted) {
      final payload = _runtimeEventPayload(runtimeEvent);
      final instanceName = _readString(
        payload['instanceName'] ?? payload['instance_name'],
      );
      if (instanceName.isNotEmpty) {
        _activeVpnInstanceName = instanceName;
        if (_pendingVpnStartInstanceName == instanceName) {
          _pendingVpnStartInstanceName = null;
        }
        _scheduleActiveVpnRefresh();
      }
    }
    if (runtimeEvent.type == CoreRuntimeEventTypes.vpnStopped) {
      final payload = _runtimeEventPayload(runtimeEvent);
      final instanceName = _readString(
        payload['instanceName'] ?? payload['instance_name'],
      );
      final reason = _readString(payload['reason']);
      final isReplacingActiveVpn =
          reason.isEmpty &&
          instanceName.isNotEmpty &&
          instanceName == _pendingVpnStartInstanceName;
      if (isReplacingActiveVpn) {
        return;
      }
      if (instanceName.isEmpty || instanceName == _activeVpnInstanceName) {
        _activeVpnInstanceName = null;
        _activeVpnInstanceId = null;
        _activeVpnConfigSignature = null;
        _pendingVpnStartInstanceName = null;
        _activeVpnFallbackConfig = null;
        _cancelActiveVpnRefresh();
      }
    }
    if (runtimeEvent.type == CoreRuntimeEventTypes.configServer) {
      _handleConfigServerEvent(runtimeEvent.data);
    }
  }

  CoreRuntimeEvent _runtimeEventFromNative(Object? event) {
    if (event is Map) {
      final data = _stringObjectMap(event);
      final type = _readString(data['type'] ?? data['event']);
      return CoreRuntimeEvent(type: type.isEmpty ? 'native' : type, data: data);
    }
    return CoreRuntimeEvent(
      type: 'native',
      data: {'value': event?.toString() ?? ''},
    );
  }

  void _handleConfigServerEvent(Map<String, Object?> data) {
    final payloadMap = _configServerPayloadFromEvent(data);
    final eventName = _readString(
      payloadMap['event'] ?? payloadMap['type'] ?? payloadMap['action'],
    );
    if (eventName != 'run_network_instance' &&
        eventName != 'delete_network_instance') {
      return;
    }

    final callbackError = _firstNonEmptyString([
      payloadMap['error'],
      payloadMap['error_msg'],
      payloadMap['errorMessage'],
      payloadMap['message'],
    ]);
    final success = _readBool(payloadMap['success']);
    if (callbackError != null || success == false) {
      _events.add(
        CoreRuntimeEvent(
          type: CoreRuntimeEventTypes.error,
          data: {
            'error': callbackError ?? 'Android config server event failed',
            'event': eventName,
            'instance_id': _readString(
              payloadMap['instance_id'] ??
                  payloadMap['instanceId'] ??
                  payloadMap['id'],
            ),
          },
        ),
      );
      return;
    }

    final instanceName = _instanceNameFromPayload(payloadMap);
    final instanceId = _readString(
      payloadMap['instance_id'] ?? payloadMap['instanceId'] ?? payloadMap['id'],
    );
    final runtimeNetworkName = _runtimeNetworkNameFromPayload(payloadMap);
    final instanceKey = _instanceKeyFromPayloadParts(
      instanceName: instanceName,
      instanceId: instanceId,
      runtimeNetworkName: runtimeNetworkName,
    );
    if (instanceKey.isEmpty) {
      return;
    }

    if (eventName == 'delete_network_instance') {
      _forgetInstanceAliases(
        instanceId: instanceId,
        instanceName: instanceName,
        runtimeNetworkName: runtimeNetworkName,
      );
      _pendingVpnPayloads.remove(instanceKey);
      unawaited(_queueVpnStop(instanceKey));
      return;
    }

    _rememberInstanceAliases(
      instanceId: instanceId,
      instanceName: instanceName,
      runtimeNetworkName: runtimeNetworkName,
    );
    _pendingVpnPayloads
      ..clear()
      ..[instanceKey] = payloadMap;
    unawaited(_queueVpnStart(instanceKey));
  }

  Map<String, Object?> _configServerPayloadFromEvent(
    Map<String, Object?> data,
  ) {
    final outer = data['payload'];
    final outerMap = outer is Map ? _stringObjectMap(outer) : data;
    final inner = outerMap['payload'];
    return inner is Map ? _stringObjectMap(inner) : outerMap;
  }

  Map<String, Object?> _runtimeEventPayload(CoreRuntimeEvent event) {
    final payload = event.data['payload'];
    return payload is Map ? _stringObjectMap(payload) : event.data;
  }

  Future<void> _queueVpnStart(String instanceKey) {
    _vpnSerial = _vpnSerial
        .then(
          (_) => _startVpnForInstance(instanceKey),
          onError: (Object error, StackTrace stackTrace) =>
              _startVpnForInstance(instanceKey),
        )
        .catchError(_emitVpnError);
    return _vpnSerial;
  }

  Future<void> _queueVpnStop(String instanceKey) {
    _vpnSerial = _vpnSerial
        .then(
          (_) => _stopActiveVpn(instanceKey),
          onError: (Object error, StackTrace stackTrace) =>
              _stopActiveVpn(instanceKey),
        )
        .catchError(_emitVpnError);
    return _vpnSerial;
  }

  Future<void> _startPendingVpns() async {
    if (_pendingVpnPayloads.isEmpty) {
      return;
    }
    final latestInstanceName = _pendingVpnPayloads.keys.last;
    await _queueVpnStart(latestInstanceName);
  }

  Future<void> _startVpnForInstance(String instanceKey) async {
    final payloadMap = _pendingVpnPayloads[instanceKey];
    if (payloadMap == null) {
      return;
    }
    if (!_vpnPrepared) {
      return;
    }

    final target = await _resolveVpnTargetWithMissingInstanceRetry(
      instanceKey,
      payloadMap,
    );
    if (target == null) {
      return;
    }
    if (!_vpnConfigHasAddress(target.vpnConfig)) {
      _events.add(
        CoreRuntimeEvent(
          type: CoreRuntimeEventTypes.error,
          data: {
            'error': 'Android VPN 缺少虚拟 IP 配置',
            'instance_key': instanceKey,
            'instance_name': target.instanceName,
            'instance_id': target.instanceId,
            'known_instances': target.knownInstanceNames,
          },
        ),
      );
      return;
    }
    _emitVpnRouteDiagnostic(
      phase: 'start_request',
      instanceKey: instanceKey,
      instanceName: target.instanceName,
      instanceId: target.instanceId,
      source: target.source,
      config: target.vpnConfig,
      decision: 'start_vpn',
    );

    final active = _activeVpnInstanceName;
    if (active != null && active != target.instanceName) {
      _activeVpnInstanceName = null;
      _activeVpnInstanceId = null;
      _activeVpnConfigSignature = null;
      _activeVpnFallbackConfig = null;
      _cancelActiveVpnRefresh();
      await _methodChannel.invokeMethod<void>('stopVpn');
    }
    await _ignoreMissingJni(
      _methodChannel.invokeMethod<void>('retainNetworkInstance', {
        'instanceNames': <String>[target.instanceName],
      }),
    );
    _pendingVpnStartInstanceName = target.instanceName;
    try {
      await _methodChannel.invokeMethod<void>('startVpn', {
        'instanceName': target.instanceName,
        'vpnConfig': target.vpnConfig,
      });
    } on Object {
      if (_pendingVpnStartInstanceName == target.instanceName) {
        _pendingVpnStartInstanceName = null;
      }
      rethrow;
    }
    _activeVpnInstanceName = target.instanceName;
    _activeVpnInstanceId = target.instanceId;
    _activeVpnConfigSignature = _vpnConfigSignature(target.vpnConfig);
    _activeVpnFallbackConfig = target.vpnConfig;
    _activeVpnRefreshCount = 0;
    _scheduleActiveVpnRefresh();
    _pendingVpnPayloads.remove(instanceKey);
  }

  Future<_ResolvedAndroidVpnTarget?> _resolveVpnTargetWithMissingInstanceRetry(
    String instanceKey,
    Map<String, Object?> payloadMap,
  ) async {
    for (
      var attempt = 0;
      attempt < _androidVpnStartMissingInstanceRetryLimit;
      attempt++
    ) {
      try {
        return await _resolveVpnTarget(instanceKey, payloadMap);
      } on Object catch (error) {
        if (!_isAndroidInstanceNotFoundError(error)) {
          rethrow;
        }
        if (_disposed ||
            !_vpnPrepared ||
            !_pendingVpnPayloads.containsKey(instanceKey)) {
          return null;
        }
        final shouldRetry =
            attempt < _androidVpnStartMissingInstanceRetryLimit - 1;
        if (!shouldRetry) {
          return null;
        }
        await Future<void>.delayed(_androidVpnStartMissingInstanceRetryDelay);
      }
    }
    return null;
  }

  Future<void> _queueActiveVpnRefresh() {
    if (_disposed) {
      return Future<void>.value();
    }
    _vpnSerial = _vpnSerial
        .then(
          (_) => _refreshActiveVpnConfig(),
          onError: (Object error, StackTrace stackTrace) =>
              _refreshActiveVpnConfig(),
        )
        .catchError(_emitVpnError);
    return _vpnSerial;
  }

  Future<void> _refreshActiveVpnConfig() async {
    if (_disposed) {
      return;
    }
    final activeName = _activeVpnInstanceName;
    if (activeName == null || activeName.isEmpty || !_vpnPrepared) {
      return;
    }

    _activeVpnRefreshCount += 1;
    try {
      final configRead = await _readJsonRpcVpnConfig(
        activeName,
        fallbackConfig: _activeVpnFallbackConfig,
      );
      final config = configRead.config;
      if (!_vpnConfigHasAddress(config)) {
        _emitVpnRouteDiagnostic(
          phase: 'refresh',
          instanceName: activeName,
          source: 'json_rpc',
          readResult: configRead,
          decision: 'skip_missing_address',
          refreshCount: _activeVpnRefreshCount,
        );
        return;
      }

      final signature = _vpnConfigSignature(config);
      final changed = signature != _activeVpnConfigSignature;
      if (changed || _activeVpnRefreshCount <= _vpnRouteRefreshFastLimit) {
        _emitVpnRouteDiagnostic(
          phase: 'refresh',
          instanceName: activeName,
          source: 'json_rpc',
          readResult: configRead,
          decision: changed ? 'restart_vpn' : 'skip_same_signature',
          refreshCount: _activeVpnRefreshCount,
          configChanged: changed,
        );
      }
      if (!changed) {
        return;
      }

      await _methodChannel.invokeMethod<void>('startVpn', {
        'instanceName': activeName,
        'vpnConfig': config,
      });
      _activeVpnInstanceName = activeName;
      _activeVpnConfigSignature = signature;
      _activeVpnFallbackConfig = config;
      if (!_disposed) {
        _events.add(
          CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.vpnConfigRefreshed,
            data: {
              'instance_name': activeName,
              'addresses': config['addresses'],
              'routes': config['routes'],
              'dns': config['dns'],
              'disallowedApplications': config['disallowedApplications'],
            },
          ),
        );
      }
    } on Object catch (error) {
      if (_isAndroidInstanceNotFoundError(error)) {
        if (_activeVpnInstanceName == activeName) {
          _activeVpnInstanceName = null;
          _activeVpnInstanceId = null;
          _activeVpnConfigSignature = null;
          _activeVpnFallbackConfig = null;
          _cancelActiveVpnRefresh();
          await _methodChannel.invokeMethod<void>('stopVpn');
        }
        return;
      }
      rethrow;
    } finally {
      if (!_disposed && _activeVpnInstanceName != null) {
        _scheduleActiveVpnRefresh();
      }
    }
  }

  void _scheduleActiveVpnRefresh() {
    _activeVpnRefreshTimer?.cancel();
    if (_disposed || _activeVpnInstanceName == null) {
      return;
    }
    final delay = _activeVpnRefreshCount < _vpnRouteRefreshFastLimit
        ? _vpnRouteRefreshFastInterval
        : _vpnRouteRefreshSteadyInterval;
    _activeVpnRefreshTimer = Timer(delay, () {
      _activeVpnRefreshTimer = null;
      unawaited(_queueActiveVpnRefresh());
    });
  }

  void _cancelActiveVpnRefresh() {
    _activeVpnRefreshTimer?.cancel();
    _activeVpnRefreshTimer = null;
    _activeVpnRefreshCount = 0;
  }

  Future<_ResolvedAndroidVpnTarget> _resolveVpnTarget(
    String instanceKey,
    Map<String, Object?> payloadMap,
  ) async {
    var instanceName = _instanceNameFromPayload(payloadMap);
    final instanceId = _instanceIdFromPayload(payloadMap);
    final directConfig = buildVpnConfigFromNetworkInfo(payloadMap);
    final hasDirectConfig =
        payloadMap.containsKey('vpn_config') ||
        payloadMap.containsKey('vpnConfig');
    var knownInstanceNames = const <String>[];
    var resolvedInstanceId = instanceId.isEmpty ? null : instanceId;

    if (instanceName.isEmpty) {
      final listedInstances = await _listInstances();
      knownInstanceNames = listedInstances.keys.take(8).toList(growable: false);
      for (final entry in listedInstances.entries) {
        if (instanceId.isNotEmpty && entry.value == instanceId) {
          instanceName = entry.key;
          resolvedInstanceId = entry.value;
          break;
        }
      }
      if (instanceName.isEmpty && listedInstances.length == 1) {
        instanceName = listedInstances.keys.single;
        resolvedInstanceId = listedInstances.values.single.isEmpty
            ? resolvedInstanceId
            : listedInstances.values.single;
      }
    }

    if (hasDirectConfig &&
        _vpnConfigHasAddress(directConfig) &&
        instanceName.isNotEmpty) {
      return _ResolvedAndroidVpnTarget(
        instanceName: instanceName,
        instanceId: resolvedInstanceId,
        vpnConfig: directConfig,
        source: 'direct_config',
        knownInstanceNames: knownInstanceNames,
      );
    }

    if (instanceName.isNotEmpty) {
      final rpcConfigRead = await _readJsonRpcVpnConfig(
        instanceName,
        fallbackConfig: hasDirectConfig ? directConfig : null,
      );
      final rpcConfig = rpcConfigRead.config;
      _emitVpnRouteDiagnostic(
        phase: 'start_json_rpc_read',
        instanceKey: instanceKey,
        instanceName: instanceName,
        source: 'json_rpc',
        readResult: rpcConfigRead,
      );
      if (_vpnConfigHasAddress(rpcConfig)) {
        return _ResolvedAndroidVpnTarget(
          instanceName: instanceName,
          instanceId: resolvedInstanceId,
          vpnConfig: rpcConfig,
          source: 'json_rpc',
          knownInstanceNames: knownInstanceNames,
        );
      }
    }

    if (_vpnConfigHasAddress(directConfig) && instanceName.isNotEmpty) {
      return _ResolvedAndroidVpnTarget(
        instanceName: instanceName,
        instanceId: resolvedInstanceId,
        vpnConfig: directConfig,
        source: 'direct_fallback',
        knownInstanceNames: knownInstanceNames,
      );
    }

    AndroidNetworkInstanceInfo? lastMatchedInstance;
    final snapshot = await _readNetworkInfoSnapshot();
    knownInstanceNames = snapshot.instances.keys
        .take(8)
        .toList(growable: false);
    final instance = snapshot.instanceMatching(
      name: instanceName.isEmpty ? instanceKey : instanceName,
      id: instanceId,
    );
    if (instance != null) {
      lastMatchedInstance = instance;
    }
    final config = instance?.vpnConfig;
    if (config != null && _vpnConfigHasAddress(config)) {
      final matchedInstance = instance!;
      final targetInstanceName = instanceName.isEmpty
          ? matchedInstance.name
          : instanceName;
      return _ResolvedAndroidVpnTarget(
        instanceName: targetInstanceName,
        instanceId: matchedInstance.id ?? instanceId,
        vpnConfig: config,
        source: 'snapshot',
        knownInstanceNames: knownInstanceNames,
      );
    }

    return _ResolvedAndroidVpnTarget(
      instanceName:
          (instanceName.isEmpty ? lastMatchedInstance?.name : instanceName) ??
          (instanceName.isEmpty ? instanceKey : instanceName),
      instanceId:
          lastMatchedInstance?.id ?? (instanceId.isEmpty ? null : instanceId),
      vpnConfig: _vpnConfigHasAddress(directConfig)
          ? directConfig
          : lastMatchedInstance?.vpnConfig ?? const <String, Object?>{},
      source: _vpnConfigHasAddress(directConfig)
          ? 'direct_empty'
          : 'snapshot_empty',
      knownInstanceNames: knownInstanceNames,
    );
  }

  Future<_AndroidVpnConfigReadResult> _readJsonRpcVpnConfig(
    String instanceName, {
    Map<String, Object?>? fallbackConfig,
  }) async {
    final payload = _jsonRpcInstancePayload(instanceName);
    final nodeInfoResponse = await _callJsonRpcMap(
      _peerManageRpcService,
      'show_node_info',
      payload: payload,
    );
    final routeResponse = await _callJsonRpcMap(
      _peerManageRpcService,
      'list_route',
      payload: payload,
    );

    final nodeInfo = _jsonRpcNodeInfo(nodeInfoResponse);
    final routes = _jsonRpcRoutes(routeResponse);
    final config = buildVpnConfigFromNetworkInfo(<String, Object?>{
      'my_node_info': nodeInfo,
      'routes': routes,
    });
    final mergedConfig = fallbackConfig == null
        ? config
        : _mergeVpnConfig(config, fallbackConfig);
    return _AndroidVpnConfigReadResult(
      config: mergedConfig,
      routeResponseKeys: routeResponse.keys.toList(growable: false),
      routePayloadType: _valueTypeName(routes),
      routePayloadCount: _routePayloadCount(routes),
      routeCidrs: _readRouteCidrs(routes),
      routeProxyCidrs: _readProxyRouteCidrs(routes),
    );
  }

  Future<AndroidNetworkInstanceInfo> _readJsonRpcNetworkInstance(
    String instanceName, {
    String? instanceId,
  }) async {
    final id = instanceId?.trim() ?? '';
    try {
      final payload = _jsonRpcInstancePayload(instanceName);
      final nodeInfoResponse = await _callJsonRpcMap(
        _peerManageRpcService,
        'show_node_info',
        payload: payload,
      );
      final routeResponse = await _callJsonRpcMap(
        _peerManageRpcService,
        'list_route',
        payload: payload,
      );
      final peerResponse = await _callJsonRpcMap(
        _peerManageRpcService,
        'list_peer',
        payload: payload,
      );
      final nodeInfo = _jsonRpcNodeInfo(nodeInfoResponse);
      final peerNodeInfo = _readMap(
        peerResponse['my_info'] ?? peerResponse['myInfo'],
      );
      final json = <String, Object?>{
        'instance_name': instanceName,
        if (id.isNotEmpty) 'instance_id': id,
        'running': true,
        'my_node_info': nodeInfo.isNotEmpty ? nodeInfo : peerNodeInfo,
        'routes': _jsonRpcRoutes(routeResponse),
        'peer_infos':
            peerResponse['peer_infos'] ??
            peerResponse['peerInfos'] ??
            peerResponse['peers'] ??
            const <Object?>[],
      };
      return AndroidNetworkInstanceInfo.fromJson(
        json,
        name: instanceName,
        idHint: id,
      );
    } on Object catch (error) {
      return AndroidNetworkInstanceInfo.fromJson(
        <String, Object?>{
          'instance_name': instanceName,
          if (id.isNotEmpty) 'instance_id': id,
          'running': false,
          'error': error.toString(),
        },
        name: instanceName,
        idHint: id,
      );
    }
  }

  static Map<String, Object?> _jsonRpcNodeInfo(Map<String, Object?> response) {
    return _readMap(response['node_info'] ?? response['nodeInfo']) ?? response;
  }

  static Object? _jsonRpcRoutes(Map<String, Object?> response) {
    return response['routes'] ??
        response['route'] ??
        response['route_infos'] ??
        response['routeInfos'] ??
        const <Object?>[];
  }

  static String _valueTypeName(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is List) {
      return 'list';
    }
    if (value is Map) {
      return 'map';
    }
    if (value is String) {
      final decoded = _tryDecodeJson(value);
      if (decoded is List) {
        return 'json_list_string';
      }
      if (decoded is Map) {
        return 'json_map_string';
      }
      return 'string';
    }
    return value.runtimeType.toString();
  }

  static int _routePayloadCount(Object? value) {
    final decoded = value is String ? _tryDecodeJson(value) : value;
    if (decoded is List) {
      return decoded.length;
    }
    if (decoded is Map) {
      return decoded.length;
    }
    return _readList(value).length;
  }

  static List<String> _readProxyRouteCidrs(Object? value) {
    final cidrs = <String>{};

    void add(Object? candidate) {
      cidrs.addAll(_readRouteCidrs(candidate));
    }

    void visit(Object? candidate) {
      final decoded = candidate is String
          ? _tryDecodeJson(candidate)
          : candidate;
      if (decoded is List) {
        for (final item in decoded) {
          visit(item);
        }
        return;
      }
      if (decoded is! Map) {
        return;
      }

      final map = _stringObjectMap(decoded);
      for (final key in const <String>[
        'proxy_cidrs',
        'proxyCidrs',
        'proxy_cidr',
        'proxyCidr',
        'proxy_network',
        'proxyNetwork',
        'proxy_networks',
        'proxyNetworks',
        'subnet_cidrs',
        'subnetCidrs',
        'subnet_routes',
        'subnetRoutes',
        'subnets',
        'subnet',
      ]) {
        if (map.containsKey(key)) {
          add(map[key]);
        }
      }

      for (final child in map.values) {
        if (child is Map || child is List || child is String) {
          visit(child);
        }
      }
    }

    visit(value);
    return cidrs.toList(growable: false);
  }

  static Map<String, Object?> _mergeVpnConfig(
    Map<String, Object?> primary,
    Map<String, Object?> fallback,
  ) {
    final merged = Map<String, Object?>.from(primary);

    if (_readStringList(
      merged['dns'] ?? merged['dns_servers'] ?? merged['dnsServers'],
    ).isEmpty) {
      final dns =
          fallback['dns'] ?? fallback['dns_servers'] ?? fallback['dnsServers'];
      if (_readStringList(dns).isNotEmpty) {
        merged['dns'] = dns;
      }
    }

    if (_readStringList(
      merged['disallowedApplications'] ??
          merged['disallowed_applications'] ??
          merged['disallowedPackages'] ??
          merged['disallowed_packages'],
    ).isEmpty) {
      final disallowed =
          fallback['disallowedApplications'] ??
          fallback['disallowed_applications'] ??
          fallback['disallowedPackages'] ??
          fallback['disallowed_packages'];
      if (_readStringList(disallowed).isNotEmpty) {
        merged['disallowedApplications'] = disallowed;
      }
    }

    if (merged['mtu'] == null && fallback['mtu'] != null) {
      merged['mtu'] = fallback['mtu'];
    }
    return merged;
  }

  void _emitVpnRouteDiagnostic({
    required String phase,
    String? instanceKey,
    String? instanceName,
    String? instanceId,
    String? source,
    String? decision,
    int? refreshCount,
    bool? configChanged,
    Map<String, Object?>? config,
    _AndroidVpnConfigReadResult? readResult,
  }) {
    if (_disposed) {
      return;
    }
    final effectiveConfig = config ?? readResult?.config;
    final addresses = effectiveConfig == null
        ? const <String>[]
        : _readCidrList(
            effectiveConfig['addresses'] ?? effectiveConfig['address'],
          );
    final routes = effectiveConfig == null
        ? const <String>[]
        : _readCidrList(effectiveConfig['routes'] ?? effectiveConfig['route']);
    final dns = effectiveConfig == null
        ? const <String>[]
        : _readStringList(
            effectiveConfig['dns'] ??
                effectiveConfig['dns_servers'] ??
                effectiveConfig['dnsServers'],
          );
    final payload = <String, Object?>{
      'phase': phase,
      if (instanceKey?.isNotEmpty ?? false) 'instance_key': instanceKey,
      if (instanceName?.isNotEmpty ?? false) 'instance_name': instanceName,
      if (instanceId?.isNotEmpty ?? false) 'instance_id': instanceId,
      if (source?.isNotEmpty ?? false) 'source': source,
      if (decision?.isNotEmpty ?? false) 'decision': decision,
      'addresses': addresses,
      'address_count': addresses.length,
      'routes': routes,
      'route_count': routes.length,
      'dns': dns,
      'dns_count': dns.length,
    };
    if (refreshCount != null) {
      payload['refresh_count'] = refreshCount;
    }
    if (configChanged != null) {
      payload['config_changed'] = configChanged;
    }
    if (readResult != null) {
      payload.addAll({
        'route_response_keys': readResult.routeResponseKeys,
        'route_payload_type': readResult.routePayloadType,
        'route_payload_count': readResult.routePayloadCount,
        'route_cidrs': readResult.routeCidrs,
        'route_cidr_count': readResult.routeCidrs.length,
        'route_proxy_cidrs': readResult.routeProxyCidrs,
        'route_proxy_cidr_count': readResult.routeProxyCidrs.length,
      });
    }
    _events.add(
      CoreRuntimeEvent(
        type: CoreRuntimeEventTypes.vpnRouteDiagnostic,
        data: payload,
      ),
    );
  }

  Future<void> _stopActiveVpn(String instanceKey) async {
    final matchesActiveName = _activeVpnInstanceName == instanceKey;
    final matchesActiveId = _activeVpnInstanceId == instanceKey;
    if (!matchesActiveName && !matchesActiveId) {
      _pendingVpnPayloads.remove(instanceKey);
      return;
    }
    _activeVpnInstanceName = null;
    _activeVpnInstanceId = null;
    _activeVpnConfigSignature = null;
    _activeVpnFallbackConfig = null;
    _cancelActiveVpnRefresh();
    await _methodChannel.invokeMethod<void>('stopVpn');
    _pendingVpnPayloads.remove(instanceKey);
  }

  String _instanceNameFromPayload(Map<String, Object?> payloadMap) {
    return _readString(
      payloadMap['instance_name'] ?? payloadMap['instanceName'],
    );
  }

  String _instanceIdFromPayload(Map<String, Object?> payloadMap) {
    return _readString(
      payloadMap['instance_id'] ?? payloadMap['instanceId'] ?? payloadMap['id'],
    );
  }

  String _runtimeNetworkNameFromPayload(Map<String, Object?> payloadMap) {
    return _readString(
      payloadMap['network_name'] ??
          payloadMap['networkName'] ??
          payloadMap['runtime_network_name'] ??
          payloadMap['runtimeNetworkName'],
    );
  }

  String _instanceKeyFromPayloadParts({
    required String instanceName,
    required String instanceId,
    required String runtimeNetworkName,
  }) {
    final name = instanceName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    final id = instanceId.trim();
    if (id.isNotEmpty) {
      return id;
    }
    final runtimeName = runtimeNetworkName.trim();
    if (runtimeName.isEmpty) {
      return '';
    }
    return _instanceNamesByRuntimeName[runtimeName] ??
        _instanceIdsByRuntimeName[runtimeName] ??
        '';
  }

  void _rememberInstanceAliases({
    required String instanceId,
    required String instanceName,
    required String runtimeNetworkName,
  }) {
    final runtimeName = runtimeNetworkName.trim();
    if (runtimeName.isEmpty) {
      return;
    }
    if (instanceId.trim().isNotEmpty) {
      _instanceIdsByRuntimeName[runtimeName] = instanceId.trim();
    }
    if (instanceName.trim().isNotEmpty) {
      _instanceNamesByRuntimeName[runtimeName] = instanceName.trim();
    }
  }

  void _forgetInstanceAliases({
    required String instanceId,
    required String instanceName,
    required String runtimeNetworkName,
  }) {
    final runtimeName = runtimeNetworkName.trim();
    if (runtimeName.isNotEmpty) {
      _instanceIdsByRuntimeName.remove(runtimeName);
      _instanceNamesByRuntimeName.remove(runtimeName);
      return;
    }
    final targetId = instanceId.trim();
    final targetName = instanceName.trim();
    if (targetId.isNotEmpty) {
      _instanceIdsByRuntimeName.removeWhere((_, id) => id == targetId);
    }
    if (targetName.isNotEmpty) {
      _instanceNamesByRuntimeName.removeWhere((_, name) => name == targetName);
    }
  }

  AndroidNetworkInstanceInfo? _instanceMatchingRuntimeName(
    AndroidNetworkInfoSnapshot snapshot,
    String runtimeNetworkName,
  ) {
    final runtimeName = runtimeNetworkName.trim();
    if (runtimeName.isEmpty) {
      return null;
    }
    final direct = snapshot.instanceNamed(runtimeName);
    if (direct != null) {
      return direct;
    }
    final instanceName = _instanceNamesByRuntimeName[runtimeName];
    if (instanceName != null && instanceName.isNotEmpty) {
      final byInstanceName = snapshot.instanceNamed(instanceName);
      if (byInstanceName != null) {
        return byInstanceName;
      }
    }
    final instanceId = _instanceIdsByRuntimeName[runtimeName];
    if (instanceId != null && instanceId.isNotEmpty) {
      return snapshot.instanceMatching(name: '', id: instanceId);
    }
    return null;
  }

  String _runtimeNameForInstance(AndroidNetworkInstanceInfo instance) {
    for (final entry in _instanceIdsByRuntimeName.entries) {
      if (entry.value == instance.id) {
        return entry.key;
      }
    }
    for (final entry in _instanceNamesByRuntimeName.entries) {
      if (entry.value == instance.name) {
        return entry.key;
      }
    }
    return instance.name;
  }

  String _runtimeNameForInstanceName(String instanceName, String? instanceId) {
    final id = instanceId?.trim() ?? '';
    if (id.isNotEmpty) {
      for (final entry in _instanceIdsByRuntimeName.entries) {
        if (entry.value == id) {
          return entry.key;
        }
      }
    }
    final name = instanceName.trim();
    for (final entry in _instanceNamesByRuntimeName.entries) {
      if (entry.value == name) {
        return entry.key;
      }
    }
    return name;
  }

  void _emitVpnError(Object error, StackTrace stackTrace) {
    if (_disposed) {
      return;
    }
    if (_isAndroidInstanceNotFoundError(error)) {
      return;
    }
    _events.add(
      CoreRuntimeEvent(
        type: CoreRuntimeEventTypes.error,
        data: {'error': error.toString(), 'stack': stackTrace.toString()},
      ),
    );
  }

  static bool _isAndroidInstanceNotFoundError(Object error) {
    final message = error is PlatformException
        ? '${error.code} ${error.message ?? ''} ${error.details ?? ''}'
        : error.toString();
    return CoreLifecycleService._isInstanceNotReadyMessage(message);
  }

  bool _vpnConfigHasAddress(Map<String, Object?> config) {
    return _readString(config['address']).isNotEmpty ||
        _readString(config['ipv4']).isNotEmpty ||
        _readString(config['virtual_ip']).isNotEmpty ||
        _readString(config['cidr']).isNotEmpty ||
        _readString(config['ipv4_cidr']).isNotEmpty ||
        _readList(config['addresses']).isNotEmpty;
  }

  static String _vpnConfigSignature(Map<String, Object?> config) {
    List<String> normalizedCidrs(Object? value) {
      final items = _readCidrList(value).toSet().toList(growable: false);
      items.sort();
      return items;
    }

    List<String> normalizedStrings(Object? value) {
      final items = _readStringList(value).toSet().toList(growable: false);
      items.sort();
      return items;
    }

    return jsonEncode({
      'addresses': normalizedCidrs(config['addresses'] ?? config['address']),
      'routes': normalizedCidrs(config['routes'] ?? config['route']),
      'dns': normalizedStrings(
        config['dns'] ?? config['dns_servers'] ?? config['dnsServers'],
      ),
      'disallowedApplications': normalizedStrings(
        config['disallowedApplications'] ??
            config['disallowed_applications'] ??
            config['disallowedPackages'] ??
            config['disallowed_packages'],
      ),
      'mtu': _readString(config['mtu']),
    });
  }

  static Map<String, Object?>? _readMap(Object? value) {
    if (value is Map) {
      return _stringObjectMap(value);
    }
    if (value is String) {
      final decoded = _tryDecodeJson(value);
      return decoded is Map ? _stringObjectMap(decoded) : null;
    }
    return null;
  }

  static List<Object?> _readList(Object? value) {
    if (value is List) {
      return value;
    }
    if (value is String && value.trim().isNotEmpty) {
      final decoded = _tryDecodeJson(value);
      if (decoded is List) {
        return decoded;
      }
      if (decoded is Map) {
        return <Object?>[decoded];
      }
      return <Object?>[value.trim()];
    }
    return const <Object?>[];
  }

  static Object? _tryDecodeJson(String value) {
    final text = value.trim();
    if ((!text.startsWith('{') || !text.endsWith('}')) &&
        (!text.startsWith('[') || !text.endsWith(']'))) {
      return null;
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static List<String> _readStringList(Object? value) {
    return _readList(value)
        .map(_readString)
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _readCidrList(Object? value) {
    if (value is Map) {
      final cidr = _cidrFromValue(value);
      return cidr.isEmpty ? const <String>[] : <String>[cidr];
    }
    return _readList(value)
        .map(_cidrFromValue)
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  static List<String> _readAddressCidrs(Map<String, Object?> json) {
    final prefix = _firstNonEmptyString([
      json['network_length'],
      json['networkLength'],
      json['prefix'],
      json['prefix_length'],
      json['prefixLength'],
      json['mask'],
    ]);
    final cidrs = <String>{};

    void add(Object? value) {
      for (final cidr in _readCidrList(value)) {
        if (cidr.contains('/') || prefix == null) {
          cidrs.add(cidr);
        } else {
          cidrs.add('$cidr/$prefix');
        }
      }
    }

    for (final key in const <String>[
      'addresses',
      'address',
      'ipv4',
      'ipv4_addr',
      'ipv4Addr',
      'ipv4_address',
      'ipv4Address',
      'virtual_ip',
      'virtualIp',
      'virtual_ipv4',
      'virtualIpv4',
      'cidr',
      'ip_cidr',
      'ipCidr',
      'ipv4_cidr',
      'ipv4Cidr',
    ]) {
      add(json[key]);
    }

    return cidrs.toList(growable: false);
  }

  static String _cidrFromValue(Object? value) {
    if (value is Map) {
      final map = _stringObjectMap(value);
      final nested = map['route'] ?? map['route_info'] ?? map['routeInfo'];
      if (nested is Map) {
        return _cidrFromValue(nested);
      }
      final ipv4Inet = _ipv4InetCidrFromMap(map);
      if (ipv4Inet.isNotEmpty) {
        return ipv4Inet;
      }
      for (final key in const <String>[
        'ipv4_addr',
        'ipv4Addr',
        'ipv4_address',
        'ipv4Address',
        'virtual_ip',
        'virtualIp',
        'virtual_ipv4',
        'virtualIpv4',
      ]) {
        final nested = map[key];
        if (nested == null) {
          continue;
        }
        final nestedCidr = _cidrFromValue(nested);
        if (nestedCidr.isNotEmpty) {
          if (!nestedCidr.contains('/')) {
            final prefix = _firstNonEmptyString([
              map['network_length'],
              map['networkLength'],
              map['prefix'],
              map['prefix_length'],
              map['prefixLength'],
              map['mask'],
            ]);
            if (prefix != null) {
              return '$nestedCidr/$prefix';
            }
          }
          return nestedCidr;
        }
      }
      final cidr = _firstNonEmptyString([
        map['cidr'],
        map['ipv4_cidr'],
        map['ipv4Cidr'],
        map['ip_cidr'],
        map['ipCidr'],
        map['destination'],
        map['dest'],
        _readScalarString(map['address']),
        map['ip'],
        map['ipv4'],
      ]);
      if (cidr == null) {
        return '';
      }
      if (cidr.contains('/')) {
        return cidr;
      }
      final prefix = _firstNonEmptyString([
        map['prefix'],
        map['prefix_length'],
        map['prefixLength'],
        map['mask'],
      ]);
      return prefix == null ? cidr : '$cidr/$prefix';
    }
    return _readString(value);
  }

  static String _routeCidrFromValue(Object? value) {
    if (value is Map) {
      final map = _stringObjectMap(value);
      final mapped = _firstNonEmptyString([
        map['mapped_cidr'],
        map['mappedCidr'],
        map['mappedCIDR'],
        map['mapped'],
      ]);
      if (mapped != null) {
        return _routeEndpointCidr(mapped);
      }
      return _routeEndpointCidr(_cidrFromValue(map));
    }
    return _routeEndpointCidr(_cidrFromValue(value));
  }

  static String _routeEndpointCidr(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      return '';
    }
    final arrowIndex = text.indexOf('->');
    if (arrowIndex < 0) {
      return text;
    }
    final mapped = text.substring(arrowIndex + 2).trim();
    return mapped.isNotEmpty ? mapped : text.substring(0, arrowIndex).trim();
  }

  static String _ipv4InetCidrFromMap(Map<String, Object?> map) {
    final address = _ipv4AddressFromValue(map['address'] ?? map['addr']);
    if (address == null || address.isEmpty) {
      return '';
    }
    if (address.contains('/')) {
      return address;
    }
    final prefix = _firstNonEmptyString([
      map['network_length'],
      map['networkLength'],
      map['prefix'],
      map['prefix_length'],
      map['prefixLength'],
      map['mask'],
    ]);
    return '$address/${prefix ?? 32}';
  }

  static String? _ipv4AddressFromValue(Object? value) {
    if (value is Map) {
      final map = _stringObjectMap(value);
      final numeric = _readIntValue(map['addr'] ?? map['value']);
      if (numeric != null) {
        return _ipv4FromUint32(numeric);
      }
      return _firstNonEmptyString([map['address'], map['ip'], map['ipv4']]);
    }
    final numeric = _readIntValue(value);
    if (numeric != null) {
      return _ipv4FromUint32(numeric);
    }
    return _readScalarString(value);
  }

  static String _ipv4FromUint32(int value) {
    final unsigned = value & 0xffffffff;
    return [
      (unsigned >> 24) & 0xff,
      (unsigned >> 16) & 0xff,
      (unsigned >> 8) & 0xff,
      unsigned & 0xff,
    ].join('.');
  }

  static int? _readIntValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(_readString(value));
  }

  static String? _readScalarString(Object? value) {
    if (value is Map || value is List) {
      return null;
    }
    final text = _readString(value);
    return text.isEmpty ? null : text;
  }

  static List<String> _readRouteCidrs(Object? value) {
    final cidrs = <String>{};
    if (value is Map) {
      _addRouteCidrsFromValue(cidrs, value);
      return cidrs.toList(growable: false);
    }
    for (final item in _readList(value)) {
      _addRouteCidrsFromValue(cidrs, item);
    }
    return cidrs.toList(growable: false);
  }

  static void _addRouteCidrsFromValue(Set<String> cidrs, Object? value) {
    if (value is Map) {
      final map = _stringObjectMap(value);
      if (!_looksLikeRouteCidrMap(map)) {
        for (final child in map.values) {
          if (child is Map || child is List) {
            _addRouteCidrsFromValue(cidrs, child);
          } else {
            final cidr = _routeCidrFromValue(child);
            if (_looksLikeRouteCidrText(cidr)) {
              cidrs.add(_routeCidr(cidr));
            }
          }
        }
        return;
      }

      for (final key in const <String>[
        'route',
        'route_info',
        'routeInfo',
        'routes',
        'route_infos',
        'routeInfos',
        'peer_routes',
        'peerRoutes',
        'peer_route_pairs',
        'peerRoutePairs',
      ]) {
        final nested = map[key];
        if (nested is Map || nested is List) {
          _addRouteCidrsFromValue(cidrs, nested);
        }
      }
      final cidr = _routeCidrFromValue(map);
      if (cidr.isNotEmpty) {
        cidrs.add(_routeCidr(cidr));
      }
      for (final key in const <String>[
        'proxy_cidrs',
        'proxyCidrs',
        'proxy_cidr',
        'proxyCidr',
        'proxy_network',
        'proxyNetwork',
        'proxy_networks',
        'proxyNetworks',
        'subnet_cidrs',
        'subnetCidrs',
        'subnet_routes',
        'subnetRoutes',
        'subnets',
        'subnet',
      ]) {
        final nested = map[key];
        if (nested != null) {
          _addRouteCidrsFromValue(cidrs, nested);
        }
      }
      return;
    }

    if (value is List) {
      for (final item in value) {
        _addRouteCidrsFromValue(cidrs, item);
      }
      return;
    }

    final cidr = _routeCidrFromValue(value);
    if (cidr.isNotEmpty) {
      cidrs.add(_routeCidr(cidr));
    }
  }

  static bool _looksLikeRouteCidrMap(Map<String, Object?> map) {
    const routeKeys = <String>{
      'route',
      'route_info',
      'routeInfo',
      'routes',
      'route_infos',
      'routeInfos',
      'peer_routes',
      'peerRoutes',
      'peer_route_pairs',
      'peerRoutePairs',
      'proxy_cidrs',
      'proxyCidrs',
      'proxy_cidr',
      'proxyCidr',
      'proxy_network',
      'proxyNetwork',
      'proxy_networks',
      'proxyNetworks',
      'subnet_cidrs',
      'subnetCidrs',
      'subnet_routes',
      'subnetRoutes',
      'subnets',
      'subnet',
      'cidr',
      'ipv4_cidr',
      'ipv4Cidr',
      'ip_cidr',
      'ipCidr',
      'destination',
      'dest',
      'address',
      'ip',
      'ipv4',
      'ipv4_addr',
      'ipv4Addr',
      'ipv4_address',
      'ipv4Address',
      'virtual_ip',
      'virtualIp',
      'virtual_ipv4',
      'virtualIpv4',
      'mapped_cidr',
      'mappedCidr',
      'mappedCIDR',
      'network_length',
      'networkLength',
    };
    return map.keys.any(routeKeys.contains);
  }

  static bool _looksLikeRouteCidrText(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      return false;
    }
    if (_networkRouteFromAddressCidr(text) != null) {
      return true;
    }
    final octets = text.split('.');
    if (octets.length != 4) {
      return false;
    }
    for (final octet in octets) {
      final value = int.tryParse(octet);
      if (value == null || value < 0 || value > 255) {
        return false;
      }
    }
    return true;
  }

  static String _routeCidr(String cidr) {
    return _networkRouteFromAddressCidr(cidr) ?? cidr;
  }

  static String? _networkRouteFromAddressCidr(String value) {
    final text = value.trim();
    final slashIndex = text.indexOf('/');
    if (slashIndex <= 0 || slashIndex == text.length - 1) {
      return null;
    }
    final addressText = text.substring(0, slashIndex);
    final prefix = int.tryParse(text.substring(slashIndex + 1));
    if (prefix == null || prefix < 0 || prefix > 32) {
      return null;
    }
    final octets = addressText.split('.');
    if (octets.length != 4) {
      return null;
    }
    var address = 0;
    for (final octet in octets) {
      final value = int.tryParse(octet);
      if (value == null || value < 0 || value > 255) {
        return null;
      }
      address = (address << 8) | value;
    }
    final mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
    final network = address & mask;
    return '${_ipv4FromUint32(network)}/$prefix';
  }

  static List<String> _networkRoutesFromAddressCidrs(Iterable<String> values) {
    final routes = <String>[];
    for (final value in values) {
      final route = _networkRouteFromAddressCidr(value);
      if (route != null) {
        routes.add(route);
      }
    }
    return routes;
  }

  static Map<String, Object?> buildVpnConfigFromNetworkInfo(
    Map<String, Object?> json,
  ) {
    final nestedConfigs = <Map<String, Object?>>[];
    for (final key in const <String>[
      'vpn_config',
      'vpnConfig',
      'config',
      'network_config',
      'networkConfig',
      'node_config',
      'nodeConfig',
      'runtime_config',
      'runtimeConfig',
      'effective_config',
      'effectiveConfig',
    ]) {
      final nested = _readMap(json[key]);
      if (nested != null) {
        nestedConfigs.add(buildVpnConfigFromNetworkInfo(nested));
      }
    }
    Object? firstNestedValue(String key) {
      for (final config in nestedConfigs) {
        final value = config[key];
        if (_readString(value).isNotEmpty) {
          return value;
        }
      }
      return null;
    }

    Iterable<String> nestedCidrs(String primary, [String? secondary]) sync* {
      for (final config in nestedConfigs) {
        yield* _readCidrList(
          secondary == null
              ? config[primary]
              : config[primary] ?? config[secondary],
        );
      }
    }

    Iterable<String> nestedRouteCidrs(
      String primary, [
      String? secondary,
    ]) sync* {
      for (final config in nestedConfigs) {
        yield* _readRouteCidrs(
          secondary == null
              ? config[primary]
              : config[primary] ?? config[secondary],
        );
      }
    }

    Iterable<String> nestedStrings(
      String primary, [
      String? secondary,
      String? tertiary,
    ]) sync* {
      for (final config in nestedConfigs) {
        yield* _readStringList(
          config[primary] ??
              (secondary == null ? null : config[secondary]) ??
              (tertiary == null ? null : config[tertiary]),
        );
      }
    }

    final myNodeInfo = _readMap(json['my_node_info'] ?? json['myNodeInfo']);
    final addresses = <String>{
      ...nestedCidrs('addresses', 'address'),
      if (myNodeInfo != null) ..._readAddressCidrs(myNodeInfo),
      ..._readAddressCidrs(json),
    };

    final routes = <String>{
      ..._networkRoutesFromAddressCidrs(addresses),
      ...nestedRouteCidrs('routes', 'route'),
      ..._readRouteCidrs(json['routes']),
      ..._readRouteCidrs(json['route']),
      ..._readRouteCidrs(json['ipv4_routes']),
      ..._readRouteCidrs(json['ipv4Routes']),
      ..._readRouteCidrs(json['peer_routes']),
      ..._readRouteCidrs(json['peerRoutes']),
      ..._readRouteCidrs(json['route_infos']),
      ..._readRouteCidrs(json['routeInfos']),
      ..._readRouteCidrs(json['peer_route_pairs']),
      ..._readRouteCidrs(json['peerRoutePairs']),
      ..._readRouteCidrs(json['proxy_cidrs']),
      ..._readRouteCidrs(json['proxyCidrs']),
      ..._readRouteCidrs(json['proxy_network']),
      ..._readRouteCidrs(json['proxyNetwork']),
      ..._readRouteCidrs(json['proxy_networks']),
      ..._readRouteCidrs(json['proxyNetworks']),
      ..._readRouteCidrs(json['subnet_cidrs']),
      ..._readRouteCidrs(json['subnetCidrs']),
      ..._readRouteCidrs(json['subnet_routes']),
      ..._readRouteCidrs(json['subnetRoutes']),
    }..removeWhere((value) => value.isEmpty);

    final dns = <String>{
      ...nestedStrings('dns', 'dns_servers', 'dnsServers'),
      ..._readStringList(json['dns']),
      ..._readStringList(json['dns_servers']),
      ..._readStringList(json['dnsServers']),
    };

    final disallowedApplications = <String>{
      ...nestedStrings('disallowedApplications', 'disallowed_applications'),
      ...nestedStrings('disallowedPackages', 'disallowed_packages'),
      ..._readStringList(json['disallowedApplications']),
      ..._readStringList(json['disallowed_applications']),
      ..._readStringList(json['disallowedPackages']),
      ..._readStringList(json['disallowed_packages']),
    };

    final config = <String, Object?>{
      'addresses': addresses.toList(growable: false),
      'routes': routes.toList(growable: false),
      'dns': dns.toList(growable: false),
    };
    if (disallowedApplications.isNotEmpty) {
      config['disallowedApplications'] = disallowedApplications.toList(
        growable: false,
      );
    }
    final mtu = json['mtu'] ?? firstNestedValue('mtu');
    if (mtu is num) {
      config['mtu'] = mtu.toInt();
    } else {
      final parsed = int.tryParse(_readString(mtu));
      if (parsed != null) {
        config['mtu'] = parsed;
      }
    }
    return config;
  }

  static String buildConfigServerClientUrl(
    String configServer,
    String bootstrapToken,
  ) {
    final base = configServer.trim();
    final token = bootstrapToken.trim();
    if (base.isEmpty) {
      throw ArgumentError.value(configServer, 'configServer', '不能为空');
    }
    if (token.isEmpty) {
      throw ArgumentError.value(bootstrapToken, 'bootstrapToken', '不能为空');
    }
    final trimmedBase = base.replaceFirst(RegExp(r'/+$'), '');
    return '$trimmedBase/${Uri.encodeComponent(token)}';
  }

  static Map<String, dynamic> _normalizeAndroidPeer(Map<String, dynamic> peer) {
    final normalized = Map<String, dynamic>.from(peer);
    void copyIfMissing(String target, List<String> sources) {
      if (_readString(normalized[target]).isNotEmpty) {
        return;
      }
      for (final source in sources) {
        final value = _readString(peer[source]);
        if (value.isNotEmpty) {
          normalized[target] = value;
          return;
        }
      }
    }

    copyIfMissing('ipv4', [
      'ip',
      'ipv4_addr',
      'ipv4Addr',
      'virtual_ip',
      'virtualIp',
      'virtual_ipv4',
      'virtualIpv4',
      'address',
    ]);
    copyIfMissing('cidr', [
      'ipv4_cidr',
      'ipv4Cidr',
      'virtual_ip_cidr',
      'virtualIpCidr',
    ]);
    copyIfMissing('hostname', ['host_name', 'name']);
    copyIfMissing('lat_ms', ['latency_ms', 'latency', 'latency_text']);
    copyIfMissing('loss_rate', [
      'loss',
      'lossRate',
      'packet_loss',
      'packetLoss',
    ]);
    copyIfMissing('rx_bytes', ['rx', 'rxBytes', 'received_bytes']);
    copyIfMissing('tx_bytes', ['tx', 'txBytes', 'transmitted_bytes']);
    copyIfMissing('tunnel_proto', ['tunnel_protocol', 'proto']);
    copyIfMissing('nat_type', ['nat']);
    copyIfMissing('peer_id', ['peerId', 'id']);
    return normalized;
  }

  static _MutableNetworkTrafficTotals? _trafficTotalsFromPeers(
    List<Map<String, dynamic>> peers,
  ) {
    final byPeer = <String, _MutableNetworkTrafficTotals>{};
    var fallbackIndex = 0;
    for (final peer in peers) {
      final rxBytes = _readTrafficBytes(
        peer['rx_bytes_raw'] ??
            peer['rxBytesRaw'] ??
            peer['rx_bytes'] ??
            peer['rxBytes'] ??
            peer['received_bytes'],
      );
      final txBytes = _readTrafficBytes(
        peer['tx_bytes_raw'] ??
            peer['txBytesRaw'] ??
            peer['tx_bytes'] ??
            peer['txBytes'] ??
            peer['transmitted_bytes'],
      );
      if (rxBytes == null && txBytes == null) {
        continue;
      }
      final peerKey = _firstNonEmptyString([
        peer['peer_id'],
        peer['peerId'],
        peer['id'],
        peer['cidr'],
        peer['ipv4'],
      ]);
      final key = peerKey ?? '#${fallbackIndex++}';
      final traffic = byPeer.putIfAbsent(key, _MutableNetworkTrafficTotals.new);
      if (rxBytes != null) {
        if (!traffic.hasDownloadBytes || rxBytes > traffic.downloadBytes) {
          traffic.downloadBytes = rxBytes;
        }
        traffic.hasDownloadBytes = true;
      }
      if (txBytes != null) {
        if (!traffic.hasUploadBytes || txBytes > traffic.uploadBytes) {
          traffic.uploadBytes = txBytes;
        }
        traffic.hasUploadBytes = true;
      }
    }

    final total = _MutableNetworkTrafficTotals();
    for (final peer in byPeer.values) {
      if (peer.hasDownloadBytes) {
        total.downloadBytes += peer.downloadBytes;
        total.hasDownloadBytes = true;
      }
      if (peer.hasUploadBytes) {
        total.uploadBytes += peer.uploadBytes;
        total.hasUploadBytes = true;
      }
    }
    return total.hasDownloadBytes || total.hasUploadBytes ? total : null;
  }

  static Map<String, CoreNetworkTrafficTotals> _trafficTotalsFromJsonRpcStats(
    Map<String, Object?> response, {
    required String defaultRuntimeNetworkName,
    required DateTime sampledAt,
  }) {
    final collected = <String, _MutableNetworkTrafficTotals>{};
    final metrics = _readList(response['metrics'] ?? response['result']);
    for (final item in metrics) {
      final metric = _readMap(item);
      if (metric == null) {
        continue;
      }
      final metricName = _readString(metric['name']);
      if (metricName != 'traffic_bytes_self_rx' &&
          metricName != 'traffic_bytes_self_tx') {
        continue;
      }
      final labels = _readMap(metric['labels']);
      final labelNetworkName = labels == null
          ? ''
          : _readString(labels['network_name'] ?? labels['networkName']);
      final runtimeNetworkName = labelNetworkName.isNotEmpty
          ? labelNetworkName
          : defaultRuntimeNetworkName;
      if (runtimeNetworkName.isEmpty || runtimeNetworkName == '__access__') {
        continue;
      }
      final value = _readIntValue(metric['value']);
      if (value == null || value < 0) {
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

    return collected.map((runtimeNetworkName, totals) {
      return MapEntry(
        runtimeNetworkName,
        CoreNetworkTrafficTotals(
          runtimeNetworkName: runtimeNetworkName,
          downloadBytes: totals.hasDownloadBytes ? totals.downloadBytes : 0,
          uploadBytes: totals.hasUploadBytes ? totals.uploadBytes : 0,
          sampledAt: sampledAt,
        ),
      );
    });
  }

  static int? _readTrafficBytes(Object? value) {
    final parsed = _readIntValue(value);
    if (parsed != null) {
      return parsed < 0 ? null : parsed;
    }
    final text = _readString(value);
    if (text.isEmpty || text == '-' || text.toLowerCase() == 'null') {
      return null;
    }
    final normalized = text.replaceAll(',', '');
    final number = num.tryParse(normalized);
    if (number == null || number < 0) {
      return null;
    }
    return number.toInt();
  }
}

class AndroidNetworkInfoSnapshot {
  const AndroidNetworkInfoSnapshot(this.instances);

  final Map<String, AndroidNetworkInstanceInfo> instances;

  AndroidNetworkInstanceInfo? instanceNamed(String name) {
    final target = name.trim();
    if (target.isEmpty) {
      return null;
    }
    final direct = instances[target];
    if (direct != null) {
      return direct;
    }
    for (final instance in instances.values) {
      if (instance.name == target) {
        return instance;
      }
    }
    return null;
  }

  AndroidNetworkInstanceInfo? instanceMatching({
    required String name,
    required String id,
  }) {
    final byName = instanceNamed(name);
    if (byName != null) {
      return byName;
    }
    final targetId = id.trim();
    if (targetId.isEmpty) {
      return null;
    }
    for (final instance in instances.values) {
      if (instance.id == targetId) {
        return instance;
      }
    }
    if (instances.length == 1) {
      return instances.values.single;
    }
    return null;
  }

  static AndroidNetworkInfoSnapshot parse(String output) {
    final text = output.trim();
    if (text.isEmpty) {
      return const AndroidNetworkInfoSnapshot(
        <String, AndroidNetworkInstanceInfo>{},
      );
    }

    final decoded = jsonDecode(text);
    final instances = <String, AndroidNetworkInstanceInfo>{};

    void collect(Object? value, {String? nameHint, String? idHint}) {
      if (value is List) {
        for (final item in value) {
          collect(item);
        }
        return;
      }
      if (value is! Map) {
        return;
      }

      final map = _stringObjectMap(value);
      final explicitName = _firstNonEmptyString([
        map['instance_name'],
        map['instanceName'],
        map['dev_name'],
        map['devName'],
        map['network_name'],
        map['networkName'],
        map['runtime_network_name'],
        map['name'],
      ]);
      final name = explicitName ?? nameHint?.trim();
      if (name != null && name.isNotEmpty && _looksLikeInstanceMap(map)) {
        final instance = AndroidNetworkInstanceInfo.fromJson(
          map,
          name: name,
          idHint: idHint,
        );
        instances[instance.name] = instance;
      }

      for (final entry in map.entries) {
        final key = entry.key;
        final child = entry.value;
        if (_containerKeys.contains(key)) {
          collect(child);
        } else if (child is Map) {
          collect(
            child,
            nameHint: key,
            idHint: _looksLikeUuid(key) ? key : null,
          );
        } else if (child is List && _containerKeys.contains(key)) {
          collect(child);
        }
      }
    }

    collect(decoded);
    return AndroidNetworkInfoSnapshot(Map.unmodifiable(instances));
  }

  static const Set<String> _containerKeys = <String>{
    'instances',
    'network_infos',
    'networkInfos',
    'items',
    'result',
    'networks',
    'map',
  };

  static bool _looksLikeInstanceMap(Map<String, Object?> map) {
    return map.containsKey('running') ||
        map.containsKey('is_running') ||
        map.containsKey('state') ||
        map.containsKey('status') ||
        map.containsKey('instance_id') ||
        map.containsKey('instanceId') ||
        map.containsKey('error') ||
        map.containsKey('error_msg') ||
        map.containsKey('errorMessage') ||
        map.containsKey('last_error') ||
        map.containsKey('my_node_info') ||
        map.containsKey('myNodeInfo') ||
        map.containsKey('vpn_config') ||
        map.containsKey('vpnConfig') ||
        map.containsKey('peers') ||
        map.containsKey('peer_infos') ||
        map.containsKey('peer_list') ||
        map.containsKey('routes');
  }

  static bool _looksLikeUuid(String value) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value.trim());
  }
}

class AndroidNetworkInstanceInfo {
  const AndroidNetworkInstanceInfo({
    required this.name,
    required this.running,
    this.id,
    this.error,
    this.vpnConfig,
    this.peers = const <Map<String, dynamic>>[],
  });

  final String name;
  final bool running;
  final String? id;
  final String? error;
  final Map<String, Object?>? vpnConfig;
  final List<Map<String, dynamic>> peers;

  static AndroidNetworkInstanceInfo fromJson(
    Map<String, Object?> json, {
    required String name,
    String? idHint,
  }) {
    final error = _firstNonEmptyString([
      json['error'],
      json['last_error'],
      json['lastError'],
      json['error_msg'],
      json['errorMessage'],
    ]);
    return AndroidNetworkInstanceInfo(
      name: name,
      running: _readRunning(json, hasError: error != null),
      id: _firstNonEmptyString([
        json['instance_id'],
        json['instanceId'],
        json['id'],
        idHint,
      ]),
      error: error,
      vpnConfig: AndroidCoreRuntime.buildVpnConfigFromNetworkInfo(json),
      peers: _extractPeers(json),
    );
  }

  static bool _readRunning(
    Map<String, Object?> json, {
    required bool hasError,
  }) {
    final explicit = _readBool(json['running'] ?? json['is_running']);
    if (explicit != null) {
      return explicit;
    }

    final state = _readString(json['state'] ?? json['status']).toLowerCase();
    if (state.isNotEmpty) {
      return (state.contains('running') ||
              state.contains('connected') ||
              state == 'up') &&
          !state.contains('error') &&
          !state.contains('failed');
    }
    return !hasError && _extractPeers(json).isNotEmpty;
  }

  static List<Map<String, dynamic>> _extractPeers(Map<String, Object?> json) {
    const peerKeys = <String>['peers', 'peer_infos', 'peerInfos'];
    const directPeerKeys = <String>['peer_list', 'peerList'];
    const routeKeys = <String>['routes', 'route_infos', 'routeInfos'];
    const peerRoutePairKeys = <String>['peer_route_pairs', 'peerRoutePairs'];
    final peers = <Map<String, dynamic>>[];

    final myNodeInfo = AndroidCoreRuntime._readMap(
      json['my_node_info'] ?? json['myNodeInfo'],
    );
    final myPeerId = _peerIdFromMap(myNodeInfo);
    if (myNodeInfo != null) {
      final localPeer = _localPeerFromMyNodeInfo(myNodeInfo);
      if (localPeer.isNotEmpty) {
        peers.add(localPeer);
      }
    }

    final peersById = <String, Map<String, Object?>>{};
    for (final key in peerKeys) {
      for (final item in AndroidCoreRuntime._readList(json[key])) {
        final peer = AndroidCoreRuntime._readMap(item);
        final peerId = _peerIdFromMap(peer);
        if (peer == null) {
          continue;
        }
        if (peerId.isEmpty) {
          peers.add(_stringDynamicMap(peer));
        } else {
          peersById[peerId] = peer;
        }
      }
    }

    for (final key in directPeerKeys) {
      for (final item in AndroidCoreRuntime._readList(json[key])) {
        final peer = AndroidCoreRuntime._readMap(item);
        if (peer != null) {
          peers.add(_stringDynamicMap(peer));
        }
      }
    }

    for (final key in peerRoutePairKeys) {
      for (final item in AndroidCoreRuntime._readList(json[key])) {
        final pair = AndroidCoreRuntime._readMap(item);
        final peer = AndroidCoreRuntime._readMap(pair?['peer']);
        final peerId = _peerIdFromMap(peer);
        if (peer != null && peerId.isNotEmpty) {
          peersById[peerId] = peer;
        }
      }
    }

    for (final peer in peersById.values) {
      final runtimePeer = _peerFromPeerInfo(peer);
      if (runtimePeer.isNotEmpty) {
        peers.add(runtimePeer);
      }
    }

    for (final key in routeKeys) {
      for (final item in AndroidCoreRuntime._readList(json[key])) {
        final route = _routeFromValue(item);
        if (route == null) {
          continue;
        }
        final peer = peersById[_peerIdFromMap(route)];
        final runtimePeer = _peerFromRoute(route, peer, myPeerId: myPeerId);
        if (runtimePeer.isNotEmpty) {
          peers.add(runtimePeer);
        }
      }
    }

    for (final key in peerRoutePairKeys) {
      for (final item in AndroidCoreRuntime._readList(json[key])) {
        final pair = AndroidCoreRuntime._readMap(item);
        final route = _routeFromValue(pair?['route'] ?? pair?['route_info']);
        if (route == null) {
          continue;
        }
        final peer =
            AndroidCoreRuntime._readMap(pair?['peer']) ??
            peersById[_peerIdFromMap(route)];
        final runtimePeer = _peerFromRoute(route, peer, myPeerId: myPeerId);
        if (runtimePeer.isNotEmpty) {
          peers.add(runtimePeer);
        }
      }
    }
    return peers;
  }

  static Map<String, dynamic> _localPeerFromMyNodeInfo(
    Map<String, Object?> myNodeInfo,
  ) {
    final cidr = AndroidCoreRuntime._cidrFromValue(
      myNodeInfo['virtual_ipv4'] ??
          myNodeInfo['virtualIpv4'] ??
          myNodeInfo['ipv4_addr'] ??
          myNodeInfo['ipv4Addr'] ??
          myNodeInfo['ipv4'] ??
          myNodeInfo['address'],
    );
    if (cidr.isEmpty) {
      return const <String, dynamic>{};
    }
    return <String, dynamic>{
      'cidr': cidr,
      'ipv4': cidr,
      'hostname': _firstScalarString([
        myNodeInfo['hostname'],
        myNodeInfo['hostName'],
        myNodeInfo['name'],
      ]),
      'cost': 'Local',
      'lat_ms': '-',
      'loss_rate': '-',
      'rx_bytes': '-',
      'tx_bytes': '-',
      'tunnel_proto': '-',
      'nat_type': _natTypeText(
        AndroidCoreRuntime._readMap(myNodeInfo['stun_info']) ??
            AndroidCoreRuntime._readMap(myNodeInfo['stunInfo']),
      ),
      'peer_id': _peerIdFromMap(myNodeInfo),
      'id': _peerIdFromMap(myNodeInfo),
      'version': _firstScalarString([myNodeInfo['version']]),
    };
  }

  static Map<String, dynamic> _peerFromPeerInfo(Map<String, Object?> peer) {
    final conn = _selectedPeerConn(peer);
    final stats = _peerConnStats(conn);
    final tunnel = _peerConnTunnel(conn);
    return <String, dynamic>{
      'peer_id': _peerIdFromMap(peer),
      'id': _peerIdFromMap(peer),
      'lat_ms': _latencyText(stats, conn),
      'loss_rate': _firstScalarString([
        conn?['loss_rate'],
        conn?['lossRate'],
        stats?['loss_rate'],
        stats?['lossRate'],
      ]),
      'rx_bytes': _byteCountText(stats?['rx_bytes'] ?? stats?['rxBytes']),
      'tx_bytes': _byteCountText(stats?['tx_bytes'] ?? stats?['txBytes']),
      'rx_bytes_raw': stats?['rx_bytes'] ?? stats?['rxBytes'],
      'tx_bytes_raw': stats?['tx_bytes'] ?? stats?['txBytes'],
      'tunnel_proto': _firstScalarString([
        tunnel?['tunnel_type'],
        tunnel?['tunnelType'],
        conn?['tunnel_proto'],
        conn?['tunnelProto'],
      ]),
    }..removeWhere((_, value) => _readString(value).isEmpty);
  }

  static Map<String, dynamic> _peerFromRoute(
    Map<String, Object?> route,
    Map<String, Object?>? peer, {
    required String myPeerId,
  }) {
    final peerId = _peerIdFromMap(route);
    final hasPeerAddressShape =
        route.containsKey('ipv4_addr') ||
        route.containsKey('ipv4Addr') ||
        route.containsKey('ipv6_addr') ||
        route.containsKey('ipv6Addr');
    if (peerId.isEmpty && !hasPeerAddressShape) {
      return const <String, dynamic>{};
    }

    final cidr = AndroidCoreRuntime._cidrFromValue(
      route['ipv4_addr'] ??
          route['ipv4Addr'] ??
          route['ipv4'] ??
          route['address'],
    );
    if (cidr.isEmpty) {
      return const <String, dynamic>{};
    }

    final peerInfo = peer == null
        ? const <String, dynamic>{}
        : _peerFromPeerInfo(peer);
    final local = peerId.isNotEmpty && peerId == myPeerId;
    final routeLatency = _firstScalarString([
      route['path_latency_latency_first'],
      route['pathLatencyLatencyFirst'],
      route['path_latency'],
      route['pathLatency'],
    ]);

    return <String, dynamic>{
      ...peerInfo,
      'cidr': cidr,
      'ipv4': cidr,
      'hostname': _firstScalarString([
        route['hostname'],
        route['hostName'],
        peer?['hostname'],
        peer?['name'],
      ]),
      'cost': local ? 'Local' : _costText(route),
      if (_readString(peerInfo['lat_ms']).isEmpty) 'lat_ms': routeLatency,
      'nat_type': _natTypeText(
        AndroidCoreRuntime._readMap(route['stun_info']) ??
            AndroidCoreRuntime._readMap(route['stunInfo']),
      ),
      'peer_id': peerId,
      'id': peerId,
      'version': _firstScalarString([route['version'], peer?['version']]),
    }..removeWhere((_, value) => _readString(value).isEmpty);
  }

  static Map<String, Object?>? _routeFromValue(Object? value) {
    final map = AndroidCoreRuntime._readMap(value);
    if (map == null) {
      return null;
    }
    final nested = AndroidCoreRuntime._readMap(
      map['route'] ?? map['route_info'] ?? map['routeInfo'],
    );
    return nested ?? map;
  }

  static Map<String, Object?>? _selectedPeerConn(Map<String, Object?> peer) {
    const keys = <String>['conns', 'connections', 'conn_infos', 'connInfos'];
    for (final key in keys) {
      final conns = AndroidCoreRuntime._readList(peer[key]);
      for (final item in conns) {
        final conn = AndroidCoreRuntime._readMap(item);
        if (conn == null) {
          continue;
        }
        if (_readBool(conn['is_closed'] ?? conn['isClosed']) != true) {
          return conn;
        }
      }
      for (final item in conns) {
        final conn = AndroidCoreRuntime._readMap(item);
        if (conn != null) {
          return conn;
        }
      }
    }
    return null;
  }

  static Map<String, Object?>? _peerConnStats(Map<String, Object?>? conn) {
    if (conn == null) {
      return null;
    }
    return AndroidCoreRuntime._readMap(conn['stats']) ?? conn;
  }

  static Map<String, Object?>? _peerConnTunnel(Map<String, Object?>? conn) {
    if (conn == null) {
      return null;
    }
    return AndroidCoreRuntime._readMap(conn['tunnel']) ??
        AndroidCoreRuntime._readMap(conn['tunnel_info']) ??
        AndroidCoreRuntime._readMap(conn['tunnelInfo']);
  }

  static String _peerIdFromMap(Map<String, Object?>? map) {
    if (map == null) {
      return '';
    }
    return _firstScalarString([map['peer_id'], map['peerId'], map['id']]) ?? '';
  }

  static String? _firstScalarString(Iterable<Object?> values) {
    for (final value in values) {
      final text = AndroidCoreRuntime._readScalarString(value);
      if (text != null && text.isNotEmpty) {
        return text;
      }
    }
    return null;
  }

  static String _latencyText(
    Map<String, Object?>? stats,
    Map<String, Object?>? conn,
  ) {
    final latencyUs = AndroidCoreRuntime._readIntValue(
      stats?['latency_us'] ?? stats?['latencyUs'] ?? conn?['latency_us'],
    );
    if (latencyUs != null && latencyUs > 0) {
      return _trimTrailingZeros((latencyUs / 1000).toStringAsFixed(3));
    }
    return _firstScalarString([
          stats?['lat_ms'],
          stats?['latMs'],
          stats?['latency_ms'],
          stats?['latencyMs'],
          conn?['lat_ms'],
          conn?['latency_ms'],
        ]) ??
        '';
  }

  static String _costText(Map<String, Object?> route) {
    final cost = AndroidCoreRuntime._readIntValue(route['cost']);
    if (cost != null) {
      return _routeCostText(cost);
    }
    final latencyFirst = AndroidCoreRuntime._readIntValue(
      route['cost_latency_first'] ?? route['costLatencyFirst'],
    );
    if (latencyFirst != null) {
      return _routeCostText(latencyFirst);
    }
    return '';
  }

  static String _routeCostText(int cost) {
    if (cost <= 0) {
      return '';
    }
    return cost == 1 ? 'p2p' : 'relay($cost)';
  }

  static String _byteCountText(Object? value) {
    final bytes = AndroidCoreRuntime._readIntValue(value);
    if (bytes == null) {
      return _firstScalarString([value]) ?? '';
    }
    const units = <String>['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var amount = bytes.toDouble();
    var unitIndex = 0;
    while (amount >= 1024 && unitIndex < units.length - 1) {
      amount = amount / 1024;
      unitIndex++;
    }
    if (unitIndex == 0) {
      return '${amount.round()} ${units[unitIndex]}';
    }
    final decimals = amount >= 10 ? 1 : 2;
    return '${amount.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  static String _natTypeText(Map<String, Object?>? stunInfo) {
    if (stunInfo == null) {
      return '';
    }
    return _natTypeValueText(
      stunInfo['udp_nat_type'] ??
          stunInfo['udpNatType'] ??
          stunInfo['nat_type'],
    );
  }

  static String _natTypeValueText(Object? value) {
    final text = AndroidCoreRuntime._readScalarString(value);
    if (text == null || text.isEmpty) {
      return '';
    }
    final index = int.tryParse(text);
    if (index == null) {
      return text;
    }
    const names = <String>[
      'Unknown',
      'OpenInternet',
      'NoPAT',
      'FullCone',
      'Restricted',
      'PortRestricted',
      'Symmetric',
      'SymUdpFirewall',
      'SymmetricEasyInc',
      'SymmetricEasyDec',
    ];
    return index >= 0 && index < names.length ? names[index] : text;
  }

  static String _trimTrailingZeros(String value) {
    return value
        .replaceFirst(RegExp(r'\.?0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
}

Map<String, Object?> _stringObjectMap(Map<dynamic, dynamic> value) {
  return value.map((key, value) => MapEntry(key.toString(), value));
}

Map<String, dynamic> _stringDynamicMap(Map<dynamic, dynamic> value) {
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String _readString(Object? value) {
  return value?.toString().trim() ?? '';
}

String? _firstNonEmptyString(Iterable<Object?> values) {
  for (final value in values) {
    final text = _readString(value);
    if (text.isNotEmpty) {
      return text;
    }
  }
  return null;
}

bool? _readBool(Object? value) {
  if (value is bool) {
    return value;
  }
  final text = _readString(value).toLowerCase();
  if (text == 'true' || text == '1' || text == 'yes') {
    return true;
  }
  if (text == 'false' || text == '0' || text == 'no') {
    return false;
  }
  return null;
}

class _AndroidVpnConfigReadResult {
  const _AndroidVpnConfigReadResult({
    required this.config,
    required this.routeResponseKeys,
    required this.routePayloadType,
    required this.routePayloadCount,
    required this.routeCidrs,
    required this.routeProxyCidrs,
  });

  final Map<String, Object?> config;
  final List<String> routeResponseKeys;
  final String routePayloadType;
  final int routePayloadCount;
  final List<String> routeCidrs;
  final List<String> routeProxyCidrs;
}

class _ResolvedAndroidVpnTarget {
  const _ResolvedAndroidVpnTarget({
    required this.instanceName,
    required this.instanceId,
    required this.vpnConfig,
    required this.source,
    required this.knownInstanceNames,
  });

  final String instanceName;
  final String? instanceId;
  final Map<String, Object?> vpnConfig;
  final String source;
  final List<String> knownInstanceNames;
}
