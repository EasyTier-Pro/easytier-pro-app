part of 'network_node_list_panel.dart';

class _NodeCard extends StatefulWidget {
  const _NodeCard({super.key, required this.node, required this.peer});

  final NetworkDevice node;
  final CorePeerStatus? peer;

  @override
  State<_NodeCard> createState() => _NodeCardState();
}

class _NodeCardState extends State<_NodeCard> {
  bool _expanded = false;
  bool _tapStartedInsideText = false;

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
          onTapDown: (details) {
            _tapStartedInsideText = tapStartedInsideSelectableText(
              context,
              details.globalPosition,
            );
          },
          onTap: () {
            if (_tapStartedInsideText) {
              return;
            }
            setState(() => _expanded = !_expanded);
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
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
                        _NodeOsIcon(
                          os: widget.node.os,
                          osVersion: widget.node.osVersion,
                          osDistribution: widget.node.osDistribution,
                          online: isOnline,
                          isLocal: isLocal,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableTextHitBoundary(
                              child: Text(
                                widget.node.name,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF0F172A),
                                    ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          isOnline ? '在线' : '离线',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: isOnline
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF9CA3AF),
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
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
          ),
        ),
      );
  }
}
