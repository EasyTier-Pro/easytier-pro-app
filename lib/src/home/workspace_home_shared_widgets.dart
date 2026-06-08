part of 'workspace_home_view.dart';

class _ControlSelectionBoundary extends StatelessWidget {
  const _ControlSelectionBoundary({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(child: child);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
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
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF737373),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 16),
          _ControlSelectionBoundary(child: trailing!),
        ],
      ],
    );
  }
}

class _NetworkSummaryBar extends StatelessWidget {
  const _NetworkSummaryBar({
    required this.totalDevices,
    required this.onlineDevices,
    required this.traffic,
    this.localIpv4,
  });

  final int totalDevices;
  final int onlineDevices;
  final _NetworkTrafficSnapshot? traffic;
  final String? localIpv4;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow =
            constraints.hasBoundedWidth && constraints.maxWidth < 480;

        final onlineItem = _SummaryItem(
          icon: Icons.circle,
          iconColor: const Color(0xFF16A34A),
          text: '$onlineDevices / $totalDevices 在线',
        );
        final downloadItem = _SummaryItem(
          icon: Icons.arrow_downward,
          iconColor: const Color(0xFF16A34A),
          text: _formatTrafficRate(traffic?.downloadBytesPerSecond),
        );
        final uploadItem = _SummaryItem(
          icon: Icons.arrow_upward,
          iconColor: const Color(0xFF2563EB),
          text: _formatTrafficRate(traffic?.uploadBytesPerSecond),
        );
        final localIpv4Text = localIpv4?.trim() ?? '';
        final localItem = localIpv4Text.isEmpty
            ? null
            : _SummaryItem(
                icon: Icons.computer_outlined,
                iconColor: const Color(0xFF2563EB),
                text: '本机 $localIpv4Text',
              );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [onlineItem, ?localItem, downloadItem, uploadItem],
              ),
            ],
          );
        }

        return Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            onlineItem,
            ?localItem,
            downloadItem,
            uploadItem,
          ],
        );
      },
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
