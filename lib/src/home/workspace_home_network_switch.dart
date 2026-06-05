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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withAlpha(8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.hub_outlined,
                    size: 18,
                    color: Color(0xFF334155),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '网络',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                    fontSize: 18,
                  ),
                ),
              ],
            ),
            const Spacer(),
            _NetworkActionGroup(
              refreshing: refreshing,
              onRefresh: onRefresh,
              onCreate: onCreate,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Column(
          children: [
            for (var i = 0; i < networks.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
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
    return Row(
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

    final accentColor = joined
        ? const Color(0xFF16A34A)
        : failed
        ? const Color(0xFFDC2626)
        : const Color(0xFFCBD5E1);

    final cardBg = joined
        ? Colors.white
        : failed
        ? const Color(0xFFFEF2F2)
        : const Color(0xFFFAFBFC);
    var tapStartedInsideText = false;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (details) {
          tapStartedInsideText = tapStartedInsideSelectableText(
            context,
            details.globalPosition,
          );
        },
        onTap: () {
          if (tapStartedInsideText) {
            return;
          }
          onOpen();
        },
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: joined
                        ? const Color(0xFFE2E8F0)
                        : const Color(0xFFE2E8F0).withAlpha(180),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F172A).withAlpha(4),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: accentColor,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(14),
                          bottomLeft: Radius.circular(14),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.language_outlined,
                                        size: 16,
                                        color: joined
                                            ? const Color(0xFF334155)
                                            : const Color(0xFF94A3B8),
                                      ),
                                      const SizedBox(width: 8),
                                      SelectableTextHitBoundary(
                                        child: Text(
                                          network.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                                color: const Color(0xFF0F172A),
                                                fontSize: 14,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (joined &&
                                      localIpv4 != null &&
                                      localIpv4.isNotEmpty)
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        _IpBadge(ip: localIpv4),
                                        if (traffic != null) ...[
                                          _MiniTrafficPill(
                                            icon: Icons.arrow_downward,
                                            label: _formatTrafficRate(
                                              traffic!.downloadBytesPerSecond,
                                            ),
                                            color: const Color(0xFF16A34A),
                                          ),
                                          _MiniTrafficPill(
                                            icon: Icons.arrow_upward,
                                            label: _formatTrafficRate(
                                              traffic!.uploadBytesPerSecond,
                                            ),
                                            color: const Color(0xFF2563EB),
                                          ),
                                        ],
                                      ],
                                    )
                                  else
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        _StatusChip(
                                          label:
                                              '$onlineCount / ${attachedDevices.length} 在线',
                                          active: onlineCount > 0,
                                        ),
                                        if (cidrText.isNotEmpty)
                                          SelectableTextHitBoundary(
                                            child: Text(
                                              'CIDR $cidrText',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: const Color(
                                                      0xFFCBD5E1,
                                                    ),
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  if (failed && state.message != null) ...[
                                    const SizedBox(height: 6),
                                    SelectableTextHitBoundary(
                                      child: Text(
                                        state.message!,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: const Color(0xFFDC2626),
                                              fontWeight: FontWeight.w500,
                                            ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                _LoadingSwitch(
                                  value: switchValue,
                                  loading: isLoading,
                                  onChange: (_) => onToggle?.call(),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  isLoading
                                      ? '处理中'
                                      : joined
                                      ? '已连接'
                                      : '未连接',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: isLoading
                                            ? const Color(0xFF64748B)
                                            : joined
                                            ? const Color(0xFF16A34A)
                                            : const Color(0xFF94A3B8),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 11,
                                      ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingSwitch extends StatefulWidget {
  const _LoadingSwitch({
    required this.value,
    required this.loading,
    this.onChange,
  });

  final bool value;
  final bool loading;
  final ValueChanged<bool>? onChange;

  @override
  State<_LoadingSwitch> createState() => _LoadingSwitchState();
}

class _LoadingSwitchState extends State<_LoadingSwitch>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    if (widget.loading) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _LoadingSwitch old) {
    super.didUpdateWidget(old);
    if (widget.loading && !old.loading) {
      _controller.repeat(reverse: true);
    } else if (!widget.loading && old.loading) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 51,
      height: 31,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Opacity(
            opacity: widget.loading
                ? 0.35 + (0.65 * _animation.value)
                : 1.0,
            child: child,
          );
        },
        child: FSwitch(
          value: widget.value,
          enabled: !widget.loading && widget.onChange != null,
          onChange: widget.onChange,
        ),
      ),
    );
  }
}

class _IpBadge extends StatelessWidget {
  const _IpBadge({required this.ip});

  final String ip;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: SelectableTextHitBoundary(
        child: Text(
          ip,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            color: const Color(0xFF15803D),
            fontSize: 11,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

class _MiniTrafficPill extends StatelessWidget {
  const _MiniTrafficPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFF0FDF4) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: active ? const Color(0xFF15803D) : const Color(0xFF64748B),
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}
