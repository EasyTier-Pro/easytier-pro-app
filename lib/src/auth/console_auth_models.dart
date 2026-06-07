part of 'console_auth_service.dart';

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DeviceAuthInfo {
  const DeviceAuthInfo({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String verificationUriComplete;
  final int expiresIn;
  final int interval;
}

class TokenSet {
  const TokenSet({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
    required this.obtainedAt,
    this.idToken,
    this.refreshToken,
  });

  final String accessToken;
  final String? idToken;
  final String? refreshToken;
  final String tokenType;
  final int expiresIn;
  final DateTime obtainedAt;

  bool get isExpired {
    final bufferSeconds = expiresIn > 120 ? 60 : 0;
    return DateTime.now().toUtc().isAfter(
      obtainedAt.toUtc().add(Duration(seconds: expiresIn - bufferSeconds)),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'access_token': accessToken,
      'id_token': idToken,
      'refresh_token': refreshToken,
      'token_type': tokenType,
      'expires_in': expiresIn,
      'obtained_at': obtainedAt.toUtc().toIso8601String(),
    };
  }

  factory TokenSet.fromJson(Map<String, dynamic> json) {
    return TokenSet(
      accessToken: json['access_token'] as String,
      idToken: json['id_token'] as String?,
      refreshToken: json['refresh_token'] as String?,
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 3600,
      obtainedAt: DateTime.parse(json['obtained_at'] as String).toUtc(),
    );
  }
}

class ConsoleUser {
  const ConsoleUser({
    required this.email,
    required this.displayName,
    required this.workspaces,
  });

  final String email;
  final String displayName;
  final List<ConsoleWorkspace> workspaces;

  List<String> get tenantNames =>
      workspaces.map((workspace) => workspace.name).toList(growable: false);

  ConsoleWorkspace? get currentWorkspace =>
      workspaces.isEmpty ? null : workspaces.first;

  String get effectiveName => displayName.isEmpty ? email : displayName;
}

class ConsoleWorkspace {
  const ConsoleWorkspace({required this.id, required this.name});

  final String id;
  final String name;
}

class ConsoleNetwork {
  const ConsoleNetwork({
    required this.id,
    required this.name,
    this.regions = const <String>[],
    this.ipv4Cidr = '',
    this.runtimeNetworkName = '',
    this.lifecycleState = '',
  });

  final String id;
  final String name;
  final List<String> regions;
  final String ipv4Cidr;
  final String runtimeNetworkName;
  final String lifecycleState;
}

class ConsoleRegion {
  const ConsoleRegion({
    required this.id,
    required this.code,
    required this.displayName,
    required this.status,
  });

  final String id;
  final String code;
  final String displayName;
  final String status;

  bool get active => status.toLowerCase() == 'active';
}

class NetworkDevice {
  const NetworkDevice({
    required this.id,
    required this.name,
    required this.online,
    this.hostname = '',
    this.ipv4,
    this.deviceId,
    this.machineId,
    this.os = '',
    this.osVersion = '',
    this.osDistribution = '',
    this.connectivityState = '',
    this.desiredState = '',
    this.lifecycleState = '',
  });

  final String id;
  final String name;
  final bool online;
  final String hostname;
  final String? ipv4;
  final String? deviceId;
  final String? machineId;
  final String os;
  final String osVersion;
  final String osDistribution;
  final String connectivityState;
  final String desiredState;
  final String lifecycleState;

  bool get attached {
    final desired = desiredState.toLowerCase();
    final lifecycle = lifecycleState.toLowerCase();
    final connectivity = connectivityState.toLowerCase();
    return desired != 'absent' &&
        lifecycle != 'delete_pending' &&
        lifecycle != 'deleted' &&
        connectivity != 'removed';
  }

  String get displayLabel {
    final label = name.trim();
    if (label.isNotEmpty) {
      return label;
    }
    final host = hostname.trim();
    return host.isNotEmpty ? host : id;
  }
}

class ManagedDevice {
  const ManagedDevice({
    required this.id,
    required this.machineId,
    required this.hostname,
    required this.approvalState,
    required this.connectivityState,
    this.displayName = '',
    this.os = '',
    this.osVersion = '',
    this.osDistribution = '',
    this.lifecycleState = '',
    this.desiredState = '',
  });

  final String id;
  final String machineId;
  final String hostname;
  final String displayName;
  final String approvalState;
  final String connectivityState;
  final String os;
  final String osVersion;
  final String osDistribution;
  final String lifecycleState;
  final String desiredState;

  bool get approved => approvalState.toLowerCase() == 'approved';
  bool get online => connectivityState.toLowerCase() == 'online';
  String get displayLabel {
    final label = displayName.trim();
    if (label.isNotEmpty) {
      return label;
    }
    final host = hostname.trim();
    return host.isNotEmpty ? host : machineId;
  }

  bool get removed {
    final approval = approvalState.toLowerCase();
    final connectivity = connectivityState.toLowerCase();
    final lifecycle = lifecycleState.toLowerCase();
    final desired = desiredState.toLowerCase();
    return approval == 'removed' ||
        connectivity == 'removed' ||
        lifecycle == 'deleted' ||
        desired == 'absent';
  }
}

class AttachNetworkResult {
  const AttachNetworkResult({required this.nodeId, this.operationId});

  final String nodeId;
  final String? operationId;
}

class CoreBootstrapConfig {
  const CoreBootstrapConfig({
    required this.bootstrapToken,
    required this.version,
    required this.configServer,
  });

  final String bootstrapToken;
  final String version;
  final String configServer;
}

class AuthSession {
  const AuthSession({required this.user, required this.tokenSet});

  final ConsoleUser user;
  final TokenSet tokenSet;
}
