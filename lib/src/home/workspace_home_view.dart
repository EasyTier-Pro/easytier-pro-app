import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:forui/forui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';
import '../core/core_lifecycle_service.dart';
import '../desktop/app_update_service.dart';
import '../desktop/tray_support.dart';
import '../desktop/window_behavior_preferences.dart';
import '../logging/app_logger.dart';
import '../shared/app_motion.dart';
import '../shared/app_smooth_scroll_view.dart';
import '../shared/selectable_text_hit_boundary.dart';
import 'dashboard_navigation.dart';
import 'device_os_icon.dart';
import 'home_shell.dart';
import 'home_settings_page.dart';
import 'network_detail_layout.dart';
import 'network_switch_tile.dart';
import 'network_node_list_panel.dart';

part 'workspace_home_models.dart';
part 'workspace_home_data_actions.dart';
part 'workspace_home_join_actions.dart';
part 'workspace_home_polling.dart';
part 'workspace_home_navigation.dart';
part 'workspace_home_pages.dart';
part 'workspace_home_network_detail_sections.dart';
part 'workspace_home_subnet_routes.dart';
part 'workspace_home_local_network_settings.dart';
part 'workspace_home_devices.dart';
part 'workspace_home_network_more_menu.dart';
part 'workspace_home_formatting.dart';
part 'workspace_home_header.dart';
part 'workspace_home_create_network.dart';
part 'workspace_home_user_menu.dart';
part 'workspace_home_shared_widgets.dart';
part 'workspace_home_settings_panel.dart';
part 'workspace_home_network_switch.dart';
part 'workspace_home_state_widgets.dart';

class WorkspaceHomeView extends StatefulWidget {
  const WorkspaceHomeView({
    super.key,
    required this.authService,
    required this.coreLifecycleService,
    required this.traySupport,
    required this.appUpdateService,
    required this.windowBehaviorPreferences,
    required this.session,
    required this.onLogout,
    this.androidMvpSingleActiveNetworkOverride,
  });

  final AuthService authService;
  final CoreLifecycleService coreLifecycleService;
  final TraySupport traySupport;
  final AppUpdateService appUpdateService;
  final WindowBehaviorPreferences windowBehaviorPreferences;
  final AuthSession session;
  final Future<void> Function() onLogout;
  final bool? androidMvpSingleActiveNetworkOverride;

  @override
  State<WorkspaceHomeView> createState() => _WorkspaceHomeViewState();
}

class _WorkspaceHomeViewState extends State<WorkspaceHomeView> {
  static const Duration _devicePollDelay = Duration(seconds: 1);
  static const int _devicePollAttempts = 60;

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
  Set<String> _deletingNetworkIds = const <String>{};
  _DashboardView _activeView = _DashboardView.overview;
  _NetworkDetailSection _networkDetailSection = _NetworkDetailSection.nodes;
  final _networkDetailHeaderCollapse =
      HomeNetworkDetailHeaderCollapseController();
  String _newNetworkName = '我的网络';
  String _newNetworkIPv4Cidr = '';
  final TextEditingController _newNetworkNameController = TextEditingController(
    text: '我的网络',
  );
  final TextEditingController _newNetworkIPv4CidrController =
      TextEditingController();
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
  final List<_TrafficHistoryPoint> _trafficHistory = <_TrafficHistoryPoint>[];
  static const int _maxTrafficHistoryPoints = 1800;
  final Map<String, List<_TrafficHistoryPoint>> _networkTrafficHistories =
      <String, List<_TrafficHistoryPoint>>{};
  static const int _maxNetworkTrafficHistoryPoints = 1800;
  Map<String, _NetworkTrafficSnapshot> _networkTraffic =
      const <String, _NetworkTrafficSnapshot>{};
  Map<String, bool> _networkInstanceReady = const <String, bool>{};
  Map<String, CoreNetworkTrafficTotals> _previousTrafficTotals =
      const <String, CoreNetworkTrafficTotals>{};
  Map<String, Map<String, CorePeerStatus>> _networkPeerStatuses =
      const <String, Map<String, CorePeerStatus>>{};
  Map<String, String> _peerStatusErrors = const <String, String>{};
  Map<String, NetworkSubnetRouteList> _networkSubnetRoutes =
      const <String, NetworkSubnetRouteList>{};
  Map<String, bool> _networkSubnetRoutesLoading = const <String, bool>{};
  Map<String, String> _networkSubnetRouteErrors = const <String, String>{};
  Map<String, NodeInstanceConfigView> _nodeConfigs =
      const <String, NodeInstanceConfigView>{};
  Map<String, bool> _nodeConfigLoading = const <String, bool>{};
  Map<String, String> _nodeConfigErrors = const <String, String>{};
  String? _trayConnectionNetworkId;
  String? _trayConnectionLabel;
  String? _trayWorkspaceName;
  bool? _trayConnectionEnabled;
  bool? _trayConnectionDisconnecting;
  String? _trayEngineLabel;
  bool? _trayEngineEnabled;

  ConsoleWorkspace? get _workspace => widget.session.user.currentWorkspace;

  bool get _isAndroidMvpSingleActiveNetwork {
    final override = widget.androidMvpSingleActiveNetworkOverride;
    if (override != null) {
      return override;
    }
    if (kIsWeb) {
      return false;
    }
    return Platform.isAndroid;
  }

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

  double _coordinateNetworkDetailScrollDelta(
    double delta,
    ScrollMetrics metrics, {
    AppScrollDeltaSource source = AppScrollDeltaSource.pointerSignal,
  }) => _networkDetailHeaderCollapse.coordinateScrollDelta(
    delta,
    metrics,
    source: source,
  );

  void _resetNetworkDetailScrollOffset({bool animate = false}) {
    _networkDetailHeaderCollapse.reset(animate: animate);
  }

  void _handleNetworkDetailStaticViewportShown() {
    _networkDetailHeaderCollapse.syncStaticViewportShown();
  }

  void _updateState(VoidCallback fn) {
    setState(fn);
    _syncTrayConnectionAction();
    _syncTrayEngineAction();
  }

  void _syncTrayConnectionAction() {
    final network =
        _selectedNetwork ?? (_networks.isEmpty ? null : _networks.first);
    final state = network == null ? null : _joinStateFor(network);
    final disconnecting =
        state?.phase == _JoinPhase.joined || state?.phase == _JoinPhase.leaving;
    final enabled =
        network != null &&
        state?.phase != _JoinPhase.joining &&
        state?.phase != _JoinPhase.leaving;
    final label = _trayConnectionLabelFor(network, state);
    final networkId = network?.id;
    final workspaceName = _trayWorkspaceNameForSession();

    if (_trayConnectionNetworkId == networkId &&
        _trayConnectionLabel == label &&
        _trayWorkspaceName == workspaceName &&
        _trayConnectionEnabled == enabled &&
        _trayConnectionDisconnecting == disconnecting) {
      return;
    }

    _trayConnectionNetworkId = networkId;
    _trayConnectionLabel = label;
    _trayWorkspaceName = workspaceName;
    _trayConnectionEnabled = enabled;
    _trayConnectionDisconnecting = disconnecting;

    widget.traySupport.setConnectionAction(
      TrayConnectionAction(
        label: label,
        enabled: enabled,
        workspaceName: workspaceName,
        onSelected: networkId == null
            ? null
            : () => _runTrayConnectionAction(networkId, disconnecting),
      ),
    );
  }

  String _trayConnectionLabelFor(
    ConsoleNetwork? network,
    _JoinNetworkState? state,
  ) {
    if (network == null) {
      return '连接';
    }

    return switch (state?.phase) {
      _JoinPhase.joined => '断开 ${network.name}',
      _JoinPhase.leaving => '正在断开 ${network.name}...',
      _JoinPhase.joining => '正在连接 ${network.name}...',
      _ => '连接到 ${network.name}',
    };
  }

  String _trayWorkspaceNameForSession() {
    final name = _workspace?.name.trim();
    return name == null || name.isEmpty ? '未关联工作区' : name;
  }

  void _syncTrayEngineAction() {
    final versionStatus = widget.coreLifecycleService.engineVersionStatus.value;
    final coreStatus = widget.coreLifecycleService.status.value;
    final busy =
        coreStatus.phase == CoreRunPhase.checking ||
        coreStatus.phase == CoreRunPhase.repairing;
    final label = _coreEngineActionLabel(versionStatus);
    final enabled = !busy;

    if (_trayEngineLabel == label && _trayEngineEnabled == enabled) {
      return;
    }

    _trayEngineLabel = label;
    _trayEngineEnabled = enabled;
    widget.traySupport.setEngineAction(
      TrayEngineAction(
        label: label,
        enabled: enabled,
        onSelected: enabled ? widget.coreLifecycleService.repair : null,
      ),
    );
  }

  Future<void> _runTrayConnectionAction(
    String networkId,
    bool disconnect,
  ) async {
    await widget.traySupport.showWindow();
    if (!mounted) {
      return;
    }

    final network = _networkById(networkId);
    if (network == null) {
      _syncTrayConnectionAction();
      return;
    }

    if (disconnect) {
      await _leaveNetwork(network);
    } else {
      await _joinNetwork(network);
    }
    _syncTrayConnectionAction();
  }

  ConsoleNetwork? _networkById(String networkId) {
    for (final network in _networks) {
      if (network.id == networkId) {
        return network;
      }
    }
    return null;
  }

  void _setNewNetworkName(String value) {
    _newNetworkName = value;
    if (_newNetworkNameController.text != value) {
      _newNetworkNameController.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  void _setNewNetworkIPv4Cidr(String value) {
    _newNetworkIPv4Cidr = value;
    if (_newNetworkIPv4CidrController.text != value) {
      _newNetworkIPv4CidrController.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
    widget.coreLifecycleService.engineVersionStatus.addListener(
      _onEngineVersionChanged,
    );
    _syncTrayConnectionAction();
    _syncTrayEngineAction();
    unawaited(_loadInitialData());
  }

  @override
  void dispose() {
    _trafficPollTimer?.cancel();
    _peerPollTimer?.cancel();
    _newNetworkNameController.dispose();
    _newNetworkIPv4CidrController.dispose();
    _networkDetailHeaderCollapse.dispose();
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
    widget.coreLifecycleService.engineVersionStatus.removeListener(
      _onEngineVersionChanged,
    );
    widget.traySupport.setConnectionAction(null);
    widget.traySupport.setEngineAction(null);
    super.dispose();
  }

  void _onCoreStatusChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _syncTrayConnectionAction();
    _syncTrayEngineAction();
    _refreshTrafficPolling();
    _refreshPeerPolling();
    final selectedNetworkId = _selectedNetworkId;
    if (_activeView == _DashboardView.network && selectedNetworkId != null) {
      unawaited(_loadLocalNodeConfigForNetworkId(selectedNetworkId));
    }
  }

  void _onEngineVersionChanged() {
    _syncTrayEngineAction();
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

    return HomeShell(
      desktopHeader: _DashboardHeader(
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
      mobileHeader: _MobileDashboardHeader(
        userName: widget.session.user.effectiveName,
        workspaceName: workspaceName,
        onShowSettings: _showSettings,
        onLogout: widget.onLogout,
        coreStatusListenable: widget.coreLifecycleService.status,
      ),
      mobileNavigation: _MobileDashboardNavigation(
        activeView: _activeView,
        networks: _networks,
        selectedNetworkId: _selectedNetworkId,
        onShowOverview: _showOverview,
        onShowNetwork: _showNetwork,
        onSelectNetwork: _selectNetwork,
        onShowDevices: _showDevices,
        onShowSettings: _showSettings,
      ),
      contentKey: contentKey,
      contentMode: switch (_activeView) {
        _DashboardView.network => HomeShellContentMode.staticConstrained,
        _DashboardView.settings => HomeShellContentMode.plain,
        _ => HomeShellContentMode.scrollConstrained,
      },
      onMobileSwipe: _handleMobilePageSwipe,
      child: _buildContent(context),
    );
  }

  String _normalizeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }
}
