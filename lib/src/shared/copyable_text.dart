import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

class AppCopyButton extends StatelessWidget {
  const AppCopyButton({
    super.key,
    required this.value,
    required this.label,
    this.size = 26,
    this.iconSize = 14,
    this.color = const Color(0xFF64748B),
  });

  final String value;
  final String label;
  final double size;
  final double iconSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final copyValue = value.trim();
    final canCopy = copyValue.isNotEmpty;

    return Tooltip(
      message: canCopy ? '复制$label' : '$label暂无可复制内容',
      child: IconButton(
        onPressed: canCopy
            ? () async {
                await Clipboard.setData(ClipboardData(text: copyValue));
                if (!context.mounted) {
                  return;
                }
                showFToast(
                  context: context,
                  variant: .primary,
                  title: Text('$label已复制'),
                );
              }
            : null,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.copy_outlined, size: iconSize, color: color),
      ),
    );
  }
}
