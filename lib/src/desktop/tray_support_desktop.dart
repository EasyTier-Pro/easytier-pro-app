import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'tray_support.dart';

class _DesktopTraySupport extends TraySupport
    with TrayListener, WindowListener {
  _DesktopTraySupport();

  static const String _trayTooltip = 'EasyTier Pro';
  static const String _trayIconPath = 'windows/runner/resources/app_icon.ico';
  static const String _trayIconPathFallback = 'web/favicon.png';

  bool _initialized = false;
  bool _quitRequested = false;
  bool _trayMenuVisible = false;

  bool get _isDesktopPlatform {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
  }

  @override
  Future<void> initialize() async {
    if (_initialized || !_isDesktopPlatform) {
      return;
    }

    await windowManager.ensureInitialized();
    trayManager.addListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await trayManager.setIcon(_trayIconForCurrentPlatform());
    await trayManager.setToolTip(_trayTooltip);
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            label: '打开主窗口',
            onClick: (_) {
              unawaited(showWindow());
            },
          ),
          MenuItem.separator(),
          MenuItem(
            label: '退出 EasyTier Pro',
            onClick: (_) {
              unawaited(quitApp());
            },
          ),
        ],
      ),
    );

    _initialized = true;
  }

  @override
  Future<void> dispose() async {
    if (!_initialized || !_isDesktopPlatform) {
      return;
    }

    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    _initialized = false;
  }

  @override
  Future<void> quitApp() async {
    if (_quitRequested || !_isDesktopPlatform) {
      return;
    }

    _quitRequested = true;
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  Future<void> showWindow() async {
    if (!_isDesktopPlatform) {
      return;
    }

    _quitRequested = false;
    await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconMouseUp() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_showTrayMenu());
  }

  @override
  void onTrayIconRightMouseUp() {
    unawaited(_showTrayMenu());
  }

  Future<void> _showTrayMenu() async {
    if (_trayMenuVisible || !_isDesktopPlatform) {
      return;
    }

    _trayMenuVisible = true;
    try {
      // Windows tray menus are more reliable when the host app is brought forward.
      // ignore: deprecated_member_use
      await trayManager.popUpContextMenu(bringAppToFront: true);
    } finally {
      _trayMenuVisible = false;
    }
  }

  @override
  void onWindowClose() {
    if (_quitRequested) {
      return;
    }

    unawaited(windowManager.hide());
  }

  @override
  void onWindowMinimize() {
    if (_quitRequested) {
      return;
    }

    unawaited(windowManager.hide());
  }

  String _trayIconForCurrentPlatform() {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return _trayIconPathFallback;
    }

    return _trayIconPath;
  }
}

TraySupport createPlatformTraySupport() => _DesktopTraySupport();
