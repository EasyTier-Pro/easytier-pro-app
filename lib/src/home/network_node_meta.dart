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

      final cost = _formatConnectionCost(p.cost);
      if (cost.isNotEmpty) {
        parts.add(cost);
      }

      final tunnel = _formatTunnelProto(p.tunnelProto);
      if (tunnel.isNotEmpty) {
        parts.add(tunnel);
      }

      final latency = p.latencyText.trim();
      if (latency.isNotEmpty && latency != '-' && latency != '*') {
        parts.add(
          latency.toLowerCase().endsWith('ms') ? latency : '$latency ms',
        );
      }

      final loss = p.lossText.trim();
      if (loss.isNotEmpty && loss != '-' && loss != '0%' && loss != '0.0%') {
        parts.add('丢包 $loss');
      }
    } else {
      parts.add('运行态未知');
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: SelectableTextHitBoundary(
        child: Text(
          parts.join('  ·  '),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF94A3B8),
            fontFamily: 'Inter',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _RuntimeStatusNotice extends StatelessWidget {
  const _RuntimeStatusNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Text(
        '运行态暂不可用：$message',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: const Color(0xFF92400E)),
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

String _formatConnectionCost(String costText) {
  final value = costText.trim();
  if (value.isEmpty || value == '-' || value == '*') {
    return '';
  }

  final normalized = value.toLowerCase();
  if (normalized == 'local') {
    return '';
  }
  if (normalized == 'p2p') {
    return 'P2P';
  }
  if (normalized == 'relay' || normalized.startsWith('relay(')) {
    return '中继';
  }
  if (num.tryParse(value) != null) {
    return '';
  }
  return value;
}

String _formatTunnelProto(String tunnelProto) {
  final value = tunnelProto.trim();
  if (value.isEmpty || value == '-' || value == '*') {
    return '';
  }

  return switch (value.toLowerCase()) {
    'udp' => 'UDP',
    'tcp' => 'TCP',
    'ws' => 'WebSocket',
    'wss' => 'WebSocket TLS',
    _ => value,
  };
}

String _formatLatency(String latencyText) {
  final value = latencyText.trim();
  if (value.isEmpty || value == '-' || value == '*') {
    return '';
  }
  return value.toLowerCase().endsWith('ms') ? '延迟 $value' : '延迟 $value ms';
}
