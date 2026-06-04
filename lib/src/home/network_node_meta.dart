part of 'network_node_list_panel.dart';

class _NodeMetaLine extends StatelessWidget {
  const _NodeMetaLine({
    required this.ipv4,
    required this.isLocal,
    required this.peer,
  });

  final String? ipv4;
  final bool isLocal;
  final CorePeerStatus? peer;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];

    if (ipv4?.isNotEmpty == true) {
      parts.add(ipv4!);
    } else {
      parts.add('未分配 IPv4');
    }

    if (isLocal) parts.add('本机');

    if (peer != null) {
      final p = peer!;

      final cost = p.cost.trim();
      if (cost.isNotEmpty && cost != '-' && cost.toLowerCase() != 'local') {
        parts.add(cost.toLowerCase() == 'p2p' ? 'P2P' : cost);
      }

      final latency = p.latencyText.trim();
      if (latency.isNotEmpty && latency != '-' && latency != '*') {
        parts.add(
          latency.toLowerCase().endsWith('ms') ? latency : '$latency ms',
        );
      }

      final peerId = p.peerId.trim();
      if (peerId.isNotEmpty) {
        parts.add('Peer: $peerId');
      }

      final loss = p.lossText.trim();
      if (loss.isNotEmpty && loss != '-' && loss != '0%' && loss != '0.0%') {
        parts.add('丢包 $loss');
      }

      final rxRaw = p.rxBytes.trim();
      final txRaw = p.txBytes.trim();
      final rx = (rxRaw.isNotEmpty && rxRaw != '-' && rxRaw != '0 B')
          ? '↓$rxRaw'
          : '';
      final tx = (txRaw.isNotEmpty && txRaw != '-' && txRaw != '0 B')
          ? '↑$txRaw'
          : '';
      if (rx.isNotEmpty || tx.isNotEmpty) {
        parts.add('$rx $tx'.trim());
      }
    } else {
      parts.add('运行态未知');
    }

    final summary = parts.join('  ·  ');
    return Row(
      children: [
        Expanded(
          child: Text(
            summary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF94A3B8),
              fontFamily: 'Inter',
            ),
          ),
        ),
        const SizedBox(width: 4),
        AppCopyButton(
          value: summary,
          label: '节点摘要',
          size: 22,
          iconSize: 13,
          color: const Color(0xFF94A3B8),
        ),
      ],
    );
  }
}

class _RuntimeStatusNotice extends StatelessWidget {
  const _RuntimeStatusNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final text = '运行态暂不可用：$message';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF92400E)),
            ),
          ),
          const SizedBox(width: 8),
          AppCopyButton(
            value: message,
            label: '运行态错误',
            size: 22,
            iconSize: 13,
            color: const Color(0xFF92400E),
          ),
        ],
      ),
    );
  }
}

class _NodeStateMessage extends StatelessWidget {
  const _NodeStateMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message, textAlign: TextAlign.center),
    );
  }
}

String _formatLatency(String latencyText) {
  final value = latencyText.trim();
  if (value.isEmpty || value == '-' || value == '*') {
    return '';
  }
  return value.toLowerCase().endsWith('ms') ? '延迟 $value' : '延迟 $value ms';
}
