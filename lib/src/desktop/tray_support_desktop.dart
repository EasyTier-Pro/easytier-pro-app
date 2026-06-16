import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/core_lifecycle_service.dart';
import '../logging/app_logger.dart';
import 'tray_support.dart';
import 'window_behavior_preferences.dart';

class _DesktopTraySupport extends TraySupport
    with TrayListener, WindowListener {
  _DesktopTraySupport({required this._windowBehaviorPreferences});

  static const String _trayTooltip = 'EasyTier Pro';
  static const String _windowsTrayIconPath =
      'windows/runner/resources/tray_icon.ico';
  static const String _macOSTrayIconPath = 'assets/images/tray_icon_macos.png';
  static const String _trayIconPathFallback = 'web/favicon.png';

  bool _initialized = false;
  bool _quitRequested = false;
  bool _trayMenuVisible = false;
  TrayConnectionAction? _connectionAction;
  final AppLogger _logger = AppLogger.instance;
  final WindowBehaviorPreferences _windowBehaviorPreferences;

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
    await _setTrayIcon();
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
  Future<void> quitApp({AppExitReason reason = AppExitReason.user}) async {
    if (_quitRequested || !_isDesktopPlatform) {
      return;
    }

    _quitRequested = true;
    _logger.info(
      'tray',
      'Quitting application',
      context: {'reason': reason.name},
    );
    await windowManager.setPreventClose(false);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await windowManager.destroy();
      return;
    }

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
    _logger.info(
      'tray',
      'Core status updated on tray',
      context: {'phase': status.phase.name, 'message': status.message},
    );
  }

  @override
  void setConnectionAction(TrayConnectionAction? action) {
    _connectionAction = action;
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
      if (defaultTargetPlatform == TargetPlatform.windows) {
        // Windows tray menus are more reliable when the host app is brought forward.
        // ignore: deprecated_member_use
        await trayManager.popUpContextMenu(bringAppToFront: true);
      } else {
        await trayManager.popUpContextMenu();
      }
    } finally {
      _trayMenuVisible = false;
    }
  }

  Future<void> _refreshContextMenu() async {
    final connectionAction =
        _connectionAction ??
        const TrayConnectionAction(
          label: '连接',
          enabled: false,
          workspaceName: '未登录',
        );
    final workspaceName = connectionAction.workspaceName?.trim();

    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            label: connectionAction.label,
            disabled: !connectionAction.enabled,
            onClick: (_) {
              _logger.info(
                'tray',
                'Connection action clicked from tray',
                context: {'label': connectionAction.label},
              );
              final onSelected = connectionAction.onSelected;
              if (connectionAction.enabled && onSelected != null) {
                unawaited(onSelected());
              }
            },
          ),
          if (workspaceName != null && workspaceName.isNotEmpty)
            MenuItem(label: '工作区：$workspaceName', disabled: true),
          MenuItem.separator(),
          MenuItem(
            label: '显示主窗口',
            onClick: (_) {
              unawaited(showWindow());
            },
          ),
          MenuItem.separator(),
          MenuItem(
            label: '退出',
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
    if (_quitRequested || !_windowBehaviorPreferences.minimizeToTray) {
      return;
    }

    unawaited(windowManager.hide());
  }

  Future<void> _setTrayIcon() async {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await trayManager.setIcon(
        _macOSTrayIconPath,
        isTemplate: true,
        iconSize: 18,
      );
      return;
    }

    await trayManager.setIcon(_trayIconForCurrentPlatform());
  }

  String _trayIconForCurrentPlatform() {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _windowsTrayIconPath;
    }

    return _trayIconPathFallback;
  }
}

TraySupport createPlatformTraySupport({
  required WindowBehaviorPreferences windowBehaviorPreferences,
}) => _DesktopTraySupport(windowBehaviorPreferences: windowBehaviorPreferences);
