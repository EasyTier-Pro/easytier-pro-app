import 'tray_support_stub.dart'
    if (dart.library.io) 'tray_support_desktop.dart';

import '../core/core_lifecycle_service.dart';

abstract class TraySupport {
  Future<void> initialize();

  Future<void> dispose();

  Future<void> showWindow();

  Future<void> quitApp();

  Future<void> updateCoreStatus(CoreRunStatus status);

  void setRepairAction(Future<void> Function()? onRepair);
}

TraySupport createTraySupport() => createPlatformTraySupport();
