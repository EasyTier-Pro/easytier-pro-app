part of 'workspace_home_view.dart';

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.user,
    required this.workspaceName,
    required this.onLogout,
    required this.coreLifecycleService,
  });

  final ConsoleUser user;
  final String workspaceName;
  final Future<void> Function() onLogout;
  final CoreLifecycleService coreLifecycleService;

  void _showToast(
    BuildContext context,
    String message, {
    bool destructive = false,
  }) {
    showRawFToast(
      context: context,
      variant: destructive ? .destructive : .primary,
      builder: (context, entry) => ExcludeSemantics(
        child: FToast(
          variant: destructive ? .destructive : .primary,
          title: Text(message),
        ),
      ),
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final file = await AppLogger.instance.exportDiagnostics();
      AppLogger.instance.info(
        'settings',
        'Diagnostics exported',
        context: {'file': file.path},
      );
      if (context.mounted) {
        _showToast(context, '诊断日志已导出: ${file.path}');
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '设置'),
            const SizedBox(height: 20),
            MasonryGridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: wide ? 2 : 1,
              mainAxisSpacing: 20,
              crossAxisSpacing: 20,
              itemCount: 3,
              itemBuilder: (context, index) {
                return switch (index) {
                  0 => FCard(
                    key: const ValueKey<String>('settings-account-card'),
                    title: const Text('账号'),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        _ConstrainedFItemGroup(
                          divider: .full,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            FItem(
                              prefix: const Icon(Icons.person_outline),
                              title: const Text('用户'),
                              subtitle: Text(
                                user.email.isEmpty ? '未提供邮箱' : user.email,
                              ),
                              details: Text(
                                user.effectiveName.isEmpty
                                    ? '用户'
                                    : user.effectiveName,
                              ),
                            ),
                            FItem(
                              prefix: const Icon(Icons.apartment_outlined),
                              title: const Text('工作区'),
                              details: Text(workspaceName),
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
                                onPress: () => unawaited(onLogout()),
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
                      valueListenable: coreLifecycleService.status,
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
                              Text(
                                status.lastError!,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color:
                                          status.phase ==
                                                  CoreRunPhase.needsElevation ||
                                              needsVpnPermission
                                          ? const Color(0xFFB45309)
                                          : const Color(0xFFDC2626),
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
                                        coreLifecycleService
                                            .repairWithElevation(),
                                      ),
                                      child: const Text('以管理员身份运行'),
                                    ),
                                  FButton(
                                    variant: .outline,
                                    onPress: () => unawaited(
                                      coreLifecycleService.repair(),
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
