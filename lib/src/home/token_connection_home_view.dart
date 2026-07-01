import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/console_links.dart';
import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';
import '../core/core_lifecycle_service.dart';
import '../desktop/app_update_service.dart';
import '../desktop/tray_support.dart';
import '../desktop/window_behavior_preferences.dart';
import '../shared/app_smooth_scroll_view.dart';
import 'dashboard_navigation.dart';
import 'home_shell.dart';
import 'home_settings_page.dart';
import 'home_tray_actions.dart';
import 'network_detail_layout.dart';
import 'network_list_section.dart';
import 'network_node_list_panel.dart';
import 'network_switch_tile.dart';
import 'network_traffic_sparkline.dart';
import 'open_console_button.dart';

class TokenConnectionHomeView extends StatefulWidget {
  const TokenConnectionHomeView({
    super.key,
    required this.profile,
    required this.coreLifecycleService,
    required this.appUpdateService,
    required this.traySupport,
    required this.windowBehaviorPreferences,
    required this.onDisconnect,
    required this.onChangeToken,
    required this.onAccountLogin,
  });

  final TokenConnectionProfile profile;
  final CoreLifecycleService coreLifecycleService;
  final AppUpdateService appUpdateService;
  final TraySupport traySupport;
  final WindowBehaviorPreferences windowBehaviorPreferences;
  final Future<void> Function() onDisconnect;
  final Future<void> Function() onChangeToken;
  final Future<void> Function() onAccountLogin;

  @override
  State<TokenConnectionHomeView> createState() =>
      _TokenConnectionHomeViewState();
}

class _TokenConnectionHomeViewState extends State<TokenConnectionHomeView>
    with HomeTrayActionsMixin<TokenConnectionHomeView> {
  static const double _mobileSwipeDistanceThreshold = 72;
  static const double _mobileSwipeHorizontalDominance = 1.25;
  static const int _maxTrafficHistoryPoints = 1800;

  _TokenHomeView _activeView = _TokenHomeView.overview;
  Timer? _trafficTimer;
  Timer? _peerStatusTimer;
  bool _trafficInFlight = false;
  bool _peerStatusInFlight = false;
  Map<String, CoreNetworkTrafficTotals> _previousTotals =
      const <String, CoreNetworkTrafficTotals>{};
  Map<String, _TokenTrafficSnapshot> _traffic =
      const <String, _TokenTrafficSnapshot>{};
  final Map<String, List<HomeTrafficHistoryPoint>> _trafficHistories =
      <String, List<HomeTrafficHistoryPoint>>{};
  Map<String, Map<String, CorePeerStatus>> _peerStatusesByRuntime =
      const <String, Map<String, CorePeerStatus>>{};
  Map<String, String> _peerStatusErrorsByRuntime = const <String, String>{};
  String? _trafficError;
  String? _selectedRuntimeName;
  String? _trayConnectionLabel;
  bool? _trayConnectionEnabled;
  final _networkDetailHeaderCollapse =
      HomeNetworkDetailHeaderCollapseController();

  @override
  TraySupport get traySupport => widget.traySupport;

  @override
  CoreLifecycleService get coreLifecycleService => widget.coreLifecycleService;

  @override
  AppUpdateService get appUpdateService => widget.appUpdateService;

  @override
  void showSettingsFromTray() => _showSettings();

  @override
  void showTrayFeedback(String message, {bool destructive = false}) {
    showHomeSettingsToast(context, message, destructive: destructive);
  }

  List<MapEntry<String, _TokenTrafficSnapshot>> get _sortedTrafficEntries {
    return _traffic.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
  }

  List<HomeDashboardNetworkOption> get _networkOptions {
    return [
      for (final entry in _sortedTrafficEntries)
        HomeDashboardNetworkOption(
          id: entry.key,
          name: _tokenRuntimeDisplayName(entry.key),
        ),
    ];
  }

  String? get _fallbackRuntimeName {
    final selected = _selectedRuntimeName?.trim();
    if (selected != null &&
        selected.isNotEmpty &&
        (_traffic.isEmpty || _traffic.containsKey(selected))) {
      return selected;
    }
    final entries = _sortedTrafficEntries;
    return entries.isEmpty ? null : entries.first.key;
  }

  int get _knownPeerCount {
    final ids = <String>{};
    for (final peers in _peerStatusesByRuntime.values) {
      for (final peer in peers.values) {
        ids.add(_tokenPeerDeviceId('token', peer, ids.length));
      }
    }
    return ids.length;
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

  @override
  void initState() {
    super.initState();
    widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
    initHomeTrayActions();
    _syncTrayConnectionAction();
    _refreshTrafficPolling();
  }

  @override
  void didUpdateWidget(TokenConnectionHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coreLifecycleService != widget.coreLifecycleService) {
      oldWidget.coreLifecycleService.status.removeListener(
        _onCoreStatusChanged,
      );
      widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
      _refreshTrafficPolling();
      _refreshPeerStatusPolling();
    }
    didUpdateHomeTrayActions(
      oldTraySupport: oldWidget.traySupport,
      oldCoreLifecycleService: oldWidget.coreLifecycleService,
    );
    if (oldWidget.traySupport != widget.traySupport) {
      oldWidget.traySupport.setConnectionAction(null);
      _trayConnectionLabel = null;
      _trayConnectionEnabled = null;
      _syncTrayConnectionAction();
    }
  }

  @override
  void dispose() {
    _trafficTimer?.cancel();
    _peerStatusTimer?.cancel();
    _networkDetailHeaderCollapse.dispose();
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
    widget.traySupport.setConnectionAction(null);
    disposeHomeTrayActions();
    super.dispose();
  }

  void _onCoreStatusChanged() {
    if (mounted) {
      setState(() {});
    }
    _syncTrayConnectionAction();
    syncHomeTrayCoreUpdateAction();
    _refreshTrafficPolling();
    _refreshPeerStatusPolling();
  }

  void _syncTrayConnectionAction() {
    final status = widget.coreLifecycleService.status.value;
    final busy =
        status.phase == CoreRunPhase.checking ||
        status.phase == CoreRunPhase.repairing;
    final running = status.phase == CoreRunPhase.running;
    final label = busy ? '正在连接...' : (running ? '重新连接' : '连接');
    final enabled = !busy;

    if (_trayConnectionLabel == label && _trayConnectionEnabled == enabled) {
      return;
    }

    _trayConnectionLabel = label;
    _trayConnectionEnabled = enabled;
    widget.traySupport.setConnectionAction(
      TrayConnectionAction(
        label: label,
        enabled: enabled,
        onSelected: enabled
            ? () async {
                await widget.traySupport.showWindow();
                await widget.coreLifecycleService.repair();
              }
            : null,
      ),
    );
  }

  void _refreshTrafficPolling() {
    final running = widget.coreLifecycleService.status.value.isRunning;
    if (!running) {
      _trafficTimer?.cancel();
      _trafficTimer = null;
      return;
    }
    if (_trafficTimer != null) {
      return;
    }
    _trafficTimer = Timer.periodic(
      widget.coreLifecycleService.networkTrafficPollInterval,
      (_) => unawaited(_pollTraffic()),
    );
    unawaited(_pollTraffic());
  }

  void _refreshPeerStatusPolling() {
    final runtimeName = _selectedRuntimeName?.trim() ?? '';
    final shouldPoll =
        widget.coreLifecycleService.status.value.isRunning &&
        _activeView == _TokenHomeView.network &&
        runtimeName.isNotEmpty;
    if (!shouldPoll) {
      _peerStatusTimer?.cancel();
      _peerStatusTimer = null;
      return;
    }
    if (_peerStatusTimer != null) {
      unawaited(_pollSelectedPeerStatuses());
      return;
    }
    _peerStatusTimer = Timer.periodic(
      widget.coreLifecycleService.peerStatusPollInterval,
      (_) => unawaited(_pollSelectedPeerStatuses()),
    );
    unawaited(_pollSelectedPeerStatuses());
  }

  Future<void> _pollSelectedPeerStatuses() async {
    final runtimeName = _selectedRuntimeName?.trim() ?? '';
    if (_peerStatusInFlight || runtimeName.isEmpty || !mounted) {
      return;
    }
    _peerStatusInFlight = true;
    try {
      final peers = await widget.coreLifecycleService.readNetworkPeerStatuses(
        runtimeName,
      );
      if (!mounted || _selectedRuntimeName != runtimeName) {
        return;
      }
      final credentialPeers = filterCredentialPeerStatuses(peers);
      setState(() {
        _peerStatusesByRuntime = {
          ..._peerStatusesByRuntime,
          runtimeName: credentialPeers,
        };
        final errors = Map<String, String>.of(_peerStatusErrorsByRuntime)
          ..remove(runtimeName);
        _peerStatusErrorsByRuntime = errors;
      });
    } catch (error) {
      if (!mounted || _selectedRuntimeName != runtimeName) {
        return;
      }
      setState(() {
        _peerStatusErrorsByRuntime = {
          ..._peerStatusErrorsByRuntime,
          runtimeName: error.toString().replaceFirst('Exception: ', ''),
        };
      });
    } finally {
      _peerStatusInFlight = false;
    }
  }

  Future<void> _pollTraffic() async {
    if (_trafficInFlight || !mounted) {
      return;
    }
    _trafficInFlight = true;
    try {
      final totals = await widget.coreLifecycleService
          .readNetworkTrafficTotals();
      if (!mounted) {
        return;
      }
      final next = <String, _TokenTrafficSnapshot>{};
      final nextHistories = Map<String, List<HomeTrafficHistoryPoint>>.from(
        _trafficHistories,
      );
      for (final entry in totals.entries) {
        final snapshot = _TokenTrafficSnapshot.fromTotals(
          entry.value,
          previous: _previousTotals[entry.key],
        );
        next[entry.key] = snapshot;

        final history =
            List<HomeTrafficHistoryPoint>.from(
              nextHistories[entry.key] ?? const <HomeTrafficHistoryPoint>[],
            )..add(
              HomeTrafficHistoryPoint(
                timestamp: DateTime.now(),
                downloadRate: snapshot.downloadBytesPerSecond ?? 0,
                uploadRate: snapshot.uploadBytesPerSecond ?? 0,
              ),
            );
        while (history.length > _maxTrafficHistoryPoints) {
          history.removeAt(0);
        }
        nextHistories[entry.key] = history;
      }
      nextHistories.removeWhere(
        (runtimeName, _) => !totals.containsKey(runtimeName),
      );
      setState(() {
        _traffic = next;
        _previousTotals = totals;
        _trafficHistories
          ..clear()
          ..addAll(nextHistories);
        _trafficError = null;
        if (_activeView == _TokenHomeView.network &&
            (_selectedRuntimeName == null ||
                !_traffic.containsKey(_selectedRuntimeName))) {
          final entries = _sortedTrafficEntries;
          final nextRuntimeName = entries.isEmpty ? null : entries.first.key;
          if (_selectedRuntimeName != nextRuntimeName) {
            _selectedRuntimeName = nextRuntimeName;
            _resetNetworkDetailScrollOffset();
          }
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _trafficError = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _trafficInFlight = false;
    }
  }

  Future<void> _copyDiagnostics() async {
    final status = widget.coreLifecycleService.status.value;
    final lines = <String>[
      'mode=token',
      'name=${widget.profile.effectiveDisplayName}',
      'phase=${status.phase.name}',
      'message=${status.message}',
      'machine_id=${status.machineId ?? ''}',
      'details=${status.details ?? ''}',
      'config_server=${widget.profile.configServer}',
      if (status.lastError?.isNotEmpty == true) 'error=${status.lastError}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) {
      return;
    }
    showHomeSettingsToast(context, '诊断信息已复制');
  }

  Future<void> _copyText(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    showHomeSettingsToast(context, '已复制到剪贴板');
  }

  Future<void> _openConsoleNetworks() async {
    await launchUrl(consoleNetworksUri(), mode: LaunchMode.externalApplication);
  }

  void _showOverview() {
    if (_activeView == _TokenHomeView.overview) {
      return;
    }
    setState(() {
      _activeView = _TokenHomeView.overview;
    });
    _refreshPeerStatusPolling();
  }

  void _showNetwork() {
    if (_activeView == _TokenHomeView.network) {
      setState(() {
        _selectedRuntimeName ??= _fallbackRuntimeName;
        _resetNetworkDetailScrollOffset();
      });
      _refreshPeerStatusPolling();
      return;
    }
    setState(() {
      _selectedRuntimeName ??= _fallbackRuntimeName;
      _activeView = _TokenHomeView.network;
      _resetNetworkDetailScrollOffset();
    });
    _refreshPeerStatusPolling();
  }

  void _selectNetwork(String runtimeName) {
    setState(() {
      _selectedRuntimeName = runtimeName;
      _activeView = _TokenHomeView.network;
      _resetNetworkDetailScrollOffset();
    });
    _refreshPeerStatusPolling();
  }

  void _showSettings() {
    if (_activeView == _TokenHomeView.settings) {
      return;
    }
    setState(() {
      _activeView = _TokenHomeView.settings;
    });
    _refreshPeerStatusPolling();
  }

  void _openNetworkInstance(String runtimeName) {
    setState(() {
      _selectedRuntimeName = runtimeName;
      _activeView = _TokenHomeView.network;
      _resetNetworkDetailScrollOffset();
    });
    _refreshPeerStatusPolling();
  }

  void _handleMobilePageSwipe(Offset delta) {
    final horizontalDistance = delta.dx.abs();
    final verticalDistance = delta.dy.abs();
    if (horizontalDistance < _mobileSwipeDistanceThreshold ||
        horizontalDistance <
            verticalDistance * _mobileSwipeHorizontalDominance) {
      return;
    }

    final currentIndex = _tokenMobileViewOrder.indexOf(_activeView);
    if (currentIndex < 0) {
      return;
    }

    final nextIndex = delta.dx < 0 ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= _tokenMobileViewOrder.length) {
      return;
    }

    switch (_tokenMobileViewOrder[nextIndex]) {
      case _TokenHomeView.overview:
        _showOverview();
      case _TokenHomeView.network:
        _showNetwork();
      case _TokenHomeView.settings:
        _showSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.coreLifecycleService.status.value;
    final selectedRuntimeName = _fallbackRuntimeName;
    final contentKey = ValueKey<String>(
      [
        'token-home',
        _activeView.name,
        if (_activeView == _TokenHomeView.network)
          selectedRuntimeName ?? 'none',
      ].join(':'),
    );

    return HomeShell(
      desktopHeader: HomeDashboardDesktopHeader(
        contentKey: const ValueKey<String>('token-desktop-dashboard-header'),
        activeView: _homeDashboardViewForToken(_activeView),
        networks: _networkOptions,
        selectedNetworkId: selectedRuntimeName,
        showNetworkNavigation: true,
        showDevicesNavigation: false,
        onShowOverview: _showOverview,
        onShowNetwork: _showNetwork,
        onSelectNetwork: _selectNetwork,
        onShowDevices: () {},
        metrics: [
          HomeHeaderMetric(
            label: '实例',
            value: '${_traffic.length}',
            icon: Icons.hub_outlined,
          ),
          HomeHeaderMetric(
            label: '节点',
            value: '$_knownPeerCount',
            icon: Icons.devices_other_outlined,
          ),
          HomeCoreStatusLabel(
            statusListenable: widget.coreLifecycleService.status,
            label: '引擎',
          ),
        ],
        trailing: _TokenHeaderActions(
          status: status,
          settingsActive: _activeView == _TokenHomeView.settings,
          onShowSettings: _showSettings,
        ),
      ),
      mobileHeader: HomeShellMobileHeader(
        title: 'EasyTier Pro',
        subtitle: _tokenHomeHeaderSubtitle(widget.profile),
        suffixes: [
          HomeCoreStatusDot(
            statusListenable: widget.coreLifecycleService.status,
          ),
          const HomeOpenConsoleButton(
            buttonKey: ValueKey<String>('token-mobile-open-console'),
          ),
        ],
      ),
      mobileNavigation: HomeDashboardMobileNavigation(
        activeView: _homeDashboardViewForToken(_activeView),
        networks: _networkOptions,
        selectedNetworkId: selectedRuntimeName,
        onShowOverview: _showOverview,
        onShowNetwork: _showNetwork,
        onSelectNetwork: _selectNetwork,
        onShowDevices: () {},
        onShowSettings: _showSettings,
        showDevicesNavigation: false,
      ),
      contentKey: contentKey,
      contentMode: switch (_activeView) {
        _TokenHomeView.network => HomeShellContentMode.staticConstrained,
        _TokenHomeView.settings => HomeShellContentMode.plain,
        _ => HomeShellContentMode.scrollConstrained,
      },
      onMobileSwipe: _handleMobilePageSwipe,
      child: switch (_activeView) {
        _TokenHomeView.overview => _TokenOverview(
          status: status,
          traffic: _traffic,
          trafficHistories: _trafficHistories,
          trafficError: _trafficError,
          running: status.isRunning,
          onOpenInstance: _openNetworkInstance,
          onOpenConsole: () => unawaited(_openConsoleNetworks()),
          onRetry: () => unawaited(_pollTraffic()),
        ),
        _TokenHomeView.network => _TokenNetworkInstanceDetailPage(
          runtimeName: selectedRuntimeName,
          snapshot: selectedRuntimeName == null
              ? null
              : _traffic[selectedRuntimeName],
          peerStatuses: selectedRuntimeName == null
              ? const <String, CorePeerStatus>{}
              : _peerStatusesByRuntime[selectedRuntimeName] ??
                    const <String, CorePeerStatus>{},
          peerStatusError: selectedRuntimeName == null
              ? _trafficError
              : _peerStatusErrorsByRuntime[selectedRuntimeName],
          collapse: _networkDetailHeaderCollapse,
          scrollDeltaCoordinator: _coordinateNetworkDetailScrollDelta,
          onStaticContentShown: _handleNetworkDetailStaticViewportShown,
          onRefresh: () => unawaited(_pollSelectedPeerStatuses()),
          onOpenConsole: () => unawaited(_openConsoleNetworks()),
          onRetry: () => unawaited(_pollTraffic()),
        ),
        _TokenHomeView.settings => _TokenSettingsPanel(
          profile: widget.profile,
          coreLifecycleService: widget.coreLifecycleService,
          appUpdateService: widget.appUpdateService,
          windowBehaviorPreferences: widget.windowBehaviorPreferences,
          onCopyDiagnostics: () => unawaited(_copyDiagnostics()),
          onCopyText: (value) => unawaited(_copyText(value)),
          onDisconnect: () => unawaited(widget.onDisconnect()),
          onChangeToken: () => unawaited(widget.onChangeToken()),
          onAccountLogin: () => unawaited(widget.onAccountLogin()),
        ),
      },
    );
  }
}

enum _TokenHomeView { overview, network, settings }

HomeDashboardView _homeDashboardViewForToken(_TokenHomeView view) {
  return switch (view) {
    _TokenHomeView.overview => HomeDashboardView.overview,
    _TokenHomeView.network => HomeDashboardView.network,
    _TokenHomeView.settings => HomeDashboardView.settings,
  };
}

const List<_TokenHomeView> _tokenMobileViewOrder = <_TokenHomeView>[
  _TokenHomeView.overview,
  _TokenHomeView.network,
  _TokenHomeView.settings,
];

class _TokenOverview extends StatelessWidget {
  const _TokenOverview({
    required this.status,
    required this.traffic,
    required this.trafficHistories,
    required this.trafficError,
    required this.running,
    required this.onOpenInstance,
    required this.onOpenConsole,
    required this.onRetry,
  });

  final CoreRunStatus status;
  final Map<String, _TokenTrafficSnapshot> traffic;
  final Map<String, List<HomeTrafficHistoryPoint>> trafficHistories;
  final String? trafficError;
  final bool running;
  final ValueChanged<String> onOpenInstance;
  final VoidCallback onOpenConsole;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final entries = traffic.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TokenStatusSummary(
          status: status,
          instanceCount: running ? entries.length : 0,
        ),
        const SizedBox(height: 24),
        _TokenNetworkInstanceList(
          entries: entries,
          trafficHistories: trafficHistories,
          trafficError: trafficError,
          running: running,
          onOpenInstance: onOpenInstance,
          onOpenConsole: onOpenConsole,
          onRetry: onRetry,
        ),
      ],
    );
  }
}

class _TokenStatusSummary extends StatelessWidget {
  const _TokenStatusSummary({
    required this.status,
    required this.instanceCount,
  });

  final CoreRunStatus status;
  final int instanceCount;

  @override
  Widget build(BuildContext context) {
    final running = status.phase == CoreRunPhase.running;
    final error = status.phase == CoreRunPhase.error;
    final checking =
        status.phase == CoreRunPhase.checking ||
        status.phase == CoreRunPhase.repairing;
    final stopped =
        status.phase == CoreRunPhase.stopped ||
        status.phase == CoreRunPhase.signedOut;
    final needsAuthorization =
        status.phase == CoreRunPhase.needsElevation ||
        status.phase == CoreRunPhase.needsVpnPermission;

    final ringColor = error
        ? const Color(0xFFDC2626)
        : needsAuthorization
        ? const Color(0xFFF59E0B)
        : checking || stopped
        ? const Color(0xFF9CA3AF)
        : running
        ? const Color(0xFF16A34A)
        : const Color(0xFF2563EB);

    final bgColor = error
        ? const Color(0xFFFEE2E2)
        : needsAuthorization
        ? const Color(0xFFFEF3C7)
        : checking || stopped
        ? const Color(0xFFF3F4F6)
        : running
        ? const Color(0xFFF0FDF4)
        : const Color(0xFFDBEAFE);

    final borderColor = error
        ? const Color(0xFFFECACA)
        : needsAuthorization
        ? const Color(0xFFFDE68A)
        : checking || stopped
        ? const Color(0xFFE5E7EB)
        : running
        ? const Color(0xFFBBF7D0)
        : const Color(0xFFBFDBFE);

    final icon = error
        ? Icons.error_outline
        : needsAuthorization
        ? Icons.verified_user_outlined
        : checking
        ? Icons.sync
        : running
        ? Icons.check
        : Icons.power_settings_new;

    final title = error
        ? '连接异常'
        : needsAuthorization
        ? '需要授权'
        : checking
        ? '正在连接'
        : running
        ? '已在线'
        : '已断开';

    final subtitle = error
        ? status.lastError?.isNotEmpty == true
              ? status.lastError!
              : '连接引擎遇到问题'
        : needsAuthorization
        ? status.lastError?.isNotEmpty == true
              ? status.lastError!
              : status.message
        : running
        ? instanceCount > 0
              ? '$instanceCount 个网络实例'
              : '暂无网络实例'
        : status.message;

    final statusBody = Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: ringColor, width: 3),
            boxShadow: [
              BoxShadow(
                color: ringColor.withAlpha(20),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(child: Icon(icon, color: ringColor, size: 18)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                  fontSize: 16,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF64748B),
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withAlpha(6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(children: [Expanded(child: statusBody)]),
    );
  }
}

class _TokenSettingsPanel extends StatefulWidget {
  const _TokenSettingsPanel({
    required this.profile,
    required this.coreLifecycleService,
    required this.appUpdateService,
    required this.windowBehaviorPreferences,
    required this.onCopyDiagnostics,
    required this.onCopyText,
    required this.onDisconnect,
    required this.onChangeToken,
    required this.onAccountLogin,
  });

  final TokenConnectionProfile profile;
  final CoreLifecycleService coreLifecycleService;
  final AppUpdateService appUpdateService;
  final WindowBehaviorPreferences windowBehaviorPreferences;
  final VoidCallback onCopyDiagnostics;
  final ValueChanged<String> onCopyText;
  final VoidCallback onDisconnect;
  final VoidCallback onChangeToken;
  final VoidCallback onAccountLogin;

  @override
  State<_TokenSettingsPanel> createState() => _TokenSettingsPanelState();
}

class _TokenSettingsPanelState extends State<_TokenSettingsPanel> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  bool _checkingForUpdates = false;

  Future<void> _checkForUpdates() async {
    if (_checkingForUpdates) {
      return;
    }
    setState(() {
      _checkingForUpdates = true;
    });
    try {
      final feedback = await runHomeAppUpdateCheck(widget.appUpdateService);
      if (!mounted) {
        return;
      }
      _showToast(feedback.message, destructive: feedback.destructive);
    } finally {
      if (mounted) {
        setState(() {
          _checkingForUpdates = false;
        });
      }
    }
  }

  void _showToast(String message, {bool destructive = false}) {
    showHomeSettingsToast(context, message, destructive: destructive);
  }

  @override
  Widget build(BuildContext context) {
    return HomeSettingsPage(
      sections: [
        HomeSettingsSection(
          id: 'connection',
          title: '连接引擎',
          icon: Icons.memory_outlined,
          builder: (context) => HomeCoreSettingsSection(
            coreLifecycleService: widget.coreLifecycleService,
            onCopyText: widget.onCopyText,
            missingMachineIdText: '等待注册',
            extraInfoBuilder: (_, _) {
              return [
                HomeSettingsInfoItem(
                  label: '控制服务器',
                  value: widget.profile.configServer,
                ),
              ];
            },
            extraActions: [
              FButton(
                variant: .outline,
                onPress: widget.onCopyDiagnostics,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_copy, size: 16),
                    SizedBox(width: 8),
                    Text('复制诊断'),
                  ],
                ),
              ),
            ],
          ),
        ),
        HomeSettingsSection(
          id: 'login',
          title: '登录方式',
          icon: Icons.vpn_key_outlined,
          builder: (context) => _TokenLoginSettingsSection(
            profile: widget.profile,
            onDisconnect: widget.onDisconnect,
            onChangeToken: widget.onChangeToken,
            onAccountLogin: widget.onAccountLogin,
          ),
        ),
        if (homeSettingsCanConfigureWindowBehavior)
          HomeSettingsSection(
            id: 'window',
            title: '窗口行为',
            icon: Icons.web_asset_outlined,
            builder: (context) => HomeWindowBehaviorSettingsSection(
              windowBehaviorPreferences: widget.windowBehaviorPreferences,
            ),
          ),
        HomeSettingsSection(
          id: 'app',
          title: '应用信息',
          icon: Icons.apps_outlined,
          builder: (context) => HomeAppSettingsSection(
            packageInfo: _packageInfo,
            checkingForUpdates: _checkingForUpdates,
            onCheckForUpdates: () => unawaited(_checkForUpdates()),
          ),
        ),
        HomeSettingsSection(
          id: 'diagnostics',
          title: '诊断日志',
          icon: Icons.description_outlined,
          builder: (context) => const HomeDiagnosticsSettingsSection(),
        ),
      ],
    );
  }
}

class _TokenLoginSettingsSection extends StatelessWidget {
  const _TokenLoginSettingsSection({
    required this.profile,
    required this.onDisconnect,
    required this.onChangeToken,
    required this.onAccountLogin,
  });

  final TokenConnectionProfile profile;
  final VoidCallback onDisconnect;
  final VoidCallback onChangeToken;
  final VoidCallback onAccountLogin;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FCard.raw(
          child: FItemGroup(
            divider: .full,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              HomeSettingsAccountItem(
                prefix: const Icon(Icons.vpn_key_outlined),
                label: '设备令牌',
                primary: profile.effectiveDisplayName,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FButton(
              variant: .outline,
              onPress: onChangeToken,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.key_outlined, size: 16),
                  SizedBox(width: 8),
                  Text('更换令牌'),
                ],
              ),
            ),
            FButton(
              variant: .outline,
              onPress: onAccountLogin,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.login, size: 16),
                  SizedBox(width: 8),
                  Text('使用账号登录'),
                ],
              ),
            ),
            FButton(
              variant: .destructive,
              onPress: onDisconnect,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.power_settings_new, size: 16),
                  SizedBox(width: 8),
                  Text('断开连接'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TokenNetworkInstanceList extends StatelessWidget {
  const _TokenNetworkInstanceList({
    required this.entries,
    required this.trafficHistories,
    required this.trafficError,
    required this.running,
    required this.onOpenInstance,
    required this.onOpenConsole,
    required this.onRetry,
  });

  final List<MapEntry<String, _TokenTrafficSnapshot>> entries;
  final Map<String, List<HomeTrafficHistoryPoint>> trafficHistories;
  final String? trafficError;
  final bool running;
  final ValueChanged<String> onOpenInstance;
  final VoidCallback onOpenConsole;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final hasTrafficError = trafficError != null && trafficError!.isNotEmpty;
    final showInstances = running && !hasTrafficError && entries.isNotEmpty;
    final Widget empty = !running
        ? const _TokenNetworkInstanceEmpty(message: '连接建立后会显示本机网络实例。')
        : _TokenNetworkSetupGuide(
            onOpenConsole: onOpenConsole,
            onRetry: onRetry,
          );

    return HomeNetworkListSection(
      trailing: const _TokenReadonlyHint(),
      empty: empty,
      children: [
        if (showInstances)
          for (final entry in entries)
            _TokenNetworkInstanceTile(
              runtimeName: entry.key,
              snapshot: entry.value,
              history:
                  trafficHistories[entry.key] ??
                  const <HomeTrafficHistoryPoint>[],
              onOpen: () => onOpenInstance(entry.key),
            ),
      ],
    );
  }
}

class _TokenNetworkInstanceDetailPage extends StatelessWidget {
  const _TokenNetworkInstanceDetailPage({
    required this.runtimeName,
    required this.snapshot,
    required this.peerStatuses,
    required this.peerStatusError,
    required this.collapse,
    required this.scrollDeltaCoordinator,
    required this.onStaticContentShown,
    required this.onRefresh,
    required this.onOpenConsole,
    required this.onRetry,
  });

  final String? runtimeName;
  final _TokenTrafficSnapshot? snapshot;
  final Map<String, CorePeerStatus> peerStatuses;
  final String? peerStatusError;
  final HomeNetworkDetailHeaderCollapseController collapse;
  final AppScrollDeltaCoordinator scrollDeltaCoordinator;
  final VoidCallback onStaticContentShown;
  final VoidCallback onRefresh;
  final VoidCallback onOpenConsole;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final name = runtimeName?.trim() ?? '';
    final displayName = _tokenRuntimeDisplayName(name);
    final nodes = name.isEmpty
        ? const <NetworkDevice>[]
        : _tokenNetworkDevicesFromPeerStatuses(name, peerStatuses);
    final downloadRate = _formatTrafficRate(snapshot?.downloadBytesPerSecond);
    final uploadRate = _formatTrafficRate(snapshot?.uploadBytesPerSecond);
    final header = HomeNetworkDetailHeader(
      title: name.isEmpty ? '网络' : displayName,
      subtitle: '设备令牌连接 · 只读实例',
      totalDevices: nodes.length,
      onlineDevices: nodes.length,
      downloadRateText: downloadRate,
      uploadRateText: uploadRate,
      collapse: collapse,
      actions: [
        Tooltip(
          message: '刷新节点',
          excludeFromSemantics: true,
          child: FButton(
            variant: .ghost,
            size: .sm,
            onPress: name.isEmpty ? null : onRefresh,
            mainAxisSize: MainAxisSize.min,
            child: const Icon(Icons.refresh, size: 16),
          ),
        ),
      ],
    );

    if (name.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 12),
          HomeNetworkDetailSectionTabs(
            selectedIndex: 0,
            onChanged: (_) {},
            tabs: const [
              HomeNetworkDetailSectionTab(
                icon: Icons.devices_other_outlined,
                label: '节点 0',
                compactLabel: '节点',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: _TokenNetworkSetupGuide(
                onOpenConsole: onOpenConsole,
                onRetry: onRetry,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 12),
        HomeNetworkDetailSectionTabs(
          selectedIndex: 0,
          onChanged: (_) {},
          tabs: [
            HomeNetworkDetailSectionTab(
              icon: Icons.devices_other_outlined,
              label: '节点 ${nodes.length}',
              compactLabel: '节点',
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: NetworkNodeListViewport(
            nodes: nodes,
            peerStatusesByIpv4: peerStatuses,
            runtimeError: peerStatusError,
            scrollDeltaCoordinator: scrollDeltaCoordinator,
            onStaticContentShown: onStaticContentShown,
          ),
        ),
      ],
    );
  }
}

class _TokenReadonlyHint extends StatelessWidget {
  const _TokenReadonlyHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Text(
        '只读',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFF64748B),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TokenNetworkSetupGuide extends StatelessWidget {
  const _TokenNetworkSetupGuide({
    required this.onOpenConsole,
    required this.onRetry,
  });

  final VoidCallback onOpenConsole;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FCard.raw(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFBBF7D0)),
                  ),
                  child: const Icon(
                    Icons.add_link,
                    size: 18,
                    color: Color(0xFF16A34A),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '还没有可用网络',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '请在控制台创建网络，并在该网络中挂载当前设备。完成后回到 EasyTier Pro，应用会自动刷新网络实例。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF475569),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  onPress: onOpenConsole,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.open_in_new, size: 16),
                      SizedBox(width: 8),
                      Text('打开控制台'),
                    ],
                  ),
                ),
                FButton(
                  variant: .outline,
                  onPress: onRetry,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh, size: 16),
                      SizedBox(width: 8),
                      Text('重新读取'),
                    ],
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

class _TokenNetworkInstanceEmpty extends StatelessWidget {
  const _TokenNetworkInstanceEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: _TokenMutedText(message),
      ),
    );
  }
}

class _TokenNetworkInstanceTile extends StatelessWidget {
  const _TokenNetworkInstanceTile({
    required this.runtimeName,
    required this.snapshot,
    required this.history,
    required this.onOpen,
  });

  final String runtimeName;
  final _TokenTrafficSnapshot snapshot;
  final List<HomeTrafficHistoryPoint> history;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final downloadRate = _formatTrafficRate(snapshot.downloadBytesPerSecond);
    final uploadRate = _formatTrafficRate(snapshot.uploadBytesPerSecond);
    final showMiniTraffic = homeNetworkSwitchTileShowsInlineMetrics(context);

    return HomeNetworkSwitchTile(
      title: _tokenRuntimeDisplayName(runtimeName),
      joined: true,
      locallyConnected: true,
      failed: false,
      metaChildren: [
        const HomeStatusChip(label: '已连接', active: true),
        if (showMiniTraffic) ...[
          HomeMiniTrafficPill(
            icon: Icons.arrow_downward,
            label: downloadRate,
            color: const Color(0xFF16A34A),
          ),
          HomeMiniTrafficPill(
            icon: Icons.arrow_upward,
            label: uploadRate,
            color: const Color(0xFF2563EB),
          ),
        ],
      ],
      trailingVisualization: history.isEmpty
          ? null
          : HomeNetworkTrafficSparkline(
              key: ValueKey<String>('token-network-traffic-$runtimeName'),
              history: history,
            ),
      switchValue: true,
      switchLoading: false,
      switchTooltip: '设备令牌连接由控制台下发，客户端仅展示状态。',
      onOpen: onOpen,
    );
  }
}

class _TokenHeaderActions extends StatelessWidget {
  const _TokenHeaderActions({
    required this.status,
    required this.settingsActive,
    required this.onShowSettings,
  });

  final CoreRunStatus status;
  final bool settingsActive;
  final VoidCallback onShowSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TokenPhasePill(status: status),
        const SizedBox(width: 8),
        const HomeOpenConsoleButton(
          buttonKey: ValueKey<String>('token-open-console'),
        ),
        const SizedBox(width: 4),
        FTooltip(
          tipBuilder: (context, controller) => const Text('设置'),
          child: FButton(
            variant: settingsActive ? .secondary : .ghost,
            size: .sm,
            onPress: onShowSettings,
            mainAxisSize: MainAxisSize.min,
            child: const Icon(Icons.settings_outlined, size: 16),
          ),
        ),
      ],
    );
  }
}

class _TokenPhasePill extends StatelessWidget {
  const _TokenPhasePill({required this.status});

  final CoreRunStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _phaseColor(status.phase);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _phaseLabel(status.phase),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _TokenMutedText extends StatelessWidget {
  const _TokenMutedText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
      ),
    );
  }
}

class _TokenTrafficSnapshot {
  const _TokenTrafficSnapshot({
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

  factory _TokenTrafficSnapshot.fromTotals(
    CoreNetworkTrafficTotals totals, {
    CoreNetworkTrafficTotals? previous,
  }) {
    final elapsed = previous == null
        ? null
        : totals.sampledAt.difference(previous.sampledAt).inMilliseconds / 1000;
    double? rate(int current, int? last) {
      if (last == null || elapsed == null || elapsed <= 0 || current < last) {
        return null;
      }
      return (current - last) / elapsed;
    }

    return _TokenTrafficSnapshot(
      downloadBytes: totals.downloadBytes,
      uploadBytes: totals.uploadBytes,
      sampledAt: totals.sampledAt,
      downloadBytesPerSecond: rate(
        totals.downloadBytes,
        previous?.downloadBytes,
      ),
      uploadBytesPerSecond: rate(totals.uploadBytes, previous?.uploadBytes),
    );
  }
}

List<NetworkDevice> _tokenNetworkDevicesFromPeerStatuses(
  String runtimeName,
  Map<String, CorePeerStatus> peerStatuses,
) {
  final peers = peerStatuses.values.toList()
    ..sort((left, right) {
      if (left.isLocal && !right.isLocal) return -1;
      if (!left.isLocal && right.isLocal) return 1;
      final leftLabel = left.hostname.trim().isNotEmpty
          ? left.hostname.trim()
          : left.ipv4.trim();
      final rightLabel = right.hostname.trim().isNotEmpty
          ? right.hostname.trim()
          : right.ipv4.trim();
      return leftLabel.compareTo(rightLabel);
    });

  return [
    for (var i = 0; i < peers.length; i++)
      NetworkDevice(
        id: _tokenPeerDeviceId(runtimeName, peers[i], i),
        name: _tokenPeerDeviceName(peers[i], i),
        online: true,
        hostname: peers[i].hostname,
        ipv4: peers[i].ipv4,
        connectivityState: 'online',
        desiredState: 'present',
        lifecycleState: 'active',
      ),
  ];
}

String _tokenRuntimeDisplayName(String runtimeName) {
  final trimmed = runtimeName.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }

  final parts = trimmed.split('_');
  if (parts.length >= 3 && parts.first == 't' && _looksLikeUuid(parts[1])) {
    final displayName = parts.skip(2).join('_').trim();
    if (displayName.isNotEmpty) {
      return displayName;
    }
  }
  return trimmed;
}

String _tokenHomeHeaderSubtitle(TokenConnectionProfile profile) {
  final displayName = profile.displayName.trim();
  if (displayName.isEmpty || displayName == '设备令牌连接') {
    return '设备令牌连接';
  }
  return '设备令牌连接 · $displayName';
}

bool _looksLikeUuid(String value) {
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);
}

String _tokenPeerDeviceId(String runtimeName, CorePeerStatus peer, int index) {
  final peerId = peer.peerId.trim();
  if (peerId.isNotEmpty) {
    return peerId;
  }
  final ipv4 = peer.ipv4.trim();
  if (ipv4.isNotEmpty) {
    return '$runtimeName-$ipv4';
  }
  return '$runtimeName-node-$index';
}

String _tokenPeerDeviceName(CorePeerStatus peer, int index) {
  final hostname = peer.hostname.trim();
  if (hostname.isNotEmpty) {
    return hostname;
  }
  final ipv4 = peer.ipv4.trim();
  if (ipv4.isNotEmpty) {
    return ipv4;
  }
  return '节点 ${index + 1}';
}

String _phaseLabel(CoreRunPhase phase) {
  return switch (phase) {
    CoreRunPhase.running => '已连接',
    CoreRunPhase.checking || CoreRunPhase.repairing => '连接中',
    CoreRunPhase.needsVpnPermission => '待授权',
    CoreRunPhase.needsElevation => '待授权',
    CoreRunPhase.error => '异常',
    CoreRunPhase.stopped => '已断开',
    CoreRunPhase.signedOut => '未连接',
  };
}

Color _phaseColor(CoreRunPhase phase) {
  return switch (phase) {
    CoreRunPhase.running => const Color(0xFF16A34A),
    CoreRunPhase.checking || CoreRunPhase.repairing => const Color(0xFF2563EB),
    CoreRunPhase.needsVpnPermission ||
    CoreRunPhase.needsElevation => const Color(0xFFD97706),
    CoreRunPhase.error => const Color(0xFFDC2626),
    CoreRunPhase.stopped || CoreRunPhase.signedOut => const Color(0xFF64748B),
  };
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
