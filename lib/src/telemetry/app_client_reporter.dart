import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/console_auth_service.dart';
import '../logging/app_logger.dart';

typedef AppClientEnvironmentLoader = Future<AppClientEnvironment> Function();
typedef AppClientClock = DateTime Function();

const Duration _defaultReportInterval = Duration(hours: 24);
const String _installationIdKey = 'app_client_installation_id';
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

class AppClientReporter {
  factory AppClientReporter({
    required SharedPreferences preferences,
    http.Client? httpClient,
    String consoleBaseUrl = defaultConsoleBaseUrl,
    AppClientEnvironmentLoader? environmentLoader,
    AppClientClock? now,
    Duration reportInterval = _defaultReportInterval,
  }) {
    return AppClientReporter._(
      preferences: preferences,
      httpClient: httpClient ?? http.Client(),
      consoleBaseUrl: consoleBaseUrl,
      environmentLoader: environmentLoader ?? AppClientEnvironment.load,
      now: now ?? DateTime.now,
      reportInterval: reportInterval,
    );
  }

  AppClientReporter._({
    required this._preferences,
    required this._httpClient,
    required this._consoleBaseUrl,
    required this._environmentLoader,
    required this._now,
    required this._reportInterval,
  });

  final SharedPreferences _preferences;
  final http.Client _httpClient;
  final String _consoleBaseUrl;
  final AppClientEnvironmentLoader _environmentLoader;
  final AppClientClock _now;
  final Duration _reportInterval;
  final AppLogger _logger = AppLogger.instance;

  Future<void> reportSessionEstablished(AuthSession session) {
    return _report(session, machineId: null, reason: 'session_established');
  }

  Future<void> reportMachineReady(AuthSession session, String? machineId) {
    final normalizedMachineId = machineId?.trim() ?? '';
    if (normalizedMachineId.isEmpty) {
      return Future<void>.value();
    }
    return _report(
      session,
      machineId: normalizedMachineId,
      reason: 'machine_ready',
    );
  }

  Future<void> _report(
    AuthSession session, {
    required String? machineId,
    required String reason,
  }) async {
    try {
      if (session.tokenSet.isExpired) {
        return;
      }
      final workspace = session.user.currentWorkspace;
      if (workspace == null || workspace.id.trim().isEmpty) {
        return;
      }

      final report = await _buildReport(machineId: machineId);
      final principalKey = _principalKeyFor(session);
      if (!_shouldSend(workspace.id, principalKey, report)) {
        return;
      }

      final response = await _httpClient.put(
        _reportUri(
          workspaceId: workspace.id,
          installationId: report.installationId,
        ),
        headers: {
          'Authorization': 'Bearer ${session.tokenSet.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(report.toJson()),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('console returned ${response.statusCode}');
      }

      await _rememberReport(workspace.id, principalKey, report);
      _logger.debug(
        'app.client',
        'Reported app client installation',
        context: {
          'workspace_id': workspace.id,
          'machine_id': report.machineId ?? '',
          'reason': reason,
        },
      );
    } catch (error) {
      _logger.warn(
        'app.client',
        'App client report failed',
        context: {'reason': reason, 'error': error.toString()},
      );
    }
  }

  Future<_AppClientReport> _buildReport({required String? machineId}) async {
    final installationId = await _ensureInstallationId();
    final environment = await _environmentLoader();
    return _AppClientReport(
      installationId: installationId,
      machineId: _emptyToNull(machineId),
      hostname: _emptyToNull(environment.hostname),
      appName: _fallback(environment.appName, 'easytier-pro-app'),
      appVersion: _fallback(environment.appVersion, 'unknown'),
      appBuild: _fallback(environment.appBuild, 'unknown'),
      appPlatform: _fallback(environment.appPlatform, 'unknown'),
      osName: _fallback(environment.osName, 'unknown'),
      osVersion: _emptyToNull(environment.osVersion),
      deviceModel: _emptyToNull(environment.deviceModel),
    );
  }

  bool _shouldSend(
    String workspaceId,
    String principalKey,
    _AppClientReport report,
  ) {
    if (_preferences.getString(_principalKey(workspaceId)) != principalKey) {
      return true;
    }

    final kind = _AppClientReportKind.from(report);
    final lastFingerprint = _preferences.getString(
      _fingerprintKey(workspaceId, kind),
    );
    if (lastFingerprint != report.fingerprint) {
      return true;
    }
    final lastReportedAt = _preferences.getInt(
      _reportedAtKey(workspaceId, kind),
    );
    if (lastReportedAt == null) {
      return true;
    }
    final elapsed = _now().toUtc().difference(
      DateTime.fromMillisecondsSinceEpoch(lastReportedAt, isUtc: true),
    );
    return elapsed >= _reportInterval;
  }

  Future<void> _rememberReport(
    String workspaceId,
    String principalKey,
    _AppClientReport report,
  ) async {
    final kind = _AppClientReportKind.from(report);
    final reportedAt = _now().toUtc().millisecondsSinceEpoch;
    await _preferences.setString(_principalKey(workspaceId), principalKey);
    await _preferences.setString(
      _fingerprintKey(workspaceId, kind),
      report.fingerprint,
    );
    await _preferences.setInt(_reportedAtKey(workspaceId, kind), reportedAt);
    if (kind == _AppClientReportKind.machine) {
      await _preferences.setString(
        _fingerprintKey(workspaceId, _AppClientReportKind.base),
        report.baseFingerprint,
      );
      await _preferences.setInt(
        _reportedAtKey(workspaceId, _AppClientReportKind.base),
        reportedAt,
      );
    }
  }

  Future<String> _ensureInstallationId() async {
    final existing = _preferences.getString(_installationIdKey)?.trim() ?? '';
    if (_uuidPattern.hasMatch(existing)) {
      return existing.toLowerCase();
    }
    final generated = _generateUuidV4();
    await _preferences.setString(_installationIdKey, generated);
    return generated;
  }

  Uri _reportUri({
    required String workspaceId,
    required String installationId,
  }) {
    final base = _consoleBaseUrl.endsWith('/')
        ? _consoleBaseUrl.substring(0, _consoleBaseUrl.length - 1)
        : _consoleBaseUrl;
    return Uri.parse(
      '$base/api/v1/tenants/${Uri.encodeComponent(workspaceId)}/app-installations/${Uri.encodeComponent(installationId)}/report',
    );
  }

  static String _principalKey(String workspaceId) =>
      'app_client_report_principal_$workspaceId';

  static String _fingerprintKey(
    String workspaceId,
    _AppClientReportKind kind,
  ) => 'app_client_report_fingerprint_${kind.name}_$workspaceId';

  static String _reportedAtKey(String workspaceId, _AppClientReportKind kind) =>
      'app_client_reported_at_${kind.name}_$workspaceId';
}

enum _AppClientReportKind {
  base,
  machine;

  static _AppClientReportKind from(_AppClientReport report) {
    return report.machineId == null
        ? _AppClientReportKind.base
        : _AppClientReportKind.machine;
  }
}

class AppClientEnvironment {
  const AppClientEnvironment({
    required this.appName,
    required this.appVersion,
    required this.appBuild,
    required this.appPlatform,
    required this.osName,
    required this.osVersion,
    required this.hostname,
    this.deviceModel,
  });

  final String appName;
  final String appVersion;
  final String appBuild;
  final String appPlatform;
  final String osName;
  final String osVersion;
  final String hostname;
  final String? deviceModel;

  static Future<AppClientEnvironment> load() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return AppClientEnvironment(
      appName: packageInfo.appName,
      appVersion: packageInfo.version,
      appBuild: packageInfo.buildNumber,
      appPlatform: Platform.operatingSystem,
      osName: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
      hostname: _loadHostname(),
    );
  }

  static String _loadHostname() {
    try {
      return Platform.localHostname.trim();
    } catch (_) {
      return '';
    }
  }
}

class _AppClientReport {
  const _AppClientReport({
    required this.installationId,
    required this.machineId,
    required this.hostname,
    required this.appName,
    required this.appVersion,
    required this.appBuild,
    required this.appPlatform,
    required this.osName,
    required this.osVersion,
    required this.deviceModel,
  });

  final String installationId;
  final String? machineId;
  final String? hostname;
  final String appName;
  final String appVersion;
  final String appBuild;
  final String appPlatform;
  final String osName;
  final String? osVersion;
  final String? deviceModel;

  String get fingerprint => jsonEncode(toJson());

  String get baseFingerprint => jsonEncode(toJson(includeMachineId: false));

  Map<String, Object?> toJson({bool includeMachineId = true}) {
    return <String, Object?>{
      if (includeMachineId && machineId != null) 'machine_id': machineId,
      if (hostname != null) 'hostname': hostname,
      'app_name': appName,
      'app_version': appVersion,
      'app_build': appBuild,
      'app_platform': appPlatform,
      'os_name': osName,
      if (osVersion != null) 'os_version': osVersion,
      if (deviceModel != null) 'device_model': deviceModel,
    };
  }
}

String _principalKeyFor(AuthSession session) {
  final email = session.user.email.trim().toLowerCase();
  if (email.isNotEmpty) {
    return 'email:$email';
  }
  final displayName = session.user.displayName.trim();
  if (displayName.isNotEmpty) {
    return 'display:$displayName';
  }
  return 'anonymous';
}

String? _emptyToNull(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

String _fallback(String value, String fallback) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? fallback : trimmed;
}

String _generateUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
