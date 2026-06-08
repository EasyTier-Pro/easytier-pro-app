part of 'workspace_home_view.dart';

extension _WorkspaceHomePages on _WorkspaceHomeViewState {
  Widget _buildContent(BuildContext context) {
    return switch (_activeView) {
      _DashboardView.overview => _buildConnectionWorkspace(context),
      _DashboardView.network => _buildNetworkPage(context),
      _DashboardView.devices => _buildDevicesPage(context),
      _DashboardView.settings => _SettingsPanel(
        user: widget.session.user,
        workspaceName: _workspace?.name ?? '未关联工作区',
        onLogout: widget.onLogout,
        coreLifecycleService: widget.coreLifecycleService,
      ),
    };
  }

  Widget _buildConnectionWorkspace(BuildContext context) {
    final joinedNetworks = _networks
        .where((network) {
          return _joinStateFor(network).phase == _JoinPhase.joined;
        })
        .toList(growable: false);

    var totalDownloadRate = 0.0;
    var totalUploadRate = 0.0;
    var hasTrafficStats = false;
    for (final network in joinedNetworks) {
      final traffic = _networkTraffic[network.id];
      if (traffic != null) {
        hasTrafficStats = true;
        totalDownloadRate += traffic.downloadBytesPerSecond ?? 0;
        totalUploadRate += traffic.uploadBytesPerSecond ?? 0;
      }
    }

    final sortedNetworks = List<ConsoleNetwork>.of(_networks);
    sortedNetworks.sort((a, b) {
      final aJoined = _joinStateFor(a).phase == _JoinPhase.joined;
      final bJoined = _joinStateFor(b).phase == _JoinPhase.joined;
      if (aJoined && !bJoined) return -1;
      if (!aJoined && bJoined) return 1;
      return a.name.compareTo(b.name);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusBadge(
          statusListenable: widget.coreLifecycleService.status,
          joinedCount: joinedNetworks.length,
          downloadRate: totalDownloadRate,
          uploadRate: totalUploadRate,
          hasTrafficStats: hasTrafficStats,
          onElevate: widget.coreLifecycleService.repairWithElevation,
        ),
        const SizedBox(height: 24),
        if (_networkError != null && _networks.isEmpty)
          _StateMessage(
            message: _networkError!,
            action: FButton(onPress: _loadNetworks, child: const Text('重试')),
          )
        else if (_isLoadingNetworks && _networks.isEmpty)
          const SizedBox(height: 260, child: Center(child: FCircularProgress()))
        else if (_networks.isEmpty)
          _CreateNetworkPanel(
            nameController: _newNetworkNameController,
            ipv4CidrController: _newNetworkIPv4CidrController,
            selectedRegionCode: _selectedRegionCode,
            regions: _activeRegions,
            loadingRegions: _isLoadingRegions,
            creating: _isCreatingNetwork,
            error: _createError ?? _regionError,
            onNameChanged: (value) =>
                _updateState(() => _setNewNetworkName(value)),
            onIPv4CidrChanged: (value) =>
                _updateState(() => _setNewNetworkIPv4Cidr(value)),
            onRegionChanged: (value) =>
                _updateState(() => _selectedRegionCode = value),
            onCreate: _createNetwork,
            onRetryRegions: _loadRegions,
          )
        else
          _NetworkSwitchList(
            networks: sortedNetworks,
            networkDevices: _networkDevices,
            trafficByNetworkId: _networkTraffic,
            networkInstanceReady: _networkInstanceReady,
            trafficHistoryFor: _networkTrafficHistories,
            joinStateFor: _joinStateFor,
            onJoin: _joinNetwork,
            onLeave: _leaveNetwork,
            onOpen: _openNetworkDetail,
            onCreate: _showCreateNetworkDialog,
            refreshing: _isLoadingNetworks,
            onRefresh: () => unawaited(_loadNetworks()),
          ),
      ],
    );
  }

  Widget _buildNetworkPage(BuildContext context) {
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
      return _CreateNetworkPanel(
        nameController: _newNetworkNameController,
        ipv4CidrController: _newNetworkIPv4CidrController,
        selectedRegionCode: _selectedRegionCode,
        regions: _activeRegions,
        loadingRegions: _isLoadingRegions,
        creating: _isCreatingNetwork,
        error: _createError ?? _regionError,
        onNameChanged: (value) => _updateState(() => _setNewNetworkName(value)),
        onIPv4CidrChanged: (value) =>
            _updateState(() => _setNewNetworkIPv4Cidr(value)),
        onRegionChanged: (value) =>
            _updateState(() => _selectedRegionCode = value),
        onCreate: _createNetwork,
        onRetryRegions: _loadRegions,
      );
    }

    final network = _selectedNetwork ?? _networks.first;
    final devices = (_networkDevices[network.id] ?? const <NetworkDevice>[])
        .where((device) => device.attached)
        .toList(growable: false);
    final onlineCount = devices.where((device) => device.online).length;
    final state = _joinStateFor(network);
    final joined = state.phase == _JoinPhase.joined;
    final deleting = _deletingNetworkIds.contains(network.id);
    final peerStatuses =
        _networkPeerStatuses[network.id] ?? const <String, CorePeerStatus>{};
    final peerStatusError = _peerStatusErrors[network.id];
    final subnetRoutes = _networkSubnetRoutes[network.id];
    final subnetRoutesLoading = _networkSubnetRoutesLoading[network.id] == true;
    final subnetRouteError = _networkSubnetRouteErrors[network.id];
    final localNode = _localNodeForNetworkId(network.id);
    final localNodeConfig = localNode == null
        ? null
        : _nodeConfigs[localNode.id];
    final localNodeConfigLoading = localNode == null
        ? false
        : _nodeConfigLoading[localNode.id] == true;
    final localNodeConfigError = localNode == null
        ? null
        : _nodeConfigErrors[localNode.id];
    final localIpv4 = state.localIpv4 ?? localNode?.ipv4 ?? '';
    final regionText = network.regions.isEmpty
        ? '-'
        : network.regions.join(', ');
    final cidrText = network.ipv4Cidr.trim().isEmpty
        ? '-'
        : network.ipv4Cidr.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFE5E7EB)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 520;

                  final title = Text(
                    network.name,
                    style: compact
                        ? Theme.of(context).textTheme.titleLarge
                        : Theme.of(context).textTheme.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  );
                  final actions = Wrap(
                    spacing: compact ? 6 : 8,
                    runSpacing: compact ? 6 : 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Tooltip(
                        message: '刷新节点',
                        excludeFromSemantics: true,
                        child: FButton(
                          variant: .ghost,
                          size: .sm,
                          onPress: deleting
                              ? null
                              : () =>
                                    unawaited(_refreshNetworkNodes(network)),
                          mainAxisSize: MainAxisSize.min,
                          child: const Icon(Icons.refresh, size: 16),
                        ),
                      ),
                      if (joined)
                        FButton(
                          variant: .outline,
                          size: compact ? .sm : .md,
                          onPress: deleting
                              ? null
                              : () => unawaited(_leaveNetwork(network)),
                          mainAxisSize: MainAxisSize.min,
                          child: const Text('退出网络'),
                        )
                      else
                        FButton(
                          size: compact ? .sm : .md,
                          onPress: deleting
                              ? null
                              : () => unawaited(_joinNetwork(network)),
                          mainAxisSize: MainAxisSize.min,
                          child: const Text('加入网络'),
                        ),
                      _NetworkMoreMenu(
                        enabled: !deleting,
                        onDelete: () =>
                            unawaited(_showDeleteNetworkDialog(network)),
                      ),
                    ],
                  );

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 12),
                      _ControlSelectionBoundary(child: actions),
                    ],
                  );
                },
              ),
              const SizedBox(height: 4),
              Text(
                '$regionText · $cidrText',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 12),
              _NetworkSummaryBar(
                totalDevices: devices.length,
                onlineDevices: onlineCount,
                traffic: _networkTraffic[network.id],
                localIpv4: localIpv4,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _NetworkDetailSectionSelector(
          selected: _networkDetailSection,
          nodeCount: devices.length,
          subnetCount: subnetRoutes?.routes.length,
          hasLocalNode: localNode != null,
          onChanged: (section) =>
              _updateState(() => _networkDetailSection = section),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: AnimatedSwitcher(
            duration: appMotionMedium,
            reverseDuration: appMotionShort,
            transitionBuilder: appFadeSlideTransition,
            layoutBuilder: appSwitcherStackLayout,
            child: switch (_networkDetailSection) {
              _NetworkDetailSection.nodes => NetworkNodeListViewport(
                key: const ValueKey<String>('network-detail-section-nodes'),
                nodes: devices,
                peerStatusesByIpv4: peerStatuses,
                runtimeError: peerStatusError,
              ),
              _NetworkDetailSection.subnets => _NetworkSubnetRouteViewport(
                key: const ValueKey<String>('network-detail-section-subnets'),
                routes: subnetRoutes,
                loading: subnetRoutesLoading,
                error: subnetRouteError,
                onRetry: () => unawaited(_loadNetworkSubnetRoutes(network.id)),
              ),
              _NetworkDetailSection.local => _LocalNetworkSettingsViewport(
                key: const ValueKey<String>('network-detail-section-local'),
                network: network,
                node: localNode,
                config: localNodeConfig,
                loading: localNodeConfigLoading,
                error: localNodeConfigError,
                joinState: state,
                onRetry: () =>
                    unawaited(_loadLocalNodeConfigForNetworkId(network.id)),
              ),
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDevicesPage(BuildContext context) {
    final devices = List<ManagedDevice>.of(_managedDevices);
    devices.sort((a, b) {
      if (a.online && !b.online) return -1;
      if (!a.online && b.online) return 1;
      if (a.approved && !b.approved) return -1;
      if (!a.approved && b.approved) return 1;
      return a.displayLabel.compareTo(b.displayLabel);
    });

    final summaryText = _deviceSummaryText(devices);
    final localMachineId =
        widget.coreLifecycleService.status.value.machineId?.trim() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '设备',
          subtitle: summaryText,
          trailing: FButton(
            variant: .outline,
            size: .sm,
            onPress: _isLoadingDevices
                ? null
                : () => unawaited(_loadManagedDevices()),
            child: SizedBox.square(
              dimension: 16,
              child: _isLoadingDevices
                  ? const FCircularProgress(size: .sm)
                  : const Icon(Icons.refresh, size: 16),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_deviceError != null) ...[
          SizedBox(
            height: 120,
            child: _StateMessage(
              message: _deviceError!,
              action: FButton(
                variant: .outline,
                size: .sm,
                onPress: _isLoadingDevices
                    ? null
                    : () => unawaited(_loadManagedDevices()),
                child: const Text('重试'),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (devices.isEmpty)
          SizedBox(
            height: 200,
            child: _StateMessage(
              message: _isLoadingDevices ? '正在读取设备列表。' : '暂无设备数据。',
            ),
          )
        else
          FCard.raw(
            child: Column(
              children: [
                for (var i = 0; i < devices.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: Color(0xFFE5E7EB)),
                  _ManagedDeviceRow(
                    key: ValueKey<String>('managed-device-${devices[i].id}'),
                    device: devices[i],
                    localMachineId: localMachineId,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  String _deviceSummaryText(List<ManagedDevice> devices) {
    final onlineCount = devices.where((device) => device.online).length;
    final pendingCount = devices
        .where((device) => device.approvalState.toLowerCase() == 'pending')
        .length;
    final rejectedCount = devices
        .where((device) => device.approvalState.toLowerCase() == 'rejected')
        .length;

    final parts = <String>[
      '${devices.length} 台设备',
      '$onlineCount 在线',
      if (pendingCount > 0) '$pendingCount 待批准',
      if (rejectedCount > 0) '$rejectedCount 已拒绝',
    ];
    return parts.join(' · ');
  }
}

class _NetworkDetailSectionSelector extends StatelessWidget {
  const _NetworkDetailSectionSelector({
    required this.selected,
    required this.nodeCount,
    required this.subnetCount,
    required this.hasLocalNode,
    required this.onChanged,
  });

  final _NetworkDetailSection selected;
  final int nodeCount;
  final int? subnetCount;
  final bool hasLocalNode;
  final ValueChanged<_NetworkDetailSection> onChanged;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 520;
          return Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Wrap(
              spacing: 0,
              runSpacing: 0,
              children: [
                _NetworkDetailSectionButton(
                  selected: selected == _NetworkDetailSection.nodes,
                  icon: Icons.devices_other_outlined,
                  label: compact ? '节点' : '节点 $nodeCount',
                  onPressed: () => onChanged(_NetworkDetailSection.nodes),
                ),
                _NetworkDetailSectionButton(
                  selected: selected == _NetworkDetailSection.subnets,
                  icon: Icons.alt_route_outlined,
                  label: subnetCount == null || compact
                      ? '子网'
                      : '子网 $subnetCount',
                  onPressed: () => onChanged(_NetworkDetailSection.subnets),
                ),
                _NetworkDetailSectionButton(
                  selected: selected == _NetworkDetailSection.local,
                  icon: Icons.computer_outlined,
                  label: hasLocalNode && !compact ? '本机已加入' : '本机',
                  onPressed: () => onChanged(_NetworkDetailSection.local),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NetworkDetailSectionButton extends StatelessWidget {
  const _NetworkDetailSectionButton({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = FButton(
      variant: .ghost,
      size: .sm,
      onPress: onPressed,
      mainAxisSize: MainAxisSize.min,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: selected
                ? const Color(0xFF0F172A)
                : const Color(0xFF64748B),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected
                  ? const Color(0xFF0F172A)
                  : const Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );

    if (!selected) return button;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withAlpha(8),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: button,
    );
  }
}

class _NetworkDetailScrollViewport extends StatefulWidget {
  const _NetworkDetailScrollViewport({required this.child});

  final Widget child;

  @override
  State<_NetworkDetailScrollViewport> createState() =>
      _NetworkDetailScrollViewportState();
}

class _NetworkDetailScrollViewportState
    extends State<_NetworkDetailScrollViewport> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: false,
      child: AppSmoothScrollView(
        controller: _scrollController,
        primary: false,
        child: widget.child,
      ),
    );
  }
}

class _NetworkSubnetRouteViewport extends StatelessWidget {
  const _NetworkSubnetRouteViewport({
    super.key,
    required this.routes,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final NetworkSubnetRouteList? routes;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading && routes == null) {
      return const Center(child: FCircularProgress());
    }
    if (error != null && routes == null) {
      return _StateMessage(
        message: error!,
        action: FButton(
          variant: .outline,
          size: .sm,
          onPress: onRetry,
          child: const Text('重试'),
        ),
      );
    }

    final routeList = routes;
    if (routeList == null) {
      return const _StateMessage(message: '正在读取子网路由...');
    }

    return _NetworkDetailScrollViewport(
      child: _NetworkSubnetRoutePanel(
        routes: routeList,
        loading: loading,
        error: error,
        onRetry: onRetry,
      ),
    );
  }
}

class _NetworkSubnetRoutePanel extends StatelessWidget {
  const _NetworkSubnetRoutePanel({
    required this.routes,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final NetworkSubnetRouteList routes;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) ...[
          const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox.square(
              dimension: 16,
              child: FCircularProgress(size: .sm),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (error != null) ...[
          _NetworkDetailNotice(message: error!),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FButton(
              variant: .outline,
              size: .sm,
              onPress: onRetry,
              child: const Text('重试'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (routes.routes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Text(
                '还没有配置子网路由',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF94A3B8),
                ),
              ),
            ),
          )
        else
          for (final route in routes.routes)
            _NetworkSubnetRouteCard(
              key: ValueKey<String>('network-subnet-route-${route.id}'),
              route: route,
            ),
      ],
    );
  }
}

class _NetworkSubnetRouteCard extends StatelessWidget {
  const _NetworkSubnetRouteCard({super.key, required this.route});

  final NetworkSubnetRoute route;

  @override
  Widget build(BuildContext context) {
    final routerOnline = route.nodes
        .where((node) => node.status.toLowerCase() == 'online')
        .length;
    final manualOnline = route.manualRouteNodes
        .where((node) => node.status.toLowerCase() == 'online')
        .length;
    final mapped = route.mappedCidr?.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.route_outlined,
                    size: 18,
                    color: Color(0xFF334155),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableTextHitBoundary(
                      child: Text(
                        route.cidr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: const Color(0xFF0F172A),
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                mapped == null || mapped.isEmpty ? '无地址映射' : '映射为 $mapped',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  _NetworkDetailMetricPill(
                    icon: Icons.router_outlined,
                    label: '负责节点',
                    value: '${route.nodes.length} 个 · $routerOnline 在线',
                  ),
                  _NetworkDetailMetricPill(
                    icon: Icons.low_priority_outlined,
                    label: '手动路由节点',
                    value: route.manualRouteNodes.isEmpty
                        ? '仅自动传播'
                        : '${route.manualRouteNodes.length} 个 · $manualOnline 在线',
                  ),
                ],
              ),
              if (route.nodes.isNotEmpty ||
                  route.manualRouteNodes.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SubnetRouteNodeLine(label: '路由器', nodes: route.nodes),
                if (route.manualRouteNodes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _SubnetRouteNodeLine(
                    label: '手动接收',
                    nodes: route.manualRouteNodes,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SubnetRouteNodeLine extends StatelessWidget {
  const _SubnetRouteNodeLine({required this.label, required this.nodes});

  final String label;
  final List<SubnetRouteNodeSummary> nodes;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label：${nodes.map((node) => node.displayLabel).join(', ')}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
    );
  }
}

class _LocalNetworkSettingsViewport extends StatelessWidget {
  const _LocalNetworkSettingsViewport({
    super.key,
    required this.network,
    required this.node,
    required this.config,
    required this.loading,
    required this.error,
    required this.joinState,
    required this.onRetry,
  });

  final ConsoleNetwork network;
  final NetworkDevice? node;
  final NodeInstanceConfigView? config;
  final bool loading;
  final String? error;
  final _JoinNetworkState joinState;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final localNode = node;
    if (localNode == null) {
      return const _StateMessage(message: '本机尚未加入此网络。');
    }
    if (loading && config == null) {
      return const Center(child: FCircularProgress());
    }
    if (error != null && config == null) {
      return _StateMessage(
        message: error!,
        action: FButton(
          variant: .outline,
          size: .sm,
          onPress: onRetry,
          child: const Text('重试'),
        ),
      );
    }
    final view = config;
    if (view == null) {
      return const _StateMessage(message: '正在读取本机设置...');
    }

    return _NetworkDetailScrollViewport(
      child: _LocalNetworkSettingsPanel(
        network: network,
        node: localNode,
        config: view,
        loading: loading,
        error: error,
        joinState: joinState,
        onRetry: onRetry,
      ),
    );
  }
}

class _LocalNetworkSettingsPanel extends StatelessWidget {
  const _LocalNetworkSettingsPanel({
    required this.network,
    required this.node,
    required this.config,
    required this.loading,
    required this.error,
    required this.joinState,
    required this.onRetry,
  });

  final ConsoleNetwork network;
  final NetworkDevice node;
  final NodeInstanceConfigView config;
  final bool loading;
  final String? error;
  final _JoinNetworkState joinState;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final effective = config.effective;
    final ipv4 = effective.ipv4 ?? joinState.localIpv4 ?? node.ipv4 ?? '-';
    final hostname = effective.hostname ?? node.hostname.trim();
    final displayHostname = hostname.isEmpty ? node.displayLabel : hostname;
    final listenerProtocols = effective.listenerProtocols.isEmpty
        ? '未监听'
        : effective.listenerProtocols
              .map((protocol) => protocol.toUpperCase())
              .join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) ...[
          const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox.square(
              dimension: 16,
              child: FCircularProgress(size: .sm),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (error != null) ...[
          _NetworkDetailNotice(message: error!),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FButton(
              variant: .outline,
              size: .sm,
              onPress: onRetry,
              child: const Text('重试'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _NetworkDetailCard(
          title: '身份',
          children: [
            _NetworkInfoGrid(
              items: [
                _NetworkInfoItem(label: '虚拟 IP', value: ipv4),
                _NetworkInfoItem(label: '主机名', value: displayHostname),
                _NetworkInfoItem(label: '网络 CIDR', value: network.ipv4Cidr),
                _NetworkInfoItem(
                  label: '配置来源',
                  value: _configScopeLabel(config.configScope),
                ),
              ],
            ),
          ],
        ),
        _NetworkDetailCard(
          title: '配置状态',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _NetworkDetailMetricPill(
                  icon: Icons.task_alt_outlined,
                  label: '应用',
                  value: _applyStatusLabel(config.applyStatus),
                ),
                _NetworkDetailMetricPill(
                  icon: Icons.sync_problem_outlined,
                  label: '漂移',
                  value: _driftStatusLabel(config.driftStatus),
                ),
              ],
            ),
            if (config.lastApplyError?.isNotEmpty == true) ...[
              const SizedBox(height: 10),
              _NetworkDetailNotice(message: config.lastApplyError!),
            ],
          ],
        ),
        _NetworkDetailCard(
          title: '连接策略',
          children: [
            _NetworkInfoGrid(
              items: [
                _NetworkInfoItem(
                  label: 'P2P 策略',
                  value: _p2pModeLabel(effective.p2pMode),
                ),
                _NetworkInfoItem(label: '监听协议', value: listenerProtocols),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ConfigTogglePill(
                  label: 'Magic DNS',
                  enabled: effective.magicDnsEnabled,
                ),
                _ConfigTogglePill(label: 'No-TUN', enabled: effective.noTun),
                _ConfigTogglePill(
                  label: '系统转发',
                  enabled: effective.proxyForwardBySystem,
                ),
                _ConfigTogglePill(
                  label: '用户态协议栈',
                  enabled: effective.userspaceStack,
                ),
              ],
            ),
          ],
        ),
        _NetworkDetailCard(
          title: '子网路由',
          children: [
            _AssignedRoutePills(
              label: '本机负责',
              routes: config.assignedSubnetRoutes,
              emptyText: '未负责子网路由',
            ),
            const SizedBox(height: 12),
            _AssignedRoutePills(
              label: config.manualRoutesEnabled ? '手动接收' : '手动接收未启用',
              routes: config.manualSubnetRoutes,
              emptyText: '未接收手动子网路由',
            ),
          ],
        ),
      ],
    );
  }
}

class _NetworkDetailNotice extends StatelessWidget {
  const _NetworkDetailNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_outlined,
              size: 18,
              color: Color(0xFFD97706),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF92400E),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkDetailCard extends StatelessWidget {
  const _NetworkDetailCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: const Color(0xFF0F172A),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkInfoGrid extends StatelessWidget {
  const _NetworkInfoGrid({required this.items});

  final List<_NetworkInfoItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 520;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final item in items)
              SizedBox(
                width: twoColumns
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth,
                child: item,
              ),
          ],
        );
      },
    );
  }
}

class _NetworkInfoItem extends StatelessWidget {
  const _NetworkInfoItem({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final text = value?.trim().isNotEmpty == true ? value!.trim() : '-';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF94A3B8),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        SelectableTextHitBoundary(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _NetworkDetailMetricPill extends StatelessWidget {
  const _NetworkDetailMetricPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: const Color(0xFF64748B)),
              const SizedBox(width: 6),
              Text(
                '$label：',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF94A3B8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF0F172A),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfigTogglePill extends StatelessWidget {
  const _ConfigTogglePill({required this.label, required this.enabled});

  final String label;
  final bool? enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled == true;
    final color = active ? const Color(0xFF16A34A) : const Color(0xFF64748B);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? const Color(0xFFF0FDF4) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? Icons.check : Icons.remove, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              '$label ${active ? '启用' : '关闭'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignedRoutePills extends StatelessWidget {
  const _AssignedRoutePills({
    required this.label,
    required this.routes,
    required this.emptyText,
  });

  final String label;
  final List<AssignedSubnetRoute> routes;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF94A3B8),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        if (routes.isEmpty)
          Text(
            emptyText,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final route in routes)
                _RouteTextPill(
                  key: ValueKey<String>('assigned-subnet-route-${route.id}'),
                  text: _assignedRouteText(route),
                ),
            ],
          ),
      ],
    );
  }
}

class _RouteTextPill extends StatelessWidget {
  const _RouteTextPill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: SelectableTextHitBoundary(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

String _assignedRouteText(AssignedSubnetRoute route) {
  final mapped = route.mappedCidr?.trim();
  if (mapped == null || mapped.isEmpty) {
    return route.cidr;
  }
  return '${route.cidr} -> $mapped';
}

String _configScopeLabel(String value) {
  return switch (value.toLowerCase()) {
    'customized' => '本机覆盖',
    'inherited' => '继承网络默认',
    '' => '-',
    _ => value,
  };
}

String _applyStatusLabel(String value) {
  return switch (value.toLowerCase()) {
    'applied' || 'config_applied' => '已应用',
    'pending' || 'queued' => '等待应用',
    'applying' || 'running' => '应用中',
    'error' || 'failed' => '应用失败',
    '' => '-',
    _ => value,
  };
}

String _driftStatusLabel(String value) {
  return switch (value.toLowerCase()) {
    'in_sync' || 'synced' || 'clean' => '一致',
    'drifted' || 'out_of_sync' => '有漂移',
    'unknown' => '未知',
    '' => '-',
    _ => value,
  };
}

String _p2pModeLabel(String? value) {
  return switch (value?.toLowerCase()) {
    'automatic' => '自动',
    'relay_preferred' => '优先中继',
    'p2p_only' => '仅 P2P',
    null || '' => '-',
    _ => value!,
  };
}

class _ManagedDeviceRow extends StatelessWidget {
  const _ManagedDeviceRow({
    super.key,
    required this.device,
    required this.localMachineId,
  });

  final ManagedDevice device;
  final String localMachineId;

  @override
  Widget build(BuildContext context) {
    final status = _managedDeviceStatus(device);
    final meta = _managedDeviceMeta(device);
    final isLocal =
        localMachineId.isNotEmpty && localMachineId == device.machineId.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          DeviceOsIcon(
            os: device.os,
            osVersion: device.osVersion,
            osDistribution: device.osDistribution,
            online: device.online,
            isLocal: isLocal,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  device.displayLabel,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF0F172A),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF94A3B8),
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ManagedDeviceStatusChip(status: status),
        ],
      ),
    );
  }
}

class _ManagedDeviceStatus {
  const _ManagedDeviceStatus({required this.label, required this.color});

  final String label;
  final Color color;
}

class _ManagedDeviceStatusChip extends StatelessWidget {
  const _ManagedDeviceStatusChip({required this.status});

  final _ManagedDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: status.color.withAlpha(12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: status.color.withAlpha(35)),
      ),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: status.color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

_ManagedDeviceStatus _managedDeviceStatus(ManagedDevice device) {
  if (!device.approved) {
    return _ManagedDeviceStatus(
      label: _approvalLabel(device),
      color: const Color(0xFFD97706),
    );
  }

  if (device.online) {
    return const _ManagedDeviceStatus(label: '在线', color: Color(0xFF16A34A));
  }

  return const _ManagedDeviceStatus(label: '离线', color: Color(0xFF64748B));
}

String _managedDeviceMeta(ManagedDevice device) {
  final osParts = <String>[
    device.osDistribution.trim(),
    device.osVersion.trim(),
  ].where((part) => part.isNotEmpty).toList(growable: false);
  final os = osParts.isNotEmpty ? osParts.join(' ') : device.os.trim();
  final hostname = device.hostname.trim();
  final showHostname =
      hostname.isNotEmpty && hostname != device.displayLabel.trim();
  final parts = <String>[
    if (showHostname) hostname,
    if (os.isNotEmpty) os,
    _shortId(device.machineId),
  ];
  return parts.join(' · ');
}

class _NetworkMoreMenu extends StatelessWidget {
  const _NetworkMoreMenu({required this.enabled, required this.onDelete});

  final bool enabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return _ControlSelectionBoundary(
      child: ExcludeSemantics(
        child: FPopoverMenu(
          menuAnchor: Alignment.topRight,
          childAnchor: Alignment.bottomRight,
          divider: FItemDivider.none,
          menuBuilder: (context, controller, menu) => [
            FItemGroup(
              divider: FItemDivider.none,
              children: [
                FItem(
                  key: const ValueKey<String>('network-more-delete'),
                  prefix: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Color(0xFFDC2626),
                  ),
                  title: Text(
                    '删除网络...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFDC2626),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPress: () {
                    unawaited(controller.hide());
                    onDelete();
                  },
                ),
              ],
            ),
          ],
          builder: (context, controller, child) => Tooltip(
            message: '更多操作',
            excludeFromSemantics: true,
            child: FButton(
              key: const ValueKey<String>('network-more-menu-button'),
              variant: .ghost,
              size: .sm,
              onPress: enabled ? () => unawaited(controller.toggle()) : null,
              mainAxisSize: MainAxisSize.min,
              child: const Icon(Icons.more_vert, size: 18),
            ),
          ),
        ),
      ),
    );
  }
}
