import 'dart:async';

import 'package:forui/forui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';
import '../core/core_lifecycle_service.dart';
import '../logging/app_logger.dart';
import '../shared/app_motion.dart';
import 'network_node_list_panel.dart';

enum _DashboardView { overview, network, devices, settings }

enum _JoinPhase { idle, joining, joined, leaving, error }

const double _dashboardHeaderCompactBreakpoint = 560;
const double _dashboardHeaderDenseBreakpoint = 400;
const double _itemListMinWidth = 360;

class _JoinNetworkState {
  const _JoinNetworkState({required this.phase, this.message, this.localIpv4});

  final _JoinPhase phase;
  final String? message;
  final String? localIpv4;

  static const idle = _JoinNetworkState(phase: _JoinPhase.idle);
  static const joining = _JoinNetworkState(phase: _JoinPhase.joining);
  static const leaving = _JoinNetworkState(phase: _JoinPhase.leaving);

  static _JoinNetworkState joinedWithIp(String? localIpv4, {String? message}) {
    final value = localIpv4?.trim();
    return _JoinNetworkState(
      phase: _JoinPhase.joined,
      message: message,
      localIpv4: value == null || value.isEmpty ? null : value,
    );
  }

  static _JoinNetworkState error(String message) {
    return _JoinNetworkState(phase: _JoinPhase.error, message: message);
  }
}

class _NetworkTrafficSnapshot {
  const _NetworkTrafficSnapshot({
    required this.downloadBytes,
    required this.uploadBytes,
    required this.sampledAt,
    this.downloadBytesPerSecond,
    this.uploadBytesPerSecond,
  });

  final int downloadBytes;
  final int uploadBytes;
  final DateTime sampledAt;
  final double? downloadBytesPerSecond;
  final double? uploadBytesPerSecond;

  static _NetworkTrafficSnapshot fromTotals(
    CoreNetworkTrafficTotals totals, {
    CoreNetworkTrafficTotals? previous,
  }) {
    double? downloadRate;
    double? uploadRate;
    final elapsedMilliseconds = previous == null
        ? 0
        : totals.sampledAt.difference(previous.sampledAt).inMilliseconds;
    if (previous != null && elapsedMilliseconds > 0) {
      final elapsedSeconds = elapsedMilliseconds / 1000;
      final downloadDelta = totals.downloadBytes - previous.downloadBytes;
      final uploadDelta = totals.uploadBytes - previous.uploadBytes;
      downloadRate = (downloadDelta < 0 ? 0 : downloadDelta) / elapsedSeconds;
      uploadRate = (uploadDelta < 0 ? 0 : uploadDelta) / elapsedSeconds;
    }

    return _NetworkTrafficSnapshot(
      downloadBytes: totals.downloadBytes,
      uploadBytes: totals.uploadBytes,
      sampledAt: totals.sampledAt,
      downloadBytesPerSecond: downloadRate,
      uploadBytesPerSecond: uploadRate,
    );
  }
}

class WorkspaceHomeView extends StatefulWidget {
  const WorkspaceHomeView({
    super.key,
    required this.authService,
    required this.coreLifecycleService,
    required this.session,
    required this.onLogout,
  });

  final AuthService authService;
  final CoreLifecycleService coreLifecycleService;
  final AuthSession session;
  final Future<void> Function() onLogout;

  @override
  State<WorkspaceHomeView> createState() => _WorkspaceHomeViewState();
}

class _WorkspaceHomeViewState extends State<WorkspaceHomeView> {
  static const Duration _devicePollDelay = Duration(seconds: 1);
  static const int _devicePollAttempts = 60;
  static const Duration _trafficPollInterval = Duration(seconds: 2);
  static const Duration _peerPollInterval = Duration(seconds: 5);

  List<ConsoleNetwork> _networks = const <ConsoleNetwork>[];
  List<ConsoleRegion> _regions = const <ConsoleRegion>[];
  List<ManagedDevice> _managedDevices = const <ManagedDevice>[];
  Map<String, List<NetworkDevice>> _networkDevices =
      const <String, List<NetworkDevice>>{};
  Map<String, _JoinNetworkState> _joinStates =
      const <String, _JoinNetworkState>{};
  String? _selectedNetworkId;
  String? _networkError;
  String? _deviceError;
  String? _regionError;
  String? _createError;
  bool _isLoadingNetworks = false;
  bool _isLoadingDevices = false;
  bool _isLoadingRegions = false;
  bool _isCreatingNetwork = false;
  _DashboardView _activeView = _DashboardView.overview;
  String _newNetworkName = '我的网络';
  String _newNetworkIPv4Cidr = '';
  String? _selectedRegionCode;
  int _networkRequestId = 0;
  int _deviceRequestId = 0;
  int _regionRequestId = 0;
  Timer? _trafficPollTimer;
  Timer? _peerPollTimer;
  bool _isTrafficPollInFlight = false;
  bool _isPeerPollInFlight = false;
  Set<String> _trafficPollNetworkIds = const <String>{};
  String? _peerPollNetworkId;
  Map<String, _NetworkTrafficSnapshot> _networkTraffic =
      const <String, _NetworkTrafficSnapshot>{};
  Map<String, CoreNetworkTrafficTotals> _previousTrafficTotals =
      const <String, CoreNetworkTrafficTotals>{};
  Map<String, Map<String, CorePeerStatus>> _networkPeerStatuses =
      const <String, Map<String, CorePeerStatus>>{};
  Map<String, String> _peerStatusErrors = const <String, String>{};

  ConsoleWorkspace? get _workspace => widget.session.user.currentWorkspace;

  ConsoleNetwork? get _selectedNetwork {
    for (final network in _networks) {
      if (network.id == _selectedNetworkId) {
        return network;
      }
    }
    return null;
  }

  List<ConsoleRegion> get _activeRegions {
    return _regions.where((region) => region.active).toList(growable: false);
  }

  int get _totalDeviceCount {
    return _managedDevices.length;
  }

  int get _onlineDeviceCount {
    return _managedDevices.where((device) => device.online).length;
  }

  List<ManagedDevice> _visibleManagedDevices(Iterable<ManagedDevice> devices) {
    return devices.where((device) => !device.removed).toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
    unawaited(_loadInitialData());
  }

  @override
  void dispose() {
    _trafficPollTimer?.cancel();
    _peerPollTimer?.cancel();
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
    super.dispose();
  }

  void _onCoreStatusChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }

  Future<void> _loadInitialData() async {
    await Future.wait([_loadRegions(), _loadNetworks(), _loadManagedDevices()]);
  }

  Future<void> _loadManagedDevices() async {
    final workspace = _workspace;
    if (workspace == null) {
      setState(() {
        _deviceError = '当前账号未关联工作区。';
        _managedDevices = const <ManagedDevice>[];
        _isLoadingDevices = false;
      });
      return;
    }

    final requestId = ++_deviceRequestId;
    setState(() {
      _isLoadingDevices = true;
      _deviceError = null;
    });

    try {
      final devices = await widget.authService.fetchManagedDevices(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );
      if (!mounted || requestId != _deviceRequestId) {
        return;
      }
      setState(() {
        _managedDevices = _visibleManagedDevices(devices);
        _isLoadingDevices = false;
      });
    } catch (error) {
      if (!mounted || requestId != _deviceRequestId) {
        return;
      }
      setState(() {
        _isLoadingDevices = false;
        _deviceError = _normalizeError(error);
      });
    }
  }

  Future<void> _loadRegions() async {
    final requestId = ++_regionRequestId;
    setState(() {
      _isLoadingRegions = true;
      _regionError = null;
    });

    try {
      final regions = await widget.authService.fetchRegions(
        accessToken: widget.session.tokenSet.accessToken,
      );
      if (!mounted || requestId != _regionRequestId) {
        return;
      }
      final active = regions.where((region) => region.active).toList();
      setState(() {
        _regions = regions;
        _selectedRegionCode ??= active.isEmpty ? null : active.first.code;
        _isLoadingRegions = false;
      });
    } catch (error) {
      if (!mounted || requestId != _regionRequestId) {
        return;
      }
      setState(() {
        _isLoadingRegions = false;
        _regionError = _normalizeError(error);
      });
    }
  }

  Future<void> _loadNetworks() async {
    final workspace = _workspace;
    if (workspace == null) {
      setState(() {
        _networkError = '当前账号未关联工作区。';
        _networks = const <ConsoleNetwork>[];
        _selectedNetworkId = null;
        _networkPeerStatuses = const <String, Map<String, CorePeerStatus>>{};
        _peerStatusErrors = const <String, String>{};
      });
      _refreshTrafficPolling();
      _refreshPeerPolling();
      return;
    }

    final requestId = ++_networkRequestId;
    setState(() {
      _isLoadingNetworks = true;
      _networkError = null;
    });

    try {
      final networks = await widget.authService.fetchNetworks(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );
      if (!mounted || requestId != _networkRequestId) {
        return;
      }

      final selectedStillExists =
          _selectedNetworkId != null &&
          networks.any((network) => network.id == _selectedNetworkId);
      final selectedId = selectedStillExists
          ? _selectedNetworkId
          : (networks.isEmpty ? null : networks.first.id);

      setState(() {
        _networks = networks;
        _selectedNetworkId = selectedId;
        _isLoadingNetworks = false;
      });
      _refreshTrafficPolling();
      _refreshPeerPolling();
      unawaited(_loadNetworkDevices(networks));
    } catch (error) {
      if (!mounted || requestId != _networkRequestId) {
        return;
      }
      setState(() {
        _isLoadingNetworks = false;
        _networkError = _normalizeError(error);
      });
    }
  }

  Future<void> _loadNetworkDevices(List<ConsoleNetwork> networks) async {
    final workspace = _workspace;
    if (workspace == null || networks.isEmpty) {
      if (mounted) {
        setState(() {
          _networkDevices = const <String, List<NetworkDevice>>{};
        });
      }
      return;
    }

    final results = await Future.wait(
      networks.map((network) async {
        try {
          final devices = await widget.authService.fetchNetworkDevices(
            accessToken: widget.session.tokenSet.accessToken,
            workspaceId: workspace.id,
            networkId: network.id,
          );
          return MapEntry(network.id, devices);
        } catch (_) {
          return MapEntry(network.id, const <NetworkDevice>[]);
        }
      }),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _networkDevices = Map<String, List<NetworkDevice>>.fromEntries(results);
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }

  Future<void> _loadSingleNetworkDevices(String networkId) async {
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }
    final devices = await widget.authService.fetchNetworkDevices(
      accessToken: widget.session.tokenSet.accessToken,
      workspaceId: workspace.id,
      networkId: networkId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _networkDevices = {..._networkDevices, networkId: devices};
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }

  Future<void> _refreshNetworkNodes(ConsoleNetwork network) async {
    await _loadSingleNetworkDevices(network.id);
    await _pollNetworkPeers(network);
  }

  Future<void> _createNetwork({VoidCallback? onSuccess}) async {
    final workspace = _workspace;
    final regionCode = _selectedRegionCode;
    final name = _newNetworkName.trim();
    final ipv4Cidr = _newNetworkIPv4Cidr.trim();
    if (workspace == null || regionCode == null || regionCode.isEmpty) {
      setState(() {
        _createError = '请选择可用区域后再创建网络。';
      });
      return;
    }
    if (name.isEmpty) {
      setState(() {
        _createError = '请输入网络名称。';
      });
      return;
    }

    setState(() {
      _isCreatingNetwork = true;
      _createError = null;
    });

    try {
      final network = await widget.authService.createNetwork(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
        name: name,
        regions: [regionCode],
        ipv4Cidr: ipv4Cidr.isEmpty ? null : ipv4Cidr,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _networks = [..._networks, network];
        _selectedNetworkId = network.id;
        _newNetworkName = '我的网络';
        _newNetworkIPv4Cidr = '';
        _isCreatingNetwork = false;
        _activeView = _DashboardView.overview;
      });
      await _loadSingleNetworkDevices(network.id);
      unawaited(_loadNetworks());
      onSuccess?.call();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCreatingNetwork = false;
        _createError = _normalizeError(error);
      });
    }
  }

  Future<void> _showCreateNetworkDialog() async {
    await showFDialog<void>(
      context: context,
      builder: (dialogContext, _, animation) => FDialog.raw(
        animation: animation,
        constraints: const BoxConstraints(minWidth: 420, maxWidth: 560),
        builder: (context, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            physics: appScrollPhysics,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('创建网络', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 18),
                _CreateNetworkForm(
                  name: _newNetworkName,
                  ipv4Cidr: _newNetworkIPv4Cidr,
                  selectedRegionCode: _selectedRegionCode,
                  regions: _activeRegions,
                  loadingRegions: _isLoadingRegions,
                  creating: _isCreatingNetwork,
                  error: _createError ?? _regionError,
                  onNameChanged: (value) =>
                      setState(() => _newNetworkName = value),
                  onIPv4CidrChanged: (value) =>
                      setState(() => _newNetworkIPv4Cidr = value),
                  onRegionChanged: (value) =>
                      setState(() => _selectedRegionCode = value),
                  onCreate: () async {
                    await _createNetwork(
                      onSuccess: () {
                        if (Navigator.of(dialogContext).canPop()) {
                          Navigator.of(dialogContext).pop();
                        }
                      },
                    );
                  },
                  onRetryRegions: _loadRegions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

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
    final existingLocalDevice = _localDeviceInNetwork(network.id, machineId);
    if (existingLocalDevice != null) {
      _setJoinState(
        network.id,
        _JoinNetworkState.joinedWithIp(existingLocalDevice.ipv4),
      );
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
    } catch (error) {
      _setJoinError(network.id, _normalizeError(error));
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
    } catch (error) {
      _setJoinState(
        network.id,
        _JoinNetworkState.joinedWithIp(
          localDevice.ipv4,
          message: '退出网络失败：${_normalizeError(error)}',
        ),
      );
    }
  }

  Future<ManagedDevice?> _waitForLocalManagedDevice(String machineId) async {
    final workspace = _workspace;
    if (workspace == null) {
      return null;
    }

    for (var attempt = 0; attempt < _devicePollAttempts; attempt++) {
      final devices = await widget.authService.fetchManagedDevices(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );
      if (mounted) {
        setState(() {
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
      if (attempt < _devicePollAttempts - 1) {
        await Future<void>.delayed(_devicePollDelay);
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
        await Future<void>.delayed(_devicePollDelay);
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
    setState(() {
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
    setState(() {
      _networkDevices = {
        ..._networkDevices,
        networkId: devices
            .where(
              (device) => device.id != nodeId && device.machineId != machineId,
            )
            .toList(growable: false),
      };
      _joinStates = {..._joinStates, networkId: _JoinNetworkState.idle};
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

  List<ConsoleNetwork> _trafficPollNetworks() {
    if (!widget.coreLifecycleService.status.value.isRunning) {
      return const <ConsoleNetwork>[];
    }
    return _networks
        .where((network) {
          if (network.runtimeNetworkName.trim().isEmpty) {
            return false;
          }
          return _joinStateFor(network).phase == _JoinPhase.joined;
        })
        .toList(growable: false);
  }

  void _refreshTrafficPolling() {
    if (!mounted) {
      return;
    }

    final networks = _trafficPollNetworks();
    if (networks.isEmpty) {
      _stopTrafficPolling(clearSnapshots: true);
      return;
    }

    final nextNetworkIds = networks.map((network) => network.id).toSet();
    final nextRuntimeNames = networks
        .map((network) => network.runtimeNetworkName.trim())
        .toSet();
    final pollTargetsChanged = !setEquals(
      _trafficPollNetworkIds,
      nextNetworkIds,
    );
    _trafficPollNetworkIds = nextNetworkIds;
    _pruneTrafficState(nextNetworkIds, nextRuntimeNames);

    if (_trafficPollTimer == null) {
      _trafficPollTimer = Timer.periodic(
        _trafficPollInterval,
        (_) => unawaited(_pollNetworkTraffic()),
      );
      unawaited(_pollNetworkTraffic());
    } else if (pollTargetsChanged) {
      unawaited(_pollNetworkTraffic());
    }
  }

  void _stopTrafficPolling({required bool clearSnapshots}) {
    _trafficPollTimer?.cancel();
    _trafficPollTimer = null;
    _trafficPollNetworkIds = const <String>{};
    _previousTrafficTotals = const <String, CoreNetworkTrafficTotals>{};
    if (!clearSnapshots || _networkTraffic.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _networkTraffic = const <String, _NetworkTrafficSnapshot>{};
    });
  }

  void _pruneTrafficState(
    Set<String> activeNetworkIds,
    Set<String> activeRuntimeNames,
  ) {
    var changed = false;
    final nextTraffic = Map<String, _NetworkTrafficSnapshot>.from(
      _networkTraffic,
    );
    nextTraffic.removeWhere((networkId, _) {
      final remove = !activeNetworkIds.contains(networkId);
      changed = changed || remove;
      return remove;
    });

    final nextPrevious = Map<String, CoreNetworkTrafficTotals>.from(
      _previousTrafficTotals,
    );
    nextPrevious.removeWhere((runtimeName, _) {
      final remove = !activeRuntimeNames.contains(runtimeName);
      changed = changed || remove;
      return remove;
    });

    if (!changed || !mounted) {
      return;
    }
    setState(() {
      _networkTraffic = nextTraffic;
      _previousTrafficTotals = nextPrevious;
    });
  }

  Future<void> _pollNetworkTraffic() async {
    if (_isTrafficPollInFlight || !mounted) {
      return;
    }
    var networks = _trafficPollNetworks();
    if (networks.isEmpty) {
      _refreshTrafficPolling();
      return;
    }

    _isTrafficPollInFlight = true;
    try {
      final totalsByRuntimeName = await widget.coreLifecycleService
          .readNetworkTrafficTotals();
      if (!mounted) {
        return;
      }

      networks = _trafficPollNetworks();
      if (networks.isEmpty) {
        _refreshTrafficPolling();
        return;
      }

      final activeNetworkIds = networks.map((network) => network.id).toSet();
      final activeRuntimeNames = networks
          .map((network) => network.runtimeNetworkName.trim())
          .toSet();
      final nextTraffic = Map<String, _NetworkTrafficSnapshot>.from(
        _networkTraffic,
      );
      final nextPrevious = Map<String, CoreNetworkTrafficTotals>.from(
        _previousTrafficTotals,
      );

      for (final network in networks) {
        final runtimeName = network.runtimeNetworkName.trim();
        final totals = totalsByRuntimeName[runtimeName];
        if (totals == null) {
          nextTraffic.remove(network.id);
          nextPrevious.remove(runtimeName);
          continue;
        }

        final previous = nextPrevious[runtimeName];
        nextTraffic[network.id] = _NetworkTrafficSnapshot.fromTotals(
          totals,
          previous: previous,
        );
        nextPrevious[runtimeName] = totals;
      }

      nextTraffic.removeWhere(
        (networkId, _) => !activeNetworkIds.contains(networkId),
      );
      nextPrevious.removeWhere(
        (runtimeName, _) => !activeRuntimeNames.contains(runtimeName),
      );

      setState(() {
        _networkTraffic = nextTraffic;
        _previousTrafficTotals = nextPrevious;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _networkTraffic = const <String, _NetworkTrafficSnapshot>{};
        _previousTrafficTotals = const <String, CoreNetworkTrafficTotals>{};
      });
    } finally {
      _isTrafficPollInFlight = false;
    }
  }

  ConsoleNetwork? _peerPollNetwork() {
    if (!widget.coreLifecycleService.status.value.isRunning ||
        _activeView != _DashboardView.network) {
      return null;
    }

    final network =
        _selectedNetwork ?? (_networks.isEmpty ? null : _networks.first);
    if (network == null || network.runtimeNetworkName.trim().isEmpty) {
      return null;
    }
    if (_joinStateFor(network).phase != _JoinPhase.joined) {
      return null;
    }
    return network;
  }

  void _refreshPeerPolling() {
    if (!mounted) {
      return;
    }

    final network = _peerPollNetwork();
    if (network == null) {
      _stopPeerPolling(
        clearSnapshots: !widget.coreLifecycleService.status.value.isRunning,
      );
      return;
    }

    final targetChanged = _peerPollNetworkId != network.id;
    _peerPollNetworkId = network.id;
    if (_peerPollTimer == null) {
      _peerPollTimer = Timer.periodic(
        _peerPollInterval,
        (_) => unawaited(_pollSelectedNetworkPeers()),
      );
      unawaited(_pollSelectedNetworkPeers());
    } else if (targetChanged) {
      unawaited(_pollSelectedNetworkPeers());
    }
  }

  void _stopPeerPolling({required bool clearSnapshots}) {
    _peerPollTimer?.cancel();
    _peerPollTimer = null;
    _peerPollNetworkId = null;
    if (!clearSnapshots || !mounted) {
      return;
    }
    setState(() {
      _networkPeerStatuses = const <String, Map<String, CorePeerStatus>>{};
      _peerStatusErrors = const <String, String>{};
    });
  }

  Future<void> _pollSelectedNetworkPeers() async {
    final network = _peerPollNetwork();
    if (network == null) {
      _refreshPeerPolling();
      return;
    }
    await _pollNetworkPeers(network);
  }

  Future<void> _pollNetworkPeers(ConsoleNetwork network) async {
    if (_isPeerPollInFlight || !mounted) {
      return;
    }
    if (!widget.coreLifecycleService.status.value.isRunning ||
        _joinStateFor(network).phase != _JoinPhase.joined) {
      return;
    }
    final runtimeNetworkName = network.runtimeNetworkName.trim();
    if (runtimeNetworkName.isEmpty) {
      return;
    }

    _isPeerPollInFlight = true;
    try {
      final statuses = await widget.coreLifecycleService
          .readNetworkPeerStatuses(runtimeNetworkName);
      if (!mounted) {
        return;
      }
      setState(() {
        _networkPeerStatuses = {..._networkPeerStatuses, network.id: statuses};
        final nextErrors = Map<String, String>.from(_peerStatusErrors)
          ..remove(network.id);
        _peerStatusErrors = nextErrors;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        final nextStatuses = Map<String, Map<String, CorePeerStatus>>.from(
          _networkPeerStatuses,
        )..remove(network.id);
        _networkPeerStatuses = nextStatuses;
        _peerStatusErrors = {
          ..._peerStatusErrors,
          network.id: _normalizeError(error),
        };
      });
    } finally {
      _isPeerPollInFlight = false;
    }
  }

  void _openNetworkDetail(ConsoleNetwork network) {
    setState(() {
      _selectedNetworkId = network.id;
      _activeView = _DashboardView.network;
    });
    _refreshPeerPolling();
    unawaited(_loadSingleNetworkDevices(network.id));
  }

  void _showOverview() {
    setState(() {
      _activeView = _DashboardView.overview;
    });
    _refreshPeerPolling();
  }

  void _selectNetwork(String networkId) {
    setState(() {
      _selectedNetworkId = networkId;
      _activeView = _DashboardView.network;
    });
    _refreshPeerPolling();
    unawaited(_loadSingleNetworkDevices(networkId));
  }

  void _showDevices() {
    setState(() {
      _activeView = _DashboardView.devices;
    });
    _refreshPeerPolling();
    if (!_isLoadingDevices) {
      unawaited(_loadManagedDevices());
    }
  }

  void _showSettings() {
    setState(() {
      _activeView = _DashboardView.settings;
    });
    _refreshPeerPolling();
  }

  @override
  Widget build(BuildContext context) {
    final workspaceName = _workspace?.name ?? '未关联工作区';
    final contentKey = ValueKey<String>(
      [
        _activeView.name,
        if (_activeView == _DashboardView.network) _selectedNetworkId ?? 'none',
      ].join(':'),
    );

    return FScaffold(
      childPad: false,
      child: Column(
        children: [
          _DashboardHeader(
            userName: widget.session.user.effectiveName,
            workspaceName: workspaceName,
            activeView: _activeView,
            networks: _networks,
            deviceCount: _totalDeviceCount,
            onlineDeviceCount: _onlineDeviceCount,
            selectedNetworkId: _selectedNetworkId,
            onShowOverview: _showOverview,
            onSelectNetwork: _selectNetwork,
            onShowDevices: _showDevices,
            onShowSettings: _showSettings,
            onLogout: widget.onLogout,
            coreStatusListenable: widget.coreLifecycleService.status,
          ),
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
              child: AnimatedSwitcher(
                duration: appMotionMedium,
                reverseDuration: appMotionShort,
                transitionBuilder: appFadeSlideTransition,
                layoutBuilder: appSwitcherStackLayout,
                child: KeyedSubtree(
                  key: contentKey,
                  child: _activeView == _DashboardView.network
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1040),
                              child: _buildContent(context),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          physics: appScrollPhysics,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1040),
                              child: _buildContent(context),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return switch (_activeView) {
      _DashboardView.overview => _buildConnectionWorkspace(context),
      _DashboardView.network => _buildNetworkPage(context),
      _DashboardView.devices => _buildDevicesPage(context),
      _DashboardView.settings => _SettingsPanel(
        user: widget.session.user,
        workspaceName: _workspace?.name ?? '未关联工作区',
        onLogout: widget.onLogout,
        coreLifecycleService: widget.coreLifecycleService,
      ),
    };
  }

  Widget _buildConnectionWorkspace(BuildContext context) {
    final joinedNetworks = _networks
        .where((network) {
          return _joinStateFor(network).phase == _JoinPhase.joined;
        })
        .toList(growable: false);

    var totalDownloadRate = 0.0;
    var totalUploadRate = 0.0;
    for (final network in joinedNetworks) {
      final traffic = _networkTraffic[network.id];
      if (traffic != null) {
        totalDownloadRate += traffic.downloadBytesPerSecond ?? 0;
        totalUploadRate += traffic.uploadBytesPerSecond ?? 0;
      }
    }

    final sortedNetworks = List<ConsoleNetwork>.of(_networks);
    sortedNetworks.sort((a, b) {
      final aJoined = _joinStateFor(a).phase == _JoinPhase.joined;
      final bJoined = _joinStateFor(b).phase == _JoinPhase.joined;
      if (aJoined && !bJoined) return -1;
      if (!aJoined && bJoined) return 1;
      return a.name.compareTo(b.name);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusBadge(
          statusListenable: widget.coreLifecycleService.status,
          joinedCount: joinedNetworks.length,
          downloadRate: totalDownloadRate,
          uploadRate: totalUploadRate,
        ),
        const SizedBox(height: 24),
        if (_networkError != null)
          _StateMessage(
            message: _networkError!,
            action: FButton(onPress: _loadNetworks, child: const Text('重试')),
          )
        else if (_isLoadingNetworks)
          const SizedBox(height: 260, child: Center(child: FCircularProgress()))
        else if (_networks.isEmpty)
          _CreateNetworkPanel(
            name: _newNetworkName,
            ipv4Cidr: _newNetworkIPv4Cidr,
            selectedRegionCode: _selectedRegionCode,
            regions: _activeRegions,
            loadingRegions: _isLoadingRegions,
            creating: _isCreatingNetwork,
            error: _createError ?? _regionError,
            onNameChanged: (value) => setState(() => _newNetworkName = value),
            onIPv4CidrChanged: (value) =>
                setState(() => _newNetworkIPv4Cidr = value),
            onRegionChanged: (value) =>
                setState(() => _selectedRegionCode = value),
            onCreate: _createNetwork,
            onRetryRegions: _loadRegions,
          )
        else
          _NetworkSwitchList(
            networks: sortedNetworks,
            networkDevices: _networkDevices,
            trafficByNetworkId: _networkTraffic,
            joinStateFor: _joinStateFor,
            onJoin: _joinNetwork,
            onLeave: _leaveNetwork,
            onOpen: _openNetworkDetail,
            onCreate: _showCreateNetworkDialog,
          ),
      ],
    );
  }

  Widget _buildNetworkPage(BuildContext context) {
    if (_isLoadingNetworks) {
      return const SizedBox(
        height: 360,
        child: Center(child: FCircularProgress()),
      );
    }

    if (_networkError != null) {
      return _StateMessage(
        message: _networkError!,
        action: FButton(onPress: _loadNetworks, child: const Text('重试')),
      );
    }

    if (_networks.isEmpty) {
      return _CreateNetworkPanel(
        name: _newNetworkName,
        ipv4Cidr: _newNetworkIPv4Cidr,
        selectedRegionCode: _selectedRegionCode,
        regions: _activeRegions,
        loadingRegions: _isLoadingRegions,
        creating: _isCreatingNetwork,
        error: _createError ?? _regionError,
        onNameChanged: (value) => setState(() => _newNetworkName = value),
        onIPv4CidrChanged: (value) =>
            setState(() => _newNetworkIPv4Cidr = value),
        onRegionChanged: (value) => setState(() => _selectedRegionCode = value),
        onCreate: _createNetwork,
        onRetryRegions: _loadRegions,
      );
    }

    final network = _selectedNetwork ?? _networks.first;
    final devices = (_networkDevices[network.id] ?? const <NetworkDevice>[])
        .where((device) => device.attached)
        .toList(growable: false);
    final onlineCount = devices.where((device) => device.online).length;
    final state = _joinStateFor(network);
    final joined = state.phase == _JoinPhase.joined;
    final peerStatuses =
        _networkPeerStatuses[network.id] ?? const <String, CorePeerStatus>{};
    final peerStatusError = _peerStatusErrors[network.id];

    final regionText = network.regions.isEmpty
        ? '-'
        : network.regions.join(', ');
    final cidrText = network.ipv4Cidr.trim().isEmpty
        ? '-'
        : network.ipv4Cidr.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    network.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_workspace?.name ?? '未关联工作区'} · $regionText · CIDR $cidrText · ID ${network.id}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (joined)
              FButton(
                variant: .outline,
                size: .sm,
                onPress: () => unawaited(_leaveNetwork(network)),
                child: const Text('退出网络'),
              )
            else
              FButton(
                size: .sm,
                onPress: () => unawaited(_joinNetwork(network)),
                child: const Text('加入网络'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _NetworkSummaryBar(
          totalDevices: devices.length,
          onlineDevices: onlineCount,
          traffic: _networkTraffic[network.id],
          onRefresh: () => unawaited(_refreshNetworkNodes(network)),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Text(
              '节点',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const Spacer(),
            FBadge(
              variant: .secondary,
              child: Text('${devices.length} 台'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: NetworkNodeListViewport(
            nodes: devices,
            peerStatusesByIpv4: peerStatuses,
            runtimeError: peerStatusError,
          ),
        ),
      ],
    );
  }

  Widget _buildDevicesPage(BuildContext context) {
    final devices = List<ManagedDevice>.of(_managedDevices);
    devices.sort((a, b) {
      if (a.online && !b.online) return -1;
      if (!a.online && b.online) return 1;
      if (a.approved && !b.approved) return -1;
      if (!a.approved && b.approved) return 1;
      return a.hostname.compareTo(b.hostname);
    });

    final onlineCount = devices.where((device) => device.online).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '设备',
          subtitle: '工作区中的所有设备与在线状态。',
          trailing: FButton(
            variant: .outline,
            size: .sm,
            onPress: _isLoadingDevices
                ? null
                : () => unawaited(_loadManagedDevices()),
            child: Text(_isLoadingDevices ? '刷新中' : '刷新设备'),
          ),
        ),
        const SizedBox(height: 20),
        if (_deviceError != null) ...[
          SizedBox(
            height: 120,
            child: _StateMessage(
              message: _deviceError!,
              action: FButton(
                variant: .outline,
                size: .sm,
                onPress: _isLoadingDevices
                    ? null
                    : () => unawaited(_loadManagedDevices()),
                child: const Text('重试'),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        Row(
          children: [
            Text('设备列表', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            FBadge(
              variant: .secondary,
              child: Text('$onlineCount / ${devices.length} 台在线'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          SizedBox(
            height: 200,
            child: _StateMessage(
              message: _isLoadingDevices ? '正在读取设备列表。' : '暂无设备数据。',
            ),
          )
        else
          FCard.raw(
            child: _ConstrainedFItemGroup(
              divider: .full,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final device in devices)
                  FItem(
                    prefix: _StatusDot(online: device.online),
                    title: Text(device.hostname),
                    subtitle: Text(
                      [
                        '审批: ${_approvalLabel(device)}',
                        '连接: ${_connectivityLabel(device)}',
                        '机器: ${_shortId(device.machineId)}',
                        'ID: ${device.id}',
                      ].join('  |  '),
                    ),
                    suffix: FBadge(
                      variant: device.online ? .secondary : .outline,
                      child: Text(_connectivityLabel(device)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _normalizeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }
}

String _formatTotalTraffic(_NetworkTrafficSnapshot? traffic) {
  if (traffic == null) {
    return '流量统计暂不可用';
  }
  return '下载 ${_formatBytes(traffic.downloadBytes)} / 上传 ${_formatBytes(traffic.uploadBytes)}';
}

String _formatTrafficRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) {
    return '计算中';
  }
  return '${_formatBytes(bytesPerSecond)}/s';
}

String _formatBytes(num bytes) {
  const units = <String>['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value = value / 1024;
    unitIndex++;
  }
  if (unitIndex == 0) {
    return '${value.round()} ${units[unitIndex]}';
  }
  final decimals = value >= 10 ? 1 : 2;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.userName,
    required this.workspaceName,
    required this.activeView,
    required this.networks,
    required this.deviceCount,
    required this.onlineDeviceCount,
    required this.selectedNetworkId,
    required this.onShowOverview,
    required this.onSelectNetwork,
    required this.onShowDevices,
    required this.onShowSettings,
    required this.onLogout,
    required this.coreStatusListenable,
  });

  final String userName;
  final String workspaceName;
  final _DashboardView activeView;
  final List<ConsoleNetwork> networks;
  final int deviceCount;
  final int onlineDeviceCount;
  final String? selectedNetworkId;
  final VoidCallback onShowOverview;
  final ValueChanged<String> onSelectNetwork;
  final VoidCallback onShowDevices;
  final VoidCallback onShowSettings;
  final Future<void> Function() onLogout;
  final ValueListenable<CoreRunStatus> coreStatusListenable;

  @override
  Widget build(BuildContext context) {
    final trimmedName = userName.trim();
    final initial = trimmedName.isEmpty ? 'U' : trimmedName.substring(0, 1);

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFFFFFFFF),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < _dashboardHeaderCompactBreakpoint;
          final dense = constraints.maxWidth < _dashboardHeaderDenseBreakpoint;

          return Row(
            children: [
              const _BrandMark(),
              if (dense)
                const SizedBox(width: 8)
              else ...[
                const SizedBox(width: 8),
                Text(
                  'EasyTier Pro',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: appScrollPhysics,
                  child: Row(
                    children: [
                      FButton(
                        variant: activeView == _DashboardView.overview
                            ? .secondary
                            : .ghost,
                        size: .sm,
                        onPress: onShowOverview,
                        child: const Text('首页'),
                      ),
                      if (networks.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _NetworkTabMenu(
                          active: activeView == _DashboardView.network,
                          networks: networks,
                          selectedNetworkId: selectedNetworkId,
                          onSelectNetwork: onSelectNetwork,
                        ),
                      ],
                      const SizedBox(width: 6),
                      FButton(
                        variant: activeView == _DashboardView.devices
                            ? .secondary
                            : .ghost,
                        size: .sm,
                        onPress: onShowDevices,
                        child: const Text('设备'),
                      ),
                      const SizedBox(width: 6),
                      FButton(
                        variant: activeView == _DashboardView.settings
                            ? .secondary
                            : .ghost,
                        size: .sm,
                        onPress: onShowSettings,
                        child: const Text('设置'),
                      ),
                    ],
                  ),
                ),
              ),
              if (!compact) const SizedBox(width: 16),
              if (!compact) ...[
                _HeaderMetric(
                  label: '设备',
                  value: '$deviceCount',
                  icon: Icons.devices_other_outlined,
                ),
                const SizedBox(width: 10),
                _HeaderMetric(
                  label: '在线',
                  value: '$onlineDeviceCount',
                  icon: Icons.circle,
                  color: onlineDeviceCount > 0
                      ? const Color(0xFF16A34A)
                      : Colors.grey,
                ),
                const SizedBox(width: 10),
                ValueListenableBuilder<CoreRunStatus>(
                  valueListenable: coreStatusListenable,
                  builder: (context, status, _) {
                    final color = switch (status.phase) {
                      CoreRunPhase.running => const Color(0xFF16A34A),
                      CoreRunPhase.repairing => const Color(0xFFF59E0B),
                      CoreRunPhase.checking => const Color(0xFF2563EB),
                      CoreRunPhase.error => const Color(0xFFDC2626),
                      CoreRunPhase.signedOut => Colors.grey,
                    };
                    return Row(
                      children: [
                        Icon(Icons.circle, size: 12, color: color),
                        const SizedBox(width: 5),
                        Text(
                          '引擎',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: const Color(0xFF737373),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    );
                  },
                ),
              ],
              const SizedBox(width: 12),
              _UserMenu(
                userName: trimmedName,
                workspaceName: workspaceName,
                initial: initial,
                onShowSettings: onShowSettings,
                onLogout: onLogout,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NetworkTabMenu extends StatelessWidget {
  const _NetworkTabMenu({
    required this.active,
    required this.networks,
    required this.selectedNetworkId,
    required this.onSelectNetwork,
  });

  final bool active;
  final List<ConsoleNetwork> networks;
  final String? selectedNetworkId;
  final ValueChanged<String> onSelectNetwork;

  @override
  Widget build(BuildContext context) {
    var selectedNetwork = networks.first;
    for (final network in networks) {
      if (network.id == selectedNetworkId) {
        selectedNetwork = network;
        break;
      }
    }

    return FPopoverMenu(
      menuAnchor: Alignment.topRight,
      childAnchor: Alignment.bottomRight,
      maxHeight: 280,
      divider: FItemDivider.none,
      menuBuilder: (context, controller, menu) => [
        FItemGroup(
          key: const ValueKey<String>('network-tab-popover'),
          divider: FItemDivider.none,
          children: [
            for (final network in networks)
              FItem(
                key: ValueKey<String>('network-tab-option-${network.id}'),
                title: Text(network.name, overflow: TextOverflow.ellipsis),
                prefix: SizedBox(
                  width: 18,
                  child: network.id == selectedNetwork.id
                      ? const Icon(Icons.check, size: 16)
                      : null,
                ),
                onPress: () {
                  unawaited(controller.hide());
                  onSelectNetwork(network.id);
                },
              ),
          ],
        ),
      ],
      builder: (context, controller, child) => _NetworkTabButton(
        active: active,
        label: selectedNetwork.name,
        onSelect: () {
          if (active) {
            unawaited(controller.toggle());
          } else {
            onSelectNetwork(selectedNetwork.id);
          }
        },
        onOpenMenu: () => unawaited(controller.toggle()),
      ),
    );
  }
}

class _NetworkTabButton extends StatelessWidget {
  const _NetworkTabButton({
    required this.active,
    required this.label,
    required this.onSelect,
    required this.onOpenMenu,
  });

  static const double _labelMinWidth = 44;
  static const double _labelMaxWidth = 112;

  final bool active;
  final String label;
  final VoidCallback onSelect;
  final VoidCallback onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: AlignmentDirectional.centerEnd,
      children: [
        FButton(
          key: const ValueKey<String>('network-tab-current'),
          variant: active ? .secondary : .ghost,
          size: .sm,
          onPress: onSelect,
          mainAxisSize: MainAxisSize.min,
          suffix: const Padding(
            padding: EdgeInsetsDirectional.only(start: 4),
            child: Icon(Icons.expand_more, size: 16),
          ),
          child: ConstrainedBox(
            key: const ValueKey<String>('network-tab-label'),
            constraints: const BoxConstraints(
              minWidth: _labelMinWidth,
              maxWidth: _labelMaxWidth,
            ),
            child: Text(label, overflow: TextOverflow.ellipsis),
          ),
        ),
        PositionedDirectional(
          top: 0,
          end: 0,
          bottom: 0,
          width: 34,
          child: FTappable.static(
            key: const ValueKey<String>('network-tab-dropdown'),
            behavior: HitTestBehavior.opaque,
            semanticsLabel: '切换网络',
            onPress: onOpenMenu,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _TrafficPill extends StatelessWidget {
  const _TrafficPill({
    required this.icon,
    required this.label,
    required this.bgColor,
    required this.textColor,
  });

  final IconData icon;
  final String label;
  final Color bgColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withAlpha(51)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.statusListenable,
    required this.joinedCount,
    required this.downloadRate,
    required this.uploadRate,
  });

  final ValueListenable<CoreRunStatus> statusListenable;
  final int joinedCount;
  final double downloadRate;
  final double uploadRate;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: statusListenable,
      builder: (context, status, _) {
        final running = status.phase == CoreRunPhase.running;
        final error = status.phase == CoreRunPhase.error;
        final checking = status.phase == CoreRunPhase.checking;
        final signedOut = status.phase == CoreRunPhase.signedOut;

        final ringColor = error
            ? const Color(0xFFDC2626)
            : checking || signedOut
            ? const Color(0xFF9CA3AF)
            : running
            ? const Color(0xFF16A34A)
            : const Color(0xFF2563EB);

        final bgColor = error
            ? const Color(0xFFFEE2E2)
            : checking || signedOut
            ? const Color(0xFFF3F4F6)
            : running
            ? const Color(0xFFF0FDF4)
            : const Color(0xFFDBEAFE);

        final borderColor = error
            ? const Color(0xFFFECACA)
            : checking || signedOut
            ? const Color(0xFFE5E7EB)
            : running
            ? const Color(0xFFBBF7D0)
            : const Color(0xFFBFDBFE);

        final icon = error
            ? Icons.error_outline
            : checking
            ? Icons.sync
            : running
            ? Icons.check
            : Icons.power_settings_new;

        final title = error
            ? '引擎异常'
            : checking
            ? '正在检查'
            : running
            ? '已在线'
            : '准备中';

        final machineId = status.machineId;
        final String subtitle;
        if (error) {
          subtitle = status.lastError?.isNotEmpty == true
              ? status.lastError!
              : '连接引擎遇到问题';
        } else if (joinedCount > 0) {
          subtitle = '$joinedCount 个网络';
        } else {
          subtitle = machineId?.isNotEmpty == true
              ? '设备 ${_shortId(machineId!)} · 尚未加入网络'
              : '正在初始化设备...';
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor, width: 3),
                ),
                child: Center(child: Icon(icon, color: ringColor, size: 22)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (joinedCount > 0 && !error) ...[
                const SizedBox(width: 12),
                _TrafficPill(
                  icon: Icons.arrow_downward,
                  label: _formatTrafficRate(downloadRate),
                  bgColor: const Color(0xFFF0FDF4),
                  textColor: const Color(0xFF16A34A),
                ),
                const SizedBox(width: 8),
                _TrafficPill(
                  icon: Icons.arrow_upward,
                  label: _formatTrafficRate(uploadRate),
                  bgColor: const Color(0xFFEFF6FF),
                  textColor: const Color(0xFF2563EB),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CreateNetworkForm extends StatelessWidget {
  const _CreateNetworkForm({
    required this.name,
    required this.ipv4Cidr,
    required this.selectedRegionCode,
    required this.regions,
    required this.loadingRegions,
    required this.creating,
    required this.error,
    required this.onNameChanged,
    required this.onIPv4CidrChanged,
    required this.onRegionChanged,
    required this.onCreate,
    required this.onRetryRegions,
  });

  final String name;
  final String ipv4Cidr;
  final String? selectedRegionCode;
  final List<ConsoleRegion> regions;
  final bool loadingRegions;
  final bool creating;
  final String? error;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onIPv4CidrChanged;
  final ValueChanged<String?> onRegionChanged;
  final Future<void> Function() onCreate;
  final Future<void> Function() onRetryRegions;

  @override
  Widget build(BuildContext context) {
    final canCreate = regions.isNotEmpty && !loadingRegions && !creating;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 480;
            final nameField = FTextField(
              key: ValueKey<String>(name),
              control: FTextFieldControl.managed(
                initial: TextEditingValue(text: name),
                onChange: (value) => onNameChanged(value.text),
              ),
              size: .sm,
              label: const Text('网络名称'),
            );
            final cidrField = FTextField(
              key: ValueKey<String>('cidr:$ipv4Cidr'),
              control: FTextFieldControl.managed(
                initial: TextEditingValue(text: ipv4Cidr),
                onChange: (value) => onIPv4CidrChanged(value.text),
              ),
              size: .sm,
              label: const Text('网络地址范围'),
              hint: '10.144.0.0/16',
              keyboardType: TextInputType.text,
            );
            final regionField = FSelect<String>(
              key: ValueKey<String?>(selectedRegionCode),
              control: FSelectControl.lifted(
                value: selectedRegionCode,
                onChange: onRegionChanged,
              ),
              size: .sm,
              label: const Text('区域'),
              items: {
                for (final region in regions) region.displayName: region.code,
              },
              enabled: !loadingRegions && regions.isNotEmpty,
            );
            if (!wide) {
              return Column(
                children: [
                  nameField,
                  const SizedBox(height: 12),
                  cidrField,
                  const SizedBox(height: 12),
                  regionField,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: nameField),
                const SizedBox(width: 12),
                Expanded(child: cidrField),
                const SizedBox(width: 12),
                Expanded(child: regionField),
              ],
            );
          },
        ),
        if (loadingRegions) ...[
          const SizedBox(height: 12),
          const Row(
            children: [
              FCircularProgress(size: .sm),
              SizedBox(width: 8),
              Text('正在读取可用区域...'),
            ],
          ),
        ],
        if (!loadingRegions && regions.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '当前没有可用区域，暂时无法创建网络。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFFDC2626)),
          ),
        ],
        if (error != null && error!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFFDC2626)),
          ),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FButton(
              onPress: canCreate ? () => unawaited(onCreate()) : null,
              child: Text(creating ? '正在创建...' : '创建网络'),
            ),
            FButton(
              variant: .outline,
              onPress: loadingRegions
                  ? null
                  : () => unawaited(onRetryRegions()),
              child: const Text('刷新区域'),
            ),
          ],
        ),
      ],
    );
  }
}

class _CreateNetworkPanel extends StatelessWidget {
  const _CreateNetworkPanel({
    required this.name,
    required this.ipv4Cidr,
    required this.selectedRegionCode,
    required this.regions,
    required this.loadingRegions,
    required this.creating,
    required this.error,
    required this.onNameChanged,
    required this.onIPv4CidrChanged,
    required this.onRegionChanged,
    required this.onCreate,
    required this.onRetryRegions,
  });

  final String name;
  final String ipv4Cidr;
  final String? selectedRegionCode;
  final List<ConsoleRegion> regions;
  final bool loadingRegions;
  final bool creating;
  final String? error;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onIPv4CidrChanged;
  final ValueChanged<String?> onRegionChanged;
  final Future<void> Function() onCreate;
  final Future<void> Function() onRetryRegions;

  @override
  Widget build(BuildContext context) {
    return FCard.raw(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('创建第一个网络', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '当前工作区还没有网络。先创建网络，然后把本机设备加入进去。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF737373)),
            ),
            const SizedBox(height: 18),
            _CreateNetworkForm(
              name: name,
              ipv4Cidr: ipv4Cidr,
              selectedRegionCode: selectedRegionCode,
              regions: regions,
              loadingRegions: loadingRegions,
              creating: creating,
              error: error,
              onNameChanged: onNameChanged,
              onIPv4CidrChanged: onIPv4CidrChanged,
              onRegionChanged: onRegionChanged,
              onCreate: onCreate,
              onRetryRegions: onRetryRegions,
            ),
          ],
        ),
      ),
    );
  }
}

class _UserMenu extends StatelessWidget {
  const _UserMenu({
    required this.userName,
    required this.workspaceName,
    required this.initial,
    required this.onShowSettings,
    required this.onLogout,
  });

  final String userName;
  final String workspaceName;
  final String initial;
  final VoidCallback onShowSettings;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final displayName = userName.isEmpty ? '用户' : userName;

    return FPopoverMenu(
      menuAnchor: Alignment.topRight,
      childAnchor: Alignment.bottomRight,
      divider: FItemDivider.full,
      menuBuilder: (context, controller, menu) => [
        FItemGroup(
          divider: FItemDivider.full,
          children: [
            FItem.raw(
              enabled: false,
              child: SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF0A0A0A),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      workspaceName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF737373),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            FItem(
              prefix: const Icon(Icons.settings_outlined, size: 18),
              title: const Text('设置'),
              onPress: () {
                unawaited(controller.hide());
                onShowSettings();
              },
            ),
            FItem(
              prefix: const Icon(Icons.logout_outlined, size: 18),
              title: const Text('退出登录'),
              onPress: () {
                unawaited(controller.hide());
                unawaited(onLogout());
              },
            ),
          ],
        ),
      ],
      builder: (context, controller, child) => FButton(
        variant: .ghost,
        size: .sm,
        onPress: () => unawaited(controller.toggle()),
        mainAxisSize: MainAxisSize.min,
        suffix: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
        child: FAvatar.raw(size: 30, child: Text(initial.toUpperCase())),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/easytier.png',
      width: 30,
      height: 30,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color ?? const Color(0xFF737373)),
        const SizedBox(width: 5),
        Text(
          '$label $value',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF737373),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF737373),
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 16), trailing!],
      ],
    );
  }
}

class _ConstrainedFItemGroup extends StatelessWidget {
  const _ConstrainedFItemGroup({
    required this.children,
    this.divider = FItemDivider.none,
    this.physics = appScrollPhysics,
  });

  final List<FItemMixin> children;
  final FItemDivider divider;
  final ScrollPhysics physics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth ||
            constraints.maxWidth >= _itemListMinWidth) {
          return FItemGroup(
            divider: divider,
            physics: physics,
            children: children,
          );
        }

        return SingleChildScrollView(
          primary: false,
          scrollDirection: Axis.horizontal,
          physics: appScrollPhysics,
          child: SizedBox(
            width: _itemListMinWidth,
            child: FItemGroup(
              divider: divider,
              physics: physics,
              children: children,
            ),
          ),
        );
      },
    );
  }
}

class _NetworkSummaryBar extends StatelessWidget {
  const _NetworkSummaryBar({
    required this.totalDevices,
    required this.onlineDevices,
    required this.traffic,
    required this.onRefresh,
  });

  final int totalDevices;
  final int onlineDevices;
  final _NetworkTrafficSnapshot? traffic;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _SummaryItem(
          icon: Icons.circle,
          iconColor: const Color(0xFF16A34A),
          text: '$onlineDevices / $totalDevices 在线',
        ),
        _SummaryItem(
          icon: Icons.arrow_downward,
          iconColor: const Color(0xFF16A34A),
          text: _formatTrafficRate(traffic?.downloadBytesPerSecond),
        ),
        _SummaryItem(
          icon: Icons.arrow_upward,
          iconColor: const Color(0xFF2563EB),
          text: _formatTrafficRate(traffic?.uploadBytesPerSecond),
        ),
        _SummaryItem(
          text: _formatTotalTraffic(traffic),
        ),
        FButton(
          variant: .outline,
          size: .sm,
          onPress: onRefresh,
          child: const Text('刷新节点'),
        ),
      ],
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({this.icon, this.iconColor, required this.text});

  final IconData? icon;
  final Color? iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: iconColor ?? const Color(0xFF94A3B8)),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF64748B),
          ),
        ),
      ],
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
  });

  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;

  void _showToast(
    BuildContext context,
    String message, {
    bool destructive = false,
  }) {
    showFToast(
      context: context,
      variant: destructive ? .destructive : .primary,
      title: Text(message),
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final file = await AppLogger.instance.exportDiagnostics();
      AppLogger.instance.info(
        'settings',
        'Diagnostics exported',
        context: {'file': file.path},
      );
      if (context.mounted) {
        _showToast(context, '诊断日志已导出: ${file.path}');
      }
    } catch (error) {
      AppLogger.instance.error(
        'settings',
        'Diagnostics export failed',
        context: {'error': error.toString()},
      );
      if (context.mounted) {
        _showToast(context, '导出诊断日志失败', destructive: true);
      }
    }
  }

  Future<void> _copyLogDirectory(BuildContext context) async {
    final path = AppLogger.instance.logDirectoryPath;
    if (path == null || path.isEmpty) {
      if (context.mounted) {
        _showToast(context, '日志目录尚未初始化', destructive: true);
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: path));
    if (context.mounted) {
      _showToast(context, '日志目录已复制: $path');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '设置', subtitle: '查看当前账号与桌面端辅助操作。'),
        const SizedBox(height: 20),
        FCard(
          title: const Text('账号'),
          child: Column(
            children: [
              const SizedBox(height: 8),
              _ConstrainedFItemGroup(
                divider: .full,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  FItem(
                    prefix: const Icon(Icons.person_outline),
                    title: const Text('用户'),
                    subtitle: Text(user.email.isEmpty ? '未提供邮箱' : user.email),
                    details: Text(
                      user.effectiveName.isEmpty ? '用户' : user.effectiveName,
                    ),
                  ),
                  FItem(
                    prefix: const Icon(Icons.apartment_outlined),
                    title: const Text('工作区'),
                    details: Text(workspaceName),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FButton(
                    variant: .outline,
                    onPress: () => unawaited(onLogout()),
                    child: const Text('退出登录'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        FCard(
          title: const Text('连接引擎'),
          subtitle: const Text('核心连接引擎状态与修复入口。'),
          child: ValueListenableBuilder<CoreRunStatus>(
            valueListenable: coreLifecycleService.status,
            builder: (context, status, _) {
              final running = status.phase == CoreRunPhase.running;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _StatusDot(online: running),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          status.message,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  if (status.machineId != null &&
                      status.machineId!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '本机设备: ${status.machineId}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF737373),
                      ),
                    ),
                  ],
                  if (status.lastError != null &&
                      status.lastError!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      status.lastError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFDC2626),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FButton(
                        variant: .outline,
                        onPress: () => unawaited(coreLifecycleService.repair()),
                        child: const Text('重试/修复'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        FCard(
          title: const Text('诊断日志'),
          subtitle: const Text('用于排查连接引擎红灯、安装失败和权限问题。'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FButton(
                    variant: .outline,
                    onPress: () => unawaited(_exportLogs(context)),
                    child: const Text('导出诊断日志'),
                  ),
                  FButton(
                    variant: .outline,
                    onPress: () => unawaited(_copyLogDirectory(context)),
                    child: const Text('复制日志目录'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<List<AppLogEntry>>(
                valueListenable: AppLogger.instance.recentEntries,
                builder: (context, entries, _) {
                  if (entries.isEmpty) {
                    return const Text('暂无日志');
                  }
                  final start = entries.length > 8 ? entries.length - 8 : 0;
                  final recent = entries.sublist(start);
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F9FB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Text(
                      recent.map((entry) => entry.humanLine).join('\n'),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NetworkSwitchList extends StatelessWidget {
  const _NetworkSwitchList({
    required this.networks,
    required this.networkDevices,
    required this.trafficByNetworkId,
    required this.joinStateFor,
    required this.onJoin,
    required this.onLeave,
    required this.onOpen,
    required this.onCreate,
  });

  final List<ConsoleNetwork> networks;
  final Map<String, List<NetworkDevice>> networkDevices;
  final Map<String, _NetworkTrafficSnapshot> trafficByNetworkId;
  final _JoinNetworkState Function(ConsoleNetwork) joinStateFor;
  final Future<void> Function(ConsoleNetwork) onJoin;
  final Future<void> Function(ConsoleNetwork) onLeave;
  final void Function(ConsoleNetwork) onOpen;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '网络',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const Spacer(),
            FButton(
              variant: .ghost,
              size: .sm,
              onPress: onCreate,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 16),
                  SizedBox(width: 4),
                  Text('新建网络'),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${networks.length} 个',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FCard.raw(
          child: Column(
            children: [
              for (var i = 0; i < networks.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _NetworkSwitchTile(
                  network: networks[i],
                  devices:
                      networkDevices[networks[i].id] ?? const <NetworkDevice>[],
                  state: joinStateFor(networks[i]),
                  traffic: trafficByNetworkId[networks[i].id],
                  onJoin: () => unawaited(onJoin(networks[i])),
                  onLeave: () => unawaited(onLeave(networks[i])),
                  onOpen: () => onOpen(networks[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _NetworkSwitchTile extends StatelessWidget {
  const _NetworkSwitchTile({
    required this.network,
    required this.devices,
    required this.state,
    required this.traffic,
    required this.onJoin,
    required this.onLeave,
    required this.onOpen,
  });

  final ConsoleNetwork network;
  final List<NetworkDevice> devices;
  final _JoinNetworkState state;
  final _NetworkTrafficSnapshot? traffic;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final attachedDevices = devices.where((d) => d.attached).toList();
    final onlineCount = attachedDevices.where((d) => d.online).length;
    final joined = state.phase == _JoinPhase.joined;
    final joining = state.phase == _JoinPhase.joining;
    final leaving = state.phase == _JoinPhase.leaving;
    final failed = state.phase == _JoinPhase.error;
    final localIpv4 = state.localIpv4?.trim();
    final cidrText = network.ipv4Cidr.trim();

    final switchValue = joined || joining;
    final isLoading = joining || leaving;
    final onToggle = isLoading
        ? null
        : () {
            if (joined) {
              onLeave();
            } else {
              onJoin();
            }
          };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onOpen,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    network.name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (joined && localIpv4 != null && localIpv4.isNotEmpty)
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0FDF4),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFBBF7D0)),
                          ),
                          child: Text(
                            localIpv4,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF15803D),
                                ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (traffic != null) ...[
                          Icon(
                            Icons.arrow_downward,
                            size: 11,
                            color: const Color(0xFF16A34A),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _formatTrafficRate(traffic!.downloadBytesPerSecond),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: const Color(0xFF16A34A),
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.arrow_upward,
                            size: 11,
                            color: const Color(0xFF2563EB),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _formatTrafficRate(traffic!.uploadBytesPerSecond),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: const Color(0xFF2563EB),
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ],
                      ],
                    )
                  else
                    Text(
                      [
                        if (cidrText.isNotEmpty) 'CIDR $cidrText',
                        '$onlineCount / ${attachedDevices.length} 台设备在线',
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  if (failed && state.message != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      state.message!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (isLoading)
            const SizedBox(
              width: 20,
              height: 20,
              child: FCircularProgress(size: .sm),
            )
          else
            FSwitch(
              value: switchValue,
              enabled: onToggle != null,
              onChange: (_) => onToggle?.call(),
            ),
        ],
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: online ? const Color(0xFF16A34A) : Colors.grey,
        shape: BoxShape.circle,
      ),
    );
  }
}

String _approvalLabel(ManagedDevice device) {
  return switch (device.approvalState.toLowerCase()) {
    'approved' => '已批准',
    'pending' => '待批准',
    'rejected' => '已拒绝',
    'removed' => '已移除',
    '' => '未知',
    _ => device.approvalState,
  };
}

String _connectivityLabel(ManagedDevice device) {
  return switch (device.connectivityState.toLowerCase()) {
    'online' => '在线',
    'connected' => '在线',
    'offline' => '离线',
    'disconnected' => '离线',
    'removed' => '已移除',
    '' => '未知',
    _ => device.connectivityState,
  };
}

String _shortId(String value) {
  if (value.length <= 8) {
    return value;
  }
  return value.substring(0, 8);
}
