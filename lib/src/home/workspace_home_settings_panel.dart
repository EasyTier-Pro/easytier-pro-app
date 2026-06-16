part of 'workspace_home_view.dart';

enum _SettingsCategory {
  account,
  core,
  window,
  app,
  diagnostics;

  String get title => switch (this) {
    account => '账号',
    core => '连接引擎',
    window => '窗口行为',
    app => '应用信息',
    diagnostics => '诊断日志',
  };

  IconData get icon => switch (this) {
    account => Icons.person_outline,
    core => Icons.memory_outlined,
    window => Icons.web_asset_outlined,
    app => Icons.apps_outlined,
    diagnostics => Icons.description_outlined,
  };
}

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
    required this.appUpdateService,
    required this.windowBehaviorPreferences,
  });

  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;
  final AppUpdateService appUpdateService;
  final WindowBehaviorPreferences windowBehaviorPreferences;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  bool _checkingForUpdates = false;
  _SettingsCategory _selectedCategory = _SettingsCategory.account;
  final ScrollController _scrollController = ScrollController();
  final Map<_SettingsCategory, GlobalKey> _categoryKeys = {};
  bool _isScrollingToCategory = false;

  static const MethodChannel _androidDiagnosticsChannel = MethodChannel(
    'net.easytier.pro/core_runtime',
  );
  static const double _sidebarWidth = 220;
  static const double _splitBreakpoint = 720;
  static const double _categoryScrollAlignment = 0.05;

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
    _SettingsCategory.app,
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

  Future<void> _checkForUpdates(BuildContext context) async {
    if (_checkingForUpdates) {
      return;
    }
    setState(() {
      _checkingForUpdates = true;
    });
    try {
      final result = await widget.appUpdateService.checkForUpdates();
      if (!mounted || !context.mounted) {
        return;
      }

      final (:message, :destructive) = _updateCheckFeedback(result.status);
      _showToast(context, message, destructive: destructive);
    } catch (error, stack) {
      AppLogger.instance.error(
        'settings',
        'Update check failed',
        context: {'error': error.toString(), 'stack': stack.toString()},
      );
      if (mounted && context.mounted) {
        final (:message, :destructive) = _updateCheckFeedback(
          AppUpdateCheckStatus.failed,
        );
        _showToast(context, message, destructive: destructive);
      }
    } finally {
      if (mounted) {
        setState(() {
          _checkingForUpdates = false;
        });
      }
    }
  }

  ({String message, bool destructive}) _updateCheckFeedback(
    AppUpdateCheckStatus status,
  ) {
    return switch (status) {
      AppUpdateCheckStatus.started => (message: '已开始检查更新', destructive: false),
      AppUpdateCheckStatus.unsupportedPlatform => (
        message: '当前平台暂不支持应用内更新检查',
        destructive: false,
      ),
      AppUpdateCheckStatus.noFeedConfigured => (
        message: '暂未配置更新检查服务',
        destructive: false,
      ),
      AppUpdateCheckStatus.noReachableFeed => (
        message: '无法连接更新源，请稍后重试',
        destructive: true,
      ),
      AppUpdateCheckStatus.failed => (
        message: '检查更新失败，请稍后重试',
        destructive: true,
      ),
    };
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
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
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
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

  @override
  void initState() {
    super.initState();
    for (final category in _categories) {
      _categoryKeys[category] = GlobalKey();
    }
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _selectCategory(_SettingsCategory category) {
    _scrollToCategory(category);
  }

  void _scrollToCategory(_SettingsCategory category) {
    final key = _categoryKeys[category];
    if (key == null) {
      return;
    }
    final context = key.currentContext;
    if (context == null) {
      setState(() {
        _selectedCategory = category;
      });
      return;
    }
    _isScrollingToCategory = true;
    Scrollable.ensureVisible(
      context,
      duration: appMotionMedium,
      curve: appMotionCurve,
      alignment: _categoryScrollAlignment,
    ).whenComplete(() {
      if (mounted) {
        setState(() {
          _isScrollingToCategory = false;
          _selectedCategory = category;
        });
      }
    });
  }

  void _onScroll() {
    if (_isScrollingToCategory) {
      return;
    }
    final scrollPosition = _scrollController.position;
    final viewportDimension = scrollPosition.viewportDimension;
    if (viewportDimension <= 0) {
      return;
    }
    final viewportTop = scrollPosition.pixels;
    final viewportCenter = viewportTop + (viewportDimension * 0.35);

    _SettingsCategory? closestCategory;
    var closestDistance = double.infinity;
    for (final category in _categories) {
      final key = _categoryKeys[category];
      if (key == null) {
        continue;
      }
      final context = key.currentContext;
      if (context == null) {
        continue;
      }
      final renderBox = context.findRenderObject();
      if (renderBox is! RenderBox) {
        continue;
      }
      final scrollable = Scrollable.maybeOf(context);
      if (scrollable == null) {
        continue;
      }
      final scrollablePosition = scrollable.position;
      final scrollableBox = scrollable.context.findRenderObject();
      if (scrollableBox is! RenderBox) {
        continue;
      }
      final categoryOffset = renderBox.localToGlobal(Offset.zero);
      final scrollableOffset = scrollableBox.localToGlobal(Offset.zero);
      final categoryTop =
          categoryOffset.dy - scrollableOffset.dy + scrollablePosition.pixels;
      final distance = (categoryTop - viewportCenter).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        closestCategory = category;
      }
    }

    if (closestCategory != null && closestCategory != _selectedCategory) {
      setState(() {
        _selectedCategory = closestCategory!;
      });
    }
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
                  categories: _categories,
                  categoryKeys: _categoryKeys,
                  scrollController: _scrollController,
                  user: widget.user,
                  workspaceName: widget.workspaceName,
                  onLogout: widget.onLogout,
                  coreLifecycleService: widget.coreLifecycleService,
                  windowBehaviorPreferences: widget.windowBehaviorPreferences,
                  packageInfo: _packageInfo,
                  checkingForUpdates: _checkingForUpdates,
                  canOpenLogDirectory: _canOpenLogDirectory,
                  onCheckForUpdates: () => unawaited(_checkForUpdates(context)),
                  onExportLogs: () => unawaited(_exportLogs(context)),
                  onOpenLogDirectory: () =>
                      unawaited(_openLogDirectory(context)),
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
          packageInfo: _packageInfo,
          checkingForUpdates: _checkingForUpdates,
          canOpenLogDirectory: _canOpenLogDirectory,
          onCheckForUpdates: () => unawaited(_checkForUpdates(context)),
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
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
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
        key: ValueKey<String>('settings-sidebar-item-${category.title}'),
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

class _SettingsDetailPane extends StatelessWidget {
  const _SettingsDetailPane({
    required this.categories,
    required this.categoryKeys,
    required this.scrollController,
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
    required this.windowBehaviorPreferences,
    required this.packageInfo,
    required this.checkingForUpdates,
    required this.canOpenLogDirectory,
    required this.onCheckForUpdates,
    required this.onExportLogs,
    required this.onOpenLogDirectory,
    required this.onShowLogsDialog,
    required this.onCopyText,
  });

  final List<_SettingsCategory> categories;
  final Map<_SettingsCategory, GlobalKey> categoryKeys;
  final ScrollController scrollController;
  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;
  final WindowBehaviorPreferences windowBehaviorPreferences;
  final Future<PackageInfo> packageInfo;
  final bool checkingForUpdates;
  final bool canOpenLogDirectory;
  final VoidCallback onCheckForUpdates;
  final VoidCallback onExportLogs;
  final VoidCallback onOpenLogDirectory;
  final VoidCallback onShowLogsDialog;
  final ValueChanged<String> onCopyText;

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
            for (var i = 0; i < categories.length; i++) ...[
              if (i > 0) const SizedBox(height: 24),
              KeyedSubtree(
                key: categoryKeys[categories[i]],
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SettingsSectionHeader(title: categories[i].title),
                    const SizedBox(height: 16),
                    buildSectionContent(
                      context: context,
                      category: categories[i],
                      user: user,
                      workspaceName: workspaceName,
                      onLogout: onLogout,
                      coreLifecycleService: coreLifecycleService,
                      windowBehaviorPreferences: windowBehaviorPreferences,
                      packageInfo: packageInfo,
                      checkingForUpdates: checkingForUpdates,
                      canOpenLogDirectory: canOpenLogDirectory,
                      onCheckForUpdates: onCheckForUpdates,
                      onExportLogs: onExportLogs,
                      onOpenLogDirectory: onOpenLogDirectory,
                      onShowLogsDialog: onShowLogsDialog,
                      onCopyText: onCopyText,
                    ),
                  ],
                ),
              ),
            ],
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
    required Future<PackageInfo> packageInfo,
    required bool checkingForUpdates,
    required bool canOpenLogDirectory,
    required VoidCallback onCheckForUpdates,
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
      _SettingsCategory.app => _AppSettingsSection(
        packageInfo: packageInfo,
        checkingForUpdates: checkingForUpdates,
        onCheckForUpdates: onCheckForUpdates,
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
      style: Theme.of(
        context,
      ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
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
    required this.packageInfo,
    required this.checkingForUpdates,
    required this.canOpenLogDirectory,
    required this.onCheckForUpdates,
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
  final Future<PackageInfo> packageInfo;
  final bool checkingForUpdates;
  final bool canOpenLogDirectory;
  final VoidCallback onCheckForUpdates;
  final VoidCallback onExportLogs;
  final VoidCallback onOpenLogDirectory;
  final VoidCallback onShowLogsDialog;
  final ValueChanged<String> onCopyText;

  @override
  Widget build(BuildContext context) {
    return AppSmoothScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingsSectionHeader(title: '设置'),
          const SizedBox(height: 16),
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
              packageInfo: packageInfo,
              checkingForUpdates: checkingForUpdates,
              canOpenLogDirectory: canOpenLogDirectory,
              onCheckForUpdates: onCheckForUpdates,
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
        return ValueListenableBuilder<CoreEngineVersionStatus>(
          valueListenable: coreLifecycleService.engineVersionStatus,
          builder: (context, engineVersionStatus, _) {
            final running = status.phase == CoreRunPhase.running;
            final needsVpnPermission =
                status.phase == CoreRunPhase.needsVpnPermission;
            final versionHint = _coreEngineVersionHint(engineVersionStatus);
            final actionLabel = _coreEngineSettingsActionLabel(
              engineVersionStatus,
            );
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
                        if (engineVersionStatus.installedVersion != null) ...[
                          const SizedBox(height: 12),
                          _SettingsInfoRow(
                            label: '当前版本',
                            value: engineVersionStatus.installedVersion!,
                            onCopy: onCopyText,
                          ),
                        ],
                        if (engineVersionStatus.consoleVersion != null) ...[
                          const SizedBox(height: 12),
                          _SettingsInfoRow(
                            label: '控制台版本',
                            value: engineVersionStatus.consoleVersion!,
                            onCopy: onCopyText,
                          ),
                        ],
                        if (versionHint != null) ...[
                          const SizedBox(height: 12),
                          _CoreEngineVersionNotice(
                            status: engineVersionStatus,
                            message: versionHint,
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
                              border: Border.all(
                                color: const Color(0xFFE5E7EB),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '错误信息',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: const Color(0xFF737373),
                                      ),
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
                                        tipBuilder: (context, controller) =>
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
                                          onPress: () =>
                                              onCopyText(status.lastError!),
                                          child: const Icon(
                                            Icons.copy,
                                            size: 14,
                                          ),
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

class _CoreEngineVersionNotice extends StatelessWidget {
  const _CoreEngineVersionNotice({required this.status, required this.message});

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

class _AppSettingsSection extends StatelessWidget {
  const _AppSettingsSection({
    required this.packageInfo,
    required this.checkingForUpdates,
    required this.onCheckForUpdates,
  });

  final Future<PackageInfo> packageInfo;
  final bool checkingForUpdates;
  final VoidCallback onCheckForUpdates;

  @override
  Widget build(BuildContext context) {
    return FCard.raw(
      key: const ValueKey<String>('settings-app-card'),
      child: FutureBuilder<PackageInfo>(
        future: packageInfo,
        builder: (context, snapshot) {
          final info = snapshot.data;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FItemGroup(
                  divider: .full,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _SettingsAccountItem(
                      prefix: const Icon(Icons.apps_outlined),
                      label: '应用',
                      primary: _appDisplayName(info),
                    ),
                    _SettingsAccountItem(
                      prefix: const Icon(Icons.info_outline),
                      label: '版本',
                      primary: _appVersionText(snapshot),
                      secondary: _platformLabel(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  _updateSupportHint(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF737373),
                  ),
                ),
                const SizedBox(height: 12),
                _ControlSelectionBoundary(
                  child: FButton(
                    variant: .outline,
                    onPress: checkingForUpdates ? null : onCheckForUpdates,
                    child: checkingForUpdates
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FCircularProgress(size: .xs),
                              SizedBox(width: 8),
                              Text('正在检查...'),
                            ],
                          )
                        : const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.refresh, size: 16),
                              SizedBox(width: 8),
                              Text('检查更新'),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _appDisplayName(PackageInfo? info) {
    final appName = info?.appName.trim();
    if (appName != null && appName.isNotEmpty) {
      return appName;
    }
    return 'EasyTier Pro';
  }

  String _appVersionText(AsyncSnapshot<PackageInfo> snapshot) {
    if (snapshot.hasError) {
      return '版本信息不可用';
    }
    final info = snapshot.data;
    if (info == null) {
      return '正在读取版本...';
    }

    final version = info.version.trim();
    final buildNumber = info.buildNumber.trim();
    if (version.isEmpty && buildNumber.isEmpty) {
      return '版本信息不可用';
    }
    if (version.isEmpty) {
      return 'build $buildNumber';
    }

    final displayVersion = version.startsWith('v') ? version : 'v$version';
    if (buildNumber.isEmpty || buildNumber == version) {
      return displayVersion;
    }
    return '$displayVersion (build $buildNumber)';
  }

  String _platformLabel() {
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
    return '平台：$platform';
  }

  String _updateSupportHint() {
    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows) {
      return '通过已配置的更新源检查桌面客户端版本。';
    }
    return '当前平台暂不支持应用内更新检查。';
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
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '在弹窗中查看最近的应用日志',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF737373)),
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
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '将日志打包为文件以便分享',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF737373)),
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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '在文件管理器中查看日志文件夹',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF737373)),
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
