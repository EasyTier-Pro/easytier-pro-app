part of 'workspace_home_view.dart';

class _NetworkSwitchList extends StatelessWidget {
  const _NetworkSwitchList({
    required this.networks,
    required this.networkDevices,
    required this.trafficByNetworkId,
    required this.networkInstanceReady,
    required this.trafficHistoryFor,
    required this.joinStateFor,
    required this.onJoin,
    required this.onLeave,
    required this.onOpen,
    required this.onCreate,
    required this.refreshing,
    this.onRefresh,
  });

  final List<ConsoleNetwork> networks;
  final Map<String, List<NetworkDevice>> networkDevices;
  final Map<String, _NetworkTrafficSnapshot> trafficByNetworkId;
  final Map<String, bool> networkInstanceReady;
  final Map<String, List<_TrafficHistoryPoint>> trafficHistoryFor;
  final _JoinNetworkState Function(ConsoleNetwork) joinStateFor;
  final Future<void> Function(ConsoleNetwork) onJoin;
  final Future<void> Function(ConsoleNetwork) onLeave;
  final void Function(ConsoleNetwork) onOpen;
  final VoidCallback onCreate;
  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return HomeNetworkListSection(
      trailing: _NetworkActionGroup(
        refreshing: refreshing,
        onRefresh: onRefresh,
        onCreate: onCreate,
      ),
      children: [
        for (final network in networks)
          _NetworkSwitchTile(
            key: ValueKey<String>('network-switch-${network.id}'),
            network: network,
            devices: networkDevices[network.id] ?? const <NetworkDevice>[],
            state: joinStateFor(network),
            traffic: trafficByNetworkId[network.id],
            instanceReady: networkInstanceReady[network.id] == true,
            trafficHistory: trafficHistoryFor[network.id],
            onJoin: () => unawaited(onJoin(network)),
            onLeave: () => unawaited(onLeave(network)),
            onOpen: () => onOpen(network),
          ),
      ],
    );
  }
}

class _NetworkActionGroup extends StatelessWidget {
  const _NetworkActionGroup({
    required this.refreshing,
    this.onRefresh,
    required this.onCreate,
  });

  final bool refreshing;
  final VoidCallback? onRefresh;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return _ControlSelectionBoundary(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FButton(
            key: const ValueKey<String>('network-create-button'),
            variant: .ghost,
            size: .sm,
            onPress: onCreate,
            mainAxisSize: MainAxisSize.min,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 15),
                SizedBox(width: 3),
                Text('新建网络'),
              ],
            ),
          ),
          if (onRefresh != null || refreshing) ...[
            const SizedBox(width: 4),
            _NetworkRefreshButton(refreshing: refreshing, onRefresh: onRefresh),
          ],
        ],
      ),
    );
  }
}

class _NetworkRefreshButton extends StatelessWidget {
  const _NetworkRefreshButton({required this.refreshing, this.onRefresh});

  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final enabled = !refreshing && onRefresh != null;

    return Tooltip(
      message: refreshing ? '正在刷新网络' : '刷新网络',
      excludeFromSemantics: true,
      child: FButton(
        key: const ValueKey<String>('network-refresh-button'),
        variant: .ghost,
        size: .sm,
        onPress: enabled ? onRefresh : null,
        mainAxisSize: MainAxisSize.min,
        child: SizedBox.square(
          dimension: 16,
          child: refreshing
              ? const Center(
                  child: SizedBox.square(
                    dimension: 14,
                    child: FCircularProgress(size: .sm),
                  ),
                )
              : const Icon(Icons.refresh, size: 16),
        ),
      ),
    );
  }
}

class _NetworkSwitchTile extends StatelessWidget {
  const _NetworkSwitchTile({
    super.key,
    required this.network,
    required this.devices,
    required this.state,
    required this.traffic,
    required this.instanceReady,
    required this.trafficHistory,
    required this.onJoin,
    required this.onLeave,
    required this.onOpen,
  });

  final ConsoleNetwork network;
  final List<NetworkDevice> devices;
  final _JoinNetworkState state;
  final _NetworkTrafficSnapshot? traffic;
  final bool instanceReady;
  final List<_TrafficHistoryPoint>? trafficHistory;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final attachedDevices = devices.where((d) => d.attached).toList();
    final onlineCount = attachedDevices.where((d) => d.online).length;
    final joined = state.phase == _JoinPhase.joined;
    final locallyConnected = joined && instanceReady;
    final joining = state.phase == _JoinPhase.joining;
    final leaving = state.phase == _JoinPhase.leaving;
    final failed = state.phase == _JoinPhase.error;
    final localIpv4 = state.localIpv4?.trim();
    final cidrText = network.ipv4Cidr.trim();
    final history = trafficHistory;
    final showMiniTraffic = homeNetworkSwitchTileShowsInlineMetrics(context);

    final switchValue = joined || joining;
    final isLoading = joining || leaving;
    final onToggle = isLoading
        ? null
        : () {
            if (joined) {
              onLeave();
            } else {
              onJoin();
            }
          };

    final metaChildren = <Widget>[];
    if (joined && localIpv4 != null && localIpv4.isNotEmpty) {
      metaChildren.add(HomeIpBadge(ip: localIpv4));
      if (!instanceReady) {
        metaChildren.add(const HomeStatusChip(label: '实例启动中', active: false));
      }
      final trafficSnapshot = traffic;
      if (showMiniTraffic && instanceReady && trafficSnapshot != null) {
        metaChildren.addAll([
          HomeMiniTrafficPill(
            icon: Icons.arrow_downward,
            label: _formatTrafficRate(trafficSnapshot.downloadBytesPerSecond),
            color: const Color(0xFF16A34A),
          ),
          HomeMiniTrafficPill(
            icon: Icons.arrow_upward,
            label: _formatTrafficRate(trafficSnapshot.uploadBytesPerSecond),
            color: const Color(0xFF2563EB),
          ),
        ]);
      }
    } else {
      metaChildren.add(
        HomeStatusChip(
          label: '$onlineCount / ${attachedDevices.length} 在线',
          active: onlineCount > 0,
        ),
      );
      if (cidrText.isNotEmpty) {
        metaChildren.add(
          SelectableTextHitBoundary(
            child: Text(
              'CIDR $cidrText',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFFCBD5E1),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      }
    }

    return HomeNetworkSwitchTile(
      title: network.name,
      joined: joined,
      locallyConnected: locallyConnected,
      failed: failed,
      metaChildren: metaChildren,
      failedMessage: state.message,
      trailingVisualization:
          locallyConnected && history != null && history.isNotEmpty
          ? HomeNetworkTrafficSparkline(history: history)
          : null,
      switchValue: switchValue,
      switchLoading: isLoading,
      onSwitchChanged: onToggle == null ? null : (_) => onToggle(),
      onOpen: onOpen,
    );
  }
}
