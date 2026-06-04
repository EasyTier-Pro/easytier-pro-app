part of 'workspace_home_view.dart';

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF737373),
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 16), trailing!],
      ],
    );
  }
}

class _ConstrainedFItemGroup extends StatelessWidget {
  const _ConstrainedFItemGroup({
    required this.children,
    this.divider = FItemDivider.none,
    this.physics = appScrollPhysics,
  });

  final List<FItemMixin> children;
  final FItemDivider divider;
  final ScrollPhysics physics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth ||
            constraints.maxWidth >= _itemListMinWidth) {
          return FItemGroup(
            divider: divider,
            physics: physics,
            children: children,
          );
        }

        return SingleChildScrollView(
          primary: false,
          scrollDirection: Axis.horizontal,
          physics: appScrollPhysics,
          child: SizedBox(
            width: _itemListMinWidth,
            child: FItemGroup(
              divider: divider,
              physics: physics,
              children: children,
            ),
          ),
        );
      },
    );
  }
}

class _NetworkSummaryBar extends StatelessWidget {
  const _NetworkSummaryBar({
    required this.totalDevices,
    required this.onlineDevices,
    required this.traffic,
  });

  final int totalDevices;
  final int onlineDevices;
  final _NetworkTrafficSnapshot? traffic;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _SummaryItem(
          icon: Icons.circle,
          iconColor: const Color(0xFF16A34A),
          text: '$onlineDevices / $totalDevices 在线',
        ),
        _SummaryItem(
          icon: Icons.arrow_downward,
          iconColor: const Color(0xFF16A34A),
          text: _formatTrafficRate(traffic?.downloadBytesPerSecond),
        ),
        _SummaryItem(
          icon: Icons.arrow_upward,
          iconColor: const Color(0xFF2563EB),
          text: _formatTrafficRate(traffic?.uploadBytesPerSecond),
        ),
        _SummaryItem(text: _formatTotalTraffic(traffic)),
      ],
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({this.icon, this.iconColor, required this.text});

  final IconData? icon;
  final Color? iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: iconColor ?? const Color(0xFF94A3B8)),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF94A3B8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
