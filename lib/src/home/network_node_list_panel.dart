import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';
import '../shared/app_motion.dart';
import '../shared/app_smooth_scroll_view.dart';
import '../shared/selectable_text_hit_boundary.dart';

part 'network_node_card.dart';
part 'network_node_os_icon.dart';
part 'network_node_detail.dart';
part 'network_node_meta.dart';

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
            thumbVisibility: false,
            child: AppSmoothScrollView(
              scrollViewKey: const ValueKey<String>('network-node-list-scroll'),
              controller: _scrollController,
              primary: false,
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
