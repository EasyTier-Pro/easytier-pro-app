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
    showFToast(
      context: context,
      variant: destructive ? .destructive : .primary,
      title: Text(message),
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

  Future<void> _copyLogDirectory(BuildContext context) async {
    final path = AppLogger.instance.logDirectoryPath;
    if (path == null || path.isEmpty) {
      if (context.mounted) {
        _showToast(context, '日志目录尚未初始化', destructive: true);
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: path));
    if (context.mounted) {
      _showToast(context, '日志目录已复制: $path');
    }
  }

  @override
  Widget build(BuildContext context) {
    final emailText = user.email.isEmpty ? '未提供邮箱' : user.email;
    final displayName = user.effectiveName.isEmpty ? '用户' : user.effectiveName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '设置', subtitle: '查看当前账号与桌面端辅助操作。'),
        const SizedBox(height: 20),
        FCard(
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
                    subtitle: Row(
                      children: [
                        Expanded(
                          child: Text(
                            emailText,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (user.email.isNotEmpty)
                          AppCopyButton(
                            value: user.email,
                            label: '邮箱',
                            size: 22,
                            iconSize: 13,
                          ),
                      ],
                    ),
                    details: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(displayName),
                        AppCopyButton(
                          value: displayName,
                          label: '用户名',
                          size: 22,
                          iconSize: 13,
                        ),
                      ],
                    ),
                  ),
                  FItem(
                    prefix: const Icon(Icons.apartment_outlined),
                    title: const Text('工作区'),
                    details: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(workspaceName),
                        AppCopyButton(
                          value: workspaceName,
                          label: '工作区',
                          size: 22,
                          iconSize: 13,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
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
            ],
          ),
        ),
        const SizedBox(height: 20),
        FCard(
          title: const Text('连接引擎'),
          subtitle: const Text('核心连接引擎状态与修复入口。'),
          child: ValueListenableBuilder<CoreRunStatus>(
            valueListenable: coreLifecycleService.status,
            builder: (context, status, _) {
              final running = status.phase == CoreRunPhase.running;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _StatusDot(
                        online: running,
                        color: status.phase == CoreRunPhase.needsElevation
                            ? const Color(0xFFF59E0B)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          status.message,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      AppCopyButton(
                        value: status.message,
                        label: '引擎状态',
                        size: 22,
                        iconSize: 13,
                      ),
                    ],
                  ),
                  if (status.machineId != null &&
                      status.machineId!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '本机设备: ${status.machineId}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: const Color(0xFF737373)),
                          ),
                        ),
                        AppCopyButton(
                          value: status.machineId!,
                          label: '本机设备 ID',
                          size: 22,
                          iconSize: 13,
                        ),
                      ],
                    ),
                  ],
                  if (status.lastError != null &&
                      status.lastError!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            status.lastError!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color:
                                      status.phase ==
                                          CoreRunPhase.needsElevation
                                      ? const Color(0xFFB45309)
                                      : const Color(0xFFDC2626),
                                ),
                          ),
                        ),
                        AppCopyButton(
                          value: status.lastError!,
                          label: '引擎错误',
                          size: 22,
                          iconSize: 13,
                          color: status.phase == CoreRunPhase.needsElevation
                              ? const Color(0xFFB45309)
                              : const Color(0xFFDC2626),
                        ),
                      ],
                    ),
                  ],
                  if (status.phase == CoreRunPhase.needsElevation) ...[
                    const SizedBox(height: 10),
                    Text(
                      '创建虚拟网卡需要管理员权限，请点击下方按钮以管理员身份运行安装程序。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF737373),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (status.phase == CoreRunPhase.needsElevation)
                        FButton(
                          variant: .primary,
                          onPress: () => unawaited(
                            coreLifecycleService.repairWithElevation(),
                          ),
                          child: const Text('以管理员身份运行'),
                        ),
                      FButton(
                        variant: .outline,
                        onPress: () => unawaited(coreLifecycleService.repair()),
                        child: const Text('重试/修复'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        FCard(
          title: const Text('诊断日志'),
          subtitle: const Text('用于排查连接引擎红灯、安装失败和权限问题。'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FButton(
                    variant: .outline,
                    onPress: () => unawaited(_exportLogs(context)),
                    child: const Text('导出诊断日志'),
                  ),
                  FButton(
                    variant: .outline,
                    onPress: () => unawaited(_copyLogDirectory(context)),
                    child: const Text('复制日志目录'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<List<AppLogEntry>>(
                valueListenable: AppLogger.instance.recentEntries,
                builder: (context, entries, _) {
                  if (entries.isEmpty) {
                    return const Text('暂无日志');
                  }
                  final start = entries.length > 8 ? entries.length - 8 : 0;
                  final recent = entries.sublist(start);
                  final recentText = recent
                      .map((entry) => entry.humanLine)
                      .join('\n');
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F9FB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            recentText,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AppCopyButton(
                          value: recentText,
                          label: '最近日志',
                          size: 22,
                          iconSize: 13,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
