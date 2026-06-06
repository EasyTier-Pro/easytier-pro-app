part of 'core_lifecycle_service.dart';

class AndroidCoreRuntime extends CorePlatformRuntime {
  AndroidCoreRuntime({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    @visibleForTesting
    Duration networkInfoCacheDuration = _androidNetworkInfoCacheDuration,
    @visibleForTesting Duration? vpnRouteRefreshFastInterval,
    @visibleForTesting Duration? vpnRouteRefreshSteadyInterval,
    @visibleForTesting int? vpnRouteRefreshFastLimit,
  }) : _methodChannel = methodChannel ?? const MethodChannel(_methodName),
       _eventChannel = eventChannel ?? const EventChannel(_eventName),
       // ignore: prefer_initializing_formals
       _networkInfoCacheDuration = networkInfoCacheDuration,
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
  static const int _networkInfoMaxLength = 2 * 1024 * 1024;
  static const Duration _androidNetworkInfoCacheDuration = Duration(
    seconds: 15,
  );
  static const Duration _androidRuntimePollInterval = Duration(seconds: 15);
  static const Duration _androidVpnRouteRefreshFastInterval = Duration(
    seconds: 3,
  );
  static const Duration _androidVpnRouteRefreshSteadyInterval = Duration(
    seconds: 15,
  );
  static const int _androidVpnRouteRefreshFastLimit = 20;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Duration _networkInfoCacheDuration;
  final Duration _vpnRouteRefreshFastInterval;
  final Duration _vpnRouteRefreshSteadyInterval;
  final int _vpnRouteRefreshFastLimit;
  final StreamController<CoreRuntimeEvent> _events =
      StreamController<CoreRuntimeEvent>.broadcast();

  late final StreamSubscription<dynamic> _nativeEvents;
  Timer? _activeVpnRefreshTimer;
  String? _cachedNetworkInfos;
  DateTime? _cachedNetworkInfosAt;
  Future<String>? _networkInfoInFlight;
  Future<void> _vpnSerial = Future<void>.value();
  final Map<String, Map<String, Object?>> _pendingVpnPayloads =
      <String, Map<String, Object?>>{};
  String? _activeVpnInstanceName;
  String? _activeVpnInstanceId;
  String? _activeVpnConfigSignature;
  int _activeVpnRefreshCount = 0;
  bool _vpnPrepared = false;
  bool _disposed = false;

  @override
  Stream<CoreRuntimeEvent> get events => _events.stream;

  @override
  Duration get networkTrafficPollInterval => _androidRuntimePollInterval;

  @override
  Duration get peerStatusPollInterval => _androidRuntimePollInterval;

  @override
  Future<CoreRuntimeStartResult?> readStatus(
    CoreBootstrapConfig bootstrap,
  ) async {
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

    final vpnPrepared =
        await _methodChannel.invokeMethod<bool>('prepareVpn') ?? false;
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
    _cancelActiveVpnRefresh();
    _pendingVpnPayloads.clear();
    _activeVpnInstanceName = null;
    _activeVpnInstanceId = null;
    _activeVpnConfigSignature = null;
    await _ignoreMissingJni(
      _methodChannel.invokeMethod<void>('stopConfigServerClient'),
    );
    await _methodChannel.invokeMethod<void>('stopVpn');
    _cachedNetworkInfos = null;
    _cachedNetworkInfosAt = null;
  }

  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    final snapshot = await _readNetworkInfoSnapshot();
    final sampledAt = DateTime.now();
    final totals = <String, CoreNetworkTrafficTotals>{};
    for (final instance in snapshot.instances.values) {
      if (!instance.running) {
        continue;
      }
      final traffic = _trafficTotalsFromPeers(instance.peers);
      if (traffic == null) {
        continue;
      }
      totals[instance.name] = CoreNetworkTrafficTotals(
        runtimeNetworkName: instance.name,
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
    return snapshot.instanceNamed(instanceName)?.running ?? false;
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
    final instance = snapshot.instanceNamed(instanceName);
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
    } on MissingPluginException {
      return;
    }
  }

  Future<AndroidNetworkInfoSnapshot> _readNetworkInfoSnapshot() async {
    final output = await _collectNetworkInfos();
    return AndroidNetworkInfoSnapshot.parse(output);
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

  Future<String> _collectNetworkInfos() {
    final cachedAt = _cachedNetworkInfosAt;
    final cached = _cachedNetworkInfos;
    if (cachedAt != null &&
        cached != null &&
        DateTime.now().difference(cachedAt) < _networkInfoCacheDuration) {
      return Future<String>.value(cached);
    }

    final inFlight = _networkInfoInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _methodChannel
        .invokeMethod<String>('collectNetworkInfos', {
          'maxLength': _networkInfoMaxLength,
        })
        .then((value) {
          final text = value ?? '{}';
          _cachedNetworkInfos = text;
          _cachedNetworkInfosAt = DateTime.now();
          return text;
        })
        .whenComplete(() {
          _networkInfoInFlight = null;
        });
    _networkInfoInFlight = future;
    return future;
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
      }
    }
    if (runtimeEvent.type == CoreRuntimeEventTypes.vpnStopped) {
      final payload = _runtimeEventPayload(runtimeEvent);
      final instanceName = _readString(
        payload['instanceName'] ?? payload['instance_name'],
      );
      if (instanceName.isEmpty || instanceName == _activeVpnInstanceName) {
        _activeVpnInstanceName = null;
        _activeVpnInstanceId = null;
        _activeVpnConfigSignature = null;
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

    final instanceName = _readString(
      payloadMap['instance_name'] ??
          payloadMap['instanceName'] ??
          payloadMap['network_name'] ??
          payloadMap['networkName'],
    );
    final instanceId = _readString(
      payloadMap['instance_id'] ?? payloadMap['instanceId'] ?? payloadMap['id'],
    );
    final instanceKey = instanceName.isNotEmpty ? instanceName : instanceId;
    if (instanceKey.isEmpty) {
      return;
    }

    if (eventName == 'delete_network_instance') {
      unawaited(_queueVpnStop(instanceKey));
      return;
    }

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

    final target = await _resolveVpnTarget(instanceKey, payloadMap);
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

    final active = _activeVpnInstanceName;
    if (active != null && active != target.instanceName) {
      _activeVpnInstanceName = null;
      _activeVpnInstanceId = null;
      _activeVpnConfigSignature = null;
      _cancelActiveVpnRefresh();
      await _methodChannel.invokeMethod<void>('stopVpn');
    }
    await _ignoreMissingJni(
      _methodChannel.invokeMethod<void>('retainNetworkInstance', {
        'instanceNames': <String>[target.instanceName],
      }),
    );
    await _methodChannel.invokeMethod<void>('startVpn', {
      'instanceName': target.instanceName,
      'vpnConfig': target.vpnConfig,
    });
    _activeVpnInstanceName = target.instanceName;
    _activeVpnInstanceId = target.instanceId;
    _activeVpnConfigSignature = _vpnConfigSignature(target.vpnConfig);
    _activeVpnRefreshCount = 0;
    _scheduleActiveVpnRefresh();
    _pendingVpnPayloads.remove(instanceKey);
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
      _cachedNetworkInfosAt = null;
      final snapshot = await _readNetworkInfoSnapshot();
      final instance = snapshot.instanceMatching(
        name: activeName,
        id: _activeVpnInstanceId ?? '',
      );
      final config = instance?.vpnConfig;
      if (instance == null ||
          !instance.running ||
          config == null ||
          !_vpnConfigHasAddress(config)) {
        return;
      }

      final signature = _vpnConfigSignature(config);
      if (signature == _activeVpnConfigSignature) {
        return;
      }

      await _methodChannel.invokeMethod<void>('startVpn', {
        'instanceName': instance.name,
        'vpnConfig': config,
      });
      _activeVpnInstanceName = instance.name;
      _activeVpnInstanceId = instance.id ?? _activeVpnInstanceId;
      _activeVpnConfigSignature = signature;
      if (!_disposed) {
        _events.add(
          CoreRuntimeEvent(
            type: CoreRuntimeEventTypes.vpnConfigRefreshed,
            data: {
              'instance_name': instance.name,
              'addresses': config['addresses'],
              'routes': config['routes'],
              'dns': config['dns'],
            },
          ),
        );
      }
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
    final instanceName = _instanceNameFromPayload(payloadMap);
    final instanceId = _instanceIdFromPayload(payloadMap);
    final direct = _readMap(
      payloadMap['vpn_config'] ?? payloadMap['vpnConfig'],
    );
    final directConfig = direct == null
        ? null
        : buildVpnConfigFromNetworkInfo(direct);
    if (directConfig != null &&
        _vpnConfigHasAddress(directConfig) &&
        instanceName.isNotEmpty) {
      return _ResolvedAndroidVpnTarget(
        instanceName: instanceName,
        instanceId: instanceId.isEmpty ? null : instanceId,
        vpnConfig: directConfig,
        knownInstanceNames: const <String>[],
      );
    }

    var knownInstanceNames = const <String>[];
    AndroidNetworkInstanceInfo? lastMatchedInstance;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      _cachedNetworkInfosAt = null;
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
        return _ResolvedAndroidVpnTarget(
          instanceName: instance!.name,
          instanceId: instance.id ?? instanceId,
          vpnConfig: config,
          knownInstanceNames: knownInstanceNames,
        );
      }
    }

    return _ResolvedAndroidVpnTarget(
      instanceName:
          lastMatchedInstance?.name ??
          (instanceName.isEmpty ? instanceKey : instanceName),
      instanceId:
          lastMatchedInstance?.id ?? (instanceId.isEmpty ? null : instanceId),
      vpnConfig:
          directConfig ??
          lastMatchedInstance?.vpnConfig ??
          const <String, Object?>{},
      knownInstanceNames: knownInstanceNames,
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
    _cancelActiveVpnRefresh();
    await _methodChannel.invokeMethod<void>('stopVpn');
    _pendingVpnPayloads.remove(instanceKey);
  }

  String _instanceNameFromPayload(Map<String, Object?> payloadMap) {
    return _readString(
      payloadMap['instance_name'] ??
          payloadMap['instanceName'] ??
          payloadMap['network_name'] ??
          payloadMap['networkName'],
    );
  }

  String _instanceIdFromPayload(Map<String, Object?> payloadMap) {
    return _readString(
      payloadMap['instance_id'] ?? payloadMap['instanceId'] ?? payloadMap['id'],
    );
  }

  void _emitVpnError(Object error, StackTrace stackTrace) {
    if (_disposed) {
      return;
    }
    _events.add(
      CoreRuntimeEvent(
        type: CoreRuntimeEventTypes.error,
        data: {'error': error.toString(), 'stack': stackTrace.toString()},
      ),
    );
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
    return value is Map ? _stringObjectMap(value) : null;
  }

  static List<Object?> _readList(Object? value) {
    if (value is List) {
      return value;
    }
    if (value is String && value.trim().isNotEmpty) {
      return <Object?>[value.trim()];
    }
    return const <Object?>[];
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
      for (final key in const <String>['route', 'route_info', 'routeInfo']) {
        final nested = map[key];
        if (nested is Map) {
          _addRouteCidrsFromValue(cidrs, nested);
        }
      }
      final cidr = _cidrFromValue(map);
      if (cidr.isNotEmpty) {
        cidrs.add(_routeCidr(cidr));
      }
      for (final key in const <String>[
        'proxy_cidrs',
        'proxyCidrs',
        'proxy_cidr',
        'proxyCidr',
        'subnet_cidrs',
        'subnetCidrs',
        'subnet_routes',
        'subnetRoutes',
        'subnets',
        'subnet',
      ]) {
        cidrs.addAll(_readCidrList(map[key]).map(_routeCidr));
      }
      return;
    }

    final cidr = _cidrFromValue(value);
    if (cidr.isNotEmpty) {
      cidrs.add(_routeCidr(cidr));
    }
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
    final nested = _readMap(json['vpn_config'] ?? json['vpnConfig']);
    if (nested != null) {
      final nestedConfig = buildVpnConfigFromNetworkInfo(nested);
      if (_vpnConfigHasAddressStatic(nestedConfig)) {
        return nestedConfig;
      }
    }

    final myNodeInfo = _readMap(json['my_node_info'] ?? json['myNodeInfo']);
    final addresses = <String>{
      if (myNodeInfo != null)
        ..._readCidrList(
          myNodeInfo['virtual_ipv4'] ?? myNodeInfo['virtualIpv4'],
        ),
      ..._readCidrList(json['addresses']),
      ..._readCidrList(json['address']),
      ..._readCidrList(json['ipv4']),
      ..._readCidrList(json['ipv4_addr']),
      ..._readCidrList(json['ipv4_address']),
      ..._readCidrList(json['ipv4Address']),
      ..._readCidrList(json['virtual_ip']),
      ..._readCidrList(json['virtualIp']),
      ..._readCidrList(json['virtual_ipv4']),
      ..._readCidrList(json['virtualIpv4']),
      ..._readCidrList(json['cidr']),
      ..._readCidrList(json['ip_cidr']),
      ..._readCidrList(json['ipv4_cidr']),
      ..._readCidrList(json['ipv4Cidr']),
    };

    final routes = <String>{
      ..._networkRoutesFromAddressCidrs(addresses),
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
      ..._readRouteCidrs(json['subnet_cidrs']),
      ..._readRouteCidrs(json['subnetCidrs']),
      ..._readRouteCidrs(json['subnet_routes']),
      ..._readRouteCidrs(json['subnetRoutes']),
    }..removeWhere((value) => value.isEmpty);

    final dns = <String>{
      ..._readStringList(json['dns']),
      ..._readStringList(json['dns_servers']),
      ..._readStringList(json['dnsServers']),
    };

    final disallowedApplications = <String>{
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
    final mtu = json['mtu'];
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

  static bool _vpnConfigHasAddressStatic(Map<String, Object?> config) {
    return _readString(config['address']).isNotEmpty ||
        _readString(config['ipv4']).isNotEmpty ||
        _readString(config['virtual_ip']).isNotEmpty ||
        _readString(config['cidr']).isNotEmpty ||
        _readString(config['ipv4_cidr']).isNotEmpty ||
        _readList(config['addresses']).isNotEmpty;
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
        peer['rx_bytes'] ?? peer['rxBytes'] ?? peer['received_bytes'],
      );
      final txBytes = _readTrafficBytes(
        peer['tx_bytes'] ?? peer['txBytes'] ?? peer['transmitted_bytes'],
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

    void collect(Object? value, {String? nameHint}) {
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
        map['network_name'],
        map['networkName'],
        map['runtime_network_name'],
        map['name'],
      ]);
      final name = explicitName ?? nameHint?.trim();
      if (name != null && name.isNotEmpty && _looksLikeInstanceMap(map)) {
        final instance = AndroidNetworkInstanceInfo.fromJson(map, name: name);
        instances[instance.name] = instance;
      }

      for (final entry in map.entries) {
        final key = entry.key;
        final child = entry.value;
        if (_containerKeys.contains(key)) {
          collect(child);
        } else if (child is Map) {
          collect(child, nameHint: key);
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
      myNodeInfo['virtual_ipv4'] ?? myNodeInfo['virtualIpv4'],
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
      'rx_bytes': _firstScalarString([stats?['rx_bytes'], stats?['rxBytes']]),
      'tx_bytes': _firstScalarString([stats?['tx_bytes'], stats?['txBytes']]),
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
    final latencyFirst = _firstScalarString([
      route['cost_latency_first'],
      route['costLatencyFirst'],
    ]);
    if (latencyFirst != null) {
      return latencyFirst;
    }
    return _firstScalarString([route['cost']]) ?? '';
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

class _ResolvedAndroidVpnTarget {
  const _ResolvedAndroidVpnTarget({
    required this.instanceName,
    required this.instanceId,
    required this.vpnConfig,
    required this.knownInstanceNames,
  });

  final String instanceName;
  final String? instanceId;
  final Map<String, Object?> vpnConfig;
  final List<String> knownInstanceNames;
}
