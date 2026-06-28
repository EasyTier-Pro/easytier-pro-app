part of 'workspace_home_view.dart';

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

    return HomeShellDesktopHeader(
      contentKey: const ValueKey<String>('desktop-dashboard-header-content'),
      navigation: [
        FButton(
          variant: activeView == _DashboardView.overview ? .secondary : .ghost,
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
          variant: activeView == _DashboardView.devices ? .secondary : .ghost,
          size: .sm,
          onPress: onShowDevices,
          child: const Text('设备'),
        ),
      ],
      metrics: [
        HomeHeaderMetric(
          label: '设备',
          value: '$deviceCount',
          icon: Icons.devices_other_outlined,
        ),
        HomeHeaderMetric(
          label: '在线',
          value: '$onlineDeviceCount',
          icon: Icons.circle,
          color: onlineDeviceCount > 0 ? const Color(0xFF16A34A) : Colors.grey,
        ),
        HomeCoreStatusLabel(
          statusListenable: coreStatusListenable,
          label: '引擎',
        ),
      ],
      trailing: _UserMenu(
        userName: trimmedName,
        workspaceName: workspaceName,
        initial: initial,
        onShowSettings: onShowSettings,
        onLogout: onLogout,
      ),
    );
  }
}

class _MobileDashboardHeader extends StatelessWidget {
  const _MobileDashboardHeader({
    required this.userName,
    required this.workspaceName,
    required this.onShowSettings,
    required this.onLogout,
    required this.coreStatusListenable,
  });

  final String userName;
  final String workspaceName;
  final VoidCallback onShowSettings;
  final Future<void> Function() onLogout;
  final ValueListenable<CoreRunStatus> coreStatusListenable;

  @override
  Widget build(BuildContext context) {
    final trimmedName = userName.trim();
    final initial = trimmedName.isEmpty ? 'U' : trimmedName.substring(0, 1);

    return HomeShellMobileHeader(
      title: 'EasyTier Pro',
      subtitle: workspaceName,
      suffixes: [
        HomeCoreStatusDot(statusListenable: coreStatusListenable),
        _UserMenu(
          userName: trimmedName,
          workspaceName: workspaceName,
          initial: initial,
          onShowSettings: onShowSettings,
          onLogout: onLogout,
        ),
      ],
    );
  }
}

class _MobileDashboardNavigation extends StatelessWidget {
  const _MobileDashboardNavigation({
    required this.activeView,
    required this.networks,
    required this.selectedNetworkId,
    required this.onShowOverview,
    required this.onShowNetwork,
    required this.onSelectNetwork,
    required this.onShowDevices,
    required this.onShowSettings,
  });

  final _DashboardView activeView;
  final List<ConsoleNetwork> networks;
  final String? selectedNetworkId;
  final VoidCallback onShowOverview;
  final VoidCallback onShowNetwork;
  final ValueChanged<String> onSelectNetwork;
  final VoidCallback onShowDevices;
  final VoidCallback onShowSettings;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = switch (activeView) {
      _DashboardView.overview => 0,
      _DashboardView.network => 1,
      _DashboardView.devices => 2,
      _DashboardView.settings => 3,
    };

    return HomeShellMobileNavigation(
      navigationKey: const ValueKey<String>('mobile-dashboard-navigation'),
      index: selectedIndex,
      items: [
        HomeShellMobileNavigationItem(
          id: 'overview',
          key: const ValueKey<String>('mobile-nav-overview'),
          icon: Icons.home_outlined,
          label: '首页',
          onSelect: onShowOverview,
        ),
        HomeShellMobileNavigationItem(
          id: 'network',
          key: const ValueKey<String>('mobile-nav-network'),
          icon: Icons.hub_outlined,
          label: '网络',
          onSelect: () => _handleNetworkNavigation(context),
        ),
        HomeShellMobileNavigationItem(
          id: 'devices',
          key: const ValueKey<String>('mobile-nav-devices'),
          icon: Icons.devices_other_outlined,
          label: '设备',
          onSelect: onShowDevices,
        ),
        HomeShellMobileNavigationItem(
          id: 'settings',
          key: const ValueKey<String>('mobile-nav-settings'),
          icon: Icons.settings_outlined,
          label: '设置',
          onSelect: onShowSettings,
        ),
      ],
    );
  }

  void _handleNetworkNavigation(BuildContext context) {
    if (activeView == _DashboardView.network && networks.length > 1) {
      _showNetworkPicker(context);
    } else {
      onShowNetwork();
    }
  }

  void _showNetworkPicker(BuildContext context) {
    final networks = this.networks;
    final selectedNetworkId = this.selectedNetworkId;
    final onSelectNetwork = this.onSelectNetwork;

    unawaited(
      showFSheet<void>(
        context: context,
        side: FLayout.btt,
        mainAxisMaxRatio: 0.5,
        builder: (context) => _MobileNetworkPickerSheet(
          networks: networks,
          selectedNetworkId: selectedNetworkId,
          onSelectNetwork: onSelectNetwork,
        ),
      ),
    );
  }
}

class _MobileNetworkPickerSheet extends StatelessWidget {
  const _MobileNetworkPickerSheet({
    required this.networks,
    required this.selectedNetworkId,
    required this.onSelectNetwork,
  });

  final List<ConsoleNetwork> networks;
  final String? selectedNetworkId;
  final ValueChanged<String> onSelectNetwork;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: SafeArea(
        top: false,
        child: Padding(
          key: const ValueKey<String>('mobile-network-picker-sheet'),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: FItemGroup(
            divider: FItemDivider.full,
            children: [
              for (final network in networks)
                FItem(
                  key: ValueKey<String>('mobile-network-option-${network.id}'),
                  prefix: SizedBox(
                    width: 18,
                    child: network.id == selectedNetworkId
                        ? const Icon(Icons.check, size: 16)
                        : null,
                  ),
                  title: Text(network.name, overflow: TextOverflow.ellipsis),
                  onPress: () {
                    Navigator.of(context).pop();
                    onSelectNetwork(network.id);
                  },
                ),
            ],
          ),
        ),
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

    return ExcludeSemantics(
      child: FPopoverMenu(
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
                  title: SelectionContainer.disabled(
                    child: Text(network.name, overflow: TextOverflow.ellipsis),
                  ),
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.statusListenable,
    required this.engineVersionListenable,
    required this.joinedCount,
    required this.downloadRate,
    required this.uploadRate,
    required this.hasTrafficStats,
    this.onElevate,
  });

  final ValueListenable<CoreRunStatus> statusListenable;
  final ValueListenable<CoreEngineVersionStatus> engineVersionListenable;
  final int joinedCount;
  final double downloadRate;
  final double uploadRate;
  final bool hasTrafficStats;
  final Future<void> Function()? onElevate;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreEngineVersionStatus>(
      valueListenable: engineVersionListenable,
      builder: (context, engineVersionStatus, _) {
        return ValueListenableBuilder<CoreRunStatus>(
          valueListenable: statusListenable,
          builder: (context, status, _) {
            final running = status.phase == CoreRunPhase.running;
            final error = status.phase == CoreRunPhase.error;
            final checking = status.phase == CoreRunPhase.checking;
            final stopped = status.phase == CoreRunPhase.stopped;
            final signedOut = status.phase == CoreRunPhase.signedOut;
            final needsElevation = status.phase == CoreRunPhase.needsElevation;
            final needsVpnPermission =
                status.phase == CoreRunPhase.needsVpnPermission;

            final ringColor = error
                ? const Color(0xFFDC2626)
                : needsElevation || needsVpnPermission
                ? const Color(0xFFF59E0B)
                : checking || stopped || signedOut
                ? const Color(0xFF9CA3AF)
                : running
                ? const Color(0xFF16A34A)
                : const Color(0xFF2563EB);

            final bgColor = error
                ? const Color(0xFFFEE2E2)
                : needsElevation || needsVpnPermission
                ? const Color(0xFFFEF3C7)
                : checking || stopped || signedOut
                ? const Color(0xFFF3F4F6)
                : running
                ? const Color(0xFFF0FDF4)
                : const Color(0xFFDBEAFE);

            final borderColor = error
                ? const Color(0xFFFECACA)
                : needsElevation || needsVpnPermission
                ? const Color(0xFFFDE68A)
                : checking || stopped || signedOut
                ? const Color(0xFFE5E7EB)
                : running
                ? const Color(0xFFBBF7D0)
                : const Color(0xFFBFDBFE);

            final icon = error
                ? Icons.error_outline
                : needsElevation
                ? Icons.admin_panel_settings_outlined
                : needsVpnPermission
                ? Icons.vpn_key_outlined
                : checking
                ? Icons.sync
                : running
                ? Icons.check
                : Icons.power_settings_new;

            final title = error
                ? '引擎异常'
                : needsElevation
                ? '需要安装连接引擎'
                : needsVpnPermission
                ? '需要 VPN 授权'
                : checking
                ? '正在检查'
                : running
                ? '已在线'
                : stopped
                ? '已断开'
                : '准备中';

            final machineId = status.machineId;
            final String subtitle;
            if (error) {
              subtitle = status.lastError?.isNotEmpty == true
                  ? status.lastError!
                  : '连接引擎遇到问题';
            } else if (needsElevation) {
              subtitle = status.lastError?.isNotEmpty == true
                  ? status.lastError!
                  : 'EasyTier 需要管理员权限来安装连接引擎并创建虚拟网卡';
            } else if (needsVpnPermission) {
              subtitle = status.lastError?.isNotEmpty == true
                  ? status.lastError!
                  : 'Android 需要授权后才能建立虚拟网卡';
            } else if (stopped) {
              subtitle = status.message;
            } else if (running && engineVersionStatus.updateAvailable) {
              final consoleVersion = engineVersionStatus.consoleVersion;
              subtitle = consoleVersion == null || consoleVersion.isEmpty
                  ? '连接引擎可更新'
                  : '连接引擎可更新至 $consoleVersion';
            } else if (joinedCount > 0) {
              subtitle = '$joinedCount 个网络';
            } else {
              subtitle = machineId?.isNotEmpty == true
                  ? '设备 ${_shortId(machineId!)} · 尚未加入网络'
                  : '正在初始化设备...';
            }

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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
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

            final trafficStrip =
                hasTrafficStats &&
                    joinedCount > 0 &&
                    !error &&
                    !needsElevation &&
                    !needsVpnPermission
                ? HomeTrafficRateStrip(
                    downloadRate: downloadRate,
                    uploadRate: uploadRate,
                  )
                : null;

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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 420;
                  final elevationButton = needsElevation && onElevate != null
                      ? _ControlSelectionBoundary(
                          child: FButton(
                            variant: .primary,
                            size: .sm,
                            onPress: () => unawaited(onElevate!()),
                            child: const Text('以管理员身份运行'),
                          ),
                        )
                      : null;

                  if (narrow && elevationButton != null) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        statusBody,
                        const SizedBox(height: 12),
                        elevationButton,
                      ],
                    );
                  }

                  if (trafficStrip != null && constraints.maxWidth < 240) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        statusBody,
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: trafficStrip,
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: statusBody),
                      if (elevationButton != null) ...[
                        const SizedBox(width: 14),
                        elevationButton,
                      ] else if (trafficStrip != null) ...[
                        const SizedBox(width: 10),
                        trafficStrip,
                      ],
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
