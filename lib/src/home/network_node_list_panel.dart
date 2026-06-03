import 'package:flutter/material.dart';
import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';
import '../shared/app_motion.dart';

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
    final content = widget.nodes.isEmpty
        ? NetworkNodeListPanel(
            key: const ValueKey<String>('network-node-list-empty'),
            nodes: widget.nodes,
            peerStatusesByIpv4: widget.peerStatusesByIpv4,
            runtimeError: widget.runtimeError,
          )
        : Scrollbar(
            key: const ValueKey<String>('network-node-list-scrollbar'),
            controller: _scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              key: const ValueKey<String>('network-node-list-scroll'),
              controller: _scrollController,
              primary: false,
              physics: appScrollPhysics,
              child: NetworkNodeListPanel(
                nodes: widget.nodes,
                peerStatusesByIpv4: widget.peerStatusesByIpv4,
                runtimeError: widget.runtimeError,
              ),
            ),
          );

    return AnimatedSwitcher(
      duration: appMotionMedium,
      reverseDuration: appMotionShort,
      transitionBuilder: appFadeSlideTransition,
      child: content,
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
    final content = nodes.isEmpty
        ? Column(
            key: const ValueKey<String>('network-node-list-panel-empty'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (runtimeError != null) ...[
                _RuntimeStatusNotice(message: runtimeError!),
                const SizedBox(height: 12),
              ],
              const Center(child: _NodeStateMessage(message: '该网络暂无节点')),
            ],
          )
        : LayoutBuilder(
            key: const ValueKey<String>('network-node-list-panel-loaded'),
            builder: (context, constraints) {
              final sortedNodes = _sortNodes(nodes);
              final isNarrow =
                  constraints.hasBoundedWidth &&
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
                      key: ValueKey<String>('network-node-${node.id}'),
                      node: node,
                      peer: _peerFor(node),
                    ),
                ],
              );

              if (isNarrow) {
                return SingleChildScrollView(
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  physics: appScrollPhysics,
                  child: SizedBox(width: _nodeListMinWidth, child: list),
                );
              }

              return list;
            },
          );

    return AnimatedSwitcher(
      duration: appMotionMedium,
      reverseDuration: appMotionShort,
      transitionBuilder: appFadeSlideTransition,
      child: content,
    );
  }

  List<NetworkDevice> _sortNodes(List<NetworkDevice> source) {
    return List<NetworkDevice>.of(source)..sort((a, b) {
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
  const _NodeCard({super.key, required this.node, required this.peer});

  final NetworkDevice node;
  final CorePeerStatus? peer;

  @override
  State<_NodeCard> createState() => _NodeCardState();
}

class _NodeCardState extends State<_NodeCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isOnline = widget.node.online;
    final isLocal = widget.peer?.isLocal ?? false;
    final peer = widget.peer;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AnimatedSize(
        duration: appMotionMedium,
        curve: appMotionCurve,
        alignment: Alignment.topCenter,
        child: GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
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
                            // 首行：名称 + 状态文字 + 展开箭头
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
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
                                const SizedBox(width: 12),
                                Text(
                                  isOnline ? '在线' : '离线',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: isOnline
                                            ? const Color(0xFF16A34A)
                                            : const Color(0xFF9CA3AF),
                                        fontWeight: FontWeight.w500,
                                      ),
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
                            const SizedBox(height: 4),
                            // 技术信息行：IPv4 + 本机 + 快捷指标
                            _NodeMetaLine(
                              ipv4: widget.node.ipv4,
                              isLocal: isLocal,
                              peer: peer,
                            ),
                            // 展开详情
                            AnimatedCrossFade(
                              firstChild: const SizedBox.shrink(),
                              secondChild: _NodeDetailPanel(peer: peer),
                              crossFadeState: _expanded
                                  ? CrossFadeState.showSecond
                                  : CrossFadeState.showFirst,
                              duration: appMotionMedium,
                              sizeCurve: appMotionCurve,
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
        parts.add(latency.toLowerCase().endsWith('ms') ? latency : '$latency ms');
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
    }

    return Text(
      parts.join('  ·  '),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: const Color(0xFF94A3B8),
        fontFamily: 'Inter',
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

String _formatLatency(String latencyText) {
  final value = latencyText.trim();
  if (value.isEmpty || value == '-' || value == '*') {
    return '';
  }
  return value.toLowerCase().endsWith('ms') ? '延迟 $value' : '延迟 $value ms';
}
