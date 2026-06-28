import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../shared/app_motion.dart';

class HomeNetworkDetailHeaderCollapse {
  const HomeNetworkDetailHeaderCollapse({
    required this.progress,
    required this.animate,
  });

  final double progress;
  final bool animate;
}

class HomeNetworkDetailHeader extends StatelessWidget {
  const HomeNetworkDetailHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.totalDevices,
    required this.onlineDevices,
    required this.downloadRateText,
    required this.uploadRateText,
    this.localIpv4,
    this.collapse,
    this.actions = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final int totalDevices;
  final int onlineDevices;
  final String downloadRateText;
  final String uploadRateText;
  final String? localIpv4;
  final ValueListenable<HomeNetworkDetailHeaderCollapse>? collapse;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final collapse = this.collapse;
    if (collapse == null) {
      return _buildHeader(
        context,
        const HomeNetworkDetailHeaderCollapse(progress: 0, animate: false),
      );
    }

    return ValueListenableBuilder<HomeNetworkDetailHeaderCollapse>(
      valueListenable: collapse,
      builder: (context, value, child) {
        final targetProgress = value.progress.clamp(0.0, 1.0).toDouble();
        if (!value.animate) {
          return _buildHeader(
            context,
            HomeNetworkDetailHeaderCollapse(
              progress: targetProgress,
              animate: false,
            ),
          );
        }

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetProgress),
          duration: appMotionShort,
          curve: appMotionCurve,
          builder: (context, progress, child) => _buildHeader(
            context,
            HomeNetworkDetailHeaderCollapse(progress: progress, animate: true),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    HomeNetworkDetailHeaderCollapse collapse,
  ) {
    final progress = collapse.progress.clamp(0.0, 1.0).toDouble();
    return Container(
      key: const ValueKey<String>('network-detail-header'),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 520;
              final textTheme = Theme.of(context).textTheme;
              final expandedTitleStyle = compact
                  ? textTheme.titleLarge
                  : textTheme.headlineSmall;
              final collapsedTitleStyle = compact
                  ? textTheme.titleMedium
                  : textTheme.titleLarge;
              final actionGroup = Wrap(
                spacing: compact ? 6 : 8,
                runSpacing: compact ? 6 : 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              );

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle.lerp(
                        expandedTitleStyle,
                        collapsedTitleStyle,
                        progress,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    SelectionContainer.disabled(child: actionGroup),
                  ],
                ],
              );
            },
          ),
          _HomeNetworkDetailCollapsibleGap(height: 4, progress: progress),
          _HomeNetworkDetailCollapsible(
            progress: progress,
            child: Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
            ),
          ),
          _HomeNetworkDetailCollapsibleGap(height: 12, progress: progress),
          _HomeNetworkDetailCollapsible(
            progress: progress,
            child: HomeNetworkSummaryBar(
              totalDevices: totalDevices,
              onlineDevices: onlineDevices,
              downloadRateText: downloadRateText,
              uploadRateText: uploadRateText,
              localIpv4: localIpv4,
            ),
          ),
          SizedBox(height: 4 * progress),
        ],
      ),
    );
  }
}

class HomeNetworkSummaryBar extends StatelessWidget {
  const HomeNetworkSummaryBar({
    super.key,
    required this.totalDevices,
    required this.onlineDevices,
    required this.downloadRateText,
    required this.uploadRateText,
    this.localIpv4,
  });

  final int totalDevices;
  final int onlineDevices;
  final String downloadRateText;
  final String uploadRateText;
  final String? localIpv4;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow =
            constraints.hasBoundedWidth && constraints.maxWidth < 480;

        final items = <Widget>[
          _HomeNetworkSummaryItem(
            icon: Icons.circle,
            iconColor: const Color(0xFF16A34A),
            text: '$onlineDevices / $totalDevices 在线',
          ),
          _HomeNetworkSummaryItem(
            icon: Icons.arrow_downward,
            iconColor: const Color(0xFF16A34A),
            text: downloadRateText,
          ),
          _HomeNetworkSummaryItem(
            icon: Icons.arrow_upward,
            iconColor: const Color(0xFF2563EB),
            text: uploadRateText,
          ),
          if (localIpv4 != null && localIpv4!.isNotEmpty)
            _HomeNetworkSummaryItem(
              icon: Icons.router_outlined,
              iconColor: const Color(0xFF64748B),
              text: localIpv4!,
            ),
        ];

        return Wrap(
          spacing: narrow ? 12 : 16,
          runSpacing: narrow ? 6 : 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: items,
        );
      },
    );
  }
}

class HomeNetworkDetailSectionTab {
  const HomeNetworkDetailSectionTab({
    required this.icon,
    required this.label,
    this.compactLabel,
  });

  final IconData icon;
  final String label;
  final String? compactLabel;
}

class HomeNetworkDetailSectionTabs extends StatelessWidget {
  const HomeNetworkDetailSectionTabs({
    super.key,
    required this.selectedIndex,
    required this.tabs,
    required this.onChanged,
  });

  final int selectedIndex;
  final List<HomeNetworkDetailSectionTab> tabs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 520;
          return Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: IntrinsicWidth(
                child: FTabs(
                  key: const ValueKey<String>('network-detail-section-tabs'),
                  control: FTabControl.lifted(
                    index: selectedIndex,
                    onChange: onChanged,
                  ),
                  style: const FTabsStyleDelta.delta(height: 28, spacing: 0),
                  contentPhysics: const NeverScrollableScrollPhysics(),
                  scrollable: true,
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      FTabEntry(
                        label: _HomeNetworkDetailSectionTabLabel(
                          selected: selectedIndex == i,
                          icon: tabs[i].icon,
                          label: compact
                              ? tabs[i].compactLabel ?? tabs[i].label
                              : tabs[i].label,
                        ),
                        child: const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HomeNetworkSummaryItem extends StatelessWidget {
  const _HomeNetworkSummaryItem({
    this.icon,
    this.iconColor,
    required this.text,
  });

  final IconData? icon;
  final Color? iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: iconColor ?? const Color(0xFF94A3B8)),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF94A3B8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _HomeNetworkDetailSectionTabLabel extends StatelessWidget {
  const _HomeNetworkDetailSectionTabLabel({
    required this.selected,
    required this.icon,
    required this.label,
  });

  final bool selected;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 12,
          color: selected ? const Color(0xFF0F172A) : const Color(0xFF64748B),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _HomeNetworkDetailCollapsible extends StatelessWidget {
  const _HomeNetworkDetailCollapsible({
    required this.progress,
    required this.child,
  });

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visible = (1 - progress).clamp(0.0, 1.0).toDouble();

    return ClipRect(
      child: Align(
        alignment: Alignment.topLeft,
        heightFactor: visible,
        child: Opacity(opacity: visible, child: child),
      ),
    );
  }
}

class _HomeNetworkDetailCollapsibleGap extends StatelessWidget {
  const _HomeNetworkDetailCollapsibleGap({
    required this.height,
    required this.progress,
  });

  final double height;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final visible = (1 - progress).clamp(0.0, 1.0).toDouble();
    return SizedBox(height: height * visible);
  }
}
