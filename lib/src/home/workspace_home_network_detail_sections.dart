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
                  style: const FTabsStyleDelta.delta(height: 28, spacing: 0),
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
          size: 12,
          color: selected ? const Color(0xFF0F172A) : const Color(0xFF64748B),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _NetworkDetailScrollViewport extends StatefulWidget {
  const _NetworkDetailScrollViewport({required this.child});

  final Widget child;

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
        child: widget.child,
      ),
    );
  }
}
