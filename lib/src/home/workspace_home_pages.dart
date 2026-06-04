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
    for (final network in joinedNetworks) {
      final traffic = _networkTraffic[network.id];
      if (traffic != null) {
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
          onElevate: widget.coreLifecycleService.repairWithElevation,
        ),
        const SizedBox(height: 24),
        if (_networkError != null)
          _StateMessage(
            message: _networkError!,
            action: FButton(onPress: _loadNetworks, child: const Text('重试')),
          )
        else if (_isLoadingNetworks)
          const SizedBox(height: 260, child: Center(child: FCircularProgress()))
        else if (_networks.isEmpty)
          _CreateNetworkPanel(
            name: _newNetworkName,
            ipv4Cidr: _newNetworkIPv4Cidr,
            selectedRegionCode: _selectedRegionCode,
            regions: _activeRegions,
            loadingRegions: _isLoadingRegions,
            creating: _isCreatingNetwork,
            error: _createError ?? _regionError,
            onNameChanged: (value) =>
                _updateState(() => _newNetworkName = value),
            onIPv4CidrChanged: (value) =>
                _updateState(() => _newNetworkIPv4Cidr = value),
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
            joinStateFor: _joinStateFor,
            onJoin: _joinNetwork,
            onLeave: _leaveNetwork,
            onOpen: _openNetworkDetail,
            onCreate: _showCreateNetworkDialog,
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
        name: _newNetworkName,
        ipv4Cidr: _newNetworkIPv4Cidr,
        selectedRegionCode: _selectedRegionCode,
        regions: _activeRegions,
        loadingRegions: _isLoadingRegions,
        creating: _isCreatingNetwork,
        error: _createError ?? _regionError,
        onNameChanged: (value) => _updateState(() => _newNetworkName = value),
        onIPv4CidrChanged: (value) =>
            _updateState(() => _newNetworkIPv4Cidr = value),
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
                  final title = Text(
                    network.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  );
                  final actions = Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FButton(
                        variant: .outline,
                        onPress: deleting
                            ? null
                            : () => unawaited(_refreshNetworkNodes(network)),
                        child: const Text('刷新节点'),
                      ),
                      if (joined)
                        FButton(
                          variant: .outline,
                          onPress: deleting
                              ? null
                              : () => unawaited(_leaveNetwork(network)),
                          child: const Text('退出网络'),
                        )
                      else
                        FButton(
                          onPress: deleting
                              ? null
                              : () => unawaited(_joinNetwork(network)),
                          child: const Text('加入网络'),
                        ),
                      IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: deleting
                            ? null
                            : () => unawaited(_showNetworkMoreMenu(network)),
                      ),
                    ],
                  );

                  if (constraints.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [title, const SizedBox(height: 12), actions],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 12),
                      actions,
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
      return a.hostname.compareTo(b.hostname);
    });

    final onlineCount = devices.where((device) => device.online).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          title: '设备',
          subtitle: '工作区中的所有设备与在线状态。',
          trailing: FButton(
            variant: .outline,
            size: .sm,
            onPress: _isLoadingDevices
                ? null
                : () => unawaited(_loadManagedDevices()),
            child: Text(_isLoadingDevices ? '刷新中' : '刷新设备'),
          ),
        ),
        const SizedBox(height: 20),
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
          const SizedBox(height: 20),
        ],
        Row(
          children: [
            Text('设备列表', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            FBadge(
              variant: .secondary,
              child: Text('$onlineCount / ${devices.length} 台在线'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          SizedBox(
            height: 200,
            child: _StateMessage(
              message: _isLoadingDevices ? '正在读取设备列表。' : '暂无设备数据。',
            ),
          )
        else
          FCard.raw(
            child: _ConstrainedFItemGroup(
              divider: .full,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final device in devices)
                  FItem(
                    prefix: _StatusDot(online: device.online),
                    title: Text(device.hostname),
                    subtitle: Text(
                      [
                        '审批: ${_approvalLabel(device)}',
                        '连接: ${_connectivityLabel(device)}',
                        '机器: ${_shortId(device.machineId)}',
                        'ID: ${device.id}',
                      ].join('  |  '),
                    ),
                    suffix: FBadge(
                      variant: device.online ? .secondary : .outline,
                      child: Text(_connectivityLabel(device)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
