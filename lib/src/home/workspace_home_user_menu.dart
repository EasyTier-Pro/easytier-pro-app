part of 'workspace_home_view.dart';

class _UserMenu extends StatelessWidget {
  const _UserMenu({
    required this.userName,
    required this.workspaceName,
    required this.initial,
    required this.onShowSettings,
    required this.onLogout,
  });

  final String userName;
  final String workspaceName;
  final String initial;
  final VoidCallback onShowSettings;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final displayName = userName.isEmpty ? '用户' : userName;

    return FPopoverMenu(
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF0A0A0A),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        workspaceName,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF737373),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            FItem(
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
        variant: .ghost,
        size: .sm,
        onPress: () => unawaited(controller.toggle()),
        mainAxisSize: MainAxisSize.min,
        suffix: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
        child: FAvatar.raw(size: 30, child: Text(initial.toUpperCase())),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/easytier.png',
      width: 30,
      height: 30,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color ?? const Color(0xFF737373)),
        const SizedBox(width: 5),
        Text(
          '$label $value',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF737373),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
