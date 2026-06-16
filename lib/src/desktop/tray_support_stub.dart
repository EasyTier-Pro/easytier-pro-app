import 'tray_support.dart';
import '../core/core_lifecycle_service.dart';
import 'window_behavior_preferences.dart';

class _NoopTraySupport implements TraySupport {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<void> quitApp({AppExitReason reason = AppExitReason.user}) async {}

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> updateCoreStatus(CoreRunStatus status) async {}

  @override
  void setConnectionAction(TrayConnectionAction? action) {}

  @override
  void setEngineAction(TrayEngineAction? action) {}
}

TraySupport createPlatformTraySupport({
  required WindowBehaviorPreferences windowBehaviorPreferences,
}) => _NoopTraySupport();
