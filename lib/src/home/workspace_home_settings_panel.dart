part of 'workspace_home_view.dart';

enum _SettingsCategory {
  account,
  core,
  window,
  diagnostics;

  String get title => switch (this) {
    account => '账号',
    core => '连接引擎',
    window => '窗口行为',
    diagnostics => '诊断日志',
  };

  IconData get icon => switch (this) {
    account => Icons.person_outline,
    core => Icons.memory_outlined,
    window => Icons.web_asset_outlined,
    diagnostics => Icons.description_outlined,
  };
}

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
    required this.windowBehaviorPreferences,
  });

  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;
  final WindowBehaviorPreferences windowBehaviorPreferences;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  _SettingsCategory _selectedCategory = _SettingsCategory.account;

  static const MethodChannel _androidDiagnosticsChannel = MethodChannel(
    'net.easytier.pro/core_runtime',
  );
  static const double _sidebarWidth = 220;
  static const double _splitBreakpoint = 720;

  bool get _canOpenLogDirectory =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  bool get _canConfigureWindowBehavior =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  List<_SettingsCategory> get _categories => [
    _SettingsCategory.account,
    _SettingsCategory.core,
    if (_canConfigureWindowBehavior) _SettingsCategory.window,
    _SettingsCategory.diagnostics,
  ];

  void _showToast(
    BuildContext context,
    String message, {
    bool destructive = false,
  }) {
    _showWorkspaceToast(context, message, destructive: destructive);
  }

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final file = await AppLogger.instance.exportDiagnostics();
      final shared = await _shareDiagnosticsFile(file);
      AppLogger.instance.info(
        'settings',
        'Diagnostics exported',
        context: {'file': file.path, 'shared': shared},
      );
      if (context.mounted) {
        _showToast(
          context,
          shared ? '诊断日志已生成，请在分享面板中发送文件' : '诊断日志已导出: ${file.path}',
        );
      }
    } catch (error) {
      AppLogger.instance.error(
        'settings',
        'Diagnostics export failed',
        context: {'error': error.toString()},
      );
      if (context.mounted) {
        _showToast(context, '导出诊断日志失败', destructive: true);
      }
    }
  }

  Future<bool> _shareDiagnosticsFile(File file) async {
    if (!Platform.isAndroid) {
      return false;
    }
    await _androidDiagnosticsChannel.invokeMethod<bool>('shareFile', {
      'path': file.path,
      'mimeType': 'text/plain',
      'title': '分享 EasyTier Pro 诊断日志',
    });
    return true;
  }

  Future<void> _copyText(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      _showToast(context, '已复制到剪贴板');
    }
  }

  Future<void> _openLogDirectory(BuildContext context) async {
    final path = AppLogger.instance.logDirectoryPath;
    if (path == null || path.isEmpty) {
      if (context.mounted) {
        _showToast(context, '日志目录尚未初始化', destructive: true);
      }
      return;
    }
    try {
      late final List<String> command;
      if (Platform.isWindows) {
        command = ['explorer', path];
      } else if (Platform.isMacOS) {
        command = ['open', path];
      } else {
        command = ['xdg-open', path];
      }
      await Process.run(command.first, command.skip(1).toList());
    } catch (error) {
      if (context.mounted) {
        _showToast(context, '打开日志目录失败', destructive: true);
      }
    }
  }

  Future<void> _showLogsDialog(BuildContext context) async {
    await showFDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext, _, animation) => ExcludeSemantics(
        child: FDialog.raw(
          animation: animation,
          constraints: const BoxConstraints(
            minWidth: 600,
            maxWidth: 800,
            maxHeight: 520,
          ),
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('诊断日志', style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    _ControlSelectionBoundary(
                      child: ExcludeSemantics(
                        child: FPopoverMenu(
                          menuAnchor: Alignment.topRight,
                          childAnchor: Alignment.bottomRight,
                          divider: FItemDivider.none,
                          menuBuilder: (context, controller, menu) => [
                            FItemGroup(
                              divider: FItemDivider.none,
                              children: [
                                FItem(
                                  prefix: const Icon(
                                    Icons.download_outlined,
                                    size: 18,
                                    color: Color(0xFF64748B),
                                  ),
                                  title: Text(
                                    '导出诊断日志',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  onPress: () {
                                    unawaited(controller.hide());
                                    unawaited(_exportLogs(dialogContext));
                                  },
                                ),
                                if (_canOpenLogDirectory)
                                  FItem(
                                    prefix: const Icon(
                                      Icons.folder_open_outlined,
                                      size: 18,
                                      color: Color(0xFF64748B),
                                    ),
                                    title: Text(
                                      '打开日志目录',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    onPress: () {
                                      unawaited(controller.hide());
                                      unawaited(
                                        _openLogDirectory(dialogContext),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ],
                          builder: (context, controller, child) => Tooltip(
                            message: '更多操作',
                            excludeFromSemantics: true,
                            child: FButton(
                              variant: .ghost,
                              size: .sm,
                              onPress: () => unawaited(controller.toggle()),
                              mainAxisSize: MainAxisSize.min,
                              child: const Icon(Icons.more_vert, size: 18),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ControlSelectionBoundary(
                      child: FButton(
                        variant: .ghost,
                        size: .sm,
                        onPress: () {
                          if (Navigator.of(context).canPop()) {
                            Navigator.of(context).pop();
                          }
                        },
                        child: const Icon(Icons.close, size: 18),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ValueListenableBuilder<List<AppLogEntry>>(
                    valueListenable: AppLogger.instance.recentEntries,
                    builder: (context, entries, _) {
                      if (entries.isEmpty) {
                        return const Center(child: Text('暂无日志'));
                      }
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F9FB),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            entries.map((entry) => entry.humanLine).join('\n'),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: const Color(0xFF374151),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectCategory(_SettingsCategory category) {
    setState(() {
      _selectedCategory = category;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _splitBreakpoint;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingsSidebar(
                categories: _categories,
                selected: _selectedCategory,
                onSelect: _selectCategory,
                width: _sidebarWidth,
              ),
              Expanded(
                child: _SettingsDetailPane(
                  category: _selectedCategory,
                  user: widget.user,
                  workspaceName: widget.workspaceName,
                  onLogout: widget.onLogout,
                  coreLifecycleService: widget.coreLifecycleService,
                  windowBehaviorPreferences: widget.windowBehaviorPreferences,
                  canOpenLogDirectory: _canOpenLogDirectory,
                  onExportLogs: () => unawaited(_exportLogs(context)),
                  onOpenLogDirectory: () => unawaited(_openLogDirectory(context)),
                  onShowLogsDialog: () => unawaited(_showLogsDialog(context)),
                  onCopyText: (value) => unawaited(_copyText(context, value)),
                ),
              ),
            ],
          );
        }

        return _SettingsCompactScrollPage(
          categories: _categories,
          user: widget.user,
          workspaceName: widget.workspaceName,
          onLogout: widget.onLogout,
          coreLifecycleService: widget.coreLifecycleService,
          windowBehaviorPreferences: widget.windowBehaviorPreferences,
          canOpenLogDirectory: _canOpenLogDirectory,
          onExportLogs: () => unawaited(_exportLogs(context)),
          onOpenLogDirectory: () => unawaited(_openLogDirectory(context)),
          onShowLogsDialog: () => unawaited(_showLogsDialog(context)),
          onCopyText: (value) => unawaited(_copyText(context, value)),
        );
      },
    );
  }
}

class _SettingsSidebar extends StatelessWidget {
  const _SettingsSidebar({
    required this.categories,
    required this.selected,
    required this.onSelect,
    required this.width,
  });

  final List<_SettingsCategory> categories;
  final _SettingsCategory selected;
  final ValueChanged<_SettingsCategory> onSelect;
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
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          for (final category in categories)
            _SettingsSidebarItem(
              category: category,
              selected: category == selected,
              onTap: () => onSelect(category),
            ),
        ],
      ),
    );
  }
}

class _SettingsSidebarItem extends StatelessWidget {
  const _SettingsSidebarItem({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final _SettingsCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
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
                    category.icon,
                    size: 18,
                    color: selected ? Colors.white : const Color(0xFF3C3C43),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      category.title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: selected ? Colors.white : const Color(0xFF1C1C1E),
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

class _SettingsDetailPane extends StatelessWidget {
  const _SettingsDetailPane({
    required this.category,
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
    required this.windowBehaviorPreferences,
    required this.canOpenLogDirectory,
    required this.onExportLogs,
    required this.onOpenLogDirectory,
    required this.onShowLogsDialog,
    required this.onCopyText,
  });

  final _SettingsCategory category;
  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;
  final WindowBehaviorPreferences windowBehaviorPreferences;
  final bool canOpenLogDirectory;
  final VoidCallback onExportLogs;
  final VoidCallback onOpenLogDirectory;
  final VoidCallback onShowLogsDialog;
  final ValueChanged<String> onCopyText;

  @override
  Widget build(BuildContext context) {
    return AppSmoothScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SettingsSectionHeader(title: category.title),
            const SizedBox(height: 20),
            buildSectionContent(
              context: context,
              category: category,
              user: user,
              workspaceName: workspaceName,
              onLogout: onLogout,
              coreLifecycleService: coreLifecycleService,
              windowBehaviorPreferences: windowBehaviorPreferences,
              canOpenLogDirectory: canOpenLogDirectory,
              onExportLogs: onExportLogs,
              onOpenLogDirectory: onOpenLogDirectory,
              onShowLogsDialog: onShowLogsDialog,
              onCopyText: onCopyText,
            ),
          ],
        ),
      ),
    );
  }

  static Widget buildSectionContent({
    required BuildContext context,
    required _SettingsCategory category,
    required ConsoleUser user,
    required String workspaceName,
    required Future<void> Function() onLogout,
    required CoreLifecycleService coreLifecycleService,
    required WindowBehaviorPreferences windowBehaviorPreferences,
    required bool canOpenLogDirectory,
    required VoidCallback onExportLogs,
    required VoidCallback onOpenLogDirectory,
    required VoidCallback onShowLogsDialog,
    required ValueChanged<String> onCopyText,
  }) {
    return switch (category) {
      _SettingsCategory.account => _AccountSettingsSection(
        user: user,
        workspaceName: workspaceName,
        onLogout: onLogout,
      ),
      _SettingsCategory.core => _CoreSettingsSection(
        coreLifecycleService: coreLifecycleService,
        onCopyText: onCopyText,
      ),
      _SettingsCategory.window => _WindowBehaviorSettingsSection(
        windowBehaviorPreferences: windowBehaviorPreferences,
      ),
      _SettingsCategory.diagnostics => _DiagnosticsSettingsSection(
        canOpenLogDirectory: canOpenLogDirectory,
        onExportLogs: onExportLogs,
        onOpenLogDirectory: onOpenLogDirectory,
        onShowLogsDialog: onShowLogsDialog,
      ),
    };
  }
}

class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _SettingsCompactScrollPage extends StatelessWidget {
  const _SettingsCompactScrollPage({
    required this.categories,
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
    required this.windowBehaviorPreferences,
    required this.canOpenLogDirectory,
    required this.onExportLogs,
    required this.onOpenLogDirectory,
    required this.onShowLogsDialog,
    required this.onCopyText,
  });

  final List<_SettingsCategory> categories;
  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;
  final WindowBehaviorPreferences windowBehaviorPreferences;
  final bool canOpenLogDirectory;
  final VoidCallback onExportLogs;
  final VoidCallback onOpenLogDirectory;
  final VoidCallback onShowLogsDialog;
  final ValueChanged<String> onCopyText;

  @override
  Widget build(BuildContext context) {
    return AppSmoothScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsSectionHeader(title: '设置'),
          const SizedBox(height: 20),
          for (var i = 0; i < categories.length; i++) ...[
            if (i > 0) const SizedBox(height: 24),
            _SettingsSectionHeader(title: categories[i].title),
            const SizedBox(height: 12),
            _SettingsDetailPane.buildSectionContent(
              context: context,
              category: categories[i],
              user: user,
              workspaceName: workspaceName,
              onLogout: onLogout,
              coreLifecycleService: coreLifecycleService,
              windowBehaviorPreferences: windowBehaviorPreferences,
              canOpenLogDirectory: canOpenLogDirectory,
              onExportLogs: onExportLogs,
              onOpenLogDirectory: onOpenLogDirectory,
              onShowLogsDialog: onShowLogsDialog,
              onCopyText: onCopyText,
            ),
          ],
        ],
      ),
    );
  }
}

class _AccountSettingsSection extends StatelessWidget {
  const _AccountSettingsSection({
    required this.user,
    required this.workspaceName,
    required this.onLogout,
  });

  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FCard.raw(
          child: FItemGroup(
            divider: .full,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _SettingsAccountItem(
                prefix: const Icon(Icons.person_outline),
                label: '用户',
                primary: user.effectiveName.isEmpty ? '用户' : user.effectiveName,
                secondary: user.email.isEmpty ? '未提供邮箱' : user.email,
              ),
              _SettingsAccountItem(
                prefix: const Icon(Icons.apartment_outlined),
                label: '工作区',
                primary: workspaceName,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _ControlSelectionBoundary(
              child: FButton(
                variant: .outline,
                onPress: () => unawaited(onLogout()),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.logout, size: 16),
                    SizedBox(width: 8),
                    Text('退出登录'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CoreSettingsSection extends StatelessWidget {
  const _CoreSettingsSection({
    required this.coreLifecycleService,
    required this.onCopyText,
  });

  final CoreLifecycleService coreLifecycleService;
  final ValueChanged<String> onCopyText;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CoreRunStatus>(
      valueListenable: coreLifecycleService.status,
      builder: (context, status, _) {
        final running = status.phase == CoreRunPhase.running;
        final needsVpnPermission =
            status.phase == CoreRunPhase.needsVpnPermission;
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
                        _StatusDot(
                          online: running,
                          color:
                              status.phase == CoreRunPhase.needsElevation ||
                                      needsVpnPermission
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
                    if (status.machineId != null &&
                        status.machineId!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _SettingsInfoRow(
                        label: '设备 ID',
                        value: status.machineId!,
                        onCopy: onCopyText,
                      ),
                    ],
                    if (status.lastError != null &&
                        status.lastError!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
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
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFF737373)),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    status.lastError!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color:
                                              status.phase ==
                                                          CoreRunPhase
                                                              .needsElevation ||
                                                      needsVpnPermission
                                                  ? const Color(0xFFB45309)
                                                  : const Color(0xFFDC2626),
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _ControlSelectionBoundary(
                                  child: FTooltip(
                                    tipBuilder:
                                        (context, controller) =>
                                            const Text('复制错误'),
                                    child: FButton(
                                      key: const ValueKey<String>(
                                        'settings-core-error-copy',
                                      ),
                                      variant: .ghost,
                                      size: .xs,
                                      style: const .delta(
                                        contentStyle: .delta(
                                          padding: .value(EdgeInsets.zero),
                                        ),
                                      ),
                                      onPress: () => onCopyText(status.lastError!),
                                      child: const Icon(Icons.copy, size: 14),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (status.phase == CoreRunPhase.needsElevation ||
                        needsVpnPermission) ...[
                      const SizedBox(height: 12),
                      Text(
                        needsVpnPermission
                            ? '需要 VPN 授权'
                            : '需要管理员权限安装引擎',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF737373),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (status.phase == CoreRunPhase.needsElevation) ...[
                  _ControlSelectionBoundary(
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
                  const SizedBox(width: 12),
                ],
                _ControlSelectionBoundary(
                  child: FButton(
                    variant: .outline,
                    onPress: () => unawaited(coreLifecycleService.repair()),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh, size: 16),
                        SizedBox(width: 8),
                        Text('重试 / 修复'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _WindowBehaviorSettingsSection extends StatelessWidget {
  const _WindowBehaviorSettingsSection({
    required this.windowBehaviorPreferences,
  });

  final WindowBehaviorPreferences windowBehaviorPreferences;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: windowBehaviorPreferences,
      builder: (context, _) {
        return FCard.raw(
          key: const ValueKey<String>('settings-window-behavior-card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.web_asset_outlined, color: Color(0xFF3C3C43)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '最小化窗口时隐藏到托盘',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF0F172A),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '关闭窗口仍会隐藏到托盘，可从托盘菜单退出应用。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF737373),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _ControlSelectionBoundary(
                  child: FSwitch(
                    value: windowBehaviorPreferences.minimizeToTray,
                    onChange: (value) => unawaited(
                      windowBehaviorPreferences.setMinimizeToTray(value),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DiagnosticsSettingsSection extends StatelessWidget {
  const _DiagnosticsSettingsSection({
    required this.canOpenLogDirectory,
    required this.onExportLogs,
    required this.onOpenLogDirectory,
    required this.onShowLogsDialog,
  });

  final bool canOpenLogDirectory;
  final VoidCallback onExportLogs;
  final VoidCallback onOpenLogDirectory;
  final VoidCallback onShowLogsDialog;

  @override
  Widget build(BuildContext context) {
    return FTileGroup(
      divider: .full,
      children: [
        FTile(
          prefix: const Icon(
            Icons.description_outlined,
            size: 22,
            color: Color(0xFF3C3C43),
          ),
          title: Text(
            '查看日志',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '在弹窗中查看最近的应用日志',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF737373),
            ),
          ),
          suffix: const Icon(
            Icons.chevron_right,
            size: 20,
            color: Color(0xFF9CA3AF),
          ),
          onPress: onShowLogsDialog,
        ),
        FTile(
          prefix: const Icon(
            Icons.download_outlined,
            size: 22,
            color: Color(0xFF3C3C43),
          ),
          title: Text(
            '导出诊断日志',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '将日志打包为文件以便分享',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF737373),
            ),
          ),
          suffix: const Icon(
            Icons.chevron_right,
            size: 20,
            color: Color(0xFF9CA3AF),
          ),
          onPress: onExportLogs,
        ),
        if (canOpenLogDirectory)
          FTile(
            prefix: const Icon(
              Icons.folder_open_outlined,
              size: 22,
              color: Color(0xFF3C3C43),
            ),
            title: Text(
              '打开日志目录',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              '在文件管理器中查看日志文件夹',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF737373),
              ),
            ),
            suffix: const Icon(
              Icons.chevron_right,
              size: 20,
              color: Color(0xFF9CA3AF),
            ),
            onPress: onOpenLogDirectory,
          ),
      ],
    );
  }
}

class _SettingsInfoRow extends StatelessWidget {
  const _SettingsInfoRow({
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
        _ControlSelectionBoundary(
          child: FTooltip(
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
        ),
      ],
    );
  }
}

class _SettingsAccountItem extends StatelessWidget with FItemMixin {
  const _SettingsAccountItem({
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
