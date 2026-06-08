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
        _NetworkDetailHeader(
          network: network,
          regionText: regionText,
          cidrText: cidrText,
          totalDevices: devices.length,
          onlineDevices: onlineCount,
          traffic: _networkTraffic[network.id],
          localIpv4: localIpv4,
          joined: joined,
          deleting: deleting,
          collapseProgress: _networkDetailHeaderCollapseProgress,
          onRefresh: () => unawaited(_refreshNetworkNodes(network)),
          onJoin: () => unawaited(_joinNetwork(network)),
          onLeave: () => unawaited(_leaveNetwork(network)),
          onDelete: () => unawaited(_showDeleteNetworkDialog(network)),
        ),
        const SizedBox(height: 12),
        _NetworkDetailSectionSelector(
          selected: _networkDetailSection,
          nodeCount: devices.length,
          subnetCount: subnetRoutes?.routes.length,
          hasLocalNode: localNode != null,
          onChanged: (section) => _updateState(() {
            _networkDetailSection = section;
            _resetNetworkDetailScrollOffset();
          }),
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
                onScrollOffsetChanged: _handleNetworkDetailScrollOffsetChanged,
              ),
              _NetworkDetailSection.subnets => _NetworkSubnetRouteViewport(
                key: const ValueKey<String>('network-detail-section-subnets'),
                routes: subnetRoutes,
                loading: subnetRoutesLoading,
                error: subnetRouteError,
                onRetry: () => unawaited(_loadNetworkSubnetRoutes(network.id)),
                onScrollOffsetChanged: _handleNetworkDetailScrollOffsetChanged,
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
                onScrollOffsetChanged: _handleNetworkDetailScrollOffsetChanged,
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

class _NetworkDetailHeader extends StatelessWidget {
  const _NetworkDetailHeader({
    required this.network,
    required this.regionText,
    required this.cidrText,
    required this.totalDevices,
    required this.onlineDevices,
    required this.traffic,
    required this.localIpv4,
    required this.joined,
    required this.deleting,
    required this.collapseProgress,
    required this.onRefresh,
    required this.onJoin,
    required this.onLeave,
    required this.onDelete,
  });

  final ConsoleNetwork network;
  final String regionText;
  final String cidrText;
  final int totalDevices;
  final int onlineDevices;
  final _NetworkTrafficSnapshot? traffic;
  final String localIpv4;
  final bool joined;
  final bool deleting;
  final double collapseProgress;
  final VoidCallback onRefresh;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final progress = collapseProgress.clamp(0.0, 1.0).toDouble();

    return Container(
      key: const ValueKey<String>('network-detail-header'),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 520;
              final textTheme = Theme.of(context).textTheme;
              final expandedTitleStyle = compact
                  ? textTheme.titleLarge
                  : textTheme.headlineSmall;
              final collapsedTitleStyle = compact
                  ? textTheme.titleMedium
                  : textTheme.titleLarge;

              final title = Text(
                network.name,
                style: TextStyle.lerp(
                  expandedTitleStyle,
                  collapsedTitleStyle,
                  progress,
                ),
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
                      onPress: deleting ? null : onRefresh,
                      mainAxisSize: MainAxisSize.min,
                      child: const Icon(Icons.refresh, size: 16),
                    ),
                  ),
                  if (!joined)
                    FButton(
                      size: compact ? .sm : .md,
                      onPress: deleting ? null : onJoin,
                      mainAxisSize: MainAxisSize.min,
                      child: const Text('加入网络'),
                    ),
                  _NetworkMoreMenu(
                    enabled: !deleting,
                    joined: joined,
                    onLeave: onLeave,
                    onDelete: onDelete,
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
          _NetworkDetailCollapsibleGap(height: 4, progress: progress),
          _NetworkDetailCollapsible(
            progress: progress,
            child: Text(
              '$regionText · $cidrText',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
            ),
          ),
          _NetworkDetailCollapsibleGap(height: 12, progress: progress),
          _NetworkDetailCollapsible(
            progress: progress,
            child: _NetworkSummaryBar(
              totalDevices: totalDevices,
              onlineDevices: onlineDevices,
              traffic: traffic,
              localIpv4: localIpv4,
            ),
          ),
        ],
      ),
    );
  }
}

class _NetworkDetailCollapsible extends StatelessWidget {
  const _NetworkDetailCollapsible({
    required this.progress,
    required this.child,
  });

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visible = (1 - progress).clamp(0.0, 1.0).toDouble();

    return ClipRect(
      child: Align(
        alignment: Alignment.topLeft,
        heightFactor: visible,
        child: Opacity(opacity: visible, child: child),
      ),
    );
  }
}

class _NetworkDetailCollapsibleGap extends StatelessWidget {
  const _NetworkDetailCollapsibleGap({
    required this.height,
    required this.progress,
  });

  final double height;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final visible = (1 - progress).clamp(0.0, 1.0).toDouble();
    return SizedBox(height: height * visible);
  }
}
