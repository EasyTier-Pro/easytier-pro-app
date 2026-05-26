import 'tray_support.dart';

class _NoopTraySupport implements TraySupport {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<void> quitApp() async {}

  @override
  Future<void> showWindow() async {}
}

TraySupport createPlatformTraySupport() => _NoopTraySupport();
