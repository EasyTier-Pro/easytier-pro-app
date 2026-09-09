part of 'console_auth_service.dart';

const _deviceAuthAppReturnUri = 'easytierpro://auth/device-complete';
const _deviceAuthFastPollIntervalSeconds = 1;
const _deviceAuthFastPollAttemptLimit = 20;

class ConsoleAuthService implements AuthService, RefreshableAuthService {
  ConsoleAuthService({
    required this.tokenStore,
    http.Client? httpClient,
    this.consoleBaseUrl = defaultConsoleBaseUrl,
  }) : _httpClient = httpClient ?? http.Client();

  final OAuthTokenStore tokenStore;
  final http.Client _httpClient;
  final String consoleBaseUrl;
  final AppLogger _logger = AppLogger.instance;
  final StreamController<SessionExpiredException> _sessionExpirations =
      StreamController<SessionExpiredException>.broadcast();
  TokenSet? _activeTokenSet;
  final Set<String> _activeAccessTokens = <String>{};
  Future<TokenSet>? _tokenRefreshInFlight;
  int _authGeneration = 0;

  @override
  Stream<SessionExpiredException> get sessionExpirations =>
      _sessionExpirations.stream;

  @override
  Future<AuthSession?> restoreSession() async {
    _logger.info('auth', 'Restoring local session');
    final storedTokenSet = await tokenStore.load();
    if (storedTokenSet == null) {
      return null;
    }
    _activateStoredTokenSet(storedTokenSet);

    try {
      final tokenSet = await _ensureFreshToken(storedTokenSet);
      final user = await _fetchCurrentUser(tokenSet.accessToken);
      _logger.info(
        'auth',
        'Session restored',
        context: {'workspace_count': user.workspaces.length},
      );
      return AuthSession(user: user, tokenSet: tokenSet);
    } on SessionExpiredException {
      _logger.warn('auth', 'Stored refresh token is no longer valid');
      await _clearActiveTokenSet();
      return null;
    } on _TokenRefreshException {
      rethrow;
    } on _ConsoleNetworkException {
      rethrow;
    } on AuthException {
      _logger.warn('auth', 'Stored session invalid, clearing local token');
      await _clearActiveTokenSet();
      return null;
    }
  }

  @override
  Future<DeviceAuthInfo> startDeviceAuth() async {
    _logger.info('auth', 'Starting device authorization');
    final requestBody = <String, String>{
      'client_id': '',
      'scope': 'openid profile email',
    };
    if (_shouldRequestDeviceAuthAppReturnUri()) {
      requestBody['app_return_uri'] = _deviceAuthAppReturnUri;
    }

    final response = await _post(
      Uri.parse('$consoleBaseUrl/api/v1/auth/device'),
      operation: 'startDeviceAuth',
      body: requestBody,
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('获取登录验证码失败：${_extractErrorMessage(response.body)}');
    }

    final body = _decodeObject(response.body);
    final verificationUri = _stripCancelToken(
      body['verification_uri']?.toString() ?? '',
    );
    final verificationUriComplete =
        (body['verification_uri_complete']?.toString().isNotEmpty ?? false)
        ? body['verification_uri_complete'].toString()
        : verificationUri;

    return DeviceAuthInfo(
      deviceCode: body['device_code']?.toString() ?? '',
      userCode: body['user_code']?.toString() ?? '',
      verificationUri: verificationUri,
      verificationUriComplete: verificationUriComplete,
      expiresIn: (body['expires_in'] as num?)?.toInt() ?? 600,
      interval: ((body['interval'] as num?)?.toInt() ?? 5).clamp(5, 600),
    );
  }

  @override
  Future<AuthSession> completeDeviceAuth(DeviceAuthInfo info) async {
    _logger.info('auth', 'Waiting for device authorization approval');
    final deadline = DateTime.now().toUtc().add(
      Duration(seconds: info.expiresIn),
    );
    var intervalSeconds = info.interval;
    var delaySeconds = 0;
    var fastPollAttemptsRemaining = _deviceAuthFastPollAttemptLimit;
    var firstAttempt = true;

    while (DateTime.now().toUtc().isBefore(deadline)) {
      if (firstAttempt) {
        firstAttempt = false;
      } else {
        await Future<void>.delayed(Duration(seconds: delaySeconds));
      }

      final response = await _post(
        Uri.parse('$consoleBaseUrl/api/v1/auth/device/token'),
        operation: 'completeDeviceAuth',
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': info.deviceCode,
          'client_id': '',
        },
      );

      if (response.statusCode.toString().startsWith('2')) {
        final body = _decodeObject(response.body);
        final tokenSet = TokenSet(
          accessToken: body['access_token']?.toString() ?? '',
          idToken: body['id_token']?.toString(),
          refreshToken: body['refresh_token']?.toString(),
          tokenType: body['token_type']?.toString() ?? 'Bearer',
          expiresIn: (body['expires_in'] as num?)?.toInt() ?? 3600,
          obtainedAt: DateTime.now().toUtc(),
        );

        await _saveNewTokenSet(tokenSet);
        final user = await _fetchCurrentUser(tokenSet.accessToken);
        _logger.info(
          'auth',
          'Device authorization completed',
          context: {'workspace_count': user.workspaces.length},
        );
        return AuthSession(user: user, tokenSet: tokenSet);
      }

      final body = _tryDecodeObject(response.body);
      final error = body?['error']?.toString() ?? 'unknown_error';
      final description =
          body?['error_description']?.toString() ??
          body?['description']?.toString() ??
          _extractErrorMessage(response.body);

      switch (error) {
        case 'authorization_pending':
          if (fastPollAttemptsRemaining > 0) {
            fastPollAttemptsRemaining--;
            delaySeconds = _deviceAuthFastPollIntervalSeconds < intervalSeconds
                ? _deviceAuthFastPollIntervalSeconds
                : intervalSeconds;
          } else {
            delaySeconds = intervalSeconds;
          }
          continue;
        case 'slow_down':
          fastPollAttemptsRemaining = 0;
          intervalSeconds += ((body?['interval'] as num?)?.toInt() ?? 5);
          delaySeconds = intervalSeconds;
          continue;
        case 'expired_token':
          throw const AuthException('登录验证码已过期，请重新发起登录。');
        case 'access_denied':
          throw const AuthException('用户拒绝了授权，请重新登录。');
        default:
          throw AuthException('登录失败：$description');
      }
    }

    throw const AuthException('登录超时，请重新发起设备登录。');
  }

  @override
  Future<void> logout() async {
    _logger.info('auth', 'Clearing local auth token');
    await _clearActiveTokenSet();
  }

  @override
  Future<AuthSession> refreshSession(
    AuthSession session, {
    bool force = false,
  }) async {
    final tokenSet = await _ensureFreshToken(session.tokenSet, force: force);
    return AuthSession(user: session.user, tokenSet: tokenSet);
  }

  @override
  Future<List<ConsoleNetwork>> fetchNetworks({
    required String accessToken,
    required String workspaceId,
  }) async {
    final response = await _get(
      Uri.parse('$consoleBaseUrl/api/v1/tenants/$workspaceId/networks'),
      operation: 'fetchNetworks',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '读取网络列表失败');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map(_networkFromJson)
        .whereType<ConsoleNetwork>()
        .toList(growable: false);
  }

  @override
  Future<List<ConsoleRegion>> fetchRegions({
    required String accessToken,
  }) async {
    final response = await _get(
      Uri.parse('$consoleBaseUrl/api/v1/regions'),
      operation: 'fetchRegions',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '读取区域列表失败');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map((item) {
          final id = item['id']?.toString() ?? item['code']?.toString() ?? '';
          final code = item['code']?.toString() ?? '';
          final displayName =
              item['display_name']?.toString() ??
              item['name']?.toString() ??
              code;
          final status =
              item['status']?.toString() ??
              (item['active'] == true ? 'active' : '');
          if (id.isEmpty || code.isEmpty) {
            return null;
          }
          return ConsoleRegion(
            id: id,
            code: code,
            displayName: displayName,
            status: status,
          );
        })
        .whereType<ConsoleRegion>()
        .toList(growable: false);
  }

  @override
  Future<ConsoleNetwork> createNetwork({
    required String accessToken,
    required String workspaceId,
    required String name,
    required List<String> regions,
    String? ipv4Cidr,
  }) async {
    final body = <String, Object?>{'name': name, 'regions': regions};
    final trimmedIPv4Cidr = ipv4Cidr?.trim();
    if (trimmedIPv4Cidr != null && trimmedIPv4Cidr.isNotEmpty) {
      body['ipv4_cidr'] = trimmedIPv4Cidr;
    }

    final response = await _post(
      Uri.parse('$consoleBaseUrl/api/v1/tenants/$workspaceId/networks'),
      operation: 'createNetwork',
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '创建网络失败');
    }

    final network = _networkFromJson(_decodeObject(response.body));
    if (network == null) {
      throw const AuthException('创建网络后服务端返回了无法识别的数据格式。');
    }
    return network;
  }

  @override
  Future<void> deleteNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    final response = await _delete(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/networks/$networkId',
      ),
      operation: 'deleteNetwork',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '删除网络失败');
    }
  }

  static ConsoleNetwork? _networkFromJson(Map<String, dynamic> item) {
    final id = item['id']?.toString() ?? '';
    final runtimeNetworkName = item['network_name']?.toString().trim() ?? '';
    final name = item['name']?.toString() ?? runtimeNetworkName;
    if (id.isEmpty || name.isEmpty) {
      return null;
    }
    final rawRegions = item['regions'];
    final regions = rawRegions is List<dynamic>
        ? rawRegions.map((region) => region.toString()).toList(growable: false)
        : const <String>[];
    return ConsoleNetwork(
      id: id,
      name: name,
      regions: regions,
      ipv4Cidr: item['ipv4_cidr']?.toString() ?? '',
      runtimeNetworkName: runtimeNetworkName,
      lifecycleState: item['lifecycle_state']?.toString() ?? '',
    );
  }

  static String _firstNonEmptyString(Iterable<Object?> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  static List<String> _readStringList(Object? value) {
    if (value is List<dynamic>) {
      return value
          .map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  static String? _nullableTrimmedString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static int? _readIntValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) {
      return null;
    }
    return int.tryParse(text);
  }

  static bool? _readBool(Object? value) {
    if (value is bool) {
      return value;
    }
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text == 'true') {
      return true;
    }
    if (text == 'false') {
      return false;
    }
    return null;
  }

  @override
  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  }) async {
    final response = await _get(
      Uri.parse('$consoleBaseUrl/api/v1/tenants/$workspaceId/devices'),
      operation: 'fetchManagedDevices',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '读取设备列表失败');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map((item) {
          final id = item['id']?.toString() ?? '';
          final machineId = item['machine_id']?.toString() ?? '';
          if (id.isEmpty || machineId.isEmpty) {
            return null;
          }
          final displayName = _firstNonEmptyString([
            item['display_name'],
            item['displayName'],
          ]);
          final hostname = _firstNonEmptyString([item['hostname'], machineId]);
          return ManagedDevice(
            id: id,
            machineId: machineId,
            hostname: hostname,
            displayName: displayName,
            approvalState: item['approval_state']?.toString() ?? '',
            connectivityState: item['connectivity_state']?.toString() ?? '',
            os: item['os']?.toString() ?? item['os_type']?.toString() ?? '',
            osVersion: item['os_version']?.toString() ?? '',
            osDistribution: item['os_distribution']?.toString() ?? '',
            lifecycleState: item['lifecycle_state']?.toString() ?? '',
            desiredState: item['desired_state']?.toString() ?? '',
          );
        })
        .whereType<ManagedDevice>()
        .where((device) => !device.removed)
        .toList(growable: false);
  }

  @override
  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    final response = await _get(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/networks/$networkId/nodes',
      ),
      operation: 'fetchNetworkDevices',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '读取设备列表失败');
    }

    final items = _decodeObjectOrList(response.body);
    return items
        .map((item) {
          final id = item['id']?.toString() ?? '';
          if (id.isEmpty) {
            return null;
          }
          final rawDevice = item['device'];
          final device = rawDevice is Map<String, dynamic>
              ? rawDevice
              : rawDevice is Map
              ? Map<String, dynamic>.from(rawDevice)
              : null;
          final hostname = _firstNonEmptyString([
            item['hostname'],
            device?['hostname'],
          ]);
          final rawName = _firstNonEmptyString([
            item['display_name'],
            item['displayName'],
            item['device_display_name'],
            item['deviceDisplayName'],
            device?['display_name'],
            device?['displayName'],
            item['name'],
            item['device_name'],
            item['deviceName'],
            device?['name'],
            device?['hostname'],
            item['hostname'],
            item['machine_id'],
            device?['machine_id'],
            id,
          ]);
          final status =
              item['status']?.toString() ??
              item['connectivity_state']?.toString() ??
              item['state']?.toString() ??
              device?['connectivity_state']?.toString() ??
              '';
          final online =
              status.toLowerCase() == 'online' ||
              status.toLowerCase() == 'connected';
          final ipv4 =
              item['ipv4_addr']?.toString() ??
              item['ipv4']?.toString() ??
              item['ip']?.toString();
          final deviceId =
              item['device_id']?.toString() ?? device?['id']?.toString();
          final machineId =
              item['machine_id']?.toString() ??
              device?['machine_id']?.toString();
          final os =
              item['os']?.toString() ??
              item['os_type']?.toString() ??
              device?['os']?.toString() ??
              device?['os_type']?.toString() ??
              '';
          final osVersion =
              item['os_version']?.toString() ??
              device?['os_version']?.toString() ??
              '';
          final osDistribution =
              item['os_distribution']?.toString() ??
              device?['os_distribution']?.toString() ??
              '';
          final desiredState = item['desired_state']?.toString() ?? '';
          final lifecycleState = item['lifecycle_state']?.toString() ?? '';

          return NetworkDevice(
            id: id,
            name: rawName,
            online: online,
            hostname: hostname,
            ipv4: ipv4,
            deviceId: deviceId == null || deviceId.isEmpty ? null : deviceId,
            machineId: machineId == null || machineId.isEmpty
                ? null
                : machineId,
            os: os,
            osVersion: osVersion,
            osDistribution: osDistribution,
            connectivityState: status,
            desiredState: desiredState,
            lifecycleState: lifecycleState,
          );
        })
        .whereType<NetworkDevice>()
        .toList(growable: false);
  }

  @override
  Future<NetworkSubnetRouteList> fetchNetworkSubnetRoutes({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  }) async {
    final response = await _get(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/networks/$networkId/subnet-routes',
      ),
      operation: 'fetchNetworkSubnetRoutes',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '读取子网路由列表失败');
    }

    return _subnetRouteListFromJson(_decodeObject(response.body));
  }

  @override
  Future<NodeInstanceConfigView> fetchNodeConfig({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  }) async {
    final response = await _get(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/nodes/$nodeId/config',
      ),
      operation: 'fetchNodeConfig',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '读取本机网络设置失败');
    }

    return _nodeConfigFromJson(_decodeObject(response.body));
  }

  static NetworkSubnetRouteList _subnetRouteListFromJson(
    Map<String, dynamic> json,
  ) {
    final rawRoutes = json['routes'];
    final routes = rawRoutes is List<dynamic>
        ? rawRoutes
              .whereType<Map<String, dynamic>>()
              .map(_subnetRouteFromJson)
              .whereType<NetworkSubnetRoute>()
              .toList(growable: false)
        : const <NetworkSubnetRoute>[];

    return NetworkSubnetRouteList(
      routes: routes,
      allowedProxyCidrs: _readStringList(json['allowed_proxy_cidrs']),
      quotaLimit: _readIntValue(json['quota_limit']) ?? 0,
      quotaUsed: _readIntValue(json['quota_used']) ?? 0,
    );
  }

  static NetworkSubnetRoute? _subnetRouteFromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final cidr = json['cidr']?.toString() ?? '';
    if (id.isEmpty || cidr.isEmpty) {
      return null;
    }

    final rawNodes = json['nodes'];
    final rawManualNodes = json['manual_route_nodes'];
    return NetworkSubnetRoute(
      id: id,
      cidr: cidr,
      mappedCidr: _nullableTrimmedString(json['mapped_cidr']),
      nodeIds: _readStringList(json['node_ids']),
      nodes: rawNodes is List<dynamic>
          ? rawNodes
                .whereType<Map<String, dynamic>>()
                .map(_subnetRouteNodeSummaryFromJson)
                .whereType<SubnetRouteNodeSummary>()
                .toList(growable: false)
          : const <SubnetRouteNodeSummary>[],
      manualRouteNodeIds: _readStringList(json['manual_route_node_ids']),
      manualRouteNodes: rawManualNodes is List<dynamic>
          ? rawManualNodes
                .whereType<Map<String, dynamic>>()
                .map(_subnetRouteNodeSummaryFromJson)
                .whereType<SubnetRouteNodeSummary>()
                .toList(growable: false)
          : const <SubnetRouteNodeSummary>[],
    );
  }

  static SubnetRouteNodeSummary? _subnetRouteNodeSummaryFromJson(
    Map<String, dynamic> json,
  ) {
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) {
      return null;
    }

    return SubnetRouteNodeSummary(
      id: id,
      hostname: json['hostname']?.toString() ?? '',
      machineId: json['machine_id']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      provisioningState: json['provisioning_state']?.toString() ?? '',
    );
  }

  static NodeInstanceConfigView _nodeConfigFromJson(Map<String, dynamic> json) {
    final rawAssigned = json['assigned_subnet_routes'];
    final rawManual = json['manual_subnet_routes'];
    return NodeInstanceConfigView(
      defaults: _nodeConfigSettingsFromJson(json['defaults']),
      overrides: _nodeConfigSettingsFromJson(json['override']),
      effective: _nodeConfigSettingsFromJson(json['effective']),
      configScope: json['config_scope']?.toString() ?? '',
      applyStatus: json['apply_status']?.toString() ?? '',
      driftStatus: json['drift_status']?.toString() ?? '',
      lastAppliedAt: _nullableTrimmedString(json['last_applied_at']),
      lastApplyError: _nullableTrimmedString(json['last_apply_error']),
      assignedSubnetRoutes: rawAssigned is List<dynamic>
          ? rawAssigned
                .whereType<Map<String, dynamic>>()
                .map(_assignedSubnetRouteFromJson)
                .whereType<AssignedSubnetRoute>()
                .toList(growable: false)
          : const <AssignedSubnetRoute>[],
      manualSubnetRoutes: rawManual is List<dynamic>
          ? rawManual
                .whereType<Map<String, dynamic>>()
                .map(_assignedSubnetRouteFromJson)
                .whereType<AssignedSubnetRoute>()
                .toList(growable: false)
          : const <AssignedSubnetRoute>[],
      manualRoutesEnabled: _readBool(json['manual_routes_enabled']) ?? false,
    );
  }

  static NodeInstanceConfigSettings _nodeConfigSettingsFromJson(Object? value) {
    final json = value is Map<String, dynamic>
        ? value
        : value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};

    return NodeInstanceConfigSettings(
      ipv4: _nullableTrimmedString(json['ipv4']),
      hostname: _nullableTrimmedString(json['hostname']),
      kcpProxyEnabled: _readBool(json['kcp_proxy_enabled']),
      kcpInputEnabled: _readBool(json['kcp_input_enabled']),
      quicProxyEnabled: _readBool(json['quic_proxy_enabled']),
      quicInputEnabled: _readBool(json['quic_input_enabled']),
      noTun: _readBool(json['no_tun']),
      holePunchUdpEnabled: _readBool(json['hole_punch_udp_enabled']),
      holePunchTcpEnabled: _readBool(json['hole_punch_tcp_enabled']),
      disableSymHolePunching: _readBool(json['disable_sym_hole_punching']),
      p2pMode: _nullableTrimmedString(json['p2p_mode']),
      proxyForwardBySystem: _readBool(json['proxy_forward_by_system']),
      lazyP2p: _readBool(json['lazy_p2p']),
      needP2p: _readBool(json['need_p2p']),
      magicDnsEnabled: _readBool(json['magic_dns_enabled']),
      latencyFirst: _readBool(json['latency_first']),
      userspaceStack: _readBool(json['userspace_stack']),
      listenerProtocols: _readStringList(json['listener_protocols']),
    );
  }

  static AssignedSubnetRoute? _assignedSubnetRouteFromJson(
    Map<String, dynamic> json,
  ) {
    final id = json['id']?.toString() ?? '';
    final cidr = json['cidr']?.toString() ?? '';
    if (id.isEmpty || cidr.isEmpty) {
      return null;
    }
    return AssignedSubnetRoute(
      id: id,
      cidr: cidr,
      mappedCidr: _nullableTrimmedString(json['mapped_cidr']),
    );
  }

  @override
  Future<AttachNetworkResult> attachDeviceToNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
    required String deviceId,
  }) async {
    final response = await _post(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/networks/$networkId/nodes',
      ),
      operation: 'attachDeviceToNetwork',
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'device_id': deviceId}),
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '加入网络失败');
    }

    final body = _decodeObject(response.body);
    final resource =
        (body['resource'] as Map<String, dynamic>?) ??
        (body['node'] as Map<String, dynamic>?) ??
        body;
    final nodeId = resource['id']?.toString() ?? '';
    if (nodeId.isEmpty) {
      throw const AuthException('加入网络后服务端返回了无法识别的数据格式。');
    }
    final operation = body['operation'] as Map<String, dynamic>?;
    return AttachNetworkResult(
      nodeId: nodeId,
      operationId: operation?['id']?.toString(),
    );
  }

  @override
  Future<void> removeNetworkNode({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  }) async {
    final response = await _post(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/nodes/$nodeId/remove',
      ),
      operation: 'removeNetworkNode',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw _authAwareException(response, '退出网络失败');
    }
  }

  @override
  Future<String> fetchRecommendedCoreVersion({
    required String accessToken,
    required String workspaceId,
  }) async {
    _logger.info(
      'auth.bootstrap',
      'Fetching recommended core version',
      context: {'workspace_id': workspaceId},
    );
    final defaults = await fetchCoreBootstrapDefaults();
    return defaults.version;
  }

  @override
  Future<String> fetchLatestCoreVersion() {
    return fetchCoreBootstrapDefaults().then((defaults) => defaults.version);
  }

  @override
  Future<CoreBootstrapDefaults> fetchCoreBootstrapDefaults() async {
    final releaseBody = await _fetchLatestReleaseBody(
      operation: 'coreBootstrapDefaults.release',
    );
    return CoreBootstrapDefaults(
      version: _releaseVersionFromBody(releaseBody),
      configServer: _configServerFromReleaseBody(releaseBody),
    );
  }

  Future<Map<String, dynamic>> _fetchLatestReleaseBody({
    required String operation,
  }) async {
    final releaseResponse = await _get(
      Uri.parse('$consoleBaseUrl/api/v1/releases/latest'),
      operation: operation,
    );
    if (!releaseResponse.statusCode.toString().startsWith('2')) {
      throw AuthException(
        '读取版本信息失败：${_extractErrorMessage(releaseResponse.body)}',
      );
    }

    return _decodeObject(releaseResponse.body);
  }

  String _releaseVersionFromBody(Map<String, dynamic> releaseBody) {
    final stable =
        (releaseBody['stable'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final rawVersion =
        stable['version']?.toString() ??
        releaseBody['version']?.toString() ??
        '';
    if (rawVersion.trim().isEmpty) {
      _logger.error(
        'auth.bootstrap',
        'No release version available from console',
      );
      throw const AuthException('控制台未返回可用版本');
    }
    return rawVersion.startsWith('v') ? rawVersion : 'v$rawVersion';
  }

  String _configServerFromReleaseBody(Map<String, dynamic> releaseBody) {
    final configServerRaw =
        releaseBody['web_config_server_url']?.toString().trim() ?? '';
    return configServerRaw.isEmpty
        ? _fallbackConfigServerUrl()
        : configServerRaw;
  }

  @override
  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
  }) async {
    _logger.info(
      'auth.bootstrap',
      'Preparing core bootstrap payload',
      context: {'workspace_id': workspaceId},
    );
    final releaseBody = await _fetchLatestReleaseBody(
      operation: 'prepareCoreBootstrap.release',
    );
    final version = _releaseVersionFromBody(releaseBody);

    final keysResponse = await _get(
      Uri.parse(
        '$consoleBaseUrl/api/v1/tenants/$workspaceId/device-enrollment-keys',
      ),
      operation: 'prepareCoreBootstrap.keys',
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (!keysResponse.statusCode.toString().startsWith('2')) {
      throw _authAwareException(keysResponse, '读取注册密钥失败');
    }
    final keyItems = _decodeObjectOrList(keysResponse.body);
    final enrollmentKeyDisplayName = _enrollmentKeyDisplayName();
    final key = _platformEnrollmentKey(
      keyItems,
      displayName: enrollmentKeyDisplayName,
    );

    String bootstrapToken;
    if (key.isNotEmpty) {
      final keyId = key['id']!.toString();
      final secretResponse = await _get(
        Uri.parse(
          '$consoleBaseUrl/api/v1/tenants/$workspaceId/device-enrollment-keys/$keyId/secret',
        ),
        operation: 'prepareCoreBootstrap.keySecret',
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (secretResponse.statusCode.toString().startsWith('2')) {
        final secretBody = _decodeObject(secretResponse.body);
        bootstrapToken = secretBody['bootstrap_token']?.toString() ?? '';
      } else {
        bootstrapToken = '';
      }
    } else {
      bootstrapToken = '';
    }

    if (bootstrapToken.isEmpty) {
      _logger.info(
        'auth.bootstrap',
        'No platform enrollment key available, creating a new one',
        context: {'display_name': enrollmentKeyDisplayName},
      );
      final createResponse = await _post(
        Uri.parse(
          '$consoleBaseUrl/api/v1/tenants/$workspaceId/device-enrollment-keys',
        ),
        operation: 'prepareCoreBootstrap.createKey',
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'display_name': enrollmentKeyDisplayName,
          'reusable': true,
          'pre_approved': true,
        }),
      );
      if (!createResponse.statusCode.toString().startsWith('2')) {
        throw _authAwareException(createResponse, '创建注册密钥失败');
      }
      final createBody = _decodeObject(createResponse.body);
      bootstrapToken = createBody['bootstrap_token']?.toString() ?? '';
      if (bootstrapToken.isEmpty) {
        throw const AuthException('创建密钥后未返回 bootstrap_token');
      }
    }

    return CoreBootstrapConfig(
      bootstrapToken: bootstrapToken,
      version: version,
      configServer: _configServerFromReleaseBody(releaseBody),
    );
  }

  Future<http.Response> _get(
    Uri uri, {
    required String operation,
    Map<String, String>? headers,
  }) {
    return _request(
      operation: operation,
      uri: uri,
      headers: headers,
      send: (requestHeaders) => _httpClient.get(uri, headers: requestHeaders),
    );
  }

  Future<http.Response> _post(
    Uri uri, {
    required String operation,
    Map<String, String>? headers,
    Object? body,
  }) {
    return _request(
      operation: operation,
      uri: uri,
      headers: headers,
      send: (requestHeaders) =>
          _httpClient.post(uri, headers: requestHeaders, body: body),
    );
  }

  Future<http.Response> _delete(
    Uri uri, {
    required String operation,
    Map<String, String>? headers,
  }) {
    return _request(
      operation: operation,
      uri: uri,
      headers: headers,
      send: (requestHeaders) =>
          _httpClient.delete(uri, headers: requestHeaders),
    );
  }

  Future<http.Response> _request({
    required String operation,
    required Uri uri,
    required Map<String, String>? headers,
    required Future<http.Response> Function(Map<String, String>? headers) send,
  }) async {
    _logger.debug(
      'auth.http',
      'Console API request start',
      context: {'operation': operation, 'host': uri.host, 'path': uri.path},
    );

    try {
      var requestHeaders = await _freshAuthorizationHeaders(headers);
      final requestGeneration = _authGeneration;
      var response = await send(requestHeaders);
      final rejectedAccessToken = _bearerAccessToken(requestHeaders);
      if (response.statusCode == 401 && rejectedAccessToken != null) {
        try {
          final tokenSet = await _refreshAfterUnauthorized(
            rejectedAccessToken,
            requestGeneration,
          );
          if (requestGeneration != _authGeneration) {
            throw const AuthException('登录状态已更新，请重试。');
          }
          requestHeaders = _withAccessToken(
            requestHeaders,
            tokenSet.accessToken,
          );
          response = await send(requestHeaders);
        } on SessionExpiredException catch (error) {
          await _expireRequestSessionIfCurrent(
            error,
            requestGeneration: requestGeneration,
            rejectedAccessToken: rejectedAccessToken,
          );
          rethrow;
        }
      }
      _logger.debug(
        'auth.http',
        'Console API request completed',
        context: {
          'operation': operation,
          'host': uri.host,
          'path': uri.path,
          'status_code': response.statusCode,
        },
      );
      return response;
    } on http.ClientException catch (error) {
      _throwNetworkAuthException(operation, uri, error);
    } on SocketException catch (error) {
      _throwNetworkAuthException(operation, uri, error);
    } on IOException catch (error) {
      _throwNetworkAuthException(operation, uri, error);
    }
  }

  Future<Map<String, String>?> _freshAuthorizationHeaders(
    Map<String, String>? headers,
  ) async {
    final requestedAccessToken = _bearerAccessToken(headers);
    if (requestedAccessToken == null) {
      return headers;
    }
    final activeTokenSet = _activeTokenSet;
    if (activeTokenSet == null) {
      throw const SessionExpiredException();
    }
    if (!_activeAccessTokens.contains(requestedAccessToken)) {
      throw const AuthException('登录状态已更新，请重试。');
    }
    final tokenSet = await _ensureFreshToken(activeTokenSet);
    return _withAccessToken(headers, tokenSet.accessToken);
  }

  Future<TokenSet> _refreshAfterUnauthorized(
    String rejectedAccessToken,
    int requestGeneration,
  ) {
    if (requestGeneration != _authGeneration) {
      throw const AuthException('登录状态已更新，请重试。');
    }
    final tokenSet = _activeTokenSet;
    if (tokenSet == null) {
      throw const SessionExpiredException();
    }
    if (tokenSet.accessToken != rejectedAccessToken) {
      return Future<TokenSet>.value(tokenSet);
    }
    return _ensureFreshToken(tokenSet, force: true);
  }

  Future<TokenSet> _ensureFreshToken(TokenSet fallback, {bool force = false}) {
    final tokenSet = _activeTokenSet;
    if (tokenSet == null) {
      throw const SessionExpiredException();
    }
    if (!_activeAccessTokens.contains(fallback.accessToken)) {
      throw const AuthException('登录状态已更新，请重试。');
    }
    if (!force && !tokenSet.isExpired) {
      return Future<TokenSet>.value(tokenSet);
    }

    final refreshToken = tokenSet.refreshToken?.trim() ?? '';
    if (refreshToken.isEmpty) {
      throw const SessionExpiredException();
    }

    final inFlight = _tokenRefreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<TokenSet> tracked;
    tracked = _refreshToken(tokenSet).whenComplete(() {
      if (identical(_tokenRefreshInFlight, tracked)) {
        _tokenRefreshInFlight = null;
      }
    });
    _tokenRefreshInFlight = tracked;
    return tracked;
  }

  Future<TokenSet> _refreshToken(TokenSet previous) async {
    final generation = _authGeneration;
    _logger.info('auth', 'Refreshing access token');
    final response = await _post(
      Uri.parse('$consoleBaseUrl/api/v1/auth/device/refresh'),
      operation: 'refreshDeviceToken',
      body: {'refresh_token': previous.refreshToken},
    );
    final body = _tryDecodeObject(response.body);
    final error = body?['error']?.toString() ?? '';
    if (error == 'invalid_grant') {
      const exception = SessionExpiredException();
      await _expireTokenSetIfCurrent(exception, previous, generation);
      throw exception;
    }
    if (!response.statusCode.toString().startsWith('2')) {
      throw _TokenRefreshException(
        '暂时无法刷新登录状态：${_extractErrorMessage(response.body)}',
      );
    }

    final accessToken = body?['access_token']?.toString().trim() ?? '';
    if (accessToken.isEmpty) {
      throw const _TokenRefreshException('刷新登录状态时服务端未返回 access_token。');
    }
    final rotatedRefreshToken = body?['refresh_token']?.toString().trim() ?? '';
    final tokenSet = TokenSet(
      accessToken: accessToken,
      idToken: body?['id_token']?.toString() ?? previous.idToken,
      refreshToken: rotatedRefreshToken.isEmpty
          ? previous.refreshToken
          : rotatedRefreshToken,
      tokenType: body?['token_type']?.toString() ?? previous.tokenType,
      expiresIn: (body?['expires_in'] as num?)?.toInt() ?? previous.expiresIn,
      obtainedAt: DateTime.now().toUtc(),
    );
    if (generation != _authGeneration ||
        !identical(_activeTokenSet, previous)) {
      throw const SessionExpiredException();
    }
    await tokenStore.save(tokenSet);
    if (generation != _authGeneration) {
      final current = _activeTokenSet;
      if (current == null) {
        await tokenStore.clear();
      } else {
        await tokenStore.save(current);
      }
      throw const SessionExpiredException();
    }
    _activeTokenSet = tokenSet;
    _activeAccessTokens.add(tokenSet.accessToken);
    _logger.info('auth', 'Access token refreshed');
    return tokenSet;
  }

  void _activateStoredTokenSet(TokenSet tokenSet) {
    _authGeneration++;
    _tokenRefreshInFlight = null;
    _activeTokenSet = tokenSet;
    _activeAccessTokens
      ..clear()
      ..add(tokenSet.accessToken);
  }

  Future<void> _saveNewTokenSet(TokenSet tokenSet) async {
    _activateStoredTokenSet(tokenSet);
    await tokenStore.save(tokenSet);
  }

  Future<int> _clearActiveTokenSet() async {
    final clearGeneration = ++_authGeneration;
    _activeTokenSet = null;
    _activeAccessTokens.clear();
    _tokenRefreshInFlight = null;
    await tokenStore.clear();
    if (clearGeneration != _authGeneration) {
      final current = _activeTokenSet;
      if (current != null) {
        await tokenStore.save(current);
      }
    }
    return clearGeneration;
  }

  Future<void> _expireTokenSetIfCurrent(
    SessionExpiredException error,
    TokenSet tokenSet,
    int generation,
  ) async {
    if (generation != _authGeneration ||
        !identical(_activeTokenSet, tokenSet)) {
      return;
    }
    final clearGeneration = await _clearActiveTokenSet();
    if (clearGeneration == _authGeneration) {
      _sessionExpirations.add(error);
    }
  }

  Future<void> _expireRequestSessionIfCurrent(
    SessionExpiredException error, {
    required int requestGeneration,
    required String rejectedAccessToken,
  }) async {
    final tokenSet = _activeTokenSet;
    if (requestGeneration != _authGeneration ||
        tokenSet?.accessToken != rejectedAccessToken) {
      return;
    }
    await _expireTokenSetIfCurrent(error, tokenSet!, requestGeneration);
  }

  static String? _bearerAccessToken(Map<String, String>? headers) {
    final authorization = headers?['Authorization']?.trim() ?? '';
    const prefix = 'Bearer ';
    if (!authorization.startsWith(prefix)) {
      return null;
    }
    final token = authorization.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  static Map<String, String> _withAccessToken(
    Map<String, String>? headers,
    String accessToken,
  ) {
    return <String, String>{
      ...?headers,
      'Authorization': 'Bearer $accessToken',
    };
  }

  Never _throwNetworkAuthException(String operation, Uri uri, Object error) {
    final message = _networkErrorMessage(operation, uri, error);
    _logger.error(
      'auth.http',
      'Console API request failed',
      context: {
        'operation': operation,
        'url': _redactedUri(uri),
        'host': uri.host,
        'error': error.toString(),
      },
    );
    throw _ConsoleNetworkException(
      message,
      operation: operation,
      host: uri.host,
      cause: error.toString(),
    );
  }

  static String _networkErrorMessage(String operation, Uri uri, Object error) {
    final host = uri.host.trim().isEmpty ? uri.toString() : uri.host.trim();
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('no address associated') ||
        lower.contains('failed host lookup')) {
      return '网络请求失败：无法解析 $host。请检查模拟器 DNS、代理/VPN，或控制台地址配置。';
    }
    return '网络请求失败：无法连接 $host（$operation）：$text';
  }

  static String _redactedUri(Uri uri) {
    if (uri.query.isEmpty) {
      return uri.toString();
    }
    return uri.replace(query: '<redacted>').toString();
  }

  Future<ConsoleUser> _fetchCurrentUser(String accessToken) async {
    final response = await _get(
      Uri.parse('$consoleBaseUrl/api/v1/auth/me'),
      operation: 'fetchCurrentUser',
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (!response.statusCode.toString().startsWith('2')) {
      throw AuthException('当前登录态已失效。');
    }

    final body = _decodeObject(response.body);
    final user =
        (body['user'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final tenants = (body['tenants'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item as Map<String, dynamic>)
        .map(
          (item) => ConsoleWorkspace(
            id: item['id']?.toString() ?? '',
            name: item['name']?.toString() ?? '',
          ),
        )
        .where((item) => item.id.isNotEmpty && item.name.isNotEmpty)
        .toList(growable: false);

    return ConsoleUser(
      email: user['email']?.toString() ?? '',
      displayName: user['display_name']?.toString() ?? '',
      workspaces: tenants,
    );
  }

  static Map<String, dynamic> _decodeObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const AuthException('服务端返回了无法识别的数据格式。');
  }

  static Map<String, dynamic>? _tryDecodeObject(String source) {
    try {
      return _decodeObject(source);
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _decodeObjectOrList(String source) {
    final decoded = jsonDecode(source);
    if (decoded is List<dynamic>) {
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    if (decoded is Map<String, dynamic>) {
      if (decoded['items'] is List<dynamic>) {
        return (decoded['items'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['networks'] is List<dynamic>) {
        return (decoded['networks'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['nodes'] is List<dynamic>) {
        return (decoded['nodes'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['devices'] is List<dynamic>) {
        return (decoded['devices'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
      if (decoded['regions'] is List<dynamic>) {
        return (decoded['regions'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
    }
    return const <Map<String, dynamic>>[];
  }

  static String _extractErrorMessage(String source) {
    final body = _tryDecodeObject(source);
    return body?['message']?.toString() ??
        body?['error_description']?.toString() ??
        body?['description']?.toString() ??
        source;
  }

  static AuthException _authAwareException(
    http.Response response,
    String prefix,
  ) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      return const AuthException('当前登录态已失效，请重新登录。');
    }
    return AuthException('$prefix：${_extractErrorMessage(response.body)}');
  }

  static String _stripCancelToken(String url) {
    final parts = url.split('?cancelToken=');
    return parts.first;
  }

  static Map<String, dynamic> _platformEnrollmentKey(
    List<Map<String, dynamic>> items, {
    required String displayName,
  }) {
    for (final item in items) {
      if (!_isReusableEnrollmentKey(item)) {
        continue;
      }
      final itemName = (item['display_name'] ?? item['name'])
          ?.toString()
          .trim();
      if (itemName == displayName) {
        return item;
      }
    }
    return const <String, dynamic>{};
  }

  static bool _isReusableEnrollmentKey(Map<String, dynamic> item) {
    final lifecycleState = item['lifecycle_state']?.toString().toLowerCase();
    return item['id']?.toString().isNotEmpty == true &&
        item['reusable'] != false &&
        item['revoked'] != true &&
        lifecycleState != 'expired' &&
        lifecycleState != 'revoked';
  }

  String _fallbackConfigServerUrl() {
    return defaultConfigServerUrlForConsoleBaseUrl(consoleBaseUrl);
  }

  static String _enrollmentKeyDisplayName() {
    return defaultTargetPlatform == TargetPlatform.android
        ? 'Android Auto Key'
        : 'Desktop Auto Key';
  }

  static bool _shouldRequestDeviceAuthAppReturnUri() {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }
}

class _ConsoleNetworkException extends AuthException {
  const _ConsoleNetworkException(
    super.message, {
    required this.operation,
    required this.host,
    required this.cause,
  });

  final String operation;
  final String host;
  final String cause;
}

class _TokenRefreshException extends AuthException {
  const _TokenRefreshException(super.message);
}
