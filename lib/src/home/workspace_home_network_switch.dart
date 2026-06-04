part of 'workspace_home_view.dart';

class _NetworkSwitchList extends StatelessWidget {
  const _NetworkSwitchList({
    required this.networks,
    required this.networkDevices,
    required this.trafficByNetworkId,
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
  final _JoinNetworkState Function(ConsoleNetwork) joinStateFor;
  final Future<void> Function(ConsoleNetwork) onJoin;
  final Future<void> Function(ConsoleNetwork) onLeave;
  final void Function(ConsoleNetwork) onOpen;
  final VoidCallback onCreate;
  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '网络',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            if (onRefresh != null || refreshing) ...[
              const SizedBox(width: 6),
              _NetworkRefreshButton(
                refreshing: refreshing,
                onRefresh: onRefresh,
              ),
            ],
            const Spacer(),
            FButton(
              variant: .ghost,
              size: .sm,
              onPress: onCreate,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 16),
                  SizedBox(width: 4),
                  Text('新建网络'),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${networks.length} 个',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FCard.raw(
          child: Column(
            children: [
              for (var i = 0; i < networks.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _NetworkSwitchTile(
                  network: networks[i],
                  devices:
                      networkDevices[networks[i].id] ?? const <NetworkDevice>[],
                  state: joinStateFor(networks[i]),
                  traffic: trafficByNetworkId[networks[i].id],
                  onJoin: () => unawaited(onJoin(networks[i])),
                  onLeave: () => unawaited(onLeave(networks[i])),
                  onOpen: () => onOpen(networks[i]),
                ),
              ],
            ],
          ),
        ),
      ],
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
      child: SizedBox.square(
        dimension: 28,
        child: IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            foregroundColor: const Color(0xFF64748B),
            disabledForegroundColor: const Color(0xFF94A3B8),
            hoverColor: const Color(0xFFF1F5F9),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          onPressed: enabled ? onRefresh : null,
          icon: refreshing
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 18),
        ),
      ),
    );
  }
}

class _NetworkSwitchTile extends StatelessWidget {
  const _NetworkSwitchTile({
    required this.network,
    required this.devices,
    required this.state,
    required this.traffic,
    required this.onJoin,
    required this.onLeave,
    required this.onOpen,
  });

  final ConsoleNetwork network;
  final List<NetworkDevice> devices;
  final _JoinNetworkState state;
  final _NetworkTrafficSnapshot? traffic;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final attachedDevices = devices.where((d) => d.attached).toList();
    final onlineCount = attachedDevices.where((d) => d.online).length;
    final joined = state.phase == _JoinPhase.joined;
    final joining = state.phase == _JoinPhase.joining;
    final leaving = state.phase == _JoinPhase.leaving;
    final failed = state.phase == _JoinPhase.error;
    final localIpv4 = state.localIpv4?.trim();
    final cidrText = network.ipv4Cidr.trim();

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onOpen,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    network.name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (joined && localIpv4 != null && localIpv4.isNotEmpty)
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0FDF4),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFBBF7D0)),
                          ),
                          child: Text(
                            localIpv4,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF15803D),
                                ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (traffic != null) ...[
                          Icon(
                            Icons.arrow_downward,
                            size: 11,
                            color: const Color(0xFF16A34A),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _formatTrafficRate(traffic!.downloadBytesPerSecond),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: const Color(0xFF16A34A),
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.arrow_upward,
                            size: 11,
                            color: const Color(0xFF2563EB),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _formatTrafficRate(traffic!.uploadBytesPerSecond),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: const Color(0xFF2563EB),
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ],
                      ],
                    )
                  else
                    Text(
                      [
                        if (cidrText.isNotEmpty) 'CIDR $cidrText',
                        '$onlineCount / ${attachedDevices.length} 台设备在线',
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  if (failed && state.message != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      state.message!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (isLoading)
            const SizedBox(
              width: 20,
              height: 20,
              child: FCircularProgress(size: .sm),
            )
          else
            FSwitch(
              value: switchValue,
              enabled: onToggle != null,
              onChange: (_) => onToggle?.call(),
            ),
        ],
      ),
    );
  }
}
