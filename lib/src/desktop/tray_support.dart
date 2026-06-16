import 'tray_support_stub.dart'
    if (dart.library.io) 'tray_support_desktop.dart';

import '../core/core_lifecycle_service.dart';
import 'window_behavior_preferences.dart';

class TrayConnectionAction {
  const TrayConnectionAction({
    required this.label,
    required this.enabled,
    this.workspaceName,
    this.onSelected,
  });

  final String label;
  final bool enabled;
  final String? workspaceName;
  final Future<void> Function()? onSelected;
}

class TrayEngineAction {
  const TrayEngineAction({
    required this.label,
    required this.enabled,
    this.onSelected,
  });

  final String label;
  final bool enabled;
  final Future<void> Function()? onSelected;
}

enum AppExitReason { user, update }

abstract class TraySupport {
  Future<void> initialize();

  Future<void> dispose();

  Future<void> showWindow();

  Future<void> quitApp({AppExitReason reason = AppExitReason.user});

  Future<void> updateCoreStatus(CoreRunStatus status);

  void setConnectionAction(TrayConnectionAction? action);

  void setEngineAction(TrayEngineAction? action);
}

TraySupport createTraySupport({
  WindowBehaviorPreferences? windowBehaviorPreferences,
}) => createPlatformTraySupport(
  windowBehaviorPreferences:
      windowBehaviorPreferences ?? WindowBehaviorPreferences.memory(),
);
