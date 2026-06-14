import 'package:flutter/material.dart';
import '../auth/console_auth_service.dart';
import '../core/core_peer_status.dart';
import '../shared/app_motion.dart';
import '../shared/app_smooth_scroll_view.dart';
import '../shared/selectable_text_hit_boundary.dart';
import 'device_os_icon.dart';

part 'network_node_card.dart';
part 'network_node_os_icon.dart';
part 'network_node_detail.dart';
part 'network_node_meta.dart';

class NetworkNodeListViewport extends StatefulWidget {
  const NetworkNodeListViewport({
    super.key,
    required this.nodes,
    required this.peerStatusesByIpv4,
    this.runtimeError,
    this.scrollDeltaCoordinator,
    this.onStaticContentShown,
  });

  final List<NetworkDevice> nodes;
  final Map<String, CorePeerStatus> peerStatusesByIpv4;
  final String? runtimeError;
  final AppScrollDeltaCoordinator? scrollDeltaCoordinator;
  final VoidCallback? onStaticContentShown;

  @override
  State<NetworkNodeListViewport> createState() =>
      _NetworkNodeListViewportState();
}

class _NetworkNodeListViewportState extends State<NetworkNodeListViewport> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleStaticContentSync();
  }

  @override
  void didUpdateWidget(covariant NetworkNodeListViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onStaticContentShown != widget.onStaticContentShown ||
        oldWidget.nodes.isEmpty != widget.nodes.isEmpty) {
      _scheduleStaticContentSync();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleStaticContentSync() {
    if (widget.nodes.isNotEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.onStaticContentShown?.call();
    });
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
              scrollDeltaCoordinator: widget.scrollDeltaCoordinator,
              child: NetworkNodeListPanel(
                nodes: widget.nodes,
                peerStatusesByIpv4: widget.peerStatusesByIpv4,
                runtimeError: widget.runtimeError,
              ),
            ),
          );

    return Semantics(
      container: true,
      label: widget.nodes.isEmpty
          ? '网络节点列表，暂无节点'
          : '网络节点列表，共 ${widget.nodes.length} 个节点',
      explicitChildNodes: true,
      child: AnimatedSwitcher(
        duration: appMotionMedium,
        reverseDuration: appMotionShort,
        transitionBuilder: appFadeSlideTransition,
        layoutBuilder: appSwitcherStackLayout,
        child: content,
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
    final content = nodes.isEmpty
        ? LayoutBuilder(
            key: const ValueKey<String>('network-node-list-panel-empty'),
            builder: (context, constraints) {
              return ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.hasBoundedHeight
                      ? constraints.maxHeight
                      : 0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (runtimeError != null) ...[
                      _RuntimeStatusNotice(message: runtimeError!),
                      const SizedBox(height: 12),
                    ],
                    const NetworkDetailEmptyState(message: '暂无节点'),
                  ],
                ),
              );
            },
          )
        : Column(
            key: const ValueKey<String>('network-node-list-panel-loaded'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (runtimeError != null) ...[
                _RuntimeStatusNotice(message: runtimeError!),
                const SizedBox(height: 12),
              ],
              for (final node in _sortNodes(nodes))
                _NodeCard(
                  key: ValueKey<String>('network-node-${node.id}'),
                  node: node,
                  peer: _peerFor(node),
                ),
            ],
          );

    return AnimatedSwitcher(
      duration: appMotionMedium,
      reverseDuration: appMotionShort,
      transitionBuilder: appFadeSlideTransition,
      layoutBuilder: appSwitcherStackLayout,
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

      return a.displayLabel.compareTo(b.displayLabel);
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

/// Network Detail 各 tab 在未加入网络或内容为空时使用的统一空状态提示。
class NetworkDetailEmptyState extends StatelessWidget {
  const NetworkDetailEmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF94A3B8)),
        ),
      ),
    );
  }
}
