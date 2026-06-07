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
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F9FB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
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
                      if (compact)
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
                        )
                      else
                        FButton(
                          variant: .outline,
                          onPress: deleting
                              ? null
                              : () => unawaited(_refreshNetworkNodes(network)),
                          mainAxisSize: MainAxisSize.min,
                          child: const Text('刷新节点'),
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
                '${_workspace?.name ?? '未关联工作区'} · $regionText · $cidrText',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 12),
              _NetworkSummaryBar(
                totalDevices: devices.length,
                onlineDevices: onlineCount,
                traffic: _networkTraffic[network.id],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: NetworkNodeListViewport(
            nodes: devices,
            peerStatusesByIpv4: peerStatuses,
            runtimeError: peerStatusError,
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
