part of 'network_node_list_panel.dart';

class _NodeDetailPanel extends StatelessWidget {
  const _NodeDetailPanel({required this.peer});

  final CorePeerStatus? peer;

  @override
  Widget build(BuildContext context) {
    final p = peer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        const SizedBox(height: 16),
        if (p == null)
          SelectableTextHitBoundary(
            child: Text(
              '运行态信息暂不可用',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF94A3B8),
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (p.peerId.isNotEmpty)
                _DetailChip(
                  icon: Icons.fingerprint_outlined,
                  label: 'Peer ID',
                  value: p.peerId,
                ),
              if (_formatLatency(p.latencyText).isNotEmpty)
                _DetailChip(
                  icon: Icons.speed_outlined,
                  label: '延迟',
                  value: _formatLatency(p.latencyText).replaceFirst('延迟 ', ''),
                ),
              if (p.lossText.isNotEmpty && p.lossText != '-')
                _DetailChip(
                  icon: Icons.signal_cellular_alt_outlined,
                  label: '丢包',
                  value: p.lossText,
                ),
              if (p.tunnelProto.isNotEmpty && p.tunnelProto != '-')
                _DetailChip(
                  icon: Icons.route_outlined,
                  label: '隧道',
                  value: p.tunnelProto,
                ),
              if (p.natType.isNotEmpty && p.natType != '-')
                _DetailChip(
                  icon: Icons.network_ping_outlined,
                  label: 'NAT',
                  value: p.natType,
                ),
              if (p.rxBytes.isNotEmpty && p.rxBytes != '-')
                _DetailChip(
                  icon: Icons.arrow_downward_outlined,
                  label: '接收',
                  value: p.rxBytes,
                ),
              if (p.txBytes.isNotEmpty && p.txBytes != '-')
                _DetailChip(
                  icon: Icons.arrow_upward_outlined,
                  label: '发送',
                  value: p.txBytes,
                ),
              if (p.version.isNotEmpty && p.version != '-')
                _DetailChip(
                  icon: Icons.info_outline,
                  label: '版本',
                  value: p.version,
                ),
            ],
          ),
      ],
    );
  }
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.hasBoundedWidth;
        final compact = bounded && constraints.maxWidth < 420;

        return ConstrainedBox(
          constraints: bounded
              ? BoxConstraints(maxWidth: constraints.maxWidth)
              : const BoxConstraints(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Row(
              mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: const Color(0xFF94A3B8)),
                const SizedBox(width: 6),
                Text(
                  '$label:',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  fit: FlexFit.loose,
                  child: SelectableTextHitBoundary(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF0F172A),
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Inter',
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
