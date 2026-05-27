import 'dart:async';

import 'package:forui/forui.dart';
import 'package:flutter/material.dart';

import '../auth/console_auth_service.dart';

class WorkspaceHomeView extends StatefulWidget {
  const WorkspaceHomeView({
    super.key,
    required this.authService,
    required this.session,
    required this.onLogout,
    required this.onShowHelloWorld,
  });

  final AuthService authService;
  final AuthSession session;
  final Future<void> Function() onLogout;
  final VoidCallback onShowHelloWorld;

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

  ConsoleWorkspace? get _workspace => widget.session.user.currentWorkspace;

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

  @override
  Widget build(BuildContext context) {
    ConsoleNetwork? selectedNetwork;
    for (final network in _networks) {
      if (network.id == _selectedNetworkId) {
        selectedNetwork = network;
        break;
      }
    }
    final workspaceName = _workspace?.name ?? '未关联工作区';

    return FScaffold(
      childPad: false,
      sidebar: SizedBox(
        width: 280,
        child: FSidebar.raw(
          header: _SidebarHeader(workspaceName: workspaceName),
          footer: FButton(
            variant: .outline,
            size: .sm,
            onPress: () => unawaited(widget.onLogout()),
            child: const Text('退出登录'),
          ),
          child: _buildNetworkList(context),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    selectedNetwork == null
                        ? '请选择网络'
                        : '网络: ${selectedNetwork.name}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                FButton(
                  variant: .outline,
                  size: .sm,
                  onPress: widget.onShowHelloWorld,
                  child: const Text('弹出 Hello World'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(child: _buildDevicePanel(context, selectedNetwork)),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkList(BuildContext context) {
    if (_isLoadingNetworks) {
      return const Center(child: FCircularProgress());
    }

    if (_networkError != null) {
      return _SidebarMessage(
        message: _networkError!,
        action: FButton(
          size: .sm,
          onPress: _loadNetworks,
          child: const Text('重试'),
        ),
      );
    }

    if (_networks.isEmpty) {
      return const _SidebarMessage(message: '当前工作区暂无网络');
    }

    return ListView(
      children: [
        FSidebarGroup(
          label: const Text('网络'),
          children: [
            for (final network in _networks)
              FSidebarItem(
                icon: const Icon(Icons.device_hub_outlined),
                label: Text(network.name),
                selected: network.id == _selectedNetworkId,
                onPress: () => _selectNetwork(network.id),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDevicePanel(
    BuildContext context,
    ConsoleNetwork? selectedNetwork,
  ) {
    if (selectedNetwork == null) {
      return const Center(child: Text('请选择左侧网络以查看设备情况'));
    }

    if (_isLoadingDevices) {
      return const Center(child: FCircularProgress());
    }

    if (_deviceError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_deviceError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FButton(
                size: .sm,
                onPress: () => _loadDevices(selectedNetwork.id),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_devices.isEmpty) {
      return const Center(child: Text('该网络暂无设备'));
    }

    return FCard.raw(
      child: FItemGroup(
        divider: .full,
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
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({required this.workspaceName});

  final String workspaceName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.hub_outlined),
            const SizedBox(width: 8),
            Text(
              'EasyTier Pro',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(workspaceName, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _SidebarMessage extends StatelessWidget {
  const _SidebarMessage({required this.message, this.action});

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
        color: online ? Colors.green : Colors.grey,
        shape: BoxShape.circle,
      ),
    );
  }
}
