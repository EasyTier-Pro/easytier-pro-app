part of 'core_lifecycle_service.dart';

class AndroidCoreRuntime extends CorePlatformRuntime {
  AndroidCoreRuntime({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    this._networkInfoCacheDuration = const Duration(seconds: 5),
  }) : _methodChannel = methodChannel ?? const MethodChannel(_methodName),
       _eventChannel = eventChannel ?? const EventChannel(_eventName) {
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

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Duration _networkInfoCacheDuration;
  final StreamController<CoreRuntimeEvent> _events =
      StreamController<CoreRuntimeEvent>.broadcast();

  late final StreamSubscription<dynamic> _nativeEvents;
  String? _cachedNetworkInfos;
  DateTime? _cachedNetworkInfosAt;
  Future<String>? _networkInfoInFlight;
  Future<void> _vpnSerial = Future<void>.value();
  final Map<String, Map<String, Object?>> _pendingVpnPayloads =
      <String, Map<String, Object?>>{};
  String? _activeVpnInstanceName;
  bool _vpnPrepared = false;

  @override
  Stream<CoreRuntimeEvent> get events => _events.stream;

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

    await _methodChannel.invokeMethod<void>('startConfigServerClient', {
      'url': fullUrl,
      'hostname': hostname,
      'machineId': machineId,
      'secureMode': true,
    });

    await _prepareNotifications();

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
    await _ignoreMissingJni(
      _methodChannel.invokeMethod<void>('stopConfigServerClient'),
    );
    await _methodChannel.invokeMethod<void>('stopVpn');
    _cachedNetworkInfos = null;
    _cachedNetworkInfosAt = null;
    _pendingVpnPayloads.clear();
    _activeVpnInstanceName = null;
  }

  @override
  Future<Map<String, CoreNetworkTrafficTotals>>
  readNetworkTrafficTotals() async {
    // Android JNI does not yet expose a stats API equivalent to `easytier-cli stats`.
    return const <String, CoreNetworkTrafficTotals>{};
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
    final runtimeEvent = _runtimeEventFromNative(event);
    _events.add(runtimeEvent);
    if (runtimeEvent.type == CoreRuntimeEventTypes.vpnPermissionGranted) {
      _vpnPrepared = true;
      unawaited(_startPendingVpns());
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

    final instanceName = _readString(
      payloadMap['instance_name'] ??
          payloadMap['instanceName'] ??
          payloadMap['network_name'] ??
          payloadMap['networkName'],
    );
    if (instanceName.isEmpty) {
      return;
    }

    if (eventName == 'delete_network_instance') {
      unawaited(_queueVpnStop(instanceName));
      return;
    }

    _pendingVpnPayloads[instanceName] = payloadMap;
    unawaited(_queueVpnStart(instanceName));
  }

  Map<String, Object?> _configServerPayloadFromEvent(
    Map<String, Object?> data,
  ) {
    final outer = data['payload'];
    final outerMap = outer is Map ? _stringObjectMap(outer) : data;
    final inner = outerMap['payload'];
    return inner is Map ? _stringObjectMap(inner) : outerMap;
  }

  Future<void> _queueVpnStart(String instanceName) {
    _vpnSerial = _vpnSerial
        .then(
          (_) => _startVpnForInstance(instanceName),
          onError: (Object error, StackTrace stackTrace) =>
              _startVpnForInstance(instanceName),
        )
        .catchError(_emitVpnError);
    return _vpnSerial;
  }

  Future<void> _queueVpnStop(String instanceName) {
    _vpnSerial = _vpnSerial
        .then(
          (_) => _stopActiveVpn(instanceName),
          onError: (Object error, StackTrace stackTrace) =>
              _stopActiveVpn(instanceName),
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

  Future<void> _startVpnForInstance(String instanceName) async {
    final payloadMap = _pendingVpnPayloads[instanceName];
    if (payloadMap == null) {
      return;
    }
    if (!_vpnPrepared) {
      return;
    }

    final vpnConfig = await _resolveVpnConfig(instanceName, payloadMap);
    if (!_vpnConfigHasAddress(vpnConfig)) {
      _events.add(
        CoreRuntimeEvent(
          type: CoreRuntimeEventTypes.error,
          data: {
            'error': 'Android VPN 缺少 $instanceName 的虚拟 IP 配置',
            'instance_name': instanceName,
          },
        ),
      );
      return;
    }

    final active = _activeVpnInstanceName;
    if (active != null && active != instanceName) {
      await _methodChannel.invokeMethod<void>('stopVpn');
    }
    await _ignoreMissingJni(
      _methodChannel.invokeMethod<void>('retainNetworkInstance', {
        'instanceNames': <String>[instanceName],
      }),
    );
    await _methodChannel.invokeMethod<void>('startVpn', {
      'instanceName': instanceName,
      'vpnConfig': vpnConfig,
    });
    _activeVpnInstanceName = instanceName;
    _pendingVpnPayloads.remove(instanceName);
  }

  Future<Map<String, Object?>> _resolveVpnConfig(
    String instanceName,
    Map<String, Object?> payloadMap,
  ) async {
    final direct = _readMap(
      payloadMap['vpn_config'] ?? payloadMap['vpnConfig'],
    );
    if (direct != null && _vpnConfigHasAddress(direct)) {
      return direct;
    }

    for (var attempt = 0; attempt < 5; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      _cachedNetworkInfosAt = null;
      final snapshot = await _readNetworkInfoSnapshot();
      final instance = snapshot.instanceNamed(instanceName);
      final config = instance?.vpnConfig;
      if (config != null && _vpnConfigHasAddress(config)) {
        return config;
      }
    }
    return direct ?? const <String, Object?>{};
  }

  Future<void> _stopActiveVpn(String instanceName) async {
    if (_activeVpnInstanceName != instanceName) {
      _pendingVpnPayloads.remove(instanceName);
      return;
    }
    await _methodChannel.invokeMethod<void>('stopVpn');
    _activeVpnInstanceName = null;
    _pendingVpnPayloads.remove(instanceName);
  }

  void _emitVpnError(Object error, StackTrace stackTrace) {
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
      final cidr = _firstNonEmptyString([
        map['cidr'],
        map['ipv4_cidr'],
        map['ipv4Cidr'],
        map['destination'],
        map['dest'],
        map['address'],
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

  static Map<String, Object?> buildVpnConfigFromNetworkInfo(
    Map<String, Object?> json,
  ) {
    final addresses = <String>{
      ..._readCidrList(json['addresses']),
      ..._readCidrList(json['address']),
      ..._readCidrList(json['ipv4']),
      ..._readCidrList(json['ipv4_addr']),
      ..._readCidrList(json['ipv4Address']),
      ..._readCidrList(json['virtual_ip']),
      ..._readCidrList(json['virtualIp']),
      ..._readCidrList(json['cidr']),
      ..._readCidrList(json['ipv4_cidr']),
      ..._readCidrList(json['ipv4Cidr']),
    };

    final routes = <String>{
      ..._readCidrList(json['routes']),
      ..._readCidrList(json['route']),
      ..._readCidrList(json['ipv4_routes']),
      ..._readCidrList(json['ipv4Routes']),
      ..._readCidrList(json['peer_routes']),
      ..._readCidrList(json['peerRoutes']),
      for (final pair in _readList(json['peer_route_pairs']))
        _cidrFromValue(pair),
      for (final pair in _readList(json['peerRoutePairs']))
        _cidrFromValue(pair),
    }..removeWhere((value) => value.isEmpty);

    final dns = <String>{
      ..._readStringList(json['dns']),
      ..._readStringList(json['dns_servers']),
      ..._readStringList(json['dnsServers']),
    };

    final config = <String, Object?>{
      'addresses': addresses.toList(growable: false),
      'routes': routes.toList(growable: false),
      'dns': dns.toList(growable: false),
    };
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

    copyIfMissing('ipv4', ['ip', 'ipv4_addr', 'virtual_ip', 'address']);
    copyIfMissing('cidr', ['ipv4_cidr', 'virtual_ip_cidr']);
    copyIfMissing('hostname', ['host_name', 'name']);
    copyIfMissing('lat_ms', ['latency_ms', 'latency', 'latency_text']);
    copyIfMissing('loss_rate', ['loss', 'packet_loss']);
    copyIfMissing('rx_bytes', ['rx', 'received_bytes']);
    copyIfMissing('tx_bytes', ['tx', 'transmitted_bytes']);
    copyIfMissing('tunnel_proto', ['tunnel_protocol', 'proto']);
    copyIfMissing('nat_type', ['nat']);
    copyIfMissing('peer_id', ['id']);
    return normalized;
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
  };

  static bool _looksLikeInstanceMap(Map<String, Object?> map) {
    return map.containsKey('running') ||
        map.containsKey('is_running') ||
        map.containsKey('state') ||
        map.containsKey('status') ||
        map.containsKey('error') ||
        map.containsKey('last_error') ||
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
    this.error,
    this.vpnConfig,
    this.peers = const <Map<String, dynamic>>[],
  });

  final String name;
  final bool running;
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
    const peerKeys = <String>[
      'peers',
      'peer_infos',
      'peerInfos',
      'peer_list',
      'peerList',
      'peer_route_pairs',
      'peerRoutePairs',
    ];
    final peers = <Map<String, dynamic>>[];
    for (final key in peerKeys) {
      final value = json[key];
      if (value is List) {
        for (final item in value) {
          if (item is Map) {
            final map = _stringObjectMap(item);
            final peer = map['peer'];
            peers.add(peer is Map ? _stringDynamicMap(peer) : map);
          }
        }
      }
    }
    return peers;
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
