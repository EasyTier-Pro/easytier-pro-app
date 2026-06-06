part of 'workspace_home_view.dart';

class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 12),
              _ControlSelectionBoundary(child: action!),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.online, this.color});

  final bool online;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color ?? (online ? const Color(0xFF16A34A) : Colors.grey),
        shape: BoxShape.circle,
      ),
    );
  }
}

String _approvalLabel(ManagedDevice device) {
  return switch (device.approvalState.toLowerCase()) {
    'approved' => '已批准',
    'pending' => '待批准',
    'rejected' => '已拒绝',
    'removed' => '已移除',
    '' => '未知',
    _ => device.approvalState,
  };
}

String _shortId(String value) {
  if (value.length <= 8) {
    return value;
  }
  return value.substring(0, 8);
}
