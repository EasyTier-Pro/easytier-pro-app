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
import '../shared/app_smooth_scroll_view.dart';
import '../shared/selectable_text_hit_boundary.dart';
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
  Set<String> _deletingNetworkIds = const <String>{};
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

  void _updateState(VoidCallback fn) {
    setState(fn);
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
                      : AppSmoothScrollView(
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
            ),
          ),
        ],
      ),
    );
  }

  String _normalizeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }
}
