import 'dart:async';

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

    return Row(
      children: [
        SizedBox(
          width: 280,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.hub_outlined),
                      const SizedBox(width: 8),
                      Text(
                        'EasyTier Pro',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      workspaceName,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                Expanded(child: _buildNetworkList(context)),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: widget.onLogout,
                      child: const Text('退出登录'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
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
                    OutlinedButton(
                      onPressed: widget.onShowHelloWorld,
                      child: const Text('弹出 Hello World'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(child: _buildDevicePanel(context, selectedNetwork)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkList(BuildContext context) {
    if (_isLoadingNetworks) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_networkError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_networkError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadNetworks, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_networks.isEmpty) {
      return const Center(child: Text('当前工作区暂无网络'));
    }

    return ListView.builder(
      itemCount: _networks.length,
      itemBuilder: (context, index) {
        final network = _networks[index];
        final selected = network.id == _selectedNetworkId;
        return ListTile(
          leading: const Icon(Icons.device_hub_outlined),
          title: Text(network.name),
          selected: selected,
          onTap: () => _selectNetwork(network.id),
        );
      },
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
      return const Center(child: CircularProgressIndicator());
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
              FilledButton(
                onPressed: () => _loadDevices(selectedNetwork.id),
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

    return Card(
      child: ListView.separated(
        itemCount: _devices.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final device = _devices[index];
          final statusText = device.online ? '在线' : '离线';
          final statusColor = device.online ? Colors.green : Colors.grey;

          return ListTile(
            leading: CircleAvatar(radius: 6, backgroundColor: statusColor),
            title: Text(device.name),
            subtitle: Text(
              device.ipv4 == null || device.ipv4!.isEmpty
                  ? 'ID: ${device.id}'
                  : 'IP: ${device.ipv4}  |  ID: ${device.id}',
            ),
            trailing: Text(statusText),
          );
        },
      ),
    );
  }
}