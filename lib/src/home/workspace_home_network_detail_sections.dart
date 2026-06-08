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
    return SelectionContainer.disabled(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 520;
          return Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: IntrinsicWidth(
                child: FTabs(
                  key: const ValueKey<String>('network-detail-section-tabs'),
                  control: FTabControl.lifted(
                    index: selected.index,
                    onChange: (index) =>
                        onChanged(_NetworkDetailSection.values[index]),
                  ),
                  style: const FTabsStyleDelta.delta(height: 32, spacing: 0),
                  contentPhysics: const NeverScrollableScrollPhysics(),
                  scrollable: true,
                  children: [
                    FTabEntry(
                      label: _NetworkDetailSectionTabLabel(
                        selected: selected == _NetworkDetailSection.nodes,
                        icon: Icons.devices_other_outlined,
                        label: compact ? '节点' : '节点 $nodeCount',
                      ),
                      child: const SizedBox.shrink(),
                    ),
                    FTabEntry(
                      label: _NetworkDetailSectionTabLabel(
                        selected: selected == _NetworkDetailSection.subnets,
                        icon: Icons.alt_route_outlined,
                        label: subnetCount == null || compact
                            ? '子网'
                            : '子网 $subnetCount',
                      ),
                      child: const SizedBox.shrink(),
                    ),
                    FTabEntry(
                      label: _NetworkDetailSectionTabLabel(
                        selected: selected == _NetworkDetailSection.local,
                        icon: Icons.computer_outlined,
                        label: hasLocalNode && !compact ? '本机已加入' : '本机',
                      ),
                      child: const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NetworkDetailSectionTabLabel extends StatelessWidget {
  const _NetworkDetailSectionTabLabel({
    required this.selected,
    required this.icon,
    required this.label,
  });

  final bool selected;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: selected ? const Color(0xFF0F172A) : const Color(0xFF64748B),
        ),
        const SizedBox(width: 5),
        Text(label),
      ],
    );
  }
}

class _NetworkDetailScrollViewport extends StatefulWidget {
  const _NetworkDetailScrollViewport({
    required this.child,
    this.onScrollOffsetChanged,
  });

  final Widget child;
  final ValueChanged<double>? onScrollOffsetChanged;

  @override
  State<_NetworkDetailScrollViewport> createState() =>
      _NetworkDetailScrollViewportState();
}

class _NetworkDetailScrollViewportState
    extends State<_NetworkDetailScrollViewport> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScrollOffsetChanged);
    _scheduleScrollOffsetSync();
  }

  @override
  void didUpdateWidget(covariant _NetworkDetailScrollViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onScrollOffsetChanged != widget.onScrollOffsetChanged) {
      _scheduleScrollOffsetSync();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScrollOffsetChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScrollOffsetChanged() {
    widget.onScrollOffsetChanged?.call(_scrollController.offset);
  }

  void _scheduleScrollOffsetSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final offset = _scrollController.hasClients
          ? _scrollController.offset
          : 0.0;
      widget.onScrollOffsetChanged?.call(offset);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: false,
      child: AppSmoothScrollView(
        controller: _scrollController,
        primary: false,
        child: widget.child,
      ),
    );
  }
}

class _NetworkDetailStaticViewport extends StatefulWidget {
  const _NetworkDetailStaticViewport({
    required this.child,
    this.onScrollOffsetChanged,
  });

  final Widget child;
  final ValueChanged<double>? onScrollOffsetChanged;

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
    if (oldWidget.onScrollOffsetChanged != widget.onScrollOffsetChanged ||
        oldWidget.child.key != widget.child.key) {
      _scheduleReset();
    }
  }

  void _scheduleReset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.onScrollOffsetChanged?.call(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
