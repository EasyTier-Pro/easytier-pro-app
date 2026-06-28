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

class NetworkSubnetRouteList {
  const NetworkSubnetRouteList({
    required this.routes,
    required this.allowedProxyCidrs,
    required this.quotaLimit,
    required this.quotaUsed,
  });

  final List<NetworkSubnetRoute> routes;
  final List<String> allowedProxyCidrs;
  final int quotaLimit;
  final int quotaUsed;
}

class NetworkSubnetRoute {
  const NetworkSubnetRoute({
    required this.id,
    required this.cidr,
    this.mappedCidr,
    this.nodeIds = const <String>[],
    this.nodes = const <SubnetRouteNodeSummary>[],
    this.manualRouteNodeIds = const <String>[],
    this.manualRouteNodes = const <SubnetRouteNodeSummary>[],
  });

  final String id;
  final String cidr;
  final String? mappedCidr;
  final List<String> nodeIds;
  final List<SubnetRouteNodeSummary> nodes;
  final List<String> manualRouteNodeIds;
  final List<SubnetRouteNodeSummary> manualRouteNodes;
}

class SubnetRouteNodeSummary {
  const SubnetRouteNodeSummary({
    required this.id,
    required this.hostname,
    required this.machineId,
    required this.status,
    required this.provisioningState,
  });

  final String id;
  final String hostname;
  final String machineId;
  final String status;
  final String provisioningState;

  String get displayLabel {
    final host = hostname.trim();
    if (host.isNotEmpty) {
      return host;
    }
    final machine = machineId.trim();
    return machine.isNotEmpty ? machine : id;
  }
}

class AssignedSubnetRoute {
  const AssignedSubnetRoute({
    required this.id,
    required this.cidr,
    this.mappedCidr,
  });

  final String id;
  final String cidr;
  final String? mappedCidr;
}

class NodeInstanceConfigSettings {
  const NodeInstanceConfigSettings({
    this.ipv4,
    this.hostname,
    this.kcpProxyEnabled,
    this.kcpInputEnabled,
    this.quicProxyEnabled,
    this.quicInputEnabled,
    this.noTun,
    this.holePunchUdpEnabled,
    this.holePunchTcpEnabled,
    this.disableSymHolePunching,
    this.p2pMode,
    this.proxyForwardBySystem,
    this.lazyP2p,
    this.needP2p,
    this.magicDnsEnabled,
    this.latencyFirst,
    this.userspaceStack,
    this.listenerProtocols = const <String>[],
  });

  final String? ipv4;
  final String? hostname;
  final bool? kcpProxyEnabled;
  final bool? kcpInputEnabled;
  final bool? quicProxyEnabled;
  final bool? quicInputEnabled;
  final bool? noTun;
  final bool? holePunchUdpEnabled;
  final bool? holePunchTcpEnabled;
  final bool? disableSymHolePunching;
  final String? p2pMode;
  final bool? proxyForwardBySystem;
  final bool? lazyP2p;
  final bool? needP2p;
  final bool? magicDnsEnabled;
  final bool? latencyFirst;
  final bool? userspaceStack;
  final List<String> listenerProtocols;
}

class NodeInstanceConfigView {
  const NodeInstanceConfigView({
    required this.defaults,
    required this.overrides,
    required this.effective,
    required this.configScope,
    required this.applyStatus,
    required this.driftStatus,
    this.lastAppliedAt,
    this.lastApplyError,
    this.assignedSubnetRoutes = const <AssignedSubnetRoute>[],
    this.manualSubnetRoutes = const <AssignedSubnetRoute>[],
    this.manualRoutesEnabled = false,
  });

  final NodeInstanceConfigSettings defaults;
  final NodeInstanceConfigSettings overrides;
  final NodeInstanceConfigSettings effective;
  final String configScope;
  final String applyStatus;
  final String driftStatus;
  final String? lastAppliedAt;
  final String? lastApplyError;
  final List<AssignedSubnetRoute> assignedSubnetRoutes;
  final List<AssignedSubnetRoute> manualSubnetRoutes;
  final bool manualRoutesEnabled;
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

class CoreBootstrapDefaults {
  const CoreBootstrapDefaults({
    required this.version,
    required this.configServer,
  });

  final String version;
  final String configServer;
}

class AuthSession {
  const AuthSession({required this.user, required this.tokenSet});

  final ConsoleUser user;
  final TokenSet tokenSet;
}
