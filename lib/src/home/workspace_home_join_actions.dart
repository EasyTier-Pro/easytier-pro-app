part of 'workspace_home_view.dart';

extension _WorkspaceHomeJoinActions on _WorkspaceHomeViewState {
  Future<void> _joinNetwork(ConsoleNetwork network) async {
    final workspace = _workspace;
    if (workspace == null) return;
    final coreStatus = widget.coreLifecycleService.status.value;
    final blocked = _joinBlockedByCoreStatus(coreStatus, coreStatus.machineId);
    if (blocked != null) {
      _setJoinState(network.id, blocked);
      _showNetworkActionToast(
        '加入「${network.name}」失败：${blocked.message}',
        destructive: true,
      );
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final connections = widget.coreLifecycleService.networkConnections.value;
      final candidates = <String, ConsoleNetwork>{
        for (final item in _networks) item.id: item,
        for (final connection in connections.values)
          connection.network.id: connection.network,
      };
      for (final other in candidates.values) {
        if (other.id == network.id) continue;
        final phase = _joinStateFor(other).phase;
        if (phase == _JoinPhase.joined ||
            phase == _JoinPhase.joining ||
            phase == _JoinPhase.leaving ||
            connections[other.id]?.nodeId != null) {
          _showNetworkActionToast(
            'iOS 当前仅支持一个活跃 VPN 网络，请先断开「${other.name}」后再加入此网络。',
            destructive: true,
          );
          return;
        }
      }
    }
    try {
      await widget.coreLifecycleService.connectNetwork(workspace, network);
      if (!mounted) return;
      if (_workspace?.id == workspace.id) {
        await _loadSingleNetworkDevices(network.id);
      }
      _showNetworkActionToast('「${network.name}」已连接');
    } catch (error) {
      if (!mounted) return;
      _showNetworkActionToast(
        '加入「${network.name}」失败：${_normalizeError(error)}',
        destructive: true,
      );
    }
  }

  _JoinNetworkState? _joinBlockedByCoreStatus(
    CoreRunStatus status,
    String? machineId,
  ) {
    return switch (status.phase) {
      CoreRunPhase.needsElevation => _JoinNetworkState.blockedByCore(
        '需要先执行管理员权限修复/重试后才能加入网络。',
      ),
      CoreRunPhase.needsVpnPermission => _JoinNetworkState.blockedByCore(
        '需要授权 VPN 连接后才能加入网络。',
      ),
      CoreRunPhase.error => _JoinNetworkState.blockedByCore(
        status.message.isEmpty
            ? '连接引擎启动失败，请先重新启动连接引擎。'
            : '${status.message}，请先修复连接引擎。',
      ),
      CoreRunPhase.stopped => _JoinNetworkState.blockedByCore(
        '连接引擎未运行，请先重新启动连接引擎。',
      ),
      CoreRunPhase.checking => _JoinNetworkState.error('连接引擎正在检查，请稍后再试。'),
      CoreRunPhase.repairing => _JoinNetworkState.error('连接引擎正在修复，请稍后再试。'),
      CoreRunPhase.signedOut => _JoinNetworkState.error('登录状态已断开，请重新登录后再加入网络。'),
      CoreRunPhase.running when machineId == null || machineId.isEmpty =>
        _JoinNetworkState.error('本机设备正在注册，请稍后再试。'),
      CoreRunPhase.running => null,
    };
  }

  Future<void> _leaveNetwork(ConsoleNetwork network) async {
    final workspace = _workspace;
    if (workspace == null) return;
    try {
      await widget.coreLifecycleService.disconnectNetwork(workspace, network);
      if (!mounted) return;
      if (_workspace?.id == workspace.id) {
        _updateState(() {
          _networkDevices = {..._networkDevices, network.id: <NetworkDevice>[]};
          _joinStates = {..._joinStates}..remove(network.id);
          _networkInstanceReady = {..._networkInstanceReady}
            ..remove(network.id);
        });
        await _loadSingleNetworkDevices(network.id);
      }
      _showNetworkActionToast('「${network.name}」已断开连接');
    } catch (error) {
      if (!mounted) return;
      _showNetworkActionToast(
        '退出「${network.name}」失败：${_normalizeError(error)}',
        destructive: true,
      );
    }
  }

  bool _isLocalDeviceInNetwork(String networkId, String machineId) {
    return _localDeviceInNetwork(networkId, machineId) != null;
  }

  NetworkDevice? _localDeviceInNetwork(
    String networkId,
    String machineId, {
    String? nodeId,
  }) {
    final devices = _networkDevices[networkId] ?? const <NetworkDevice>[];
    for (final device in devices) {
      if ((widget.coreLifecycleService.localDeviceId != null
              ? device.deviceId == widget.coreLifecycleService.localDeviceId
              : device.machineId == machineId) &&
          device.attached &&
          (nodeId == null || device.id == nodeId)) {
        return device;
      }
    }
    return null;
  }

  _JoinNetworkState _joinStateFor(ConsoleNetwork network) {
    final connection =
        widget.coreLifecycleService.networkConnections.value[network.id];
    if (connection != null) {
      return _JoinNetworkState(
        phase: switch (connection.phase) {
          CoreNetworkConnectionPhase.joining => _JoinPhase.joining,
          CoreNetworkConnectionPhase.joined => _JoinPhase.joined,
          CoreNetworkConnectionPhase.leaving => _JoinPhase.leaving,
          CoreNetworkConnectionPhase.error => _JoinPhase.error,
        },
        message: connection.message,
        localIpv4: connection.ipv4,
      );
    }
    final explicit = _joinStates[network.id];
    if (explicit != null && explicit.phase != _JoinPhase.idle) {
      return explicit;
    }

    final machineId = widget.coreLifecycleService.status.value.machineId;
    if (machineId != null &&
        machineId.isNotEmpty &&
        _isLocalDeviceInNetwork(network.id, machineId)) {
      final localDevice = _localDeviceInNetwork(network.id, machineId);
      return _JoinNetworkState.joinedWithIp(localDevice?.ipv4);
    }
    return explicit ?? _JoinNetworkState.idle;
  }

  void _setJoinState(String networkId, _JoinNetworkState state) {
    if (!mounted) {
      return;
    }
    _updateState(() {
      _joinStates = {..._joinStates, networkId: state};
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }
}
