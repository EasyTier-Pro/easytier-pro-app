part of 'core_lifecycle_service.dart';

abstract class CorePlatformRuntime {
  const CorePlatformRuntime();

  factory CorePlatformRuntime.current(CoreLifecycleService owner) {
    if (!kIsWeb && Platform.isAndroid) {
      return AndroidCoreRuntime();
    }
    return DesktopCoreRuntime(owner);
  }

  bool get supportsElevationRepair => false;

  Duration get networkTrafficPollInterval => const Duration(seconds: 2);

  Duration get peerStatusPollInterval => const Duration(seconds: 5);

  Stream<CoreRuntimeEvent> get events => const Stream<CoreRuntimeEvent>.empty();

  Future<CoreRuntimeStartResult?> readStatus(CoreBootstrapConfig bootstrap);

  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  });

  Future<void> stop();

  Future<Map<String, CoreNetworkTrafficTotals>> readNetworkTrafficTotals();

  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName);

  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  );

  Future<void> dispose() async {}
}

class CoreRuntimeStartResult {
  const CoreRuntimeStartResult({
    required this.phase,
    required this.message,
    this.machineId,
    this.details,
    this.lastError,
  });

  final CoreRunPhase phase;
  final String message;
  final String? machineId;
  final String? details;
  final String? lastError;

  CoreRunStatus toStatus() {
    return CoreRunStatus(
      phase: phase,
      message: message,
      machineId: machineId,
      details: details,
      lastError: lastError,
    );
  }
}

class CoreRuntimeEvent {
  const CoreRuntimeEvent({
    required this.type,
    this.data = const <String, Object?>{},
  });

  final String type;
  final Map<String, Object?> data;
}

class CoreRuntimeEventTypes {
  const CoreRuntimeEventTypes._();

  static const String vpnPermissionGranted = 'vpn_permission_granted';
  static const String vpnPermissionDenied = 'vpn_permission_denied';
  static const String vpnStarted = 'vpn_started';
  static const String vpnStopped = 'vpn_stopped';
  static const String vpnConfigRefreshed = 'vpn_config_refreshed';
  static const String notificationPermissionGranted =
      'notification_permission_granted';
  static const String notificationPermissionDenied =
      'notification_permission_denied';
  static const String configServer = 'config_server';
  static const String configServerStarted = 'config_server_started';
  static const String configServerStopped = 'config_server_stopped';
  static const String error = 'error';
}
