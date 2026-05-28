import 'dart:async';

import 'package:forui/forui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_lifecycle_service.dart';
import '../logging/app_logger.dart';
import '../auth/console_auth_service.dart';

enum _DashboardView { overview, network, nodes, services, settings }

enum _UserMenuAction { settings, logout }

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
  List<ConsoleNetwork> _networks = const <ConsoleNetwork>[];
  List<NetworkDevice> _devices = const <NetworkDevice>[];
  String? _selectedNetworkId;
  String? _networkError;
  String? _deviceError;
  bool _isLoadingNetworks = false;
  bool _isLoadingDevices = false;
  int _networkRequestId = 0;
  int _deviceRequestId = 0;
  _DashboardView _activeView = _DashboardView.overview;
  bool _isNetworkDetailOpen = false;

  ConsoleWorkspace? get _workspace => widget.session.user.currentWorkspace;

  ConsoleNetwork? get _selectedNetwork {
    for (final network in _networks) {
      if (network.id == _selectedNetworkId) {
        return network;
      }
    }
    return null;
  }

  int get _onlineDeviceCount {
    return _devices.where((device) => device.online).length;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadNetworks());
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

      if (selectedId != null) {
        await _loadDevices(selectedId);
      } else {
        setState(() {
          _devices = const <NetworkDevice>[];
          _deviceError = null;
        });
      }
    } catch (error) {
      if (!mounted || requestId != _networkRequestId) {
        return;
      }
      setState(() {
        _isLoadingNetworks = false;
        _networkError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadDevices(String networkId) async {
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }

    final requestId = ++_deviceRequestId;
    setState(() {
      _isLoadingDevices = true;
      _deviceError = null;
    });

    try {
      final devices = await widget.authService.fetchNetworkDevices(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
        networkId: networkId,
      );

      if (!mounted || requestId != _deviceRequestId) {
        return;
      }

      setState(() {
        _devices = devices;
        _isLoadingDevices = false;
      });
    } catch (error) {
      if (!mounted || requestId != _deviceRequestId) {
        return;
      }
      setState(() {
        _isLoadingDevices = false;
        _deviceError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _selectNetwork(String networkId) {
    if (_selectedNetworkId == networkId) {
      return;
    }

    setState(() {
      _selectedNetworkId = networkId;
    });
    unawaited(_loadDevices(networkId));
  }

  void _openNetworkDetail(ConsoleNetwork network) {
    if (_selectedNetworkId != network.id) {
      _selectNetwork(network.id);
    }
    setState(() {
      _isNetworkDetailOpen = true;
    });
  }

  void _closeNetworkDetail() {
    setState(() {
      _isNetworkDetailOpen = false;
    });
  }

  void _showOverview() {
    setState(() {
      _activeView = _DashboardView.overview;
      _isNetworkDetailOpen = false;
    });
  }

  void _showNetwork() {
    setState(() {
      _activeView = _DashboardView.network;
      _isNetworkDetailOpen = false;
    });
  }

  void _showServices() {
    setState(() {
      _activeView = _DashboardView.services;
      _isNetworkDetailOpen = false;
    });
  }

  void _showNodes() {
    setState(() {
      _activeView = _DashboardView.nodes;
      _isNetworkDetailOpen = false;
    });
  }

  void _showSettings() {
    setState(() {
      _activeView = _DashboardView.settings;
      _isNetworkDetailOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedNetwork = _selectedNetwork;
    final workspaceName = _workspace?.name ?? '未关联工作区';

    return FScaffold(
      childPad: false,
      child: Stack(
        children: [
          Column(
            children: [
              _DashboardHeader(
                userName: widget.session.user.effectiveName,
                workspaceName: workspaceName,
                activeView: _activeView,
                networkCount: _networks.length,
                deviceCount: _devices.length,
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
                        child: _buildContent(context, selectedNetwork),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          _buildNetworkDetailOverlay(selectedNetwork),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, ConsoleNetwork? selectedNetwork) {
    return switch (_activeView) {
      _DashboardView.overview => _buildOverview(context, selectedNetwork),
      _DashboardView.network => _buildNetworkListPage(context, selectedNetwork),
      _DashboardView.nodes => _buildNodesPage(context, selectedNetwork),
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

  Widget _buildNetworkDetailOverlay(ConsoleNetwork? selectedNetwork) {
    final isOpen = _isNetworkDetailOpen && selectedNetwork != null;

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !isOpen,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final panelWidth = constraints.maxWidth >= 720
                ? 560.0
                : constraints.maxWidth * 0.88;

            return Stack(
              children: [
                AnimatedOpacity(
                  opacity: isOpen ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeNetworkDetail,
                    child: const ColoredBox(color: Color(0x66000000)),
                  ),
                ),
                AnimatedPositioned(
                  top: 0,
                  right: isOpen ? 0 : -panelWidth,
                  bottom: 0,
                  width: panelWidth,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0xFFF8FAFC),
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x330F172A),
                          blurRadius: 24,
                          offset: Offset(-8, 0),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: !isOpen
                          ? const SizedBox.shrink()
                          : _buildNetworkDetail(
                              context,
                              selectedNetwork,
                              onClose: _closeNetworkDetail,
                            ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildOverview(BuildContext context, ConsoleNetwork? selectedNetwork) {
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
      return const SizedBox(
        height: 360,
        child: _StateMessage(message: '当前工作区暂无网络'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '概览',
          subtitle: '管理工作区内的零信任网络与设备状态。',
          trailing: FButton(
            variant: .outline,
            size: .sm,
            onPress: _loadNetworks,
            child: const Text('刷新网络'),
          ),
        ),
        const SizedBox(height: 20),
        Text('网络', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width >= 860 ? 3 : (width >= 560 ? 2 : 1);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _networks.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.58,
              ),
              itemBuilder: (context, index) {
                final network = _networks[index];
                final selected = network.id == selectedNetwork?.id;
                return _NetworkCard(
                  network: network,
                  selected: selected,
                  deviceCount: selected ? _devices.length : null,
                  onlineDeviceCount: selected ? _onlineDeviceCount : null,
                  loading: selected && _isLoadingDevices,
                  onOpen: () => _openNetworkDetail(network),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildDevicePanel(
    BuildContext context,
    ConsoleNetwork? selectedNetwork,
  ) {
    if (selectedNetwork == null) {
      return const SizedBox(
        height: 360,
        child: _StateMessage(message: '请选择一个网络以查看设备情况'),
      );
    }

    if (_isLoadingDevices) {
      return const SizedBox(
        height: 360,
        child: Center(child: FCircularProgress()),
      );
    }

    if (_deviceError != null) {
      return SizedBox(
        height: 360,
        child: _StateMessage(
          message: _deviceError!,
          action: FButton(
            onPress: () => _loadDevices(selectedNetwork.id),
            child: const Text('重试'),
          ),
        ),
      );
    }

    if (_devices.isEmpty) {
      return const SizedBox(
        height: 240,
        child: _StateMessage(message: '该网络暂无设备'),
      );
    }

    return FCard.raw(
      child: FItemGroup(
        divider: .full,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final device in _devices)
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
    );
  }

  Widget _buildNetworkListPage(
    BuildContext context,
    ConsoleNetwork? selectedNetwork,
  ) {
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
      return const SizedBox(
        height: 360,
        child: _StateMessage(message: '当前工作区暂无网络'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '所有网络',
          subtitle: '当前用户工作区下的全部零信任网络。',
          trailing: FButton(
            variant: .outline,
            size: .sm,
            onPress: _loadNetworks,
            child: const Text('刷新网络'),
          ),
        ),
        const SizedBox(height: 20),
        FCard.raw(
          child: FItemGroup(
            divider: .full,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final network in _networks)
                FItem(
                  prefix: const Icon(Icons.hub_outlined),
                  title: Text(network.name),
                  subtitle: Text(
                    network.id == selectedNetwork?.id
                        ? '$_onlineDeviceCount / ${_devices.length} 台设备在线'
                        : '点击查看设备列表',
                  ),
                  details: Text(network.id),
                  suffix: const Icon(Icons.chevron_right_rounded),
                  onPress: () => _openNetworkDetail(network),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkDetail(
    BuildContext context,
    ConsoleNetwork? selectedNetwork, {
    required VoidCallback onClose,
  }) {
    if (selectedNetwork == null) {
      return _buildDevicePanel(context, selectedNetwork);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: selectedNetwork.name,
          subtitle: '网络详情与设备列表',
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FButton(
                variant: .outline,
                size: .sm,
                onPress: onClose,
                child: const Text('关闭'),
              ),
              FButton(
                variant: .outline,
                size: .sm,
                onPress: () => _loadDevices(selectedNetwork.id),
                child: const Text('刷新设备'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            final info = _NetworkInfoPanel(
              network: selectedNetwork,
              workspaceName: _workspace?.name ?? '未关联工作区',
              totalDevices: _devices.length,
              onlineDevices: _onlineDeviceCount,
            );
            final devices = _DeviceListPanel(
              deviceCount: _devices.length,
              child: _buildDevicePanel(context, selectedNetwork),
            );

            if (!wide) {
              return Column(
                children: [info, const SizedBox(height: 16), devices],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: info),
                const SizedBox(width: 16),
                Expanded(flex: 3, child: devices),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildNodesPage(
    BuildContext context,
    ConsoleNetwork? selectedNetwork,
  ) {
    if (selectedNetwork == null) {
      return const SizedBox(
        height: 360,
        child: _StateMessage(message: '请选择一个网络以查看节点'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '节点',
          subtitle: '当前网络 ${selectedNetwork.name} 下的节点。',
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
                onPress: () => _loadDevices(selectedNetwork.id),
                child: const Text('刷新节点'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _NodeListPanel(
          nodeCount: _devices.length,
          child: _buildDevicePanel(context, selectedNetwork),
        ),
      ],
    );
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
            child: const Text('概览'),
          ),
          const SizedBox(width: 6),
          FButton(
            variant: activeView == _DashboardView.network ? .secondary : .ghost,
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

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({
    required this.network,
    required this.selected,
    required this.loading,
    required this.onOpen,
    this.deviceCount,
    this.onlineDeviceCount,
  });

  final ConsoleNetwork network;
  final bool selected;
  final bool loading;
  final int? deviceCount;
  final int? onlineDeviceCount;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final online = (onlineDeviceCount ?? 0) > 0;
    final statusText = selected ? (online ? '在线' : '离线') : '待查看';
    final subtitle =
        selected && deviceCount != null && onlineDeviceCount != null
        ? '$onlineDeviceCount / $deviceCount 台设备在线'
        : '点击查看设备与网络详情';

    return GestureDetector(
      onTap: onOpen,
      child: FCard.raw(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StatusDot(online: online),
                  const SizedBox(width: 8),
                  Text(
                    statusText,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF737373),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  if (loading)
                    const FCircularProgress(size: .sm)
                  else if (selected)
                    const Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: Color(0xFFFF5530),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                network.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF737373)),
              ),
            ],
          ),
        ),
      ),
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
  const _DeviceListPanel({required this.deviceCount, required this.child});

  final int deviceCount;
  final Widget child;

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
        child,
      ],
    );
  }
}

class _NodeListPanel extends StatelessWidget {
  const _NodeListPanel({required this.nodeCount, required this.child});

  final int nodeCount;
  final Widget child;

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
        child,
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
      AppLogger.instance.info('settings', 'Diagnostics exported', context: {
        'file': file.path,
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('诊断日志已导出: ${file.path}')),
        );
      }
    } catch (error) {
      AppLogger.instance.error('settings', 'Diagnostics export failed', context: {
        'error': error.toString(),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出诊断日志失败')),
        );
      }
    }
  }

  Future<void> _copyLogDirectory(BuildContext context) async {
    final path = AppLogger.instance.logDirectoryPath;
    if (path == null || path.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('日志目录尚未初始化')),
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: path));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志目录已复制: $path')),
      );
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
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
