import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';

const double _nodeListMinWidth = 360;

class NetworkNodeListViewport extends StatefulWidget {
  const NetworkNodeListViewport({
    super.key,
    required this.nodes,
    required this.peerStatusesByIpv4,
    this.runtimeError,
  });

  final List<NetworkDevice> nodes;
  final Map<String, CorePeerStatus> peerStatusesByIpv4;
  final String? runtimeError;

  @override
  State<NetworkNodeListViewport> createState() =>
      _NetworkNodeListViewportState();
}

class _NetworkNodeListViewportState extends State<NetworkNodeListViewport> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.isEmpty) {
      return NetworkNodeListPanel(
        nodes: widget.nodes,
        peerStatusesByIpv4: widget.peerStatusesByIpv4,
        runtimeError: widget.runtimeError,
      );
    }

    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        key: const ValueKey<String>('network-node-list-scroll'),
        controller: _scrollController,
        primary: false,
        child: NetworkNodeListPanel(
          nodes: widget.nodes,
          peerStatusesByIpv4: widget.peerStatusesByIpv4,
          runtimeError: widget.runtimeError,
        ),
      ),
    );
  }
}

class NetworkNodeListPanel extends StatelessWidget {
  const NetworkNodeListPanel({
    super.key,
    required this.nodes,
    required this.peerStatusesByIpv4,
    this.runtimeError,
  });

  final List<NetworkDevice> nodes;
  final Map<String, CorePeerStatus> peerStatusesByIpv4;
  final String? runtimeError;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (runtimeError != null) ...[
            _RuntimeStatusNotice(message: runtimeError!),
            const SizedBox(height: 12),
          ],
          const Center(child: _NodeStateMessage(message: '该网络暂无节点')),
        ],
      );
    }

    final sortedNodes = _sortNodes(nodes);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.hasBoundedWidth &&
            constraints.maxWidth < _nodeListMinWidth;

        Widget list = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (runtimeError != null) ...[
              _RuntimeStatusNotice(message: runtimeError!),
              const SizedBox(height: 12),
            ],
            for (final node in sortedNodes)
              _NodeCard(
                node: node,
                peer: _peerFor(node),
              ),
          ],
        );

        if (isNarrow) {
          return SingleChildScrollView(
            primary: false,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _nodeListMinWidth,
              child: list,
            ),
          );
        }

        return list;
      },
    );
  }

  List<NetworkDevice> _sortNodes(List<NetworkDevice> source) {
    return List<NetworkDevice>.of(source)
      ..sort((a, b) {
        if (a.online && !b.online) return -1;
        if (!a.online && b.online) return 1;

        final aPeer = _peerFor(a);
        final bPeer = _peerFor(b);
        final aLocal = aPeer?.isLocal ?? false;
        final bLocal = bPeer?.isLocal ?? false;
        if (aLocal && !bLocal) return -1;
        if (!aLocal && bLocal) return 1;

        return a.name.compareTo(b.name);
      });
  }

  CorePeerStatus? _peerFor(NetworkDevice node) {
    final ipv4 = normalizeCorePeerIpv4(node.ipv4 ?? '');
    if (ipv4.isEmpty) {
      return null;
    }
    return peerStatusesByIpv4[ipv4];
  }
}

class _NodeCard extends StatefulWidget {
  const _NodeCard({
    required this.node,
    required this.peer,
  });

  final NetworkDevice node;
  final CorePeerStatus? peer;

  @override
  State<_NodeCard> createState() => _NodeCardState();
}

class _NodeCardState extends State<_NodeCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _breathController;

  @override
  void initState() {
    super.initState();
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = widget.node.online;
    final isLocal = widget.peer?.isLocal ?? false;
    final peer = widget.peer;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 左侧状态条
                  Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: isOnline
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF9CA3AF),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 首行：状态圆点 + 图标 + 名称 + 标记 + Badge + 展开箭头
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              _BreathingDot(
                                controller: _breathController,
                                online: isOnline,
                              ),
                              const SizedBox(width: 10),
                              Icon(
                                isLocal
                                    ? Icons.computer
                                    : Icons.devices_other_outlined,
                                size: 20,
                                color: const Color(0xFF64748B),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.node.name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF0F172A),
                                      ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isLocal) ...[
                                const SizedBox(width: 8),
                                const _LocalBadge(),
                              ],
                              const SizedBox(width: 8),
                              FBadge(
                                variant: isOnline ? .secondary : .outline,
                                child: Text(isOnline ? '在线' : '离线'),
                              ),
                              const SizedBox(width: 6),
                              FBadge(
                                variant: peer == null ? .outline : .secondary,
                                child: Text(peer == null
                                    ? '运行态未知'
                                    : _formatPeerCost(peer.cost)),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                _expanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                                color: const Color(0xFF94A3B8),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          // IPv4 地址
                          Row(
                            children: [
                              const Icon(
                                Icons.vpn_key_outlined,
                                size: 14,
                                color: Color(0xFF94A3B8),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                widget.node.ipv4?.isNotEmpty == true
                                    ? widget.node.ipv4!
                                    : '未分配 IPv4',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: const Color(0xFF64748B),
                                      fontFamily: 'Inter',
                                    ),
                              ),
                            ],
                          ),
                          // 快捷指标行
                          if (peer != null) ...[
                            const SizedBox(height: 8),
                            _QuickMetrics(peer: peer),
                          ],
                          // 展开详情
                          AnimatedCrossFade(
                            firstChild: const SizedBox.shrink(),
                            secondChild: _NodeDetailPanel(peer: peer),
                            crossFadeState: _expanded
                                ? CrossFadeState.showSecond
                                : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 250),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BreathingDot extends StatelessWidget {
  const _BreathingDot({
    required this.controller,
    required this.online,
  });

  final AnimationController controller;
  final bool online;

  @override
  Widget build(BuildContext context) {
    if (!online) {
      return Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Colors.grey,
          shape: BoxShape.circle,
        ),
      );
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: const Color(0xFF16A34A).withValues(
              alpha: 0.5 + controller.value * 0.5,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF16A34A).withValues(
                  alpha: 0.2 + controller.value * 0.3,
                ),
                blurRadius: 4 + controller.value * 4,
                spreadRadius: controller.value * 1,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LocalBadge extends StatelessWidget {
  const _LocalBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFDBEAFE),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF93C5FD)),
      ),
      child: const Text(
        '本机',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: Color(0xFF2563EB),
          height: 1.2,
        ),
      ),
    );
  }
}

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
          Text(
            '运行态信息暂不可用',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF94A3B8),
                  fontStyle: FontStyle.italic,
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
                  value: _formatLatency(p.latencyText)
                      .replaceFirst('延迟 ', ''),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF0F172A),
              fontWeight: FontWeight.w600,
              fontFamily: 'Inter',
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickMetrics extends StatelessWidget {
  const _QuickMetrics({required this.peer});

  final CorePeerStatus peer;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];

    final latency = _formatLatency(peer.latencyText);
    if (latency.isNotEmpty) {
      items.add(_metricChip(Icons.speed_outlined, latency.replaceFirst('延迟 ', '')));
    }

    if (peer.tunnelProto.isNotEmpty && peer.tunnelProto != '-') {
      items.add(_metricChip(Icons.route_outlined, peer.tunnelProto));
    }

    if (peer.rxBytes.isNotEmpty && peer.rxBytes != '-') {
      items.add(_metricChip(Icons.arrow_downward_outlined, peer.rxBytes));
    }

    if (peer.txBytes.isNotEmpty && peer.txBytes != '-') {
      items.add(_metricChip(Icons.arrow_upward_outlined, peer.txBytes));
    }

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: items,
    );
  }

  Widget _metricChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: const Color(0xFF16A34A)),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF15803D),
              fontFamily: 'Inter',
              height: 1.2,
            ),
          ),
        ],
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

String _formatPeerCost(String cost) {
  final value = cost.trim();
  if (value.isEmpty || value == '-') {
    return '运行态';
  }
  if (value.toLowerCase() == 'p2p') {
    return 'P2P';
  }
  return value;
}

String _formatLatency(String latencyText) {
  final value = latencyText.trim();
  if (value.isEmpty || value == '-' || value == '*') {
    return '';
  }
  return value.toLowerCase().endsWith('ms') ? '延迟 $value' : '延迟 $value ms';
}
