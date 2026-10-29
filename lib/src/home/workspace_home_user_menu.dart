part of 'workspace_home_view.dart';

class _UserMenu extends StatelessWidget {
  const _UserMenu({
    required this.userName,
    required this.workspaces,
    required this.selectedWorkspaceId,
    required this.initial,
    required this.onSelectWorkspace,
    required this.onRefreshWorkspaces,
    required this.onShowSettings,
    required this.onLogout,
  });

  final String userName;
  final List<ConsoleWorkspace> workspaces;
  final String? selectedWorkspaceId;
  final String initial;
  final ValueChanged<String> onSelectWorkspace;
  final Future<void> Function() onRefreshWorkspaces;
  final VoidCallback onShowSettings;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final displayName = userName.isEmpty ? '用户' : userName;

    return ExcludeSemantics(
      child: FPopoverMenu(
        menuAnchor: Alignment.topRight,
        childAnchor: Alignment.bottomRight,
        divider: FItemDivider.full,
        menuBuilder: (context, controller, menu) => [
          FItemGroup(
            divider: FItemDivider.full,
            children: [
              FItem.raw(
                enabled: false,
                child: SizedBox(
                  width: 200,
                  child: SelectionContainer.disabled(
                    child: Text(
                      displayName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF0A0A0A),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          FItemGroup(
            children: [
              FItem.raw(
                enabled: false,
                child: SelectionContainer.disabled(
                  child: Text(
                    '工作区',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF737373),
                    ),
                  ),
                ),
              ),
              for (final workspace in workspaces)
                FItem(
                  key: ValueKey('workspace-option-${workspace.id}'),
                  title: SelectionContainer.disabled(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        workspace.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  suffix: workspace.id == selectedWorkspaceId
                      ? const Icon(Icons.check, size: 16)
                      : null,
                  onPress: () {
                    unawaited(controller.hide());
                    onSelectWorkspace(workspace.id);
                  },
                ),
              FItem(
                title: SelectionContainer.disabled(child: const Text('刷新工作区')),
                prefix: const Icon(Icons.refresh, size: 16),
                onPress: () {
                  unawaited(controller.hide());
                  unawaited(onRefreshWorkspaces());
                },
              ),
            ],
          ),
          FItemGroup(
            divider: FItemDivider.full,
            children: [
              FItem(
                key: const ValueKey<String>('user-menu-settings'),
                prefix: const Icon(Icons.settings_outlined, size: 18),
                title: SelectionContainer.disabled(child: const Text('设置')),
                onPress: () {
                  unawaited(controller.hide());
                  onShowSettings();
                },
              ),
              FItem(
                prefix: const Icon(Icons.logout_outlined, size: 18),
                title: SelectionContainer.disabled(child: const Text('退出登录')),
                onPress: () {
                  unawaited(controller.hide());
                  unawaited(onLogout());
                },
              ),
            ],
          ),
        ],
        builder: (context, controller, child) => FButton(
          key: const ValueKey<String>('user-menu-button'),
          variant: .ghost,
          size: .sm,
          onPress: () => unawaited(controller.toggle()),
          mainAxisSize: MainAxisSize.min,
          suffix: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
          child: FAvatar.raw(size: 30, child: Text(initial.toUpperCase())),
        ),
      ),
    );
  }
}
