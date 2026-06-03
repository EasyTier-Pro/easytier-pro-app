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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (runtimeError != null) ...[
          _RuntimeStatusNotice(message: runtimeError!),
          const SizedBox(height: 12),
        ],
        FCard.raw(
          child: _ConstrainedNodeItemGroup(
            divider: .full,
            children: [
              for (final node in nodes)
                FItem(
                  prefix: _NodeStatusDot(online: node.online),
                  title: Text(node.name),
                  subtitle: Text(_nodeSubtitle(node, _peerFor(node))),
                  suffix: _NodeRuntimeBadges(
                    online: node.online,
                    peer: _peerFor(node),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  CorePeerStatus? _peerFor(NetworkDevice node) {
    final ipv4 = normalizeCorePeerIpv4(node.ipv4 ?? '');
    if (ipv4.isEmpty) {
      return null;
    }
    return peerStatusesByIpv4[ipv4];
  }
}

class _NodeRuntimeBadges extends StatelessWidget {
  const _NodeRuntimeBadges({required this.online, required this.peer});

  final bool online;
  final CorePeerStatus? peer;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FBadge(
          variant: online ? .secondary : .outline,
          child: Text(online ? '在线' : '离线'),
        ),
        const SizedBox(height: 6),
        FBadge(
          variant: peer == null ? .outline : .secondary,
          child: Text(peer == null ? '运行态未知' : _formatPeerCost(peer!.cost)),
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

class _ConstrainedNodeItemGroup extends StatelessWidget {
  const _ConstrainedNodeItemGroup({
    required this.children,
    this.divider = FItemDivider.none,
  });

  final List<FItemMixin> children;
  final FItemDivider divider;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth ||
            constraints.maxWidth >= _nodeListMinWidth) {
          return FItemGroup(
            divider: divider,
            physics: const ClampingScrollPhysics(),
            children: children,
          );
        }

        return SingleChildScrollView(
          primary: false,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: _nodeListMinWidth,
            child: FItemGroup(
              divider: divider,
              physics: const ClampingScrollPhysics(),
              children: children,
            ),
          ),
        );
      },
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

class _NodeStatusDot extends StatelessWidget {
  const _NodeStatusDot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: online ? const Color(0xFF16A34A) : Colors.grey,
        shape: BoxShape.circle,
      ),
    );
  }
}

String _nodeSubtitle(NetworkDevice node, CorePeerStatus? peer) {
  final base = node.ipv4 == null || node.ipv4!.isEmpty
      ? 'ID: ${node.id}'
      : 'IP: ${node.ipv4}  |  ID: ${node.id}';
  final runtimeDetails = _peerRuntimeDetails(peer);
  return runtimeDetails.isEmpty ? base : '$base\n$runtimeDetails';
}

String _peerRuntimeDetails(CorePeerStatus? peer) {
  if (peer == null) {
    return '运行态: 未知';
  }

  final details = <String>[
    if (peer.peerId.isNotEmpty) 'Peer: ${peer.peerId}',
    if (_formatLatency(peer.latencyText).isNotEmpty)
      _formatLatency(peer.latencyText),
    if (peer.lossText.isNotEmpty && peer.lossText != '-') '丢包 ${peer.lossText}',
    if (peer.tunnelProto.isNotEmpty && peer.tunnelProto != '-')
      '隧道 ${peer.tunnelProto}',
    if (peer.natType.isNotEmpty && peer.natType != '-') 'NAT ${peer.natType}',
  ];

  if (details.isEmpty) {
    return '运行态: ${_formatPeerCost(peer.cost)}';
  }
  return details.join('  |  ');
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
