import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/core_lifecycle_service.dart';
import '../logging/app_logger.dart';
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
  String _coreStatusText = '未登录';
  Future<void> Function()? _onRepairRequested;
  final AppLogger _logger = AppLogger.instance;

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
    await _refreshContextMenu();

    _initialized = true;
    _logger.info('tray', 'Tray initialized');
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
    await windowManager.setPreventClose(false);
    await windowManager.close();
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
  Future<void> updateCoreStatus(CoreRunStatus status) async {
    _coreStatusText = switch (status.phase) {
      CoreRunPhase.running => '运行中',
      CoreRunPhase.checking => '检查中',
      CoreRunPhase.repairing => '修复中',
      CoreRunPhase.error => '异常',
      CoreRunPhase.signedOut => '未登录',
    };
    _logger.info(
      'tray',
      'Core status updated on tray',
      context: {'phase': status.phase.name, 'message': status.message},
    );

    if (_initialized && _isDesktopPlatform) {
      await _refreshContextMenu();
    }
  }

  @override
  void setRepairAction(Future<void> Function()? onRepair) {
    _onRepairRequested = onRepair;
    if (_initialized && _isDesktopPlatform) {
      unawaited(_refreshContextMenu());
    }
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

  Future<void> _refreshContextMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(label: '连接引擎: $_coreStatusText', onClick: (_) {}),
          MenuItem(
            label: '修复连接引擎',
            onClick: (_) {
              _logger.info('tray', 'Repair action clicked from tray');
              final repair = _onRepairRequested;
              if (repair != null) {
                unawaited(repair());
              }
            },
          ),
          MenuItem.separator(),
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
