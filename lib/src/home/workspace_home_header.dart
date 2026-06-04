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

          return Row(
            children: [
              const _BrandMark(),
              const SizedBox(width: 12),
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
    this.onElevate,
  });

  final ValueListenable<CoreRunStatus> statusListenable;
  final int joinedCount;
  final double downloadRate;
  final double uploadRate;
  final Future<void> Function()? onElevate;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: statusListenable,
      builder: (context, status, _) {
        final running = status.phase == CoreRunPhase.running;
        final error = status.phase == CoreRunPhase.error;
        final checking = status.phase == CoreRunPhase.checking;
        final signedOut = status.phase == CoreRunPhase.signedOut;
        final needsElevation = status.phase == CoreRunPhase.needsElevation;

        final ringColor = error
            ? const Color(0xFFDC2626)
            : needsElevation
            ? const Color(0xFFF59E0B)
            : checking || signedOut
            ? const Color(0xFF9CA3AF)
            : running
            ? const Color(0xFF16A34A)
            : const Color(0xFF2563EB);

        final bgColor = error
            ? const Color(0xFFFEE2E2)
            : needsElevation
            ? const Color(0xFFFEF3C7)
            : checking || signedOut
            ? const Color(0xFFF3F4F6)
            : running
            ? const Color(0xFFF0FDF4)
            : const Color(0xFFDBEAFE);

        final borderColor = error
            ? const Color(0xFFFECACA)
            : needsElevation
            ? const Color(0xFFFDE68A)
            : checking || signedOut
            ? const Color(0xFFE5E7EB)
            : running
            ? const Color(0xFFBBF7D0)
            : const Color(0xFFBFDBFE);

        final icon = error
            ? Icons.error_outline
            : needsElevation
            ? Icons.admin_panel_settings_outlined
            : checking
            ? Icons.sync
            : running
            ? Icons.check
            : Icons.power_settings_new;

        final title = error
            ? '引擎异常'
            : needsElevation
            ? '需要管理员权限'
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
        } else if (needsElevation) {
          subtitle = status.lastError?.isNotEmpty == true
              ? status.lastError!
              : '创建虚拟网卡需要管理员权限';
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
              if (needsElevation && onElevate != null) ...[
                const SizedBox(width: 12),
                FButton(
                  variant: .primary,
                  size: .sm,
                  onPress: () => unawaited(onElevate!()),
                  child: const Text('以管理员身份运行'),
                ),
              ] else if (joinedCount > 0 && !error && !needsElevation) ...[
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
