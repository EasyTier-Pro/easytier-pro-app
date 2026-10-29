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
            : await widget.coreLifecycleService.fetchWorkspaceNetworks(
                workspace,
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

  Future<void> _showConnections() async {
    Widget
    connectionList() => ValueListenableBuilder<Map<String, CoreNetworkConnection>>(
      valueListenable: widget.coreLifecycleService.networkConnections,
      builder: (context, connections, _) => ValueListenableBuilder<CoreRunStatus>(
        valueListenable: widget.coreLifecycleService.status,
        builder: (context, status, _) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (connections.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('暂无网络连接'),
                ),
              for (final connection in connections.values)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connection.network.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: const Color(0xFF0F172A),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${connection.workspace.name}${connection.workspace.id == widget.coreLifecycleService.selectedWorkspaceId.value ? ' · 当前工作区' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFF64748B)),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              connection.message ??
                                  switch (connection.phase) {
                                    CoreNetworkConnectionPhase.joining =>
                                      '正在连接',
                                    CoreNetworkConnectionPhase.leaving =>
                                      '正在断开',
                                    CoreNetworkConnectionPhase.error => '连接失败',
                                    CoreNetworkConnectionPhase.joined =>
                                      connection.ready && status.isRunning
                                          ? connection.ipv4 ?? '已连接'
                                          : '等待实例就绪',
                                  },
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FButton(
                        variant: .outline,
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
    );

    if (MediaQuery.sizeOf(context).width < _mobileShellBreakpoint) {
      await showFSheet<void>(
        context: context,
        side: FLayout.btt,
        mainAxisMaxRatio: 0.7,
        builder: (sheetContext) => Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD1D5DB),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '已接入网络',
                    style: Theme.of(sheetContext).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Flexible(child: connectionList()),
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      await showFDialog<void>(
        context: context,
        builder: (dialogContext, _, animation) => FDialog.adaptive(
          animation: animation,
          title: const Text('已接入网络'),
          body: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: connectionList(),
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
}
