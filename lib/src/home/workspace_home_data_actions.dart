part of 'workspace_home_view.dart';

extension _WorkspaceHomeDataActions on _WorkspaceHomeViewState {
  Future<void> _loadInitialData() async {
    await Future.wait([_loadRegions(), _loadNetworks(), _loadManagedDevices()]);
  }

  Future<void> _loadManagedDevices() async {
    final workspace = _workspace;
    if (workspace == null) {
      _updateState(() {
        _deviceError = '当前账号未关联工作区。';
        _managedDevices = const <ManagedDevice>[];
        _isLoadingDevices = false;
      });
      return;
    }

    final requestId = ++_deviceRequestId;
    _updateState(() {
      _isLoadingDevices = true;
      _deviceError = null;
    });

    try {
      final devices = await widget.authService.fetchManagedDevices(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );
      if (!mounted || requestId != _deviceRequestId) {
        return;
      }
      _updateState(() {
        _managedDevices = _visibleManagedDevices(devices);
        _isLoadingDevices = false;
      });
    } catch (error) {
      if (!mounted || requestId != _deviceRequestId) {
        return;
      }
      _updateState(() {
        _isLoadingDevices = false;
        _deviceError = _normalizeError(error);
      });
    }
  }

  Future<void> _loadRegions() async {
    final requestId = ++_regionRequestId;
    _updateState(() {
      _isLoadingRegions = true;
      _regionError = null;
    });

    try {
      final regions = await widget.authService.fetchRegions(
        accessToken: widget.session.tokenSet.accessToken,
      );
      if (!mounted || requestId != _regionRequestId) {
        return;
      }
      final active = regions.where((region) => region.active).toList();
      _updateState(() {
        _regions = regions;
        _selectedRegionCode ??= active.isEmpty ? null : active.first.code;
        _isLoadingRegions = false;
      });
    } catch (error) {
      if (!mounted || requestId != _regionRequestId) {
        return;
      }
      _updateState(() {
        _isLoadingRegions = false;
        _regionError = _normalizeError(error);
      });
    }
  }

  Future<void> _loadNetworks() async {
    final workspace = _workspace;
    if (workspace == null) {
      _updateState(() {
        _networkError = '当前账号未关联工作区。';
        _networks = const <ConsoleNetwork>[];
        _selectedNetworkId = null;
        _networkPeerStatuses = const <String, Map<String, CorePeerStatus>>{};
        _peerStatusErrors = const <String, String>{};
      });
      _refreshTrafficPolling();
      _refreshPeerPolling();
      return;
    }

    final requestId = ++_networkRequestId;
    _updateState(() {
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

      _updateState(() {
        _networks = networks;
        _selectedNetworkId = selectedId;
        _isLoadingNetworks = false;
      });
      _refreshTrafficPolling();
      _refreshPeerPolling();
      unawaited(_loadNetworkDevices(networks));
    } catch (error) {
      if (!mounted || requestId != _networkRequestId) {
        return;
      }
      _updateState(() {
        _isLoadingNetworks = false;
        _networkError = _normalizeError(error);
      });
    }
  }

  Future<void> _loadNetworkDevices(List<ConsoleNetwork> networks) async {
    final workspace = _workspace;
    if (workspace == null || networks.isEmpty) {
      if (mounted) {
        _updateState(() {
          _networkDevices = const <String, List<NetworkDevice>>{};
        });
      }
      return;
    }

    final results = await Future.wait(
      networks.map((network) async {
        try {
          final devices = await widget.authService.fetchNetworkDevices(
            accessToken: widget.session.tokenSet.accessToken,
            workspaceId: workspace.id,
            networkId: network.id,
          );
          return MapEntry(network.id, devices);
        } catch (_) {
          return MapEntry(network.id, const <NetworkDevice>[]);
        }
      }),
    );
    if (!mounted) {
      return;
    }
    _updateState(() {
      _networkDevices = Map<String, List<NetworkDevice>>.fromEntries(results);
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }

  Future<void> _loadSingleNetworkDevices(String networkId) async {
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }
    final devices = await widget.authService.fetchNetworkDevices(
      accessToken: widget.session.tokenSet.accessToken,
      workspaceId: workspace.id,
      networkId: networkId,
    );
    if (!mounted) {
      return;
    }
    _updateState(() {
      _networkDevices = {..._networkDevices, networkId: devices};
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }

  Future<void> _refreshNetworkNodes(ConsoleNetwork network) async {
    await _loadSingleNetworkDevices(network.id);
    await _pollNetworkPeers(network);
  }

  Future<void> _createNetwork({
    VoidCallback? onSuccess,
    VoidCallback? onStateChanged,
  }) async {
    final workspace = _workspace;
    final regionCode = _selectedRegionCode;
    final name = _newNetworkName.trim();
    final ipv4Cidr = _newNetworkIPv4Cidr.trim();
    if (workspace == null || regionCode == null || regionCode.isEmpty) {
      _updateState(() {
        _createError = '请选择可用区域后再创建网络。';
      });
      onStateChanged?.call();
      return;
    }
    if (name.isEmpty) {
      _updateState(() {
        _createError = '请输入网络名称。';
      });
      onStateChanged?.call();
      return;
    }

    _updateState(() {
      _isCreatingNetwork = true;
      _createError = null;
    });
    onStateChanged?.call();

    try {
      final network = await widget.authService.createNetwork(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
        name: name,
        regions: [regionCode],
        ipv4Cidr: ipv4Cidr.isEmpty ? null : ipv4Cidr,
      );
      if (!mounted) {
        return;
      }
      _updateState(() {
        _networks = [..._networks, network];
        _selectedNetworkId = network.id;
        _setNewNetworkName('我的网络');
        _setNewNetworkIPv4Cidr('');
        _isCreatingNetwork = false;
        _activeView = _DashboardView.overview;
      });
      onStateChanged?.call();
      await _loadSingleNetworkDevices(network.id);
      unawaited(_loadNetworks());
      onSuccess?.call();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _updateState(() {
        _isCreatingNetwork = false;
        _createError = _normalizeError(error);
      });
      onStateChanged?.call();
    }
  }

  Future<void> _showDeleteNetworkDialog(ConsoleNetwork network) async {
    if (_deletingNetworkIds.contains(network.id)) {
      return;
    }

    final accepted = await showFDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext, _, animation) => ExcludeSemantics(
        child: FDialog.adaptive(
          animation: animation,
          title: const Text('删除网络'),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('网络「${network.name}」删除后不可恢复。'),
              const SizedBox(height: 8),
              const Text('网络中的所有节点会自动踢出网络，现有连接会中断。'),
            ],
          ),
          actions: [
            FButton(
              variant: .destructive,
              onPress: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除网络'),
            ),
            FButton(
              variant: .outline,
              onPress: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    if (accepted == true) {
      await _deleteNetwork(network);
    }
  }

  Future<void> _deleteNetwork(ConsoleNetwork network) async {
    final workspace = _workspace;
    if (workspace == null) {
      _showNetworkActionToast('当前账号未关联工作区。', destructive: true);
      return;
    }
    if (_deletingNetworkIds.contains(network.id)) {
      return;
    }

    _updateState(() {
      _deletingNetworkIds = {..._deletingNetworkIds, network.id};
    });

    try {
      await widget.authService.deleteNetwork(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
        networkId: network.id,
      );
      if (!mounted) {
        return;
      }
      _removeDeletedNetworkLocally(network);
      _showNetworkActionToast('网络已删除，相关节点会自动退出。');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _updateState(() {
        _deletingNetworkIds = {..._deletingNetworkIds}..remove(network.id);
      });
      _showNetworkActionToast(
        '删除网络失败：${_normalizeError(error)}',
        destructive: true,
      );
    }
  }

  void _removeDeletedNetworkLocally(ConsoleNetwork network) {
    final networkId = network.id;
    final runtimeNetworkName = network.runtimeNetworkName.trim();
    final selectedRemoved = _selectedNetworkId == networkId;
    final nextNetworks = _networks
        .where((item) => item.id != networkId)
        .toList(growable: false);

    _updateState(() {
      _networks = nextNetworks;
      _deletingNetworkIds = {..._deletingNetworkIds}..remove(networkId);
      if (selectedRemoved) {
        _selectedNetworkId = nextNetworks.isEmpty
            ? null
            : nextNetworks.first.id;
        if (_activeView == _DashboardView.network) {
          _activeView = _DashboardView.overview;
        }
      }

      _networkDevices = Map<String, List<NetworkDevice>>.from(_networkDevices)
        ..remove(networkId);
      _joinStates = Map<String, _JoinNetworkState>.from(_joinStates)
        ..remove(networkId);
      _networkTraffic = Map<String, _NetworkTrafficSnapshot>.from(
        _networkTraffic,
      )..remove(networkId);
      _networkPeerStatuses = Map<String, Map<String, CorePeerStatus>>.from(
        _networkPeerStatuses,
      )..remove(networkId);
      _peerStatusErrors = Map<String, String>.from(_peerStatusErrors)
        ..remove(networkId);
      _trafficPollNetworkIds = {..._trafficPollNetworkIds}..remove(networkId);
      if (_peerPollNetworkId == networkId) {
        _peerPollNetworkId = null;
      }
      if (runtimeNetworkName.isNotEmpty) {
        _previousTrafficTotals = Map<String, CoreNetworkTrafficTotals>.from(
          _previousTrafficTotals,
        )..remove(runtimeNetworkName);
      }
    });
    _refreshTrafficPolling();
    _refreshPeerPolling();
  }

  void _showNetworkActionToast(String message, {bool destructive = false}) {
    showRawFToast(
      context: context,
      variant: destructive ? .destructive : .primary,
      builder: (context, entry) => ExcludeSemantics(
        child: FToast(
          variant: destructive ? .destructive : .primary,
          title: Text(message),
        ),
      ),
    );
  }

  Future<void> _showCreateNetworkDialog() async {
    var dialogOpen = true;
    try {
      await showFDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext, _, animation) => ExcludeSemantics(
          child: FDialog.raw(
            animation: animation,
            constraints: const BoxConstraints(minWidth: 420, maxWidth: 560),
            builder: (context, _) => StatefulBuilder(
              builder: (context, setDialogState) {
                void rebuildDialog() {
                  if (dialogOpen && mounted) {
                    setDialogState(() {});
                  }
                }

                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: AppSmoothScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.language_outlined,
                                size: 22,
                                color: Color(0xFF334155),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '创建网络',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '创建一个新的虚拟网络，用于连接不同区域的设备。',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: const Color(0xFF94A3B8),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            FButton(
                              variant: .ghost,
                              size: .sm,
                              onPress: () => Navigator.of(dialogContext).pop(),
                              child: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _CreateNetworkForm(
                          nameController: _newNetworkNameController,
                          ipv4CidrController: _newNetworkIPv4CidrController,
                          selectedRegionCode: _selectedRegionCode,
                          regions: _activeRegions,
                          loadingRegions: _isLoadingRegions,
                          creating: _isCreatingNetwork,
                          error: _createError ?? _regionError,
                          onNameChanged: (value) {
                            _updateState(() => _setNewNetworkName(value));
                            rebuildDialog();
                          },
                          onIPv4CidrChanged: (value) {
                            _updateState(() => _setNewNetworkIPv4Cidr(value));
                            rebuildDialog();
                          },
                          onRegionChanged: (value) {
                            _updateState(() => _selectedRegionCode = value);
                            rebuildDialog();
                          },
                          onCreate: () async {
                            await _createNetwork(
                              onStateChanged: rebuildDialog,
                              onSuccess: () {
                                if (Navigator.of(dialogContext).canPop()) {
                                  Navigator.of(dialogContext).pop();
                                }
                              },
                            );
                          },
                          onRetryRegions: () async {
                            await _loadRegions();
                            rebuildDialog();
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    } finally {
      dialogOpen = false;
    }
  }
}
