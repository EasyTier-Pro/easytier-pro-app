import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/console_links.dart';

class HomeOpenConsoleButton extends StatelessWidget {
  const HomeOpenConsoleButton({
    super.key,
    this.buttonKey,
    this.tooltip = '打开控制台',
  });

  final Key? buttonKey;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: FButton(
        key: buttonKey,
        variant: .ghost,
        size: .sm,
        onPress: () => unawaited(
          launchUrl(consoleHomeUri(), mode: LaunchMode.externalApplication),
        ),
        mainAxisSize: MainAxisSize.min,
        child: const Icon(Icons.open_in_new, size: 16),
      ),
    );
  }
}
