part of 'core_lifecycle_service.dart';

extension CoreWorkspaceConnections on CoreLifecycleService {
  String? get sourceWorkspaceId => _workspacePreferences.sourceWorkspaceId;
  String? get localDeviceId => _workspacePreferences.deviceId;

  ConsoleWorkspace? get _sourceWorkspace {
    for (final workspace in _session?.user.workspaces ?? <ConsoleWorkspace>[]) {
      if (workspace.id == sourceWorkspaceId) return workspace;
    }
    return null;
  }

  Future<void> initializeWorkspaceSession(
    AuthSession session, {
    bool checkSourceAccess = true,
  }) async {
    if (_workspaceInitialization != null) await _workspaceInitialization;
    if (_workspaceAccountId == session.user.id) {
      _session = session;
      if (!session.user.workspaces.any(
        (w) => w.id == selectedWorkspaceId.value,
      )) {
        final selected = session.user.workspaces.firstOrNull?.id;
        _workspacePreferences = WorkspacePreferences(
          selectedWorkspaceId: selected,
          sourceWorkspaceId: sourceWorkspaceId,
          deviceId: localDeviceId,
          enrollmentKeyId: _workspacePreferences.enrollmentKeyId,
        );
        selectedWorkspaceId.value = selected;
        await authService.saveWorkspacePreferences(
          session.user.id,
          _workspacePreferences,
        );
      }
      if (checkSourceAccess &&
          _sourceWorkspace == null &&
          status.value.isRunning) {
        _connectionGeneration++;
        await _stopRuntimeForMissingWorkspace();
        status.value = const CoreRunStatus(
          phase: CoreRunPhase.error,
          message: '源工作区授权已失效，请检查本机设备登记。',
        );
      }
      return;
    }
    final pending = _initializeWorkspaceSession(session);
    _workspaceInitialization = pending;
    try {
      await pending;
    } finally {
      _workspaceInitialization = null;
    }
  }

  Future<void> _initializeWorkspaceSession(AuthSession session) async {
    final generation = _connectionGeneration;
    final preferences = await authService.loadWorkspacePreferences(
      session.user.id,
    );
    if (_connectionsDisposed || generation != _connectionGeneration) return;
    _session = session;
    _workspaceAccountId = session.user.id;
    final workspaces = session.user.workspaces;
    final selected =
        workspaces.any((w) => w.id == preferences.selectedWorkspaceId)
        ? preferences.selectedWorkspaceId
        : workspaces.firstOrNull?.id;
    _workspacePreferences = WorkspacePreferences(
      selectedWorkspaceId: selected,
      sourceWorkspaceId:
          preferences.sourceWorkspaceId ?? workspaces.firstOrNull?.id,
      deviceId: preferences.deviceId,
      enrollmentKeyId: preferences.enrollmentKeyId,
    );
    selectedWorkspaceId.value = selected;
    await authService.saveWorkspacePreferences(
      session.user.id,
      _workspacePreferences,
    );
  }

  Future<void> selectWorkspace(String workspaceId) async {
    final session = _session;
    if (session == null ||
        !session.user.workspaces.any((w) => w.id == workspaceId)) {
      return;
    }
    _workspacePreferences = _workspacePreferences.copyWith(
      selectedWorkspaceId: workspaceId,
    );
    selectedWorkspaceId.value = workspaceId;
    await authService.saveWorkspacePreferences(
      session.user.id,
      _workspacePreferences,
    );
  }

  Future<CoreBootstrapConfig> _prepareSourceBootstrap(
    AuthSession session,
    String workspaceId,
  ) async {
    final bootstrap = await authService.prepareCoreBootstrap(
      accessToken: session.tokenSet.accessToken,
      workspaceId: workspaceId,
      enrollmentKeyId: _workspacePreferences.enrollmentKeyId,
    );
    _workspacePreferences = _workspacePreferences.copyWith(
      enrollmentKeyId: bootstrap.enrollmentKeyId,
    );
    await authService.saveWorkspacePreferences(
      session.user.id,
      _workspacePreferences,
    );
    return bootstrap;
  }

  Future<ManagedDevice> _resolveSourceDevice() async {
    final pending = _sourceDeviceRequest;
    if (pending != null) return pending;
    final request = _loadSourceDevice();
    _sourceDeviceRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_sourceDeviceRequest, request)) _sourceDeviceRequest = null;
    }
  }

  Future<ManagedDevice> _loadSourceDevice() async {
    final session = _session;
    final source = _sourceWorkspace;
    final machineId = status.value.machineId;
    final generation = _connectionGeneration;
    if (session == null || source == null) {
      throw const AuthException('源工作区不可用，请检查设备授权。');
    }
    if (machineId == null || machineId.isEmpty) {
      throw const AuthException('本机设备正在注册，请稍后重试。');
    }
    _checkConnectionGeneration(generation);
    final devices = await authService.fetchManagedDevices(
      accessToken: _session!.tokenSet.accessToken,
      workspaceId: source.id,
    );
    _checkConnectionGeneration(generation);
    final candidates = devices
        .where(
          (d) =>
              !d.removed &&
              (d.workspaceId.isEmpty || d.workspaceId == source.id) &&
              (localDeviceId != null
                  ? d.id == localDeviceId
                  : d.machineId == machineId),
        )
        .toList();
    if (candidates.length > 1) {
      throw const AuthException('本机设备登记不唯一，请在控制台检查设备。');
    }
    if (candidates.length == 1) {
      final device = candidates.single;
      if (device.machineId != machineId) {
        throw const AuthException('本机身份与原设备登记不一致，请检查源工作区设备状态。');
      }
      _workspacePreferences = _workspacePreferences.copyWith(
        deviceId: device.id,
        enrollmentKeyId:
            _workspacePreferences.enrollmentKeyId ?? device.enrollmentKeyId,
      );
      await authService.saveWorkspacePreferences(
        session.user.id,
        _workspacePreferences,
      );
      return device;
    }
    if (localDeviceId != null) {
      throw const AuthException('原设备登记已不可用，请检查源工作区设备状态。');
    }
    throw const AuthException('核心已启动，正在等待设备注册到控制台。');
  }

  void _checkConnectionGeneration(int generation) {
    if (_connectionsDisposed ||
        generation != _connectionGeneration ||
        _session == null) {
      throw const AuthException('登录状态已变更，连接操作已停止。');
    }
  }

  void _publishConnection(CoreNetworkConnection connection, int generation) {
    if (_connectionsDisposed || generation != _connectionGeneration) return;
    networkConnections.value = {
      ...networkConnections.value,
      connection.network.id: connection,
    };
  }

  Future<void> connectNetwork(
    ConsoleWorkspace workspace,
    ConsoleNetwork network,
  ) {
    final pending = _networkOperations[network.id];
    if (pending != null) return pending;
    _networkOperationGenerations[network.id] =
        (_networkOperationGenerations[network.id] ?? 0) + 1;
    final operation = _connectNetwork(workspace, network);
    _networkOperations[network.id] = operation;
    return operation.whenComplete(() {
      if (identical(_networkOperations[network.id], operation)) {
        _networkOperations.remove(network.id);
      }
    });
  }

  Future<void> _connectNetwork(
    ConsoleWorkspace workspace,
    ConsoleNetwork network,
  ) async {
    final generation = _connectionGeneration;
    _publishConnection(
      CoreNetworkConnection(
        workspace: workspace,
        network: network,
        phase: CoreNetworkConnectionPhase.joining,
      ),
      generation,
    );
    String? nodeId;
    var began = false;
    try {
      _checkConnectionGeneration(generation);
      if (!status.value.isRunning) throw AuthException(status.value.message);
      await beginNetworkConnection();
      began = true;
      _checkConnectionGeneration(generation);
      final source = await _resolveSourceDevice();
      var device = source;
      if (workspace.id != sourceWorkspaceId) {
        var devices = await authService.fetchManagedDevices(
          accessToken: _session!.tokenSet.accessToken,
          workspaceId: workspace.id,
        );
        _checkConnectionGeneration(generation);
        if (!devices.any((d) => d.id == source.id)) {
          await authService.authorizeDeviceWorkspace(
            accessToken: _session!.tokenSet.accessToken,
            sourceWorkspaceId: sourceWorkspaceId!,
            deviceId: source.id,
            targetWorkspaceId: workspace.id,
          );
          _checkConnectionGeneration(generation);
          devices = await authService.fetchManagedDevices(
            accessToken: _session!.tokenSet.accessToken,
            workspaceId: workspace.id,
          );
        }
        device =
            devices.where((d) => d.id == source.id).firstOrNull ??
            (throw const AuthException('设备授权已提交，等待控制台确认。'));
      }
      _checkConnectionGeneration(generation);
      if (!device.approved) throw const AuthException('本机在此工作区尚未批准，请等待管理员批准。');
      if (!device.canManageNodes) throw const AuthException('没有在此工作区连接网络的权限。');
      if (!source.online) throw const AuthException('本机设备当前离线，请确认连接引擎已正常运行。');
      var nodes = await authService.fetchNetworkDevices(
        accessToken: _session!.tokenSet.accessToken,
        workspaceId: workspace.id,
        networkId: network.id,
      );
      _checkConnectionGeneration(generation);
      var node = nodes
          .where((n) => n.deviceId == source.id && n.attached)
          .firstOrNull;
      if (node == null) {
        final attachment = await authService.attachDeviceToNetwork(
          accessToken: _session!.tokenSet.accessToken,
          workspaceId: workspace.id,
          networkId: network.id,
          deviceId: source.id,
        );
        nodeId = attachment.nodeId;
      } else {
        nodeId = node.id;
      }
      _checkConnectionGeneration(generation);
      final ipv4 = await waitForNetworkConnection(
        network.runtimeNetworkName,
        readInstanceId: () async {
          _checkConnectionGeneration(generation);
          nodes = await authService.fetchNetworkDevices(
            accessToken: _session!.tokenSet.accessToken,
            workspaceId: workspace.id,
            networkId: network.id,
          );
          return nodes
              .where((n) => n.id == nodeId && n.attached)
              .firstOrNull
              ?.instanceId;
        },
      );
      _checkConnectionGeneration(generation);
      nodes = await authService.fetchNetworkDevices(
        accessToken: _session!.tokenSet.accessToken,
        workspaceId: workspace.id,
        networkId: network.id,
      );
      _checkConnectionGeneration(generation);
      node = nodes.where((n) => n.id == nodeId && n.attached).firstOrNull;
      final ready = await isNetworkInstanceRunning(network.runtimeNetworkName);
      _checkConnectionGeneration(generation);
      _publishConnection(
        CoreNetworkConnection(
          workspace: workspace,
          network: network,
          phase: CoreNetworkConnectionPhase.joined,
          nodeId: nodeId,
          ipv4: ipv4 ?? node?.ipv4,
          ready: ready,
        ),
        generation,
      );
    } catch (error) {
      _publishConnection(
        CoreNetworkConnection(
          workspace: workspace,
          network: network,
          phase: CoreNetworkConnectionPhase.error,
          nodeId: nodeId,
          message: _normalizeError(error),
        ),
        generation,
      );
      rethrow;
    } finally {
      if (began &&
          generation == _connectionGeneration &&
          !_connectionsDisposed) {
        await endNetworkConnection();
      }
    }
  }

  Future<void> disconnectNetwork(
    ConsoleWorkspace workspace,
    ConsoleNetwork network,
  ) {
    final pending = _networkOperations[network.id];
    if (pending != null) return pending;
    _networkOperationGenerations[network.id] =
        (_networkOperationGenerations[network.id] ?? 0) + 1;
    final operation = _disconnectNetwork(workspace, network);
    _networkOperations[network.id] = operation;
    return operation.whenComplete(() {
      if (identical(_networkOperations[network.id], operation)) {
        _networkOperations.remove(network.id);
      }
    });
  }

  Future<void> _disconnectNetwork(
    ConsoleWorkspace workspace,
    ConsoleNetwork network,
  ) async {
    final generation = _connectionGeneration;
    final previous = networkConnections.value[network.id];
    _publishConnection(
      CoreNetworkConnection(
        workspace: workspace,
        network: network,
        phase: CoreNetworkConnectionPhase.leaving,
        nodeId: previous?.nodeId,
        ipv4: previous?.ipv4,
      ),
      generation,
    );
    try {
      _checkConnectionGeneration(generation);
      final device = await _resolveSourceDevice();
      final nodes = await authService.fetchNetworkDevices(
        accessToken: _session!.tokenSet.accessToken,
        workspaceId: workspace.id,
        networkId: network.id,
      );
      _checkConnectionGeneration(generation);
      final node = nodes
          .where((n) => n.deviceId == device.id && n.attached)
          .firstOrNull;
      if (node != null) {
        await authService.removeNetworkNode(
          accessToken: _session!.tokenSet.accessToken,
          workspaceId: workspace.id,
          nodeId: node.id,
        );
      }
      _checkConnectionGeneration(generation);
      networkConnections.value = {...networkConnections.value}
        ..remove(network.id);
    } catch (error) {
      _publishConnection(
        CoreNetworkConnection(
          workspace: workspace,
          network: network,
          phase: previous?.phase ?? CoreNetworkConnectionPhase.error,
          nodeId: previous?.nodeId,
          ipv4: previous?.ipv4,
          ready: previous?.ready ?? false,
          message: '退出网络失败：${_normalizeError(error)}',
        ),
        generation,
      );
      rethrow;
    }
  }

  /// Restores a view of Console-owned Nodes; never removes runtime instances.
  Future<void> refreshWorkspaceConnections(
    ConsoleWorkspace workspace,
    List<ConsoleNetwork> networks,
  ) async {
    if (!status.value.isRunning || _session == null || networks.isEmpty) return;
    await _resolveSourceDevice();
    for (final network in networks) {
      await fetchWorkspaceNetworkDevices(workspace, network);
    }
  }

  Future<List<ConsoleNetwork>> fetchWorkspaceNetworks(
    ConsoleWorkspace workspace,
  ) async {
    final generation = _connectionGeneration;
    final operationGenerations = Map<String, int>.of(
      _networkOperationGenerations,
    );
    final networks = await authService.fetchNetworks(
      accessToken: _session!.tokenSet.accessToken,
      workspaceId: workspace.id,
    );
    _checkConnectionGeneration(generation);
    final visibleIds = networks.map((network) => network.id).toSet();
    final next = {...networkConnections.value};
    for (final connection in networkConnections.value.values) {
      final id = connection.network.id;
      if (connection.workspace.id == workspace.id &&
          !visibleIds.contains(id) &&
          !_networkOperations.containsKey(id) &&
          (operationGenerations[id] ?? 0) ==
              (_networkOperationGenerations[id] ?? 0)) {
        next.remove(id);
        // Fence node reads started before this successful list response.
        _networkOperationGenerations[id] =
            (_networkOperationGenerations[id] ?? 0) + 1;
      }
    }
    if (next.length != networkConnections.value.length) {
      networkConnections.value = next;
    }
    return networks;
  }

  /// A null result means a join/leave superseded the read. Callers keep their
  /// current topology instead of treating that result as an empty node list.
  Future<List<NetworkDevice>?> fetchWorkspaceNetworkDevices(
    ConsoleWorkspace workspace,
    ConsoleNetwork network,
  ) async {
    final generation = _connectionGeneration;
    final operationGeneration = _networkOperationGenerations[network.id] ?? 0;
    if (_networkOperations.containsKey(network.id)) return null;
    final nodes = await authService.fetchNetworkDevices(
      accessToken: _session!.tokenSet.accessToken,
      workspaceId: workspace.id,
      networkId: network.id,
    );
    _checkConnectionGeneration(generation);
    bool superseded() =>
        _networkOperations.containsKey(network.id) ||
        operationGeneration != (_networkOperationGenerations[network.id] ?? 0);
    if (superseded()) return null;
    final deviceId = localDeviceId;
    if (deviceId == null) return nodes;
    final node = nodes
        .where((n) => n.deviceId == deviceId && n.attached)
        .firstOrNull;
    if (node == null) {
      if (networkConnections.value.containsKey(network.id)) {
        networkConnections.value = {...networkConnections.value}
          ..remove(network.id);
        _networkOperationGenerations[network.id] = operationGeneration + 1;
      }
      return nodes;
    }
    final previous = networkConnections.value[network.id];
    // Console attachment alone does not repair a rejected local instance.
    if (previous?.phase == CoreNetworkConnectionPhase.error &&
        previous?.nodeId == node.id) {
      return nodes;
    }
    final ready =
        status.value.isRunning &&
        await isNetworkInstanceRunning(network.runtimeNetworkName);
    _checkConnectionGeneration(generation);
    if (superseded()) return null;
    _publishConnection(
      CoreNetworkConnection(
        workspace: workspace,
        network: network,
        phase: CoreNetworkConnectionPhase.joined,
        nodeId: node.id,
        ipv4: node.ipv4,
        ready: ready,
      ),
      generation,
    );
    return nodes;
  }

  void updateNetworkReadiness(String networkId, bool ready) {
    final previous = networkConnections.value[networkId];
    if (previous == null ||
        previous.ready == ready ||
        previous.phase != CoreNetworkConnectionPhase.joined) {
      return;
    }
    _publishConnection(
      CoreNetworkConnection(
        workspace: previous.workspace,
        network: previous.network,
        phase: previous.phase,
        nodeId: previous.nodeId,
        ipv4: previous.ipv4,
        message: previous.message,
        ready: ready,
      ),
      _connectionGeneration,
    );
  }

  void _resetWorkspaceConnections() {
    _connectionGeneration++;
    _workspaceAccountId = null;
    _sourceDeviceRequest = null;
    _workspacePreferences = const WorkspacePreferences();
    _networkOperations.clear();
    _networkOperationGenerations.clear();
    networkConnections.value = {};
    selectedWorkspaceId.value = null;
  }

  void _disposeWorkspaceConnections() {
    _connectionGeneration++;
    _connectionsDisposed = true;
    selectedWorkspaceId.dispose();
    networkConnections.dispose();
  }
}
