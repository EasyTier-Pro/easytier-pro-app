import 'package:flutter/widgets.dart';

import '../core/core_lifecycle_service.dart';
import '../desktop/app_update_service.dart';
import '../desktop/tray_support.dart';
import 'home_settings_page.dart';

mixin HomeTrayActionsMixin<T extends StatefulWidget> on State<T> {
  TraySupport get traySupport;

  CoreLifecycleService get coreLifecycleService;

  AppUpdateService get appUpdateService;

  void showSettingsFromTray();

  void showTrayFeedback(String message, {bool destructive = false});

  void logTrayAppUpdateError(Object error, StackTrace stack) {}

  String? _trayEngineLabel;
  bool? _trayEngineEnabled;
  String? _trayAppUpdateLabel;
  bool? _trayAppUpdateEnabled;
  bool _trayCheckingForAppUpdates = false;

  void initHomeTrayActions() {
    coreLifecycleService.engineVersionStatus.addListener(
      syncHomeTrayCoreUpdateAction,
    );
    _syncHomeTraySettingsAction();
    _syncHomeTrayAppUpdateAction();
    syncHomeTrayCoreUpdateAction();
  }

  void didUpdateHomeTrayActions({
    required TraySupport oldTraySupport,
    required CoreLifecycleService oldCoreLifecycleService,
  }) {
    if (oldCoreLifecycleService != coreLifecycleService) {
      oldCoreLifecycleService.engineVersionStatus.removeListener(
        syncHomeTrayCoreUpdateAction,
      );
      coreLifecycleService.engineVersionStatus.addListener(
        syncHomeTrayCoreUpdateAction,
      );
      oldTraySupport.setEngineAction(null);
      _trayEngineLabel = null;
      _trayEngineEnabled = null;
      syncHomeTrayCoreUpdateAction();
    }

    if (oldTraySupport != traySupport) {
      oldTraySupport.setEngineAction(null);
      oldTraySupport.setSettingsAction(null);
      oldTraySupport.setAppUpdateAction(null);
      _trayEngineLabel = null;
      _trayEngineEnabled = null;
      _trayAppUpdateLabel = null;
      _trayAppUpdateEnabled = null;
      _syncHomeTraySettingsAction();
      _syncHomeTrayAppUpdateAction();
      syncHomeTrayCoreUpdateAction();
    }
  }

  void disposeHomeTrayActions() {
    coreLifecycleService.engineVersionStatus.removeListener(
      syncHomeTrayCoreUpdateAction,
    );
    traySupport.setEngineAction(null);
    traySupport.setSettingsAction(null);
    traySupport.setAppUpdateAction(null);
  }

  void syncHomeTrayCoreUpdateAction() {
    final versionStatus = coreLifecycleService.engineVersionStatus.value;
    final coreStatus = coreLifecycleService.status.value;
    if (!versionStatus.updateAvailable) {
      if (_trayEngineLabel != null || _trayEngineEnabled != null) {
        _trayEngineLabel = null;
        _trayEngineEnabled = null;
        traySupport.setEngineAction(null);
      }
      return;
    }

    final busy =
        coreStatus.phase == CoreRunPhase.checking ||
        coreStatus.phase == CoreRunPhase.repairing;
    final label = homeCoreEngineActionLabel(versionStatus);
    final enabled = !busy;
    if (_trayEngineLabel == label && _trayEngineEnabled == enabled) {
      return;
    }

    _trayEngineLabel = label;
    _trayEngineEnabled = enabled;
    traySupport.setEngineAction(
      TrayEngineAction(
        label: label,
        enabled: enabled,
        onSelected: enabled ? _updateCoreFromTray : null,
      ),
    );
  }

  void _syncHomeTraySettingsAction() {
    traySupport.setSettingsAction(
      TrayMenuAction(
        label: '设置',
        enabled: true,
        onSelected: _openSettingsFromTray,
      ),
    );
  }

  void _syncHomeTrayAppUpdateAction() {
    final label = _trayCheckingForAppUpdates ? '正在检查更新...' : '检查更新';
    final enabled = !_trayCheckingForAppUpdates;
    if (_trayAppUpdateLabel == label && _trayAppUpdateEnabled == enabled) {
      return;
    }

    _trayAppUpdateLabel = label;
    _trayAppUpdateEnabled = enabled;
    traySupport.setAppUpdateAction(
      TrayMenuAction(
        label: label,
        enabled: enabled,
        onSelected: enabled ? _checkForAppUpdatesFromTray : null,
      ),
    );
  }

  Future<void> _openSettingsFromTray() async {
    await traySupport.showWindow();
    if (!mounted) {
      return;
    }
    showSettingsFromTray();
  }

  Future<void> _checkForAppUpdatesFromTray() async {
    await traySupport.showWindow();
    if (!mounted || _trayCheckingForAppUpdates) {
      return;
    }
    showSettingsFromTray();
    setState(() {
      _trayCheckingForAppUpdates = true;
    });
    _syncHomeTrayAppUpdateAction();
    try {
      final feedback = await runHomeAppUpdateCheck(
        appUpdateService,
        onError: logTrayAppUpdateError,
      );
      if (mounted) {
        showTrayFeedback(feedback.message, destructive: feedback.destructive);
      }
    } finally {
      if (mounted) {
        setState(() {
          _trayCheckingForAppUpdates = false;
        });
        _syncHomeTrayAppUpdateAction();
      }
    }
  }

  Future<void> _updateCoreFromTray() async {
    await traySupport.showWindow();
    if (!mounted) {
      return;
    }
    await coreLifecycleService.repair();
  }
}
