import 'dart:async';

import 'package:forui/forui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/console_auth_service.dart';
import '../core/core_lifecycle_service.dart';
import '../logging/app_logger.dart';

enum _DashboardView {
  overview,
  network,
  networkDetail,
  nodes,
  services,
  settings,
}

enum _UserMenuAction { settings, logout }

enum _JoinPhase { idle, joining, joined, leaving, error }

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

  List<ConsoleNetwork> _networks = const <ConsoleNetwork>[];
  List<ConsoleRegion> _regions = const <ConsoleRegion>[];
  Map<String, List<NetworkDevice>> _networkDevices =
      const <String, List<NetworkDevice>>{};
  Map<String, _JoinNetworkState> _joinStates =
      const <String, _JoinNetworkState>{};
  String? _selectedNetworkId;
  String? _networkError;
  String? _regionError;
  String? _createError;
  bool _isLoadingNetworks = false;
  bool _isLoadingRegions = false;
  bool _isCreatingNetwork = false;
  _DashboardView _activeView = _DashboardView.overview;
  String _newNetworkName = '我的网络';
  String? _selectedRegionCode;
  int _networkRequestId = 0;
  int _regionRequestId = 0;

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
    final seen = <String>{};
    for (final devices in _networkDevices.values) {
      for (final device in devices) {
        if (!device.attached) {
          continue;
        }
        seen.add(device.deviceId ?? device.id);
      }
    }
    return seen.length;
  }

  int get _onlineDeviceCount {
    final seen = <String>{};
    for (final devices in _networkDevices.values) {
      for (final device in devices) {
        if (!device.attached) {
          continue;
        }
        if (device.online) {
          seen.add(device.deviceId ?? device.id);
        }
      }
    }
    return seen.length;
  }

  @override
  void initState() {
    super.initState();
    widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
    unawaited(_loadInitialData());
  }

  @override
  void dispose() {
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
    super.dispose();
  }

  void _onCoreStatusChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _loadInitialData() async {
    await Future.wait([_loadRegions(), _loadNetworks()]);
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
      });
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
  }

  Future<void> _createNetwork() async {
    final workspace = _workspace;
    final regionCode = _selectedRegionCode;
    final name = _newNetworkName.trim();
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
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _networks = [..._networks, network];
        _selectedNetworkId = network.id;
        _newNetworkName = '我的网络';
        _isCreatingNetwork = false;
        _activeView = _DashboardView.overview;
      });
      await _loadSingleNetworkDevices(network.id);
      unawaited(_loadNetworks());
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
      for (final device in devices) {
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
    });
  }

  void _openNetworkDetail(ConsoleNetwork network) {
    setState(() {
      _selectedNetworkId = network.id;
      _activeView = _DashboardView.networkDetail;
    });
    unawaited(_loadSingleNetworkDevices(network.id));
  }

  void _showOverview() {
    setState(() {
      _activeView = _DashboardView.overview;
    });
  }

  void _showNetwork() {
    setState(() {
      _activeView = _DashboardView.network;
    });
  }

  void _showNodes() {
    setState(() {
      _activeView = _DashboardView.nodes;
    });
  }

  void _showServices() {
    setState(() {
      _activeView = _DashboardView.services;
    });
  }

  void _showSettings() {
    setState(() {
      _activeView = _DashboardView.settings;
    });
  }

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final file = await AppLogger.instance.exportDiagnostics();
      AppLogger.instance.info(
        'home',
        'Diagnostics exported',
        context: {'file': file.path},
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('诊断日志已导出: ${file.path}')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出诊断日志失败')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspaceName = _workspace?.name ?? '未关联工作区';

    return FScaffold(
      childPad: false,
      child: Column(
        children: [
          _DashboardHeader(
            userName: widget.session.user.effectiveName,
            workspaceName: workspaceName,
            activeView: _activeView,
            networkCount: _networks.length,
            deviceCount: _totalDeviceCount,
            onlineDeviceCount: _onlineDeviceCount,
            onShowOverview: _showOverview,
            onShowNetwork: _showNetwork,
            onShowNodes: _showNodes,
            onShowServices: _showServices,
            onShowSettings: _showSettings,
            onLogout: widget.onLogout,
            coreStatusListenable: widget.coreLifecycleService.status,
          ),
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1040),
                    child: _buildContent(context),
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
      _DashboardView.network => _buildNetworkListPage(context),
      _DashboardView.networkDetail => _buildNetworkDetail(context),
      _DashboardView.nodes => _buildNodesPage(context),
      _DashboardView.services => _ServicesPanel(
        coreLifecycleService: widget.coreLifecycleService,
      ),
      _DashboardView.settings => _SettingsPanel(
        user: widget.session.user,
        workspaceName: _workspace?.name ?? '未关联工作区',
        onLogout: widget.onLogout,
      ),
    };
  }

  Widget _buildConnectionWorkspace(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CoreStatusPanel(
          statusListenable: widget.coreLifecycleService.status,
          workspaceName: _workspace?.name ?? '未关联工作区',
          onRepair: () => unawaited(widget.coreLifecycleService.repair()),
          onExportLogs: () => unawaited(_exportLogs(context)),
        ),
        const SizedBox(height: 20),
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
            selectedRegionCode: _selectedRegionCode,
            regions: _activeRegions,
            loadingRegions: _isLoadingRegions,
            creating: _isCreatingNetwork,
            error: _createError ?? _regionError,
            onNameChanged: (value) => setState(() => _newNetworkName = value),
            onRegionChanged: (value) =>
                setState(() => _selectedRegionCode = value),
            onCreate: _createNetwork,
            onRetryRegions: _loadRegions,
          )
        else
          _NetworkJoinList(
            title: '工作区网络',
            subtitle: '选择要让本机设备加入的网络。',
            networks: _networks,
            networkDevices: _networkDevices,
            joinStateFor: _joinStateFor,
            onJoin: _joinNetwork,
            onLeave: _leaveNetwork,
            onOpen: _openNetworkDetail,
            onRefresh: _loadNetworks,
          ),
      ],
    );
  }

  Widget _buildNetworkListPage(BuildContext context) {
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
        selectedRegionCode: _selectedRegionCode,
        regions: _activeRegions,
        loadingRegions: _isLoadingRegions,
        creating: _isCreatingNetwork,
        error: _createError ?? _regionError,
        onNameChanged: (value) => setState(() => _newNetworkName = value),
        onRegionChanged: (value) => setState(() => _selectedRegionCode = value),
        onCreate: _createNetwork,
        onRetryRegions: _loadRegions,
      );
    }

    return _NetworkJoinList(
      title: '所有网络',
      subtitle: '每个网络都可以单独加入。',
      networks: _networks,
      networkDevices: _networkDevices,
      joinStateFor: _joinStateFor,
      onJoin: _joinNetwork,
      onLeave: _leaveNetwork,
      onOpen: _openNetworkDetail,
      onRefresh: _loadNetworks,
    );
  }

  Widget _buildNetworkDetail(BuildContext context) {
    final network = _selectedNetwork;
    if (network == null) {
      return _StateMessage(
        message: '请选择一个网络。',
        action: FButton(onPress: _showNetwork, child: const Text('返回网络列表')),
      );
    }
    final devices = (_networkDevices[network.id] ?? const <NetworkDevice>[])
        .where((device) => device.attached)
        .toList(growable: false);
    final onlineCount = devices.where((device) => device.online).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: network.name,
          subtitle: '网络详情与设备列表',
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FButton(
                variant: .outline,
                size: .sm,
                onPress: _showNetwork,
                child: const Text('返回网络列表'),
              ),
              FButton(
                variant: .outline,
                size: .sm,
                onPress: () => unawaited(_loadSingleNetworkDevices(network.id)),
                child: const Text('刷新设备'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _NetworkInfoPanel(
          network: network,
          workspaceName: _workspace?.name ?? '未关联工作区',
          totalDevices: devices.length,
          onlineDevices: onlineCount,
        ),
        const SizedBox(height: 16),
        _DeviceListPanel(deviceCount: devices.length, devices: devices),
      ],
    );
  }

  Widget _buildNodesPage(BuildContext context) {
    final network = _selectedNetwork;
    if (network == null) {
      if (_networks.isEmpty) {
        return _StateMessage(
          message: '当前工作区暂无网络。',
          action: FButton(onPress: _showOverview, child: const Text('返回首页')),
        );
      }
      return _StateMessage(
        message: '请先选择一个网络查看节点。',
        action: FButton(onPress: _showNetwork, child: const Text('选择网络')),
      );
    }

    final devices = (_networkDevices[network.id] ?? const <NetworkDevice>[])
        .where((device) => device.attached)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '节点',
          subtitle: '${network.name} 的节点与在线状态。',
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FButton(
                variant: .outline,
                size: .sm,
                onPress: _showNetwork,
                child: const Text('切换网络'),
              ),
              FButton(
                variant: .outline,
                size: .sm,
                onPress: () => unawaited(_loadSingleNetworkDevices(network.id)),
                child: const Text('刷新节点'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _NodeListPanel(nodeCount: devices.length, devices: devices),
      ],
    );
  }

  String _normalizeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.userName,
    required this.workspaceName,
    required this.activeView,
    required this.networkCount,
    required this.deviceCount,
    required this.onlineDeviceCount,
    required this.onShowOverview,
    required this.onShowNetwork,
    required this.onShowNodes,
    required this.onShowServices,
    required this.onShowSettings,
    required this.onLogout,
    required this.coreStatusListenable,
  });

  final String userName;
  final String workspaceName;
  final _DashboardView activeView;
  final int networkCount;
  final int deviceCount;
  final int onlineDeviceCount;
  final VoidCallback onShowOverview;
  final VoidCallback onShowNetwork;
  final VoidCallback onShowNodes;
  final VoidCallback onShowServices;
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
      child: Row(
        children: [
          const _BrandMark(),
          const SizedBox(width: 8),
          Text('EasyTier Pro', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 16),
          FButton(
            variant: activeView == _DashboardView.overview
                ? .secondary
                : .ghost,
            size: .sm,
            onPress: onShowOverview,
            child: const Text('首页'),
          ),
          const SizedBox(width: 6),
          FButton(
            variant:
                activeView == _DashboardView.network ||
                    activeView == _DashboardView.networkDetail
                ? .secondary
                : .ghost,
            size: .sm,
            onPress: onShowNetwork,
            child: const Text('网络'),
          ),
          const SizedBox(width: 6),
          FButton(
            variant: activeView == _DashboardView.nodes ? .secondary : .ghost,
            size: .sm,
            onPress: onShowNodes,
            child: const Text('节点'),
          ),
          const SizedBox(width: 6),
          FButton(
            variant: activeView == _DashboardView.services
                ? .secondary
                : .ghost,
            size: .sm,
            onPress: onShowServices,
            child: const Text('服务'),
          ),
          const Spacer(),
          _HeaderMetric(
            label: '网络',
            value: '$networkCount',
            icon: Icons.hub_outlined,
          ),
          const SizedBox(width: 10),
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
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF737373),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 12),
          _UserMenu(
            userName: trimmedName,
            workspaceName: workspaceName,
            initial: initial,
            onShowSettings: onShowSettings,
            onLogout: onLogout,
          ),
        ],
      ),
    );
  }
}

class _CoreStatusPanel extends StatelessWidget {
  const _CoreStatusPanel({
    required this.statusListenable,
    required this.workspaceName,
    required this.onRepair,
    required this.onExportLogs,
  });

  final ValueListenable<CoreRunStatus> statusListenable;
  final String workspaceName;
  final VoidCallback onRepair;
  final VoidCallback onExportLogs;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: statusListenable,
      builder: (context, status, _) {
        final running = status.phase == CoreRunPhase.running;
        final error = status.phase == CoreRunPhase.error;
        final title = running
            ? '本机设备已就绪'
            : error
            ? '连接引擎异常'
            : '正在准备本机设备';
        final machineId = status.machineId;
        final subtitle = machineId == null || machineId.isEmpty
            ? '$workspaceName · ${status.message}'
            : '$workspaceName · 设备 ${_shortId(machineId)}';

        return FCard.raw(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatusDot(online: running),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: const Color(0xFF737373)),
                          ),
                        ],
                      ),
                    ),
                    if (!running && !error) const FCircularProgress(size: .sm),
                  ],
                ),
                if (status.details != null && status.details!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    status.details!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF737373),
                    ),
                  ),
                ],
                if (status.lastError != null && status.lastError!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      status.lastError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFDC2626),
                      ),
                    ),
                  ),
                if (error) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FButton(onPress: onRepair, child: const Text('修复连接引擎')),
                      FButton(
                        variant: .outline,
                        onPress: onExportLogs,
                        child: const Text('导出诊断日志'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CreateNetworkPanel extends StatelessWidget {
  const _CreateNetworkPanel({
    required this.name,
    required this.selectedRegionCode,
    required this.regions,
    required this.loadingRegions,
    required this.creating,
    required this.error,
    required this.onNameChanged,
    required this.onRegionChanged,
    required this.onCreate,
    required this.onRetryRegions,
  });

  final String name;
  final String? selectedRegionCode;
  final List<ConsoleRegion> regions;
  final bool loadingRegions;
  final bool creating;
  final String? error;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String?> onRegionChanged;
  final Future<void> Function() onCreate;
  final Future<void> Function() onRetryRegions;

  @override
  Widget build(BuildContext context) {
    final canCreate = regions.isNotEmpty && !loadingRegions && !creating;

    return FCard.raw(
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('创建第一个网络', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                '当前工作区还没有网络。先创建网络，然后把本机设备加入进去。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF737373),
                ),
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 680;
                  final nameField = TextFormField(
                    key: ValueKey<String>(name),
                    initialValue: name,
                    decoration: const InputDecoration(
                      labelText: '网络名称',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: onNameChanged,
                  );
                  final regionField = DropdownButtonFormField<String>(
                    key: ValueKey<String?>(selectedRegionCode),
                    initialValue: selectedRegionCode,
                    decoration: const InputDecoration(
                      labelText: '区域',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final region in regions)
                        DropdownMenuItem<String>(
                          value: region.code,
                          child: Text(region.displayName),
                        ),
                    ],
                    onChanged: loadingRegions || regions.isEmpty
                        ? null
                        : onRegionChanged,
                  );
                  if (!wide) {
                    return Column(
                      children: [
                        nameField,
                        const SizedBox(height: 12),
                        regionField,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: nameField),
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFDC2626),
                  ),
                ),
              ],
              if (error != null && error!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFDC2626),
                  ),
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
          ),
        ),
      ),
    );
  }
}

class _NetworkJoinList extends StatelessWidget {
  const _NetworkJoinList({
    required this.title,
    required this.subtitle,
    required this.networks,
    required this.networkDevices,
    required this.joinStateFor,
    required this.onJoin,
    required this.onLeave,
    required this.onOpen,
    required this.onRefresh,
  });

  final String title;
  final String subtitle;
  final List<ConsoleNetwork> networks;
  final Map<String, List<NetworkDevice>> networkDevices;
  final _JoinNetworkState Function(ConsoleNetwork network) joinStateFor;
  final Future<void> Function(ConsoleNetwork network) onJoin;
  final Future<void> Function(ConsoleNetwork network) onLeave;
  final void Function(ConsoleNetwork network) onOpen;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: title,
          subtitle: subtitle,
          trailing: FButton(
            variant: .outline,
            size: .sm,
            onPress: onRefresh,
            child: const Text('刷新'),
          ),
        ),
        const SizedBox(height: 16),
        Column(
          children: [
            for (final network in networks) ...[
              _NetworkJoinCard(
                network: network,
                devices: networkDevices[network.id] ?? const <NetworkDevice>[],
                state: joinStateFor(network),
                onJoin: () => unawaited(onJoin(network)),
                onLeave: () => unawaited(onLeave(network)),
                onOpen: () => onOpen(network),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ],
    );
  }
}

class _NetworkJoinCard extends StatelessWidget {
  const _NetworkJoinCard({
    required this.network,
    required this.devices,
    required this.state,
    required this.onJoin,
    required this.onLeave,
    required this.onOpen,
  });

  final ConsoleNetwork network;
  final List<NetworkDevice> devices;
  final _JoinNetworkState state;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final attachedDevices = devices.where((device) => device.attached).toList();
    final online = attachedDevices.where((device) => device.online).length;
    final joined = state.phase == _JoinPhase.joined;
    final joining = state.phase == _JoinPhase.joining;
    final leaving = state.phase == _JoinPhase.leaving;
    final failed = state.phase == _JoinPhase.error;
    final localIpv4 = state.localIpv4?.trim();

    final statusLabel = joined
        ? '已加入'
        : joining
        ? '正在加入'
        : leaving
        ? '正在退出'
        : failed
        ? '操作失败'
        : '未加入';
    final statusColor = joined
        ? const Color(0xFF16A34A)
        : joining
        ? const Color(0xFF2563EB)
        : leaving
        ? const Color(0xFFF59E0B)
        : failed
        ? const Color(0xFFDC2626)
        : Colors.grey;

    return FCard.raw(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.hub_outlined, color: statusColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          network.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      FBadge(
                        variant: joined ? .secondary : .outline,
                        child: Text(statusLabel),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$online / ${attachedDevices.length} 台设备在线',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF737373),
                    ),
                  ),
                  if (joined) ...[
                    const SizedBox(height: 4),
                    Text(
                      localIpv4 == null || localIpv4.isEmpty
                          ? '本机 IP 分配中'
                          : '本机 IP $localIpv4',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF0F172A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (network.regions.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '区域 ${network.regions.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF737373),
                      ),
                    ),
                  ],
                  if (state.message != null && state.message!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.message!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            failed || (joined && state.message!.contains('失败'))
                            ? const Color(0xFFDC2626)
                            : const Color(0xFF737373),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  variant: .outline,
                  size: .sm,
                  onPress: onOpen,
                  child: const Text('详情'),
                ),
                if (joined || leaving)
                  FButton(
                    variant: .outline,
                    size: .sm,
                    onPress: leaving ? null : onLeave,
                    child: Text(leaving ? '退出中' : '退出'),
                  )
                else
                  FButton(
                    size: .sm,
                    onPress: joining ? null : onJoin,
                    child: Text(
                      joining
                          ? '加入中'
                          : failed
                          ? '重试'
                          : '加入',
                    ),
                  ),
              ],
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

    return Material(
      color: Colors.transparent,
      child: PopupMenuButton<_UserMenuAction>(
        tooltip: '账户菜单',
        position: PopupMenuPosition.under,
        onSelected: (action) {
          switch (action) {
            case _UserMenuAction.settings:
              onShowSettings();
            case _UserMenuAction.logout:
              unawaited(onLogout());
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<_UserMenuAction>(
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
          const PopupMenuDivider(),
          const PopupMenuItem<_UserMenuAction>(
            value: _UserMenuAction.settings,
            child: Row(
              children: [
                Icon(Icons.settings_outlined, size: 18),
                SizedBox(width: 10),
                Text('设置'),
              ],
            ),
          ),
          const PopupMenuItem<_UserMenuAction>(
            value: _UserMenuAction.logout,
            child: Row(
              children: [
                Icon(Icons.logout_outlined, size: 18),
                SizedBox(width: 10),
                Text('退出登录'),
              ],
            ),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              FAvatar.raw(size: 30, child: Text(initial.toUpperCase())),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
            ],
          ),
        ),
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

class _NetworkInfoPanel extends StatelessWidget {
  const _NetworkInfoPanel({
    required this.network,
    required this.workspaceName,
    required this.totalDevices,
    required this.onlineDevices,
  });

  final ConsoleNetwork network;
  final String workspaceName;
  final int totalDevices;
  final int onlineDevices;

  @override
  Widget build(BuildContext context) {
    return FCard(
      title: Text(network.name, style: Theme.of(context).textTheme.titleLarge),
      subtitle: const Text('网络信息'),
      child: Column(
        children: [
          const SizedBox(height: 8),
          FItemGroup(
            divider: .full,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              FItem(
                prefix: const Icon(Icons.badge_outlined),
                title: const Text('网络 ID'),
                details: Text(network.id),
              ),
              FItem(
                prefix: const Icon(Icons.apartment_outlined),
                title: const Text('工作区'),
                details: Text(workspaceName),
              ),
              FItem(
                prefix: const Icon(Icons.public_outlined),
                title: const Text('区域'),
                details: Text(
                  network.regions.isEmpty ? '-' : network.regions.join(', '),
                ),
              ),
              FItem(
                prefix: const Icon(Icons.devices_other_outlined),
                title: const Text('设备'),
                details: Text('$onlineDevices / $totalDevices 在线'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceListPanel extends StatelessWidget {
  const _DeviceListPanel({required this.deviceCount, required this.devices});

  final int deviceCount;
  final List<NetworkDevice> devices;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('设备列表', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            FBadge(variant: .secondary, child: Text('$deviceCount 台设备')),
          ],
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          const SizedBox(height: 160, child: _StateMessage(message: '该网络暂无设备'))
        else
          FCard.raw(
            child: FItemGroup(
              divider: .full,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final device in devices)
                  FItem(
                    prefix: _StatusDot(online: device.online),
                    title: Text(device.name),
                    subtitle: Text(
                      device.ipv4 == null || device.ipv4!.isEmpty
                          ? 'ID: ${device.id}'
                          : 'IP: ${device.ipv4}  |  ID: ${device.id}',
                    ),
                    suffix: FBadge(
                      variant: device.online ? .secondary : .outline,
                      child: Text(device.online ? '在线' : '离线'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _NodeListPanel extends StatelessWidget {
  const _NodeListPanel({required this.nodeCount, required this.devices});

  final int nodeCount;
  final List<NetworkDevice> devices;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('节点列表', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            FBadge(variant: .secondary, child: Text('$nodeCount 个节点')),
          ],
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          const SizedBox(height: 160, child: _StateMessage(message: '该网络暂无节点'))
        else
          FCard.raw(
            child: FItemGroup(
              divider: .full,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final device in devices)
                  FItem(
                    prefix: _StatusDot(online: device.online),
                    title: Text(device.name),
                    subtitle: Text(
                      [
                        if (device.machineId != null &&
                            device.machineId!.isNotEmpty)
                          'Machine: ${_shortId(device.machineId!)}',
                        if (device.ipv4 != null && device.ipv4!.isNotEmpty)
                          'IP: ${device.ipv4}',
                        'Node: ${device.id}',
                      ].join('  |  '),
                    ),
                    suffix: FBadge(
                      variant: device.online ? .secondary : .outline,
                      child: Text(device.online ? '在线' : '离线'),
                    ),
                  ),
              ],
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
  });

  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final file = await AppLogger.instance.exportDiagnostics();
      AppLogger.instance.info(
        'settings',
        'Diagnostics exported',
        context: {'file': file.path},
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('诊断日志已导出: ${file.path}')));
      }
    } catch (error) {
      AppLogger.instance.error(
        'settings',
        'Diagnostics export failed',
        context: {'error': error.toString()},
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出诊断日志失败')));
      }
    }
  }

  Future<void> _copyLogDirectory(BuildContext context) async {
    final path = AppLogger.instance.logDirectoryPath;
    if (path == null || path.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('日志目录尚未初始化')));
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: path));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('日志目录已复制: $path')));
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
              FItemGroup(
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

class _ServicesPanel extends StatelessWidget {
  const _ServicesPanel({required this.coreLifecycleService});

  final CoreLifecycleService coreLifecycleService;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: coreLifecycleService.status,
      builder: (context, status, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '服务', subtitle: '核心连接引擎状态与修复入口。'),
            const SizedBox(height: 20),
            FCard(
              title: const Text('连接引擎'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _StatusDot(online: status.phase == CoreRunPhase.running),
                      const SizedBox(width: 8),
                      Text(status.message),
                    ],
                  ),
                  if (status.machineId != null &&
                      status.machineId!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('本机设备: ${status.machineId}'),
                  ],
                  if (status.lastError != null &&
                      status.lastError!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      status.lastError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF737373),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  FButton(
                    variant: .outline,
                    onPress: () => unawaited(coreLifecycleService.repair()),
                    child: const Text('重试/修复'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
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

String _shortId(String value) {
  if (value.length <= 8) {
    return value;
  }
  return value.substring(0, 8);
}
