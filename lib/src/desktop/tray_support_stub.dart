import 'tray_support.dart';
import '../core/core_lifecycle_service.dart';

class _NoopTraySupport implements TraySupport {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<void> quitApp() async {}

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> updateCoreStatus(CoreRunStatus status) async {}

  @override
  void setRepairAction(Future<void> Function()? onRepair) {}
}

TraySupport createPlatformTraySupport() => _NoopTraySupport();
