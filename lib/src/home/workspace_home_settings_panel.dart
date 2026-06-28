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

  static const MethodChannel _androidDiagnosticsChannel = MethodChannel(
    'net.easytier.pro/core_runtime',
  );

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

      final feedback = homeAppUpdateCheckFeedback(result.status);
      _showToast(context, feedback.message, destructive: feedback.destructive);
    } catch (error, stack) {
      AppLogger.instance.error(
        'settings',
        'Update check failed',
        context: {'error': error.toString(), 'stack': stack.toString()},
      );
      if (mounted && context.mounted) {
        final feedback = homeAppUpdateCheckFeedback(
          AppUpdateCheckStatus.failed,
        );
        _showToast(
          context,
          feedback.message,
          destructive: feedback.destructive,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _checkingForUpdates = false;
        });
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
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HomeSettingsPage(
      sections: [
        for (final category in _categories)
          HomeSettingsSection(
            id: category.name,
            title: category.title,
            icon: category.icon,
            builder: (context) => _buildSectionContent(context, category),
          ),
      ],
    );
  }

  Widget _buildSectionContent(
    BuildContext context,
    _SettingsCategory category,
  ) {
    return switch (category) {
      _SettingsCategory.account => _AccountSettingsSection(
        user: widget.user,
        workspaceName: widget.workspaceName,
        onLogout: widget.onLogout,
      ),
      _SettingsCategory.core => HomeCoreSettingsSection(
        coreLifecycleService: widget.coreLifecycleService,
        onCopyText: (value) => unawaited(_copyText(context, value)),
      ),
      _SettingsCategory.window => _WindowBehaviorSettingsSection(
        windowBehaviorPreferences: widget.windowBehaviorPreferences,
      ),
      _SettingsCategory.app => HomeAppSettingsSection(
        packageInfo: _packageInfo,
        checkingForUpdates: _checkingForUpdates,
        onCheckForUpdates: () => unawaited(_checkForUpdates(context)),
      ),
      _SettingsCategory.diagnostics => _DiagnosticsSettingsSection(
        canOpenLogDirectory: _canOpenLogDirectory,
        onExportLogs: () => unawaited(_exportLogs(context)),
        onOpenLogDirectory: () => unawaited(_openLogDirectory(context)),
        onShowLogsDialog: () => unawaited(_showLogsDialog(context)),
      ),
    };
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
              HomeSettingsAccountItem(
                prefix: const Icon(Icons.person_outline),
                label: '用户',
                primary: user.effectiveName.isEmpty ? '用户' : user.effectiveName,
                secondary: user.email.isEmpty ? '未提供邮箱' : user.email,
              ),
              HomeSettingsAccountItem(
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
