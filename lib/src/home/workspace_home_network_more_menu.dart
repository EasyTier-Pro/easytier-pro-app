part of 'workspace_home_view.dart';

class _NetworkMoreMenu extends StatelessWidget {
  const _NetworkMoreMenu({
    required this.enabled,
    required this.joined,
    required this.onLeave,
    required this.onDelete,
  });

  final bool enabled;
  final bool joined;
  final VoidCallback onLeave;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return _ControlSelectionBoundary(
      child: ExcludeSemantics(
        child: FPopoverMenu(
          menuAnchor: Alignment.topRight,
          childAnchor: Alignment.bottomRight,
          divider: FItemDivider.none,
          menuBuilder: (context, controller, menu) => [
            FItemGroup(
              divider: FItemDivider.none,
              children: [
                if (joined)
                  FItem(
                    key: const ValueKey<String>('network-more-leave'),
                    prefix: const Icon(
                      Icons.logout_outlined,
                      size: 18,
                      color: Color(0xFF64748B),
                    ),
                    title: Text(
                      '退出网络',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPress: () {
                      unawaited(controller.hide());
                      onLeave();
                    },
                  ),
                FItem(
                  key: const ValueKey<String>('network-more-delete'),
                  prefix: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Color(0xFFDC2626),
                  ),
                  title: Text(
                    '删除网络...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFDC2626),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPress: () {
                    unawaited(controller.hide());
                    onDelete();
                  },
                ),
              ],
            ),
          ],
          builder: (context, controller, child) => Tooltip(
            message: '更多操作',
            excludeFromSemantics: true,
            child: FButton(
              key: const ValueKey<String>('network-more-menu-button'),
              variant: .ghost,
              size: .sm,
              onPress: enabled ? () => unawaited(controller.toggle()) : null,
              mainAxisSize: MainAxisSize.min,
              child: const Icon(Icons.more_vert, size: 18),
            ),
          ),
        ),
      ),
    );
  }
}
