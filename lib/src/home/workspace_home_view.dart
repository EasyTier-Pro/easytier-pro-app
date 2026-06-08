import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:forui/forui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';
import '../core/core_lifecycle_service.dart';
import '../desktop/tray_support.dart';
import '../logging/app_logger.dart';
import '../shared/app_motion.dart';
import '../shared/app_smooth_scroll_view.dart';
import '../shared/app_text_selection.dart';
import '../shared/selectable_text_hit_boundary.dart';
import 'device_os_icon.dart';
import 'network_node_list_panel.dart';

part 'workspace_home_models.dart';
part 'workspace_home_data_actions.dart';
part 'workspace_home_join_actions.dart';
part 'workspace_home_polling.dart';
part 'workspace_home_navigation.dart';
part 'workspace_home_pages.dart';
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
    required this.session,
    required this.onLogout,
    this.androidMvpSingleActiveNetworkOverride,
  });

  final AuthService authService;
  final CoreLifecycleService coreLifecycleService;
  final TraySupport traySupport;
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

  void _updateState(VoidCallback fn) {
    setState(fn);
    _syncTrayConnectionAction();
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
    _syncTrayConnectionAction();
    unawaited(_loadInitialData());
  }

  @override
  void dispose() {
    _trafficPollTimer?.cancel();
    _peerPollTimer?.cancel();
    _newNetworkNameController.dispose();
    _newNetworkIPv4CidrController.dispose();
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
    widget.traySupport.setConnectionAction(null);
    super.dispose();
  }

  void _onCoreStatusChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _syncTrayConnectionAction();
    _refreshTrafficPolling();
    _refreshPeerPolling();
    final selectedNetworkId = _selectedNetworkId;
    if (_activeView == _DashboardView.network && selectedNetworkId != null) {
      unawaited(_loadLocalNodeConfigForNetworkId(selectedNetworkId));
    }
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < _mobileShellBreakpoint;
          final pagePadding = EdgeInsets.all(mobile ? 16 : 24);

          return Column(
            children: [
              if (!mobile) const _DesktopSystemTopInset(),
              if (mobile)
                _MobileDashboardHeader(
                  userName: widget.session.user.effectiveName,
                  workspaceName: workspaceName,
                  onShowSettings: _showSettings,
                  onLogout: widget.onLogout,
                  coreStatusListenable: widget.coreLifecycleService.status,
                )
              else
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
                child: AppTextSelectionTapCleaner(
                  child: _MobilePageSwipeGate(
                    enabled: mobile,
                    onSwipe: _handleMobilePageSwipe,
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
                                  padding: pagePadding,
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 1040,
                                      ),
                                      child: _buildContent(context),
                                    ),
                                  ),
                                )
                              : AppSmoothScrollView(
                                  padding: pagePadding,
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 1040,
                                      ),
                                      child: _buildContent(context),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (mobile)
                _MobileDashboardNavigation(
                  activeView: _activeView,
                  networks: _networks,
                  selectedNetworkId: _selectedNetworkId,
                  onShowOverview: _showOverview,
                  onShowNetwork: _showNetwork,
                  onSelectNetwork: _selectNetwork,
                  onShowDevices: _showDevices,
                  onShowSettings: _showSettings,
                ),
            ],
          );
        },
      ),
    );
  }

  String _normalizeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }
}

class _MobilePageSwipeGate extends StatefulWidget {
  const _MobilePageSwipeGate({
    required this.enabled,
    required this.onSwipe,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<Offset> onSwipe;
  final Widget child;

  @override
  State<_MobilePageSwipeGate> createState() => _MobilePageSwipeGateState();
}

class _MobilePageSwipeGateState extends State<_MobilePageSwipeGate> {
  int? _trackingPointer;
  Offset _pointerDelta = Offset.zero;

  void _startTracking(PointerDownEvent event) {
    if (!widget.enabled || _trackingPointer != null) {
      return;
    }

    _trackingPointer = event.pointer;
    _pointerDelta = Offset.zero;
  }

  void _trackMove(PointerMoveEvent event) {
    if (!widget.enabled || event.pointer != _trackingPointer) {
      return;
    }

    _pointerDelta += event.delta;
  }

  void _finishTracking(PointerEvent event) {
    if (event.pointer != _trackingPointer) {
      return;
    }

    final delta = _pointerDelta;
    _trackingPointer = null;
    _pointerDelta = Offset.zero;
    if (widget.enabled) {
      widget.onSwipe(delta);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return Listener(
      key: const ValueKey<String>('mobile-dashboard-page-swipe'),
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _startTracking,
      onPointerMove: _trackMove,
      onPointerUp: _finishTracking,
      onPointerCancel: _finishTracking,
      child: widget.child,
    );
  }
}

class _DesktopSystemTopInset extends StatelessWidget {
  const _DesktopSystemTopInset();

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    if (topInset <= 0) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const ValueKey<String>('desktop-system-top-inset'),
      height: topInset,
      color: const Color(0xFFF8F9FB),
    );
  }
}
