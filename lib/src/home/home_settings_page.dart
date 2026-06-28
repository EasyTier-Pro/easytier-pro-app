import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../core/core_lifecycle_service.dart';
import '../shared/app_motion.dart';
import '../shared/app_smooth_scroll_view.dart';
import 'home_shell.dart';

class HomeSettingsSection {
  const HomeSettingsSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
  });

  final String id;
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
}

class HomeSettingsPage extends StatefulWidget {
  const HomeSettingsPage({
    super.key,
    required this.sections,
    this.sidebarWidth = 220,
    this.splitBreakpoint = 720,
  });

  final List<HomeSettingsSection> sections;
  final double sidebarWidth;
  final double splitBreakpoint;

  @override
  State<HomeSettingsPage> createState() => _HomeSettingsPageState();
}

class _HomeSettingsPageState extends State<HomeSettingsPage> {
  static const double _categoryScrollAlignment = 0.05;

  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _sectionKeys = {};
  String? _selectedSectionId;
  bool _isScrollingToSection = false;

  @override
  void initState() {
    super.initState();
    _syncSectionState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(HomeSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSectionState();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _syncSectionState() {
    final ids = widget.sections.map((section) => section.id).toSet();
    _sectionKeys.removeWhere((id, _) => !ids.contains(id));
    for (final section in widget.sections) {
      _sectionKeys.putIfAbsent(section.id, GlobalKey.new);
    }
    if (!ids.contains(_selectedSectionId)) {
      _selectedSectionId = widget.sections.isEmpty
          ? null
          : widget.sections.first.id;
    }
  }

  void _selectSection(HomeSettingsSection section) {
    _scrollToSection(section.id);
  }

  void _scrollToSection(String sectionId) {
    final key = _sectionKeys[sectionId];
    if (key == null) {
      return;
    }
    final context = key.currentContext;
    if (context == null) {
      setState(() {
        _selectedSectionId = sectionId;
      });
      return;
    }
    _isScrollingToSection = true;
    Scrollable.ensureVisible(
      context,
      duration: appMotionMedium,
      curve: appMotionCurve,
      alignment: _categoryScrollAlignment,
    ).whenComplete(() {
      if (mounted) {
        setState(() {
          _isScrollingToSection = false;
          _selectedSectionId = sectionId;
        });
      }
    });
  }

  void _onScroll() {
    if (_isScrollingToSection) {
      return;
    }
    final scrollPosition = _scrollController.position;
    final viewportDimension = scrollPosition.viewportDimension;
    if (viewportDimension <= 0) {
      return;
    }
    final viewportTop = scrollPosition.pixels;
    final viewportCenter = viewportTop + (viewportDimension * 0.35);

    String? closestSectionId;
    var closestDistance = double.infinity;
    for (final section in widget.sections) {
      final key = _sectionKeys[section.id];
      final context = key?.currentContext;
      if (context == null) {
        continue;
      }
      final renderBox = context.findRenderObject();
      if (renderBox is! RenderBox) {
        continue;
      }
      final scrollable = Scrollable.maybeOf(context);
      final scrollableBox = scrollable?.context.findRenderObject();
      if (scrollable == null || scrollableBox is! RenderBox) {
        continue;
      }
      final sectionOffset = renderBox.localToGlobal(Offset.zero);
      final scrollableOffset = scrollableBox.localToGlobal(Offset.zero);
      final sectionTop =
          sectionOffset.dy - scrollableOffset.dy + scrollable.position.pixels;
      final distance = (sectionTop - viewportCenter).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        closestSectionId = section.id;
      }
    }

    if (closestSectionId != null && closestSectionId != _selectedSectionId) {
      setState(() {
        _selectedSectionId = closestSectionId;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= widget.splitBreakpoint;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HomeSettingsSidebar(
                sections: widget.sections,
                selectedId: _selectedSectionId,
                onSelect: _selectSection,
                width: widget.sidebarWidth,
              ),
              Expanded(
                child: _HomeSettingsDetailPane(
                  sections: widget.sections,
                  sectionKeys: _sectionKeys,
                  scrollController: _scrollController,
                ),
              ),
            ],
          );
        }

        return _HomeSettingsCompactScrollPage(sections: widget.sections);
      },
    );
  }
}

class HomeSettingsSectionHeader extends StatelessWidget {
  const HomeSettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
    );
  }
}

class HomeSettingsAccountItem extends StatelessWidget with FItemMixin {
  const HomeSettingsAccountItem({
    super.key,
    required this.prefix,
    required this.label,
    required this.primary,
    this.secondary,
  });

  final Widget prefix;
  final String label;
  final String primary;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    return FItem.raw(
      prefix: prefix,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            overflow: TextOverflow.visible,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF737373),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            primary,
            softWrap: true,
            overflow: TextOverflow.visible,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (secondary != null && secondary!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              secondary!,
              softWrap: true,
              overflow: TextOverflow.visible,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF737373)),
            ),
          ],
        ],
      ),
    );
  }
}

class HomeSettingsInfoItem {
  const HomeSettingsInfoItem({required this.label, required this.value});

  final String label;
  final String value;
}

typedef HomeSettingsInfoBuilder =
    List<HomeSettingsInfoItem> Function(
      CoreRunStatus status,
      CoreEngineVersionStatus engineVersionStatus,
    );

typedef HomeCoreRepairActionLabelBuilder =
    String Function(CoreEngineVersionStatus engineVersionStatus);

class HomeCoreSettingsSection extends StatelessWidget {
  const HomeCoreSettingsSection({
    super.key,
    required this.coreLifecycleService,
    required this.onCopyText,
    this.showVersionInfo = true,
    this.missingMachineIdText,
    this.extraInfoBuilder,
    this.extraActions = const <Widget>[],
    this.repairActionLabelBuilder = _homeCoreEngineSettingsActionLabel,
  });

  final CoreLifecycleService coreLifecycleService;
  final ValueChanged<String> onCopyText;
  final bool showVersionInfo;
  final String? missingMachineIdText;
  final HomeSettingsInfoBuilder? extraInfoBuilder;
  final List<Widget> extraActions;
  final HomeCoreRepairActionLabelBuilder repairActionLabelBuilder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: coreLifecycleService.status,
      builder: (context, status, _) {
        return ValueListenableBuilder<CoreEngineVersionStatus>(
          valueListenable: coreLifecycleService.engineVersionStatus,
          builder: (context, engineVersionStatus, _) {
            final running = status.phase == CoreRunPhase.running;
            final needsVpnPermission =
                status.phase == CoreRunPhase.needsVpnPermission;
            final needsElevation = status.phase == CoreRunPhase.needsElevation;
            final versionHint = showVersionInfo
                ? _homeCoreEngineVersionHint(engineVersionStatus)
                : null;
            final actionLabel = repairActionLabelBuilder(engineVersionStatus);
            final machineId = status.machineId?.trim();
            final extraInfo =
                extraInfoBuilder?.call(status, engineVersionStatus) ??
                const <HomeSettingsInfoItem>[];

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FCard.raw(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _HomeSettingsStatusDot(
                              online: running,
                              color: needsElevation || needsVpnPermission
                                  ? const Color(0xFFF59E0B)
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                status.message,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        if (machineId != null && machineId.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          HomeSettingsInfoRow(
                            label: '设备 ID',
                            value: machineId,
                            onCopy: onCopyText,
                          ),
                        ] else if (missingMachineIdText != null) ...[
                          const SizedBox(height: 12),
                          HomeSettingsInfoRow(
                            label: '设备 ID',
                            value: missingMachineIdText!,
                            onCopy: onCopyText,
                          ),
                        ],
                        if (showVersionInfo &&
                            engineVersionStatus.installedVersion != null) ...[
                          const SizedBox(height: 12),
                          HomeSettingsInfoRow(
                            label: '当前版本',
                            value: engineVersionStatus.installedVersion!,
                            onCopy: onCopyText,
                          ),
                        ],
                        if (showVersionInfo &&
                            engineVersionStatus.consoleVersion != null) ...[
                          const SizedBox(height: 12),
                          HomeSettingsInfoRow(
                            label: '控制台版本',
                            value: engineVersionStatus.consoleVersion!,
                            onCopy: onCopyText,
                          ),
                        ],
                        for (final item in extraInfo) ...[
                          const SizedBox(height: 12),
                          HomeSettingsInfoRow(
                            label: item.label,
                            value: item.value,
                            onCopy: onCopyText,
                          ),
                        ],
                        if (versionHint != null) ...[
                          const SizedBox(height: 12),
                          _HomeCoreEngineVersionNotice(
                            status: engineVersionStatus,
                            message: versionHint,
                          ),
                        ],
                        if (status.lastError != null &&
                            status.lastError!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _HomeCoreErrorMessage(
                            message: status.lastError!,
                            warning: needsElevation || needsVpnPermission,
                            onCopy: onCopyText,
                          ),
                        ],
                        if (needsElevation || needsVpnPermission) ...[
                          const SizedBox(height: 12),
                          Text(
                            needsVpnPermission ? '需要 VPN 授权' : '需要管理员权限安装引擎',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: const Color(0xFF737373)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (needsElevation)
                      _HomeSettingsControlBoundary(
                        child: FButton(
                          onPress: () => unawaited(
                            coreLifecycleService.repairWithElevation(),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.admin_panel_settings, size: 16),
                              SizedBox(width: 8),
                              Text('以管理员身份运行'),
                            ],
                          ),
                        ),
                      ),
                    _HomeSettingsControlBoundary(
                      child: FButton(
                        variant: .outline,
                        onPress: () => unawaited(coreLifecycleService.repair()),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.refresh, size: 16),
                            const SizedBox(width: 8),
                            Text(actionLabel),
                          ],
                        ),
                      ),
                    ),
                    for (final action in extraActions)
                      _HomeSettingsControlBoundary(child: action),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _HomeSettingsSidebar extends StatelessWidget {
  const _HomeSettingsSidebar({
    required this.sections,
    required this.selectedId,
    required this.onSelect,
    required this.width,
  });

  final List<HomeSettingsSection> sections;
  final String? selectedId;
  final ValueChanged<HomeSettingsSection> onSelect;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F7),
        border: Border(right: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 12),
            child: Text(
              '设置',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          for (final section in sections)
            _HomeSettingsSidebarItem(
              section: section,
              selected: section.id == selectedId,
              onTap: () => onSelect(section),
            ),
        ],
      ),
    );
  }
}

class _HomeSettingsSidebarItem extends StatelessWidget {
  const _HomeSettingsSidebarItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final HomeSettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        key: ValueKey<String>('settings-sidebar-item-${section.title}'),
        color: selected ? const Color(0xFF007AFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: selected
              ? const Color(0xFF007AFF)
              : const Color(0xFFE5E5EA).withValues(alpha: 0.6),
          highlightColor: selected
              ? const Color(0xFF007AFF)
              : const Color(0xFFE5E5EA),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    section.icon,
                    size: 18,
                    color: selected ? Colors.white : const Color(0xFF3C3C43),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      section.title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: selected
                            ? Colors.white
                            : const Color(0xFF1C1C1E),
                        fontWeight: FontWeight.w600,
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

class _HomeSettingsDetailPane extends StatelessWidget {
  const _HomeSettingsDetailPane({
    required this.sections,
    required this.sectionKeys,
    required this.scrollController,
  });

  final List<HomeSettingsSection> sections;
  final Map<String, GlobalKey> sectionKeys;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return AppSmoothScrollView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < sections.length; i++) ...[
              if (i > 0) const SizedBox(height: 24),
              KeyedSubtree(
                key: sectionKeys[sections[i].id],
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HomeSettingsSectionHeader(title: sections[i].title),
                    const SizedBox(height: 16),
                    sections[i].builder(context),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HomeSettingsCompactScrollPage extends StatelessWidget {
  const _HomeSettingsCompactScrollPage({required this.sections});

  final List<HomeSettingsSection> sections;

  @override
  Widget build(BuildContext context) {
    return AppSmoothScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HomeSettingsSectionHeader(title: '设置'),
          const SizedBox(height: 16),
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: 24),
            HomeSettingsSectionHeader(title: sections[i].title),
            const SizedBox(height: 12),
            sections[i].builder(context),
          ],
        ],
      ),
    );
  }
}

class _HomeSettingsStatusDot extends StatelessWidget {
  const _HomeSettingsStatusDot({required this.online, this.color});

  final bool online;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final dotColor = color ?? (online ? const Color(0xFF16A34A) : Colors.grey);
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
    );
  }
}

class _HomeCoreErrorMessage extends StatelessWidget {
  const _HomeCoreErrorMessage({
    required this.message,
    required this.warning,
    required this.onCopy,
  });

  final String message;
  final bool warning;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '错误信息',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF737373)),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: warning
                        ? const Color(0xFFB45309)
                        : const Color(0xFFDC2626),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _HomeSettingsControlBoundary(
                child: FTooltip(
                  tipBuilder: (context, controller) => const Text('复制错误'),
                  child: FButton(
                    key: const ValueKey<String>('settings-core-error-copy'),
                    variant: .ghost,
                    size: .xs,
                    style: const .delta(
                      contentStyle: .delta(padding: .value(EdgeInsets.zero)),
                    ),
                    onPress: () => onCopy(message),
                    child: const Icon(Icons.copy, size: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HomeCoreEngineVersionNotice extends StatelessWidget {
  const _HomeCoreEngineVersionNotice({
    required this.status,
    required this.message,
  });

  final CoreEngineVersionStatus status;
  final String message;

  @override
  Widget build(BuildContext context) {
    final updateAvailable = status.updateAvailable;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: updateAvailable
            ? const Color(0xFFFFF7ED)
            : const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: updateAvailable
              ? const Color(0xFFFED7AA)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            updateAvailable ? Icons.system_update_alt : Icons.info_outline,
            size: 16,
            color: updateAvailable
                ? const Color(0xFFC2410C)
                : const Color(0xFF737373),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: updateAvailable
                    ? const Color(0xFF9A3412)
                    : const Color(0xFF737373),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeSettingsControlBoundary extends StatelessWidget {
  const _HomeSettingsControlBoundary({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(child: child);
  }
}

String _homeCoreEngineSettingsActionLabel(CoreEngineVersionStatus status) {
  return status.updateAvailable ? '更新连接引擎' : '重装连接引擎';
}

String? _homeCoreEngineVersionHint(CoreEngineVersionStatus status) {
  final installedVersion = status.installedVersion;
  final consoleVersion = status.consoleVersion;
  return switch (status.relation) {
    CoreEngineVersionRelation.updateAvailable =>
      installedVersion != null && consoleVersion != null
          ? '当前版本 $installedVersion，控制台推荐版本 $consoleVersion。'
          : '控制台推荐版本已有更新。',
    CoreEngineVersionRelation.current =>
      installedVersion != null
          ? '当前版本 $installedVersion，已是控制台推荐版本。'
          : '连接引擎已是控制台推荐版本。',
    CoreEngineVersionRelation.aheadOfConsole =>
      installedVersion != null && consoleVersion != null
          ? '当前版本 $installedVersion，控制台推荐版本 $consoleVersion。'
          : '当前连接引擎版本与控制台推荐版本不一致。',
    CoreEngineVersionRelation.unknown =>
      consoleVersion != null ? '控制台推荐版本 $consoleVersion。' : null,
  };
}
