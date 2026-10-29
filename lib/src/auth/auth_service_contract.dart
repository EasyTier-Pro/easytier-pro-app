part of 'console_auth_service.dart';

abstract class AuthService {
  Future<WorkspacePreferences> loadWorkspacePreferences(String accountId);

  Future<void> saveWorkspacePreferences(
    String accountId,
    WorkspacePreferences preferences,
  );

  Future<ConsoleUser> fetchCurrentUser(String accessToken);

  Future<void> authorizeDeviceWorkspace({
    required String accessToken,
    required String sourceWorkspaceId,
    required String deviceId,
    required String targetWorkspaceId,
  });

  Future<AuthSession?> restoreSession();

  Future<DeviceAuthInfo> startDeviceAuth();

  Future<AuthSession> completeDeviceAuth(
    DeviceAuthInfo info, {
    Future<bool> Function()? waitForForeground,
    int Function()? lifecycleGeneration,
  });

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

  Future<String> fetchRecommendedCoreVersion({
    required String accessToken,
    required String workspaceId,
  });

  Future<String> fetchLatestCoreVersion();

  Future<CoreBootstrapDefaults> fetchCoreBootstrapDefaults();

  Future<CoreBootstrapConfig> prepareCoreBootstrap({
    required String accessToken,
    required String workspaceId,
    String? enrollmentKeyId,
  });

  Future<void> logout();
}

abstract interface class RefreshableAuthService {
  Stream<SessionExpiredException> get sessionExpirations;

  Future<AuthSession> refreshSession(AuthSession session, {bool force = false});
}
