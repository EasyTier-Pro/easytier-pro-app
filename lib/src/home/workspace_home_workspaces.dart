part of 'workspace_home_view.dart';

extension _WorkspaceHomeWorkspaces on _WorkspaceHomeViewState {
  Future<void> _initializeWorkspaces() async {
    try {
      await widget.coreLifecycleService.initializeWorkspaceSession(
        widget.session,
      );
      if (!mounted) return;
      _displayedWorkspaceId =
          widget.coreLifecycleService.selectedWorkspaceId.value;
      _workspaceReady = true;
      await _loadInitialData();
      await _restoreWorkspaceConnections();
    } catch (error) {
      if (!mounted) return;
      AppLogger.instance.warn(
        'home.workspace',
        'Workspace context restore failed',
        context: {'error': error.toString()},
      );
    }
  }

  Future<void> _restoreWorkspaceConnections() async {
    if (_isRestoringConnections ||
        !widget.coreLifecycleService.status.value.isRunning) {
      return;
    }
    _isRestoringConnections = true;
    try {
      // Recover background connections too, without changing the selected view.
      for (final workspace in _workspaces) {
        if (!mounted) return;
        final networks = workspace.id == _workspace?.id
            ? _networks
            : await widget.authService.fetchNetworks(
                accessToken: widget.session.tokenSet.accessToken,
                workspaceId: workspace.id,
              );
        if (!mounted) return;
        await widget.coreLifecycleService.refreshWorkspaceConnections(
          workspace,
          networks,
        );
      }
    } catch (error) {
      if (!mounted) return;
      AppLogger.instance.warn(
        'home.workspace',
        'Workspace connections restore failed',
        context: {'error': error.toString()},
      );
    } finally {
      _isRestoringConnections = false;
    }
  }

  void _onWorkspaceChanged() {
    if (!mounted || !_workspaceReady) return;
    final next = widget.coreLifecycleService.selectedWorkspaceId.value;
    if (next == _displayedWorkspaceId) return;
    final previous = _displayedWorkspaceId;
    if (previous != null) {
      _workspaceSelectedNetworks[previous] = _selectedNetworkId;
    }
    _workspaceGeneration++;
    _networkRequestId++;
    _deviceRequestId++;
    _updateState(() {
      _displayedWorkspaceId = next;
      _networks = [];
      _managedDevices = [];
      _networkDevices = {};
      _networkError = null;
      _deviceError = null;
      _createError = null;
      _isCreatingNetwork = false;
      _selectedNetworkId = _workspaceSelectedNetworks[next];
      _activeView = _DashboardView.overview;
      _networkSubnetRoutesLoading = {};
      _nodeConfigLoading = {};
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
    unawaited(Future.wait([_loadNetworks(), _loadManagedDevices()]));
  }

  void _onConnectionsChanged() {
    if (!mounted) return;
    _updateState(() {
      final current = widget.coreLifecycleService.networkConnections.value.keys
          .toSet();
      for (final id in _knownConnections.difference(current)) {
        _networkDevices = {
          ..._networkDevices,
          id: (_networkDevices[id] ?? [])
              .where(
                (node) =>
                    node.deviceId != widget.coreLifecycleService.localDeviceId,
              )
              .toList(),
        };
        _joinStates = {..._joinStates}..remove(id);
        _networkInstanceReady = {..._networkInstanceReady}..remove(id);
      }
      _knownConnections = current;

      for (final entry
          in widget.coreLifecycleService.networkConnections.value.entries) {
        _networkInstanceReady = {
          ..._networkInstanceReady,
          entry.key: entry.value.ready,
        };
        _joinStates = {..._joinStates}..remove(entry.key);
      }
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }

  Future<void> _refreshWorkspaceMemberships() async {
    try {
      final user = await widget.authService.fetchCurrentUser(
        widget.session.tokenSet.accessToken,
      );
      if (!mounted) return;
      _updateState(() => _availableWorkspaces = user.workspaces);
      final selected = widget.coreLifecycleService.selectedWorkspaceId.value;
      await widget.coreLifecycleService.initializeWorkspaceSession(
        AuthSession(user: user, tokenSet: widget.session.tokenSet),
      );
      if (user.workspaces.isNotEmpty &&
          !user.workspaces.any((w) => w.id == selected)) {
        await widget.coreLifecycleService.selectWorkspace(
          user.workspaces.first.id,
        );
      }
    } catch (error) {
      if (mounted) {
        _showNetworkActionToast(
          '刷新工作区失败：${_normalizeError(error)}',
          destructive: true,
        );
      }
    }
  }

  Widget _workspaceSelector() => FPopoverMenu(
    menuAnchor: Alignment.topLeft,
    childAnchor: Alignment.bottomLeft,
    menuBuilder: (context, controller, _) => [
      FItemGroup(
        children: [
          for (final workspace in _workspaces)
            FItem(
              key: ValueKey('workspace-option-${workspace.id}'),
              title: Text(workspace.name),
              suffix: workspace.id == _workspace?.id
                  ? const Icon(Icons.check, size: 16)
                  : null,
              onPress: () {
                unawaited(controller.hide());
                unawaited(
                  widget.coreLifecycleService.selectWorkspace(workspace.id),
                );
              },
            ),
          FItem(
            title: const Text('刷新工作区'),
            prefix: const Icon(Icons.refresh, size: 16),
            onPress: () {
              unawaited(controller.hide());
              unawaited(_refreshWorkspaceMemberships());
            },
          ),
        ],
      ),
    ],
    builder: (context, controller, _) => FButton(
      key: const ValueKey('workspace-switcher'),
      variant: .ghost,
      size: .sm,
      mainAxisSize: MainAxisSize.min,
      onPress: () => unawaited(controller.toggle()),
      suffix: const Icon(Icons.keyboard_arrow_down, size: 16),
      child: Flexible(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            _workspace?.name ?? '未关联工作区',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ),
  );

  Widget _connectionSummary() {
    final connections = widget
        .coreLifecycleService
        .networkConnections
        .value
        .values
        .toList();
    final running = connections
        .where(
          (c) => c.ready && widget.coreLifecycleService.status.value.isRunning,
        )
        .length;
    if (connections.isEmpty) return const SizedBox.shrink();
    return FButton(
      key: const ValueKey('workspace-connections'),
      variant: .ghost,
      size: .sm,
      onPress: _showConnections,
      prefix: MediaQuery.sizeOf(context).width < _mobileShellBreakpoint
          ? const Icon(Icons.hub_outlined, size: 16)
          : null,
      child: Text(
        MediaQuery.sizeOf(context).width < _mobileShellBreakpoint
            ? '$running'
            : '$running 已连接',
      ),
    );
  }

  Future<void> _showConnections() async {
    await showFDialog<void>(
      context: context,
      builder: (dialogContext, _, animation) => FDialog.adaptive(
        animation: animation,
        title: const Text('所有工作区的连接'),
        body: ValueListenableBuilder<Map<String, CoreNetworkConnection>>(
          valueListenable: widget.coreLifecycleService.networkConnections,
          builder: (context, connections, _) => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (connections.isEmpty) const Text('暂无网络连接'),
                  for (final connection in connections.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${connection.workspace.name} · ${connection.network.name}',
                                ),
                                Text(
                                  connection.message ??
                                      switch (connection.phase) {
                                        CoreNetworkConnectionPhase.joining =>
                                          '正在连接',
                                        CoreNetworkConnectionPhase.leaving =>
                                          '正在断开',
                                        CoreNetworkConnectionPhase.error =>
                                          '连接失败',
                                        CoreNetworkConnectionPhase.joined =>
                                          connection.ready &&
                                                  widget
                                                      .coreLifecycleService
                                                      .status
                                                      .value
                                                      .isRunning
                                              ? connection.ipv4 ?? '已连接'
                                              : '等待实例就绪',
                                      },
                                ),
                              ],
                            ),
                          ),
                          FButton(
                            variant: .ghost,
                            size: .sm,
                            onPress:
                                connection.phase ==
                                        CoreNetworkConnectionPhase.joining ||
                                    connection.phase ==
                                        CoreNetworkConnectionPhase.leaving
                                ? null
                                : () async {
                                    try {
                                      await widget.coreLifecycleService
                                          .disconnectNetwork(
                                            connection.workspace,
                                            connection.network,
                                          );
                                    } catch (error) {
                                      if (mounted) {
                                        _showNetworkActionToast(
                                          _normalizeError(error),
                                          destructive: true,
                                        );
                                      }
                                    }
                                  },
                            child: const Text('断开'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          FButton(
            variant: .outline,
            onPress: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
