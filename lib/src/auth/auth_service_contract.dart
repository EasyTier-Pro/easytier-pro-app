part of 'console_auth_service.dart';

abstract class AuthService {
  Future<AuthSession?> restoreSession();

  Future<DeviceAuthInfo> startDeviceAuth();

  Future<AuthSession> completeDeviceAuth(DeviceAuthInfo info);

  Future<List<ConsoleNetwork>> fetchNetworks({
    required String accessToken,
    required String workspaceId,
  });

  Future<List<ConsoleRegion>> fetchRegions({required String accessToken});

  Future<ConsoleNetwork> createNetwork({
    required String accessToken,
    required String workspaceId,
    required String name,
    required List<String> regions,
    String? ipv4Cidr,
  });

  Future<void> deleteNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  });

  Future<List<NetworkDevice>> fetchNetworkDevices({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  });

  Future<NetworkSubnetRouteList> fetchNetworkSubnetRoutes({
    required String accessToken,
    required String workspaceId,
    required String networkId,
  });

  Future<NodeInstanceConfigView> fetchNodeConfig({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  });

  Future<List<ManagedDevice>> fetchManagedDevices({
    required String accessToken,
    required String workspaceId,
  });

  Future<AttachNetworkResult> attachDeviceToNetwork({
    required String accessToken,
    required String workspaceId,
    required String networkId,
    required String deviceId,
  });

  Future<void> removeNetworkNode({
    required String accessToken,
    required String workspaceId,
    required String nodeId,
  });

  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
  });

  Future<void> logout();
}
