part of 'workspace_home_view.dart';

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
    required this.appUpdateService,
  });

  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;
  final AppUpdateService appUpdateService;

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
    final result = await widget.appUpdateService.checkForUpdates();
    if (!mounted || !context.mounted) {
      return;
    }
    setState(() {
      _checkingForUpdates = false;
    });

    final (:message, :destructive) = _updateCheckFeedback(result.status);
    _showToast(context, message, destructive: destructive);
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
                const SizedBox(height: 16),
                _ControlSelectionBoundary(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FButton(
                        variant: .outline,
                        size: .sm,
                        onPress: () => unawaited(_exportLogs(dialogContext)),
                        child: const Text('导出诊断日志'),
                      ),
                      if (_canOpenLogDirectory)
                        FButton(
                          variant: .outline,
                          size: .sm,
                          onPress: () =>
                              unawaited(_openLogDirectory(dialogContext)),
                          child: const Text('打开日志目录'),
                        ),
                    ],
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
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final compact = constraints.maxWidth < 520;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(
              key: ValueKey<String>('settings-section-title'),
              title: '设置',
            ),
            SizedBox(height: compact ? 10 : 20),
            MasonryGridView.count(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: wide ? 2 : 1,
              mainAxisSpacing: compact ? 12 : 20,
              crossAxisSpacing: compact ? 12 : 20,
              itemCount: 4,
              itemBuilder: (context, index) {
                return switch (index) {
                  0 => FCard(
                    key: const ValueKey<String>('settings-account-card'),
                    title: const Text('账号'),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        FItemGroup(
                          divider: .full,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            _SettingsAccountItem(
                              prefix: const Icon(Icons.person_outline),
                              label: '用户',
                              primary: widget.user.effectiveName.isEmpty
                                  ? '用户'
                                  : widget.user.effectiveName,
                              secondary: widget.user.email.isEmpty
                                  ? '未提供邮箱'
                                  : widget.user.email,
                            ),
                            _SettingsAccountItem(
                              prefix: const Icon(Icons.apartment_outlined),
                              label: '工作区',
                              primary: widget.workspaceName,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _ControlSelectionBoundary(
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FButton(
                                variant: .outline,
                                onPress: () => unawaited(widget.onLogout()),
                                child: const Text('退出登录'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  1 => FCard(
                    key: const ValueKey<String>('settings-core-card'),
                    title: const Text('连接引擎'),
                    child: ValueListenableBuilder<CoreRunStatus>(
                      valueListenable: widget.coreLifecycleService.status,
                      builder: (context, status, _) {
                        final running = status.phase == CoreRunPhase.running;
                        final needsVpnPermission =
                            status.phase == CoreRunPhase.needsVpnPermission;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                _StatusDot(
                                  online: running,
                                  color:
                                      status.phase ==
                                              CoreRunPhase.needsElevation ||
                                          needsVpnPermission
                                      ? const Color(0xFFF59E0B)
                                      : null,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    status.message,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                            if (status.machineId != null &&
                                status.machineId!.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                'ID: ${status.machineId}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFF737373)),
                              ),
                            ],
                            if (status.lastError != null &&
                                status.lastError!.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8F9FB),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: const Color(0xFFE5E7EB),
                                  ),
                                ),
                                child: SelectableTextHitBoundary(
                                  child: SelectableText(
                                    status.lastError!,
                                    style: Theme.of(context).textTheme.bodySmall
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
                              ),
                              const SizedBox(height: 8),
                              _ControlSelectionBoundary(
                                child: FButton(
                                  variant: .outline,
                                  size: .sm,
                                  onPress: () => unawaited(
                                    _copyText(context, status.lastError!),
                                  ),
                                  child: const Text('复制错误'),
                                ),
                              ),
                            ],
                            if (status.phase == CoreRunPhase.needsElevation ||
                                needsVpnPermission) ...[
                              const SizedBox(height: 10),
                              Text(
                                needsVpnPermission ? '需要 VPN 授权' : '需要管理员权限',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFF737373)),
                              ),
                            ],
                            const SizedBox(height: 14),
                            _ControlSelectionBoundary(
                              child: Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  if (status.phase ==
                                      CoreRunPhase.needsElevation)
                                    FButton(
                                      variant: .primary,
                                      onPress: () => unawaited(
                                        widget.coreLifecycleService
                                            .repairWithElevation(),
                                      ),
                                      child: const Text('以管理员身份运行'),
                                    ),
                                  FButton(
                                    variant: .outline,
                                    onPress: () => unawaited(
                                      widget.coreLifecycleService.repair(),
                                    ),
                                    child: const Text('重试/修复'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  2 => FCard(
                    key: const ValueKey<String>('settings-app-card'),
                    title: const Text('应用信息'),
                    child: FutureBuilder<PackageInfo>(
                      future: _packageInfo,
                      builder: (context, snapshot) {
                        final info = snapshot.data;
                        return Column(
                          children: [
                            const SizedBox(height: 8),
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
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _updateSupportHint(),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFF737373)),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _ControlSelectionBoundary(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FButton(
                                  variant: .outline,
                                  onPress: _checkingForUpdates
                                      ? null
                                      : () => unawaited(
                                          _checkForUpdates(context),
                                        ),
                                  child: _checkingForUpdates
                                      ? const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            FCircularProgress(size: .xs),
                                            SizedBox(width: 8),
                                            Text('正在检查...'),
                                          ],
                                        )
                                      : const Text('检查更新'),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  _ => FCard(
                    key: const ValueKey<String>('settings-diagnostics-card'),
                    title: const Text('诊断日志'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        _ControlSelectionBoundary(
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FButton(
                                variant: .outline,
                                onPress: () =>
                                    unawaited(_showLogsDialog(context)),
                                child: const Text('查看日志'),
                              ),
                              FButton(
                                variant: .outline,
                                onPress: () => unawaited(_exportLogs(context)),
                                child: const Text('导出诊断日志'),
                              ),
                              if (_canOpenLogDirectory)
                                FButton(
                                  variant: .outline,
                                  onPress: () =>
                                      unawaited(_openLogDirectory(context)),
                                  child: const Text('打开日志目录'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                };
              },
            ),
          ],
        );
      },
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
