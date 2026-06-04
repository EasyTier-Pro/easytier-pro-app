part of 'workspace_home_view.dart';

extension _WorkspaceHomePolling on _WorkspaceHomeViewState {
  List<ConsoleNetwork> _trafficPollNetworks() {
    if (!widget.coreLifecycleService.status.value.isRunning) {
      return const <ConsoleNetwork>[];
    }
    return _networks
        .where((network) {
          if (network.runtimeNetworkName.trim().isEmpty) {
            return false;
          }
          return _joinStateFor(network).phase == _JoinPhase.joined;
        })
        .toList(growable: false);
  }

  void _refreshTrafficPolling() {
    if (!mounted) {
      return;
    }

    final networks = _trafficPollNetworks();
    if (networks.isEmpty) {
      _stopTrafficPolling(clearSnapshots: true);
      return;
    }

    final nextNetworkIds = networks.map((network) => network.id).toSet();
    final nextRuntimeNames = networks
        .map((network) => network.runtimeNetworkName.trim())
        .toSet();
    final pollTargetsChanged = !setEquals(
      _trafficPollNetworkIds,
      nextNetworkIds,
    );
    _trafficPollNetworkIds = nextNetworkIds;
    _pruneTrafficState(nextNetworkIds, nextRuntimeNames);

    if (_trafficPollTimer == null) {
      _trafficPollTimer = Timer.periodic(
        _WorkspaceHomeViewState._trafficPollInterval,
        (_) => unawaited(_pollNetworkTraffic()),
      );
      unawaited(_pollNetworkTraffic());
    } else if (pollTargetsChanged) {
      unawaited(_pollNetworkTraffic());
    }
  }

  void _stopTrafficPolling({required bool clearSnapshots}) {
    _trafficPollTimer?.cancel();
    _trafficPollTimer = null;
    _trafficPollNetworkIds = const <String>{};
    _previousTrafficTotals = const <String, CoreNetworkTrafficTotals>{};
    if (!clearSnapshots || _networkTraffic.isEmpty || !mounted) {
      return;
    }
    _updateState(() {
      _networkTraffic = const <String, _NetworkTrafficSnapshot>{};
    });
  }

  void _pruneTrafficState(
    Set<String> activeNetworkIds,
    Set<String> activeRuntimeNames,
  ) {
    var changed = false;
    final nextTraffic = Map<String, _NetworkTrafficSnapshot>.from(
      _networkTraffic,
    );
    nextTraffic.removeWhere((networkId, _) {
      final remove = !activeNetworkIds.contains(networkId);
      changed = changed || remove;
      return remove;
    });

    final nextPrevious = Map<String, CoreNetworkTrafficTotals>.from(
      _previousTrafficTotals,
    );
    nextPrevious.removeWhere((runtimeName, _) {
      final remove = !activeRuntimeNames.contains(runtimeName);
      changed = changed || remove;
      return remove;
    });

    if (!changed || !mounted) {
      return;
    }
    _updateState(() {
      _networkTraffic = nextTraffic;
      _previousTrafficTotals = nextPrevious;
    });
  }

  Future<void> _pollNetworkTraffic() async {
    if (_isTrafficPollInFlight || !mounted) {
      return;
    }
    var networks = _trafficPollNetworks();
    if (networks.isEmpty) {
      _refreshTrafficPolling();
      return;
    }

    _isTrafficPollInFlight = true;
    try {
      final totalsByRuntimeName = await widget.coreLifecycleService
          .readNetworkTrafficTotals();
      if (!mounted) {
        return;
      }

      networks = _trafficPollNetworks();
      if (networks.isEmpty) {
        _refreshTrafficPolling();
        return;
      }

      final activeNetworkIds = networks.map((network) => network.id).toSet();
      final activeRuntimeNames = networks
          .map((network) => network.runtimeNetworkName.trim())
          .toSet();
      final nextTraffic = Map<String, _NetworkTrafficSnapshot>.from(
        _networkTraffic,
      );
      final nextPrevious = Map<String, CoreNetworkTrafficTotals>.from(
        _previousTrafficTotals,
      );

      for (final network in networks) {
        final runtimeName = network.runtimeNetworkName.trim();
        final totals = totalsByRuntimeName[runtimeName];
        if (totals == null) {
          nextTraffic.remove(network.id);
          nextPrevious.remove(runtimeName);
          continue;
        }

        final previous = nextPrevious[runtimeName];
        nextTraffic[network.id] = _NetworkTrafficSnapshot.fromTotals(
          totals,
          previous: previous,
        );
        nextPrevious[runtimeName] = totals;
      }

      nextTraffic.removeWhere(
        (networkId, _) => !activeNetworkIds.contains(networkId),
      );
      nextPrevious.removeWhere(
        (runtimeName, _) => !activeRuntimeNames.contains(runtimeName),
      );

      _updateState(() {
        _networkTraffic = nextTraffic;
        _previousTrafficTotals = nextPrevious;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      _updateState(() {
        _networkTraffic = const <String, _NetworkTrafficSnapshot>{};
        _previousTrafficTotals = const <String, CoreNetworkTrafficTotals>{};
      });
    } finally {
      _isTrafficPollInFlight = false;
    }
  }

  ConsoleNetwork? _peerPollNetwork() {
    if (!widget.coreLifecycleService.status.value.isRunning ||
        _activeView != _DashboardView.network) {
      return null;
    }

    final network =
        _selectedNetwork ?? (_networks.isEmpty ? null : _networks.first);
    if (network == null || network.runtimeNetworkName.trim().isEmpty) {
      return null;
    }
    if (_joinStateFor(network).phase != _JoinPhase.joined) {
      return null;
    }
    return network;
  }

  void _refreshPeerPolling() {
    if (!mounted) {
      return;
    }

    final network = _peerPollNetwork();
    if (network == null) {
      _stopPeerPolling(
        clearSnapshots: !widget.coreLifecycleService.status.value.isRunning,
      );
      return;
    }

    final targetChanged = _peerPollNetworkId != network.id;
    _peerPollNetworkId = network.id;
    if (_peerPollTimer == null) {
      _peerPollTimer = Timer.periodic(
        _WorkspaceHomeViewState._peerPollInterval,
        (_) => unawaited(_pollSelectedNetworkPeers()),
      );
      unawaited(_pollSelectedNetworkPeers());
    } else if (targetChanged) {
      unawaited(_pollSelectedNetworkPeers());
    }
  }

  void _stopPeerPolling({required bool clearSnapshots}) {
    _peerPollTimer?.cancel();
    _peerPollTimer = null;
    _peerPollNetworkId = null;
    if (!clearSnapshots || !mounted) {
      return;
    }
    _updateState(() {
      _networkPeerStatuses = const <String, Map<String, CorePeerStatus>>{};
      _peerStatusErrors = const <String, String>{};
    });
  }

  Future<void> _pollSelectedNetworkPeers() async {
    final network = _peerPollNetwork();
    if (network == null) {
      _refreshPeerPolling();
      return;
    }
    await _pollNetworkPeers(network);
  }

  Future<void> _pollNetworkPeers(ConsoleNetwork network) async {
    if (_isPeerPollInFlight || !mounted) {
      return;
    }
    if (!widget.coreLifecycleService.status.value.isRunning ||
        _joinStateFor(network).phase != _JoinPhase.joined) {
      return;
    }
    final runtimeNetworkName = network.runtimeNetworkName.trim();
    if (runtimeNetworkName.isEmpty) {
      return;
    }

    _isPeerPollInFlight = true;
    try {
      final statuses = await widget.coreLifecycleService
          .readNetworkPeerStatuses(runtimeNetworkName);
      if (!mounted) {
        return;
      }
      _updateState(() {
        _networkPeerStatuses = {..._networkPeerStatuses, network.id: statuses};
        final nextErrors = Map<String, String>.from(_peerStatusErrors)
          ..remove(network.id);
        _peerStatusErrors = nextErrors;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _updateState(() {
        final nextStatuses = Map<String, Map<String, CorePeerStatus>>.from(
          _networkPeerStatuses,
        )..remove(network.id);
        _networkPeerStatuses = nextStatuses;
        _peerStatusErrors = {
          ..._peerStatusErrors,
          network.id: _normalizeError(error),
        };
      });
    } finally {
      _isPeerPollInFlight = false;
    }
  }
}
