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
        widget.coreLifecycleService.networkTrafficPollInterval,
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
    if (!clearSnapshots ||
        (_networkTraffic.isEmpty && _networkInstanceReady.isEmpty) ||
        !mounted) {
      return;
    }
    _updateState(() {
      _networkTraffic = const <String, _NetworkTrafficSnapshot>{};
      _networkInstanceReady = const <String, bool>{};
      _networkTrafficHistories.clear();
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

    final nextInstanceReady = Map<String, bool>.from(_networkInstanceReady);
    nextInstanceReady.removeWhere((networkId, _) {
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

    final nextHistories = Map<String, List<_TrafficHistoryPoint>>.from(
      _networkTrafficHistories,
    );
    nextHistories.removeWhere((networkId, _) {
      final remove = !activeNetworkIds.contains(networkId);
      changed = changed || remove;
      return remove;
    });

    if (!changed || !mounted) {
      return;
    }
    _updateState(() {
      _networkTraffic = nextTraffic;
      _networkInstanceReady = nextInstanceReady;
      _previousTrafficTotals = nextPrevious;
      _networkTrafficHistories
        ..clear()
        ..addAll(nextHistories);
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
      final nextInstanceReady = Map<String, bool>.from(_networkInstanceReady);

      final nextHistories = Map<String, List<_TrafficHistoryPoint>>.from(
        _networkTrafficHistories,
      );
      final instanceReadinessFallbacks = <ConsoleNetwork>[];

      for (final network in networks) {
        final runtimeName = network.runtimeNetworkName.trim();
        final totals = totalsByRuntimeName[runtimeName];
        if (totals == null) {
          nextTraffic.remove(network.id);
          nextPrevious.remove(runtimeName);
          nextHistories.remove(network.id);
          if (nextInstanceReady[network.id] != true) {
            instanceReadinessFallbacks.add(network);
          }
          continue;
        }

        final previous = nextPrevious[runtimeName];
        final snapshot = _NetworkTrafficSnapshot.fromTotals(
          totals,
          previous: previous,
        );
        nextTraffic[network.id] = snapshot;
        nextPrevious[runtimeName] = totals;
        nextInstanceReady[network.id] = true;

        final history =
            List<_TrafficHistoryPoint>.from(
              nextHistories[network.id] ?? const <_TrafficHistoryPoint>[],
            )..add(
              _TrafficHistoryPoint(
                timestamp: DateTime.now(),
                downloadRate: snapshot.downloadBytesPerSecond ?? 0,
                uploadRate: snapshot.uploadBytesPerSecond ?? 0,
              ),
            );
        while (history.length >
            _WorkspaceHomeViewState._maxNetworkTrafficHistoryPoints) {
          history.removeAt(0);
        }
        nextHistories[network.id] = history;
      }

      nextTraffic.removeWhere(
        (networkId, _) => !activeNetworkIds.contains(networkId),
      );
      nextPrevious.removeWhere(
        (runtimeName, _) => !activeRuntimeNames.contains(runtimeName),
      );
      nextHistories.removeWhere(
        (networkId, _) => !activeNetworkIds.contains(networkId),
      );
      nextInstanceReady.removeWhere(
        (networkId, _) => !activeNetworkIds.contains(networkId),
      );

      var totalDownloadRate = 0.0;
      var totalUploadRate = 0.0;
      for (final network in networks) {
        final snapshot = nextTraffic[network.id];
        if (snapshot != null) {
          totalDownloadRate += snapshot.downloadBytesPerSecond ?? 0;
          totalUploadRate += snapshot.uploadBytesPerSecond ?? 0;
        }
      }
      final nextHistory = List<_TrafficHistoryPoint>.from(_trafficHistory)
        ..add(
          _TrafficHistoryPoint(
            timestamp: DateTime.now(),
            downloadRate: totalDownloadRate,
            uploadRate: totalUploadRate,
          ),
        );
      while (nextHistory.length >
          _WorkspaceHomeViewState._maxTrafficHistoryPoints) {
        nextHistory.removeAt(0);
      }

      _updateState(() {
        _networkTraffic = nextTraffic;
        _networkInstanceReady = nextInstanceReady;
        _previousTrafficTotals = nextPrevious;
        _networkTrafficHistories
          ..clear()
          ..addAll(nextHistories);
        _trafficHistory
          ..clear()
          ..addAll(nextHistory);
      });
      if (instanceReadinessFallbacks.isNotEmpty) {
        unawaited(_refreshNetworkInstanceStates(instanceReadinessFallbacks));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = _normalizeError(error);
      // 当 EasyTier 实例尚未就绪时，CLI 会返回此错误；此时保留已有数据，
      // 仅静默跳过本次轮询，避免 sparkline 等状态被清空。
      if (_isInstanceNotReadyError(message)) {
        _markNetworkInstancesNotReady(networks);
        return;
      }
      _updateState(() {
        _networkTraffic = const <String, _NetworkTrafficSnapshot>{};
        _networkInstanceReady = const <String, bool>{};
        _previousTrafficTotals = const <String, CoreNetworkTrafficTotals>{};
        _networkTrafficHistories.clear();
        _trafficHistory.clear();
      });
    } finally {
      _isTrafficPollInFlight = false;
    }
  }

  Future<void> _refreshNetworkInstanceStates(
    Iterable<ConsoleNetwork> networks,
  ) async {
    if (!mounted || !widget.coreLifecycleService.status.value.isRunning) {
      return;
    }
    final targets = <String, ConsoleNetwork>{};
    for (final network in networks) {
      if (network.runtimeNetworkName.trim().isEmpty ||
          _joinStateFor(network).phase != _JoinPhase.joined) {
        continue;
      }
      targets[network.id] = network;
    }
    if (targets.isEmpty) {
      return;
    }
    await Future.wait(targets.values.map(_refreshNetworkInstanceState));
  }

  Future<void> _refreshNetworkInstanceState(ConsoleNetwork network) async {
    if (!mounted || !widget.coreLifecycleService.status.value.isRunning) {
      return;
    }
    final runtimeName = network.runtimeNetworkName.trim();
    if (runtimeName.isEmpty ||
        _joinStateFor(network).phase != _JoinPhase.joined) {
      return;
    }

    try {
      final ready = await widget.coreLifecycleService.isNetworkInstanceRunning(
        runtimeName,
      );
      if (!mounted) {
        return;
      }
      _updateState(() {
        _networkInstanceReady = {..._networkInstanceReady, network.id: ready};
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = _normalizeError(error);
      if (_isInstanceNotReadyError(message)) {
        _markNetworkInstancesNotReady([network]);
        return;
      }
      AppLogger.instance.warn(
        'home.instance',
        'Network instance readiness check failed',
        context: {'network_id': network.id, 'error': message},
      );
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
        widget.coreLifecycleService.peerStatusPollInterval,
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
        _networkInstanceReady = {..._networkInstanceReady, network.id: true};
        final nextErrors = Map<String, String>.from(_peerStatusErrors)
          ..remove(network.id);
        _peerStatusErrors = nextErrors;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = _normalizeError(error);
      // 实例尚未就绪是正常过渡状态，不应作为错误展示给用户。
      if (_isInstanceNotReadyError(message)) {
        _markNetworkInstancesNotReady([network]);
        return;
      }
      _updateState(() {
        final nextStatuses = Map<String, Map<String, CorePeerStatus>>.from(
          _networkPeerStatuses,
        )..remove(network.id);
        _networkPeerStatuses = nextStatuses;
        _peerStatusErrors = {..._peerStatusErrors, network.id: message};
      });
    } finally {
      _isPeerPollInFlight = false;
    }
  }

  bool _isInstanceNotReadyError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('no running instances found') ||
        lower.contains('no instance matches') ||
        lower.contains('no instance');
  }

  void _markNetworkInstancesNotReady(List<ConsoleNetwork> networks) {
    if (!mounted || networks.isEmpty) {
      return;
    }
    _updateState(() {
      _networkInstanceReady = {
        ..._networkInstanceReady,
        for (final network in networks) network.id: false,
      };
    });
  }
}
