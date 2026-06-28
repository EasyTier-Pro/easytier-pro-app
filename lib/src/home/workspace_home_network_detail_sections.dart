part of 'workspace_home_view.dart';

class _NetworkDetailSectionSelector extends StatelessWidget {
  const _NetworkDetailSectionSelector({
    required this.selected,
    required this.nodeCount,
    required this.subnetCount,
    required this.hasLocalNode,
    required this.onChanged,
  });

  final _NetworkDetailSection selected;
  final int nodeCount;
  final int? subnetCount;
  final bool hasLocalNode;
  final ValueChanged<_NetworkDetailSection> onChanged;

  @override
  Widget build(BuildContext context) {
    return HomeNetworkDetailSectionTabs(
      selectedIndex: selected.index,
      onChanged: (index) => onChanged(_NetworkDetailSection.values[index]),
      tabs: [
        HomeNetworkDetailSectionTab(
          icon: Icons.devices_other_outlined,
          label: '节点 $nodeCount',
          compactLabel: '节点',
        ),
        HomeNetworkDetailSectionTab(
          icon: Icons.alt_route_outlined,
          label: subnetCount == null ? '子网' : '子网 $subnetCount',
          compactLabel: '子网',
        ),
        HomeNetworkDetailSectionTab(
          icon: Icons.computer_outlined,
          label: hasLocalNode ? '本机已加入' : '本机',
          compactLabel: '本机',
        ),
      ],
    );
  }
}

class _NetworkDetailScrollViewport extends StatefulWidget {
  const _NetworkDetailScrollViewport({
    required this.child,
    this.scrollDeltaCoordinator,
  });

  final Widget child;
  final AppScrollDeltaCoordinator? scrollDeltaCoordinator;

  @override
  State<_NetworkDetailScrollViewport> createState() =>
      _NetworkDetailScrollViewportState();
}

class _NetworkDetailScrollViewportState
    extends State<_NetworkDetailScrollViewport> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: false,
      child: AppSmoothScrollView(
        controller: _scrollController,
        primary: false,
        scrollDeltaCoordinator: widget.scrollDeltaCoordinator,
        child: widget.child,
      ),
    );
  }
}

class _NetworkDetailStaticViewport extends StatefulWidget {
  const _NetworkDetailStaticViewport({required this.child, this.onShown});

  final Widget child;
  final VoidCallback? onShown;

  @override
  State<_NetworkDetailStaticViewport> createState() =>
      _NetworkDetailStaticViewportState();
}

class _NetworkDetailStaticViewportState
    extends State<_NetworkDetailStaticViewport> {
  @override
  void initState() {
    super.initState();
    _scheduleReset();
  }

  @override
  void didUpdateWidget(covariant _NetworkDetailStaticViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onShown != widget.onShown ||
        oldWidget.child.key != widget.child.key) {
      _scheduleReset();
    }
  }

  void _scheduleReset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.onShown?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
