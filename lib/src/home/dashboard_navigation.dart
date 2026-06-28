import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'home_shell.dart';

enum HomeDashboardView { overview, network, devices, settings }

class HomeDashboardNetworkOption {
  const HomeDashboardNetworkOption({required this.id, required this.name});

  final String id;
  final String name;
}

class HomeDashboardDesktopHeader extends StatelessWidget {
  const HomeDashboardDesktopHeader({
    super.key,
    required this.activeView,
    required this.networks,
    required this.selectedNetworkId,
    required this.onShowOverview,
    required this.onShowNetwork,
    required this.onSelectNetwork,
    required this.onShowDevices,
    this.showNetworkNavigation = true,
    this.metrics = const <Widget>[],
    this.trailing,
    this.contentKey,
  });

  final HomeDashboardView activeView;
  final List<HomeDashboardNetworkOption> networks;
  final String? selectedNetworkId;
  final VoidCallback onShowOverview;
  final VoidCallback onShowNetwork;
  final ValueChanged<String> onSelectNetwork;
  final VoidCallback onShowDevices;
  final bool showNetworkNavigation;
  final List<Widget> metrics;
  final Widget? trailing;
  final Key? contentKey;

  @override
  Widget build(BuildContext context) {
    return HomeShellDesktopHeader(
      contentKey: contentKey,
      navigation: [
        FButton(
          variant: activeView == HomeDashboardView.overview
              ? .secondary
              : .ghost,
          size: .sm,
          onPress: onShowOverview,
          child: const Text('首页'),
        ),
        if (showNetworkNavigation) ...[
          const SizedBox(width: 6),
          if (networks.isEmpty)
            FButton(
              variant: activeView == HomeDashboardView.network
                  ? .secondary
                  : .ghost,
              size: .sm,
              onPress: onShowNetwork,
              child: const Text('网络'),
            )
          else
            _HomeDashboardNetworkTabMenu(
              active: activeView == HomeDashboardView.network,
              networks: networks,
              selectedNetworkId: selectedNetworkId,
              onSelectNetwork: onSelectNetwork,
            ),
        ],
        const SizedBox(width: 6),
        FButton(
          variant: activeView == HomeDashboardView.devices
              ? .secondary
              : .ghost,
          size: .sm,
          onPress: onShowDevices,
          child: const Text('设备'),
        ),
      ],
      metrics: metrics,
      trailing: trailing,
    );
  }
}

class HomeDashboardMobileNavigation extends StatelessWidget {
  const HomeDashboardMobileNavigation({
    super.key,
    required this.activeView,
    required this.networks,
    required this.selectedNetworkId,
    required this.onShowOverview,
    required this.onShowNetwork,
    required this.onSelectNetwork,
    required this.onShowDevices,
    required this.onShowSettings,
  });

  final HomeDashboardView activeView;
  final List<HomeDashboardNetworkOption> networks;
  final String? selectedNetworkId;
  final VoidCallback onShowOverview;
  final VoidCallback onShowNetwork;
  final ValueChanged<String> onSelectNetwork;
  final VoidCallback onShowDevices;
  final VoidCallback onShowSettings;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = switch (activeView) {
      HomeDashboardView.overview => 0,
      HomeDashboardView.network => 1,
      HomeDashboardView.devices => 2,
      HomeDashboardView.settings => 3,
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
    if (activeView == HomeDashboardView.network && networks.length > 1) {
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
        builder: (context) => _HomeDashboardMobileNetworkPickerSheet(
          networks: networks,
          selectedNetworkId: selectedNetworkId,
          onSelectNetwork: onSelectNetwork,
        ),
      ),
    );
  }
}

class _HomeDashboardMobileNetworkPickerSheet extends StatelessWidget {
  const _HomeDashboardMobileNetworkPickerSheet({
    required this.networks,
    required this.selectedNetworkId,
    required this.onSelectNetwork,
  });

  final List<HomeDashboardNetworkOption> networks;
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

class _HomeDashboardNetworkTabMenu extends StatelessWidget {
  const _HomeDashboardNetworkTabMenu({
    required this.active,
    required this.networks,
    required this.selectedNetworkId,
    required this.onSelectNetwork,
  });

  final bool active;
  final List<HomeDashboardNetworkOption> networks;
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
        builder: (context, controller, child) => _HomeDashboardNetworkTabButton(
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

class _HomeDashboardNetworkTabButton extends StatelessWidget {
  const _HomeDashboardNetworkTabButton({
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
