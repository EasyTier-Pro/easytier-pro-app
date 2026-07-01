import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../shared/selectable_text_hit_boundary.dart';
import 'home_shell.dart';

bool homeNetworkSwitchTileShowsInlineMetrics(BuildContext context) {
  return MediaQuery.sizeOf(context).width >= homeShellMobileBreakpoint;
}

class HomeNetworkSwitchTile extends StatelessWidget {
  const HomeNetworkSwitchTile({
    super.key,
    required this.title,
    required this.joined,
    required this.locallyConnected,
    required this.failed,
    required this.metaChildren,
    required this.switchValue,
    required this.switchLoading,
    this.failedMessage,
    this.trailingVisualization,
    this.onSwitchChanged,
    this.onOpen,
    this.switchTooltip,
  });

  final String title;
  final bool joined;
  final bool locallyConnected;
  final bool failed;
  final List<Widget> metaChildren;
  final String? failedMessage;
  final Widget? trailingVisualization;
  final bool switchValue;
  final bool switchLoading;
  final ValueChanged<bool>? onSwitchChanged;
  final VoidCallback? onOpen;
  final String? switchTooltip;

  @override
  Widget build(BuildContext context) {
    final accentColor = locallyConnected
        ? const Color(0xFF16A34A)
        : joined
        ? const Color(0xFFF59E0B)
        : failed
        ? const Color(0xFFDC2626)
        : const Color(0xFFCBD5E1);
    final cardBg = joined
        ? Colors.white
        : failed
        ? const Color(0xFFFEF2F2)
        : const Color(0xFFFAFBFC);
    final open = onOpen;
    var tapStartedInsideText = false;

    final content = Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: joined
                    ? const Color(0xFFE2E8F0)
                    : const Color(0xFFE2E8F0).withAlpha(180),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F172A).withAlpha(4),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      bottomLeft: Radius.circular(14),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.language_outlined,
                                    size: 16,
                                    color: joined
                                        ? const Color(0xFF334155)
                                        : const Color(0xFF94A3B8),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: const Color(0xFF0F172A),
                                              fontSize: 14,
                                            ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: metaChildren,
                              ),
                              if (failed && failedMessage != null) ...[
                                const SizedBox(height: 6),
                                SelectableTextHitBoundary(
                                  child: Text(
                                    failedMessage!,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: const Color(0xFFDC2626),
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (trailingVisualization != null) ...[
                          trailingVisualization!,
                          const SizedBox(width: 8),
                        ],
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            HomeLoadingSwitch(
                              value: switchValue,
                              loading: switchLoading,
                              onChange: onSwitchChanged,
                              tooltip: switchTooltip,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    if (open == null) {
      return content;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (details) {
          tapStartedInsideText = tapStartedInsideSelectableText(
            context,
            details.globalPosition,
          );
        },
        onTap: () {
          if (!tapStartedInsideText) {
            open();
          }
        },
        behavior: HitTestBehavior.opaque,
        child: content,
      ),
    );
  }
}

class HomeLoadingSwitch extends StatefulWidget {
  const HomeLoadingSwitch({
    super.key,
    required this.value,
    required this.loading,
    this.onChange,
    this.tooltip,
  });

  final bool value;
  final bool loading;
  final ValueChanged<bool>? onChange;
  final String? tooltip;

  @override
  State<HomeLoadingSwitch> createState() => _HomeLoadingSwitchState();
}

class _HomeLoadingSwitchState extends State<HomeLoadingSwitch>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    if (widget.loading) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant HomeLoadingSwitch old) {
    super.didUpdateWidget(old);
    if (widget.loading && !old.loading) {
      _controller.repeat(reverse: true);
    } else if (!widget.loading && old.loading) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final control = SizedBox(
      width: 51,
      height: 31,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Opacity(
            opacity: widget.loading ? 0.35 + (0.65 * _animation.value) : 1.0,
            child: child,
          );
        },
        child: FSwitch(
          value: widget.value,
          enabled: !widget.loading && widget.onChange != null,
          onChange: widget.onChange,
        ),
      ),
    );
    final tooltip = widget.tooltip;
    if (tooltip == null || tooltip.isEmpty) {
      return control;
    }
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: control,
    );
  }
}

class HomeIpBadge extends StatelessWidget {
  const HomeIpBadge({super.key, required this.ip});

  final String ip;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: SelectableTextHitBoundary(
        child: Text(
          ip,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            color: const Color(0xFF15803D),
            fontSize: 11,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

class HomeMiniTrafficPill extends StatelessWidget {
  const HomeMiniTrafficPill({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class HomeStatusChip extends StatelessWidget {
  const HomeStatusChip({super.key, required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFF0FDF4) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: active ? const Color(0xFF15803D) : const Color(0xFF64748B),
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}
