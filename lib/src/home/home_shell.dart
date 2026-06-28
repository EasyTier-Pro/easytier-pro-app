import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../core/core_lifecycle_service.dart';
import '../shared/app_motion.dart';
import '../shared/app_smooth_scroll_view.dart';
import '../shared/app_text_selection.dart';

const double homeShellHeaderCompactBreakpoint = 560;
const double homeShellMobileBreakpoint = 600;

enum HomeShellContentMode { scrollConstrained, staticConstrained, plain }

class HomeShell extends StatelessWidget {
  const HomeShell({
    super.key,
    required this.desktopHeader,
    required this.mobileHeader,
    required this.contentKey,
    required this.child,
    required this.contentMode,
    this.mobileNavigation,
    this.onMobileSwipe,
    this.maxContentWidth = 1040,
    this.backgroundColor = const Color(0xFFFFFFFF),
  });

  final Widget desktopHeader;
  final Widget mobileHeader;
  final Widget? mobileNavigation;
  final Key contentKey;
  final Widget child;
  final HomeShellContentMode contentMode;
  final ValueChanged<Offset>? onMobileSwipe;
  final double maxContentWidth;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return FScaffold(
      childPad: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < homeShellMobileBreakpoint;
          final pagePadding = EdgeInsets.all(mobile ? 16 : 24);

          return Column(
            children: [
              if (!mobile) const _DesktopSystemTopInset(),
              if (mobile) mobileHeader else desktopHeader,
              Expanded(
                child: AppTextSelectionTapCleaner(
                  child: _HomeMobilePageSwipeGate(
                    enabled: mobile && onMobileSwipe != null,
                    onSwipe: onMobileSwipe,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: backgroundColor),
                      child: AnimatedSwitcher(
                        duration: appMotionMedium,
                        reverseDuration: appMotionShort,
                        transitionBuilder: appFadeSlideTransition,
                        layoutBuilder: appSwitcherStackLayout,
                        child: KeyedSubtree(
                          key: contentKey,
                          child: _HomeShellContent(
                            mode: contentMode,
                            padding: pagePadding,
                            maxWidth: maxContentWidth,
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (mobile && mobileNavigation != null) mobileNavigation!,
            ],
          );
        },
      ),
    );
  }
}

class HomeShellDesktopHeader extends StatelessWidget {
  const HomeShellDesktopHeader({
    super.key,
    required this.navigation,
    this.metrics = const <Widget>[],
    this.trailing,
    this.contentKey,
    this.compactBreakpoint = homeShellHeaderCompactBreakpoint,
  });

  final List<Widget> navigation;
  final List<Widget> metrics;
  final Widget? trailing;
  final Key? contentKey;
  final double compactBreakpoint;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: Container(
        key: contentKey,
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
          color: Color(0xFFFFFFFF),
          border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < compactBreakpoint;
            return Row(
              children: [
                const HomeBrandMark(),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: appScrollPhysics,
                    child: Row(children: navigation),
                  ),
                ),
                if (!compact && metrics.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  ..._spaced(metrics, 10),
                ],
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            );
          },
        ),
      ),
    );
  }
}

class HomeShellMobileHeader extends StatelessWidget {
  const HomeShellMobileHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.suffixes = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final List<Widget> suffixes;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: FHeader(
        style: FHeaderStyleDelta.delta(
          constraints: const BoxConstraints(minHeight: 58),
          decoration: DecorationDelta.value(
            const BoxDecoration(
              color: Color(0xFFFFFFFF),
              border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
            ),
          ),
          padding: EdgeInsetsGeometryDelta.value(
            const EdgeInsets.symmetric(horizontal: 14),
          ),
          actionSpacing: 4,
        ),
        title: Row(
          children: [
            const HomeBrandMark(),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: const Color(0xFF0F172A),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        suffixes: suffixes,
      ),
    );
  }
}

class HomeShellMobileNavigationItem {
  const HomeShellMobileNavigationItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelect,
    this.key,
  });

  final String id;
  final IconData icon;
  final String label;
  final VoidCallback onSelect;
  final Key? key;
}

class HomeShellMobileNavigation extends StatelessWidget {
  const HomeShellMobileNavigation({
    super.key,
    required this.index,
    required this.items,
    this.navigationKey,
  });

  final int index;
  final List<HomeShellMobileNavigationItem> items;
  final Key? navigationKey;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: FBottomNavigationBar(
        key: navigationKey,
        index: index,
        onChange: (index) {
          if (index < 0 || index >= items.length) {
            return;
          }
          items[index].onSelect();
        },
        children: [
          for (final item in items)
            FBottomNavigationBarItem(
              key: item.key ?? ValueKey<String>('mobile-nav-${item.id}'),
              icon: Icon(item.icon),
              label: Text(item.label),
            ),
        ],
      ),
    );
  }
}

class HomeBrandMark extends StatelessWidget {
  const HomeBrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/easytier_header.png',
      width: 30,
      height: 30,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

class HomeHeaderMetric extends StatelessWidget {
  const HomeHeaderMetric({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color ?? const Color(0xFF737373)),
        const SizedBox(width: 5),
        Text(
          '$label $value',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF737373),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class HomeSettingsInfoRow extends StatelessWidget {
  const HomeSettingsInfoRow({
    super.key,
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF737373),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF0F172A),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        FTooltip(
          tipBuilder: (context, controller) => const Text('复制'),
          child: FButton(
            variant: .ghost,
            size: .xs,
            style: const .delta(
              contentStyle: .delta(padding: .value(EdgeInsets.zero)),
            ),
            onPress: () => onCopy(value),
            child: const Icon(Icons.copy, size: 14),
          ),
        ),
      ],
    );
  }
}

class HomeCoreStatusLabel extends StatelessWidget {
  const HomeCoreStatusLabel({
    super.key,
    required this.statusListenable,
    required this.label,
  });

  final ValueListenable<CoreRunStatus> statusListenable;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: statusListenable,
      builder: (context, status, _) {
        return Tooltip(
          message: status.message,
          child: Row(
            children: [
              Icon(
                Icons.circle,
                size: 12,
                color: homeCoreStatusColor(status.phase),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF737373),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class HomeCoreStatusDot extends StatelessWidget {
  const HomeCoreStatusDot({super.key, required this.statusListenable});

  final ValueListenable<CoreRunStatus> statusListenable;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: statusListenable,
      builder: (context, status, _) {
        final color = homeCoreStatusColor(status.phase);
        return Tooltip(
          message: status.message,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.circle, size: 10, color: color),
          ),
        );
      },
    );
  }
}

Color homeCoreStatusColor(CoreRunPhase phase) {
  return switch (phase) {
    CoreRunPhase.running => const Color(0xFF16A34A),
    CoreRunPhase.repairing => const Color(0xFFF59E0B),
    CoreRunPhase.checking => const Color(0xFF2563EB),
    CoreRunPhase.needsElevation => const Color(0xFFF59E0B),
    CoreRunPhase.needsVpnPermission => const Color(0xFFF59E0B),
    CoreRunPhase.error => const Color(0xFFDC2626),
    CoreRunPhase.stopped => Colors.grey,
    CoreRunPhase.signedOut => Colors.grey,
  };
}

class _HomeShellContent extends StatelessWidget {
  const _HomeShellContent({
    required this.mode,
    required this.padding,
    required this.maxWidth,
    required this.child,
  });

  final HomeShellContentMode mode;
  final EdgeInsets padding;
  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      HomeShellContentMode.scrollConstrained => AppSmoothScrollView(
        padding: padding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        ),
      ),
      HomeShellContentMode.staticConstrained => Padding(
        padding: padding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        ),
      ),
      HomeShellContentMode.plain => child,
    };
  }
}

class _HomeMobilePageSwipeGate extends StatefulWidget {
  const _HomeMobilePageSwipeGate({
    required this.enabled,
    required this.onSwipe,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<Offset>? onSwipe;
  final Widget child;

  @override
  State<_HomeMobilePageSwipeGate> createState() =>
      _HomeMobilePageSwipeGateState();
}

class _HomeMobilePageSwipeGateState extends State<_HomeMobilePageSwipeGate> {
  int? _trackingPointer;
  Offset _pointerDelta = Offset.zero;

  void _startTracking(PointerDownEvent event) {
    if (!widget.enabled || _trackingPointer != null) {
      return;
    }

    _trackingPointer = event.pointer;
    _pointerDelta = Offset.zero;
  }

  void _trackMove(PointerMoveEvent event) {
    if (!widget.enabled || event.pointer != _trackingPointer) {
      return;
    }

    _pointerDelta += event.delta;
  }

  void _finishTracking(PointerEvent event) {
    if (event.pointer != _trackingPointer) {
      return;
    }

    final delta = _pointerDelta;
    _trackingPointer = null;
    _pointerDelta = Offset.zero;
    if (widget.enabled) {
      widget.onSwipe?.call(delta);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return Listener(
      key: const ValueKey<String>('mobile-dashboard-page-swipe'),
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _startTracking,
      onPointerMove: _trackMove,
      onPointerUp: _finishTracking,
      onPointerCancel: _finishTracking,
      child: widget.child,
    );
  }
}

class _DesktopSystemTopInset extends StatelessWidget {
  const _DesktopSystemTopInset();

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    if (topInset <= 0) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const ValueKey<String>('desktop-system-top-inset'),
      height: topInset,
      color: const Color(0xFFF8F9FB),
    );
  }
}

List<Widget> _spaced(List<Widget> children, double spacing) {
  if (children.isEmpty) {
    return const <Widget>[];
  }
  return [
    for (var index = 0; index < children.length; index++) ...[
      if (index > 0) SizedBox(width: spacing),
      children[index],
    ],
  ];
}
