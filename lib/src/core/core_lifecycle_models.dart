part of 'core_lifecycle_service.dart';

enum CoreRunPhase {
  signedOut,
  stopped,
  checking,
  repairing,
  running,
  error,
  needsElevation,
  needsVpnPermission,
}

class _ElevationRequiredException implements Exception {
  const _ElevationRequiredException([this.message = '安装连接引擎需要管理员权限']);
  final String message;
  @override
  String toString() => message;
}

class _DesktopCoreStatus {
  const _DesktopCoreStatus({
    required this.ready,
    required this.installed,
    required this.running,
    this.machineId,
    this.version,
    this.serviceState,
    this.cliPath,
  });

  final bool ready;
  final bool installed;
  final bool running;
  final String? machineId;
  final String? version;
  final String? serviceState;
  final String? cliPath;

  static _DesktopCoreStatus fromEvent(Map<String, dynamic> event) {
    final data = event['data'];
    final values = data is Map<String, dynamic>
        ? data
        : const <String, dynamic>{};
    return _DesktopCoreStatus(
      ready: _readBool(values['ready']),
      installed: _readBool(values['installed']),
      running: _readBool(values['running']),
      machineId: _readString(values['machine_id']),
      version: _readString(values['version']),
      serviceState: _readString(values['service_state']),
      cliPath: _readString(values['cli_path']),
    );
  }

  static bool _readBool(Object? value) {
    if (value is bool) {
      return value;
    }
    final text = value?.toString().toLowerCase().trim();
    return text == 'true' || text == '1';
  }

  static String? _readString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class CoreNetworkTrafficTotals {
  const CoreNetworkTrafficTotals({
    required this.runtimeNetworkName,
    required this.downloadBytes,
    required this.uploadBytes,
    required this.sampledAt,
  });

  final String runtimeNetworkName;
  final int downloadBytes;
  final int uploadBytes;
  final DateTime sampledAt;
}

class _MutableNetworkTrafficTotals {
  int downloadBytes = 0;
  int uploadBytes = 0;
  bool hasDownloadBytes = false;
  bool hasUploadBytes = false;
}

class CoreRunStatus {
  const CoreRunStatus({
    required this.phase,
    required this.message,
    this.lastError,
    this.machineId,
    this.details,
  });

  final CoreRunPhase phase;
  final String message;
  final String? lastError;
  final String? machineId;
  final String? details;

  bool get isRunning => phase == CoreRunPhase.running;

  static const CoreRunStatus signedOut = CoreRunStatus(
    phase: CoreRunPhase.signedOut,
    message: '未登录',
  );
}
