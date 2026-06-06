import 'tray_support_stub.dart'
    if (dart.library.io) 'tray_support_desktop.dart';

import '../core/core_lifecycle_service.dart';

class TrayConnectionAction {
  const TrayConnectionAction({
    required this.label,
    required this.enabled,
    this.onSelected,
  });

  final String label;
  final bool enabled;
  final Future<void> Function()? onSelected;
}

abstract class TraySupport {
  Future<void> initialize();

  Future<void> dispose();

  Future<void> showWindow();

  Future<void> quitApp();

  Future<void> updateCoreStatus(CoreRunStatus status);

  void setConnectionAction(TrayConnectionAction? action);
}

TraySupport createTraySupport() => createPlatformTraySupport();
