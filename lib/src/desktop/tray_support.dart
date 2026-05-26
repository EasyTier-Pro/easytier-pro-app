import 'tray_support_stub.dart'
    if (dart.library.io) 'tray_support_desktop.dart';

abstract class TraySupport {
  Future<void> initialize();

  Future<void> dispose();

  Future<void> showWindow();

  Future<void> quitApp();
}

TraySupport createTraySupport() => createPlatformTraySupport();
