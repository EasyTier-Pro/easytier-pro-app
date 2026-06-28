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

  List<_SettingsCategory> get _categories => [
    _SettingsCategory.account,
    _SettingsCategory.core,
    if (homeSettingsCanConfigureWindowBehavior) _SettingsCategory.window,
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

  Future<void> _copyText(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      _showToast(context, '已复制到剪贴板');
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
      final feedback = await runHomeAppUpdateCheck(
        widget.appUpdateService,
        onError: (error, stack) {
          AppLogger.instance.error(
            'settings',
            'Update check failed',
            context: {'error': error.toString(), 'stack': stack.toString()},
          );
        },
      );
      if (!mounted || !context.mounted) {
        return;
      }
      _showToast(context, feedback.message, destructive: feedback.destructive);
    } finally {
      if (mounted) {
        setState(() {
          _checkingForUpdates = false;
        });
      }
    }
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
      _SettingsCategory.window => HomeWindowBehaviorSettingsSection(
        windowBehaviorPreferences: widget.windowBehaviorPreferences,
      ),
      _SettingsCategory.app => HomeAppSettingsSection(
        packageInfo: _packageInfo,
        checkingForUpdates: _checkingForUpdates,
        onCheckForUpdates: () => unawaited(_checkForUpdates(context)),
      ),
      _SettingsCategory.diagnostics => const HomeDiagnosticsSettingsSection(),
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
