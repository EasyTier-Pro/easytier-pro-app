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
                key: ValueKey<String>('network-switch-${networks[i].id}'),
                network: networks[i],
                devices:
                    networkDevices[networks[i].id] ?? const <NetworkDevice>[],
                state: joinStateFor(networks[i]),
                traffic: trafficByNetworkId[networks[i].id],
                instanceReady: networkInstanceReady[networks[i].id] == true,
                trafficHistory: trafficHistoryFor[networks[i].id],
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

    final accentColor = locallyConnected
        ? const Color(0xFF16A34A)
        : joined
        ? const Color(0xFFF59E0B)
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
                                        if (!instanceReady)
                                          const _StatusChip(
                                            label: '实例启动中',
                                            active: false,
                                          ),
                                        if (instanceReady &&
                                            traffic != null) ...[
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
                            if (locallyConnected &&
                                history != null &&
                                history.isNotEmpty) ...[
                              _NetworkTrafficSparkline(history: history),
                              const SizedBox(width: 8),
                            ],
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                _LoadingSwitch(
                                  value: switchValue,
                                  loading: isLoading,
                                  onChange: (_) => onToggle?.call(),
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
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
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
            opacity: widget.loading ? 0.35 + (0.65 * _animation.value) : 1.0,
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

class _NetworkTrafficSparkline extends StatefulWidget {
  const _NetworkTrafficSparkline({required this.history});

  final List<_TrafficHistoryPoint> history;

  @override
  State<_NetworkTrafficSparkline> createState() =>
      _NetworkTrafficSparklineState();
}

class _NetworkTrafficSparklineState extends State<_NetworkTrafficSparkline>
    with SingleTickerProviderStateMixin {
  OverlayEntry? _detailOverlay;
  OverlayEntry? _fullscreenOverlay;
  Rect? _anchorRect;
  bool _overlayUpdateScheduled = false;
  late final AnimationController _overlayAnimationController;
  late final Animation<double> _overlayAnimation;

  @override
  void initState() {
    super.initState();
    _overlayAnimationController = AnimationController(
      vsync: this,
      duration: appMotionShort,
      reverseDuration: appMotionShort,
    );
    _overlayAnimation = CurvedAnimation(
      parent: _overlayAnimationController,
      curve: appMotionCurve,
      reverseCurve: appMotionReverseCurve,
    );
  }

  @override
  void didUpdateWidget(covariant _NetworkTrafficSparkline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_detailOverlay != null || _fullscreenOverlay != null) {
      _scheduleDetailOverlayUpdate();
    }
  }

  @override
  void dispose() {
    _removeDetailsImmediately();
    _removeFullscreenImmediately();
    _overlayAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final downloadColor = const Color(0xFF16A34A);
    final uploadColor = const Color(0xFF2563EB);
    final chart = _trafficSparklineData(widget.history);

    return MouseRegion(
      onEnter: (_) => _showDetails(),
      onExit: (_) => _hideDetails(),
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showFullscreen,
          child: SizedBox(
            width: 100,
            height: 40,
            child: LineChart(
              _trafficSparklineChartData(
                chart: chart,
                downloadColor: downloadColor,
                uploadColor: uploadColor,
              ),
              duration: Duration.zero,
            ),
          ),
        ),
      ),
    );
  }

  void _showDetails() {
    if (_detailOverlay != null) {
      _overlayAnimationController.forward();
      return;
    }
    _updateAnchorRect();
    _detailOverlay = OverlayEntry(
      builder: (context) => _NetworkTrafficDetailOverlay(
        anchorRect: _anchorRect,
        history: widget.history,
        animation: _overlayAnimation,
      ),
    );
    Overlay.of(context).insert(_detailOverlay!);
    _overlayAnimationController.forward(from: 0);
  }

  void _hideDetails() {
    final overlay = _detailOverlay;
    if (overlay == null) {
      return;
    }

    _overlayAnimationController.reverse().whenComplete(() {
      if (_detailOverlay != overlay) {
        return;
      }

      overlay.remove();
      _detailOverlay = null;
    });
  }

  void _removeDetailsImmediately() {
    _detailOverlay?.remove();
    _detailOverlay = null;
  }

  void _showFullscreen() {
    _removeDetailsImmediately();
    final overlay = _fullscreenOverlay;
    if (overlay != null) {
      overlay.markNeedsBuild();
      return;
    }

    _fullscreenOverlay = OverlayEntry(
      builder: (context) => _NetworkTrafficFullscreenOverlay(
        history: widget.history,
        onClose: _removeFullscreenImmediately,
      ),
    );
    Overlay.of(context).insert(_fullscreenOverlay!);
  }

  void _removeFullscreenImmediately() {
    _fullscreenOverlay?.remove();
    _fullscreenOverlay = null;
  }

  void _scheduleDetailOverlayUpdate() {
    if (_overlayUpdateScheduled) {
      return;
    }

    _overlayUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayUpdateScheduled = false;
      if (!mounted || (_detailOverlay == null && _fullscreenOverlay == null)) {
        return;
      }

      _updateAnchorRect();
      _detailOverlay?.markNeedsBuild();
      _fullscreenOverlay?.markNeedsBuild();
    });
  }

  void _updateAnchorRect() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) {
      return;
    }

    final topLeft = box.localToGlobal(Offset.zero);
    _anchorRect = topLeft & box.size;
  }
}

class _NetworkTrafficFullscreenOverlay extends StatelessWidget {
  const _NetworkTrafficFullscreenOverlay({
    required this.history,
    required this.onClose,
  });

  final List<_TrafficHistoryPoint> history;
  final VoidCallback onClose;

  static const double _screenPadding = 24;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final panelWidth = math.min(screenSize.width - (_screenPadding * 2), 960.0);
    final panelHeight = math.min(
      screenSize.height - (_screenPadding * 2),
      720.0,
    );

    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          key: const ValueKey<String>('traffic-fullscreen-overlay'),
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          child: Container(
            color: const Color(0xFF020617).withAlpha(170),
            padding: const EdgeInsets.all(_screenPadding),
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: SizedBox(
                  width: panelWidth,
                  height: panelHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF020617).withAlpha(60),
                          blurRadius: 34,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '实时流量详情',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: const Color(0xFF0F172A),
                                    ),
                              ),
                              const Spacer(),
                              FButton(
                                key: const ValueKey<String>(
                                  'traffic-fullscreen-close',
                                ),
                                variant: .ghost,
                                size: .sm,
                                onPress: onClose,
                                mainAxisSize: MainAxisSize.min,
                                child: const Icon(Icons.close, size: 18),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Expanded(
                            child: _NetworkTrafficDetailChart(history: history),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NetworkTrafficDetailOverlay extends StatelessWidget {
  const _NetworkTrafficDetailOverlay({
    required this.anchorRect,
    required this.history,
    required this.animation,
  });

  final Rect? anchorRect;
  final List<_TrafficHistoryPoint> history;
  final Animation<double> animation;

  static const Size _panelSize = Size(320, 244);
  static const double _screenPadding = 12;

  @override
  Widget build(BuildContext context) {
    final anchor = anchorRect;
    if (anchor == null || history.isEmpty) {
      return const SizedBox.shrink();
    }

    final screenSize = MediaQuery.sizeOf(context);
    final preferredTop = anchor.bottom + 10;
    final top = math.min(
      preferredTop,
      math.max(
        _screenPadding,
        screenSize.height - _panelSize.height - _screenPadding,
      ),
    );
    final left = (anchor.center.dx - (_panelSize.width / 2)).clamp(
      _screenPadding,
      math.max(
        _screenPadding,
        screenSize.width - _panelSize.width - _screenPadding,
      ),
    );

    return Positioned(
      left: left.toDouble(),
      top: top.toDouble(),
      width: _panelSize.width,
      height: _panelSize.height,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: FadeTransition(
            opacity: animation,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, -6 + (6 * animation.value)),
                  child: child,
                );
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F172A).withAlpha(22),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: _NetworkTrafficDetailChart(history: history),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NetworkTrafficDetailChart extends StatelessWidget {
  const _NetworkTrafficDetailChart({required this.history});

  final List<_TrafficHistoryPoint> history;

  @override
  Widget build(BuildContext context) {
    final downloadColor = const Color(0xFF16A34A);
    final uploadColor = const Color(0xFF2563EB);
    final chart = _trafficSparklineData(history);
    final latest = chart.visibleHistory.last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '实时流量',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: const Color(0xFF0F172A),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _TrafficLegendValue(
              icon: Icons.arrow_downward,
              color: downloadColor,
              text: _formatTrafficRate(latest.downloadRate),
            ),
            _TrafficLegendValue(
              icon: Icons.arrow_upward,
              color: uploadColor,
              text: _formatTrafficRate(latest.uploadRate),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LineChart(
            _trafficSparklineChartData(
              chart: chart,
              downloadColor: downloadColor,
              uploadColor: uploadColor,
              detailed: true,
            ),
            duration: Duration.zero,
          ),
        ),
      ],
    );
  }
}

class _TrafficLegendValue extends StatelessWidget {
  const _TrafficLegendValue({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _TrafficSparklineData {
  const _TrafficSparklineData({
    required this.visibleHistory,
    required this.downloadSpots,
    required this.uploadSpots,
    required this.minX,
    required this.maxX,
    required this.yMax,
    required this.hasTraffic,
  });

  final List<_TrafficHistoryPoint> visibleHistory;
  final List<FlSpot> downloadSpots;
  final List<FlSpot> uploadSpots;
  final double minX;
  final double maxX;
  final double yMax;
  final bool hasTraffic;
}

_TrafficSparklineData _trafficSparklineData(
  List<_TrafficHistoryPoint> history,
) {
  const maxHistoryPoints =
      _WorkspaceHomeViewState._maxNetworkTrafficHistoryPoints;
  final visibleHistory = history.length > maxHistoryPoints
      ? history.sublist(history.length - maxHistoryPoints)
      : history;

  final maxRate = visibleHistory
      .map((h) => math.max(h.downloadRate, h.uploadRate))
      .fold(0.0, math.max);
  final hasTraffic = maxRate > 0;
  final yMax = _trafficSparklineYMax(maxRate);

  const minX = 0.0;
  final maxX = (maxHistoryPoints - 1).toDouble();
  final firstX = maxX - (visibleHistory.length - 1);

  final downloadSpots = <FlSpot>[
    for (var i = 0; i < visibleHistory.length; i++)
      FlSpot(firstX + i, visibleHistory[i].downloadRate),
  ];
  final uploadSpots = <FlSpot>[
    for (var i = 0; i < visibleHistory.length; i++)
      FlSpot(firstX + i, visibleHistory[i].uploadRate),
  ];

  return _TrafficSparklineData(
    visibleHistory: visibleHistory,
    downloadSpots: downloadSpots,
    uploadSpots: uploadSpots,
    minX: minX,
    maxX: maxX,
    yMax: yMax,
    hasTraffic: hasTraffic,
  );
}

LineChartData _trafficSparklineChartData({
  required _TrafficSparklineData chart,
  required Color downloadColor,
  required Color uploadColor,
  bool detailed = false,
}) {
  return LineChartData(
    minX: chart.minX,
    maxX: chart.maxX,
    minY: 0,
    maxY: chart.yMax,
    gridData: FlGridData(
      show: detailed,
      drawVerticalLine: false,
      horizontalInterval: chart.yMax / 2,
      getDrawingHorizontalLine: (_) =>
          FlLine(color: const Color(0xFFE2E8F0).withAlpha(180), strokeWidth: 1),
    ),
    titlesData: detailed
        ? FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitleAlignment: SideTitleAlignment.inside,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                interval: chart.yMax,
                minIncluded: false,
                getTitlesWidget: (value, meta) => _trafficYAxisTitle(
                  value: value,
                  meta: meta,
                  maxY: chart.yMax,
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitleAlignment: SideTitleAlignment.outside,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: chart.maxX,
                getTitlesWidget: (value, meta) => _trafficXAxisTitle(
                  value: value,
                  meta: meta,
                  minX: chart.minX,
                  maxX: chart.maxX,
                  visibleHistory: chart.visibleHistory,
                ),
              ),
            ),
          )
        : const FlTitlesData(show: false),
    borderData: detailed
        ? FlBorderData(
            show: true,
            border: const Border(
              left: BorderSide(color: Color(0xFFCBD5E1)),
              bottom: BorderSide(color: Color(0xFFCBD5E1)),
            ),
          )
        : FlBorderData(show: false),
    lineTouchData: const LineTouchData(enabled: false),
    lineBarsData: [
      _buildTrafficLine(chart.downloadSpots, downloadColor, detailed: detailed),
      _buildTrafficLine(chart.uploadSpots, uploadColor, detailed: detailed),
      if (!chart.hasTraffic)
        LineChartBarData(
          spots: [FlSpot(chart.minX, 0), FlSpot(chart.maxX, 0)],
          barWidth: 1,
          dotData: FlDotData(show: false),
          color: const Color(0xFFCBD5E1),
          belowBarData: BarAreaData(show: false),
        ),
    ],
  );
}

Widget _trafficYAxisTitle({
  required double value,
  required TitleMeta meta,
  required double maxY,
}) {
  final isMax = (value - maxY).abs() < 0.001;
  if (!isMax) {
    return const SizedBox.shrink();
  }

  return SideTitleWidget(
    meta: meta,
    space: 6,
    child: Transform.translate(
      offset: const Offset(8, 0),
      child: Text(
        _formatTrafficRate(maxY),
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
        style: const TextStyle(
          color: Color(0xFF64748B),
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

Widget _trafficXAxisTitle({
  required double value,
  required TitleMeta meta,
  required double minX,
  required double maxX,
  required List<_TrafficHistoryPoint> visibleHistory,
}) {
  if (visibleHistory.isEmpty) {
    return const SizedBox.shrink();
  }

  final isMin = (value - minX).abs() < 0.001;
  final isMax = (value - maxX).abs() < 0.001;
  if (!isMax && (!isMin || visibleHistory.length == 1)) {
    return const SizedBox.shrink();
  }

  return SideTitleWidget(
    meta: meta,
    space: 6,
    fitInside: SideTitleFitInsideData.fromTitleMeta(meta, distanceFromEdge: 4),
    child: Text(
      _formatTrafficTime(
        isMin ? visibleHistory.first.timestamp : visibleHistory.last.timestamp,
      ),
      maxLines: 1,
      overflow: TextOverflow.visible,
      softWrap: false,
      style: const TextStyle(
        color: Color(0xFF64748B),
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

LineChartBarData _buildTrafficLine(
  List<FlSpot> spots,
  Color color, {
  bool detailed = false,
}) {
  return LineChartBarData(
    spots: spots,
    isCurved: spots.length >= 4,
    curveSmoothness: 0.3,
    barWidth: detailed ? 2.2 : 1.8,
    isStrokeCapRound: true,
    dotData: FlDotData(show: false),
    color: color,
    belowBarData: BarAreaData(
      show: spots.length > 1,
      color: color.withAlpha(detailed ? 28 : 35),
    ),
  );
}

double _trafficSparklineYMax(double maxRate) {
  const fixedScales = <double>[
    1024,
    10 * 1024,
    100 * 1024,
    1024 * 1024,
    10 * 1024 * 1024,
    100 * 1024 * 1024,
    1024 * 1024 * 1024,
    10 * 1024 * 1024 * 1024,
    100 * 1024 * 1024 * 1024,
    1024 * 1024 * 1024 * 1024,
  ];

  for (final scale in fixedScales) {
    if (maxRate <= scale) {
      return scale;
    }
  }

  return fixedScales.last;
}

String _formatTrafficTime(DateTime time) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(time.hour)}:${twoDigits(time.minute)}:${twoDigits(time.second)}';
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
