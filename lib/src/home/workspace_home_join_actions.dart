part of 'workspace_home_view.dart';

extension _WorkspaceHomeJoinActions on _WorkspaceHomeViewState {
  Future<void> _joinNetwork(ConsoleNetwork network) async {
    final workspace = _workspace;
    final coreStatus = widget.coreLifecycleService.status.value;
    final machineId = coreStatus.machineId?.trim();

    if (workspace == null) {
      _setJoinError(network.id, '当前账号未关联工作区。');
      return;
    }
    if (!coreStatus.isRunning || machineId == null || machineId.isEmpty) {
      _setJoinError(network.id, '请等待本机设备准备完成后再加入网络。');
      return;
    }
    final joinedAndroidNetwork = _joinedAndroidNetworkExcluding(network.id);
    if (joinedAndroidNetwork != null) {
      final message =
          'Android 当前仅支持一个活跃 VPN 网络，请先断开「${joinedAndroidNetwork.name}」后再加入此网络。';
      _setJoinError(network.id, message);
      _showNetworkActionToast(message, destructive: true);
      return;
    }
    final existingLocalDevice = _localDeviceInNetwork(network.id, machineId);
    if (existingLocalDevice != null) {
      _setJoinState(
        network.id,
        _JoinNetworkState.joinedWithIp(existingLocalDevice.ipv4),
      );
      unawaited(_refreshNetworkInstanceState(network));
      return;
    }

    _setJoinState(network.id, _JoinNetworkState.joining);
    try {
      final device = await _waitForLocalManagedDevice(machineId);
      if (device == null) {
        throw const AuthException('核心已启动，正在等待设备注册到控制台。');
      }
      if (!device.approved) {
        throw const AuthException('本机设备尚未批准，请先在控制台批准设备。');
      }
      if (!device.online) {
        throw const AuthException('本机设备当前离线，请确认连接引擎已正常运行。');
      }

      await _loadSingleNetworkDevices(network.id);
      final refreshedLocalDevice = _localDeviceInNetwork(network.id, machineId);
      if (refreshedLocalDevice != null) {
        _setJoinState(
          network.id,
          _JoinNetworkState.joinedWithIp(refreshedLocalDevice.ipv4),
        );
        unawaited(_refreshNetworkInstanceState(network));
        return;
      }

      await widget.authService.attachDeviceToNetwork(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
        networkId: network.id,
        deviceId: device.id,
      );
      final joinedLocalDevice = await _loadLocalNetworkDevice(
        network.id,
        machineId,
        waitForIpv4: true,
      );
      _setJoinState(
        network.id,
        _JoinNetworkState.joinedWithIp(joinedLocalDevice?.ipv4),
      );
      unawaited(_refreshNetworkInstanceState(network));
      _showNetworkActionToast('「${network.name}」已连接');
    } catch (error) {
      final message = _normalizeError(error);
      _setJoinError(network.id, message);
      _showNetworkActionToast(
        '加入「${network.name}」失败：$message',
        destructive: true,
      );
    }
  }

  Future<void> _leaveNetwork(ConsoleNetwork network) async {
    final workspace = _workspace;
    final machineId = widget.coreLifecycleService.status.value.machineId
        ?.trim();

    if (workspace == null) {
      _setJoinError(network.id, '当前账号未关联工作区。');
      return;
    }
    if (machineId == null || machineId.isEmpty) {
      _setJoinError(network.id, '未找到本机设备标识，请等待本机设备准备完成。');
      return;
    }

    final localDevice = _localDeviceInNetwork(network.id, machineId);
    if (localDevice == null) {
      _setJoinState(network.id, _JoinNetworkState.idle);
      return;
    }

    _setJoinState(network.id, _JoinNetworkState.leaving);
    try {
      await widget.authService.removeNetworkNode(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
        nodeId: localDevice.id,
      );
      _markNetworkLeft(network.id, localDevice.id, machineId);
      _showNetworkActionToast('「${network.name}」已断开连接');
    } catch (error) {
      final message = _normalizeError(error);
      _setJoinState(
        network.id,
        _JoinNetworkState.joinedWithIp(
          localDevice.ipv4,
          message: '退出网络失败：$message',
        ),
      );
      _showNetworkActionToast(
        '退出「${network.name}」失败：$message',
        destructive: true,
      );
    }
  }

  Future<ManagedDevice?> _waitForLocalManagedDevice(String machineId) async {
    final workspace = _workspace;
    if (workspace == null) {
      return null;
    }

    for (
      var attempt = 0;
      attempt < _WorkspaceHomeViewState._devicePollAttempts;
      attempt++
    ) {
      final devices = await widget.authService.fetchManagedDevices(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );
      if (mounted) {
        _updateState(() {
          _managedDevices = _visibleManagedDevices(devices);
          _deviceError = null;
          _isLoadingDevices = false;
        });
      }
      for (final device in _visibleManagedDevices(devices)) {
        if (device.machineId == machineId) {
          return device;
        }
      }
      if (attempt < _WorkspaceHomeViewState._devicePollAttempts - 1) {
        await Future<void>.delayed(_WorkspaceHomeViewState._devicePollDelay);
      }
    }
    return null;
  }

  ConsoleNetwork? _joinedAndroidNetworkExcluding(String networkId) {
    if (!_isAndroidMvpSingleActiveNetwork) {
      return null;
    }
    for (final network in _networks) {
      if (network.id == networkId) {
        continue;
      }
      final phase = _joinStateFor(network).phase;
      if (phase == _JoinPhase.joined ||
          phase == _JoinPhase.joining ||
          phase == _JoinPhase.leaving) {
        return network;
      }
    }
    return null;
  }

  bool _isLocalDeviceInNetwork(String networkId, String machineId) {
    return _localDeviceInNetwork(networkId, machineId) != null;
  }

  NetworkDevice? _localDeviceInNetwork(String networkId, String machineId) {
    final devices = _networkDevices[networkId] ?? const <NetworkDevice>[];
    for (final device in devices) {
      if (device.machineId == machineId && device.attached) {
        return device;
      }
    }
    return null;
  }

  Future<NetworkDevice?> _loadLocalNetworkDevice(
    String networkId,
    String machineId, {
    bool waitForIpv4 = false,
  }) async {
    final attempts = waitForIpv4 ? 5 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      await _loadSingleNetworkDevices(networkId);
      final localDevice = _localDeviceInNetwork(networkId, machineId);
      final ipv4 = localDevice?.ipv4?.trim();
      if (localDevice != null &&
          (!waitForIpv4 || (ipv4 != null && ipv4.isNotEmpty))) {
        return localDevice;
      }
      if (attempt < attempts - 1) {
        await Future<void>.delayed(_WorkspaceHomeViewState._devicePollDelay);
      }
    }
    return _localDeviceInNetwork(networkId, machineId);
  }

  _JoinNetworkState _joinStateFor(ConsoleNetwork network) {
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

  void _setJoinError(String networkId, String message) {
    _setJoinState(networkId, _JoinNetworkState.error(message));
  }

  void _markNetworkLeft(String networkId, String nodeId, String machineId) {
    if (!mounted) {
      return;
    }
    final devices = _networkDevices[networkId] ?? const <NetworkDevice>[];
    _updateState(() {
      _networkDevices = {
        ..._networkDevices,
        networkId: devices
            .where(
              (device) => device.id != nodeId && device.machineId != machineId,
            )
            .toList(growable: false),
      };
      _joinStates = {..._joinStates, networkId: _JoinNetworkState.idle};
      _networkInstanceReady = Map<String, bool>.from(_networkInstanceReady)
        ..remove(networkId);
      final nextPeerStatuses = Map<String, Map<String, CorePeerStatus>>.from(
        _networkPeerStatuses,
      )..remove(networkId);
      final nextPeerErrors = Map<String, String>.from(_peerStatusErrors)
        ..remove(networkId);
      _networkPeerStatuses = nextPeerStatuses;
      _peerStatusErrors = nextPeerErrors;
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }
}
