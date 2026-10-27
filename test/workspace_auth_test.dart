import 'dart:convert';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'workspace preferences are isolated by Console and stable account ID',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final a = ConsoleAuthService(
        tokenStore: OAuthTokenStore(prefs),
        consoleBaseUrl: 'https://a.test',
      );
      final b = ConsoleAuthService(
        tokenStore: OAuthTokenStore(prefs),
        consoleBaseUrl: 'https://b.test',
      );
      await a.saveWorkspacePreferences(
        'one',
        const WorkspacePreferences(
          sourceWorkspaceId: 'source',
          deviceId: 'device',
          enrollmentKeyId: 'key',
          selectedWorkspaceId: 'target',
        ),
      );
      expect((await a.loadWorkspacePreferences('one')).deviceId, 'device');
      expect((await a.loadWorkspacePreferences('two')).deviceId, isNull);
      expect((await b.loadWorkspacePreferences('one')).deviceId, isNull);
      expect(prefs.getKeys(), hasLength(1));
      expect(
        prefs.getString(prefs.getKeys().single),
        isNot(contains('bootstrap_token')),
      );
    },
  );

  test(
    'restoring bootstrap uses only the bound key and never acquires another',
    () async {
      SharedPreferences.setMockInitialValues({});
      final paths = <String>[];
      final service = await authenticatedService((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/v1/releases/latest') {
          return json({'version': 'v2.6.4'});
        }
        if (request.url.path.endsWith('/bound-key/secret')) {
          return json({'bootstrap_token': 'bound-secret'});
        }
        return json({'message': 'unexpected'}, 500);
      });
      final bootstrap = await service.prepareCoreBootstrap(
        accessToken: 'access',
        workspaceId: 'source',
        enrollmentKeyId: 'bound-key',
      );
      expect(bootstrap.enrollmentKeyId, 'bound-key');
      expect(bootstrap.bootstrapToken, 'bound-secret');
      expect(paths, [
        'GET /api/v1/releases/latest',
        'GET /api/v1/tenants/source/device-enrollment-keys/bound-key/secret',
      ]);
    },
  );

  test(
    'sharing uses the Console member default and source canonical device',
    () async {
      SharedPreferences.setMockInitialValues({});
      final requests = <http.Request>[];
      final service = await authenticatedService((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/device-enrollment-keys')) {
          return json({
            'enrollment_key': {'id': 'target-default'},
            'bootstrap_token': 'unused-secret',
          });
        }
        return json({'approval_state': 'pending'}, 201);
      });
      await service.authorizeDeviceWorkspace(
        accessToken: 'access',
        sourceWorkspaceId: 'source',
        deviceId: 'canonical',
        targetWorkspaceId: 'target',
      );
      expect(requests.map((r) => r.url.path), [
        '/api/v1/tenants/target/device-enrollment-keys',
        '/api/v1/tenants/source/devices/canonical/shares',
      ]);
      final acquisition =
          jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(
        acquisition['display_name'],
        anyOf('Desktop Auto Key', 'Android Auto Key'),
      );
      expect(acquisition['reusable'], isTrue);
      expect(acquisition['pre_approved'], isTrue);
      expect(jsonDecode(requests.last.body), {
        'target_workspace_id': 'target',
        'enrollment_key_id': 'target-default',
      });
    },
  );

  test(
    'shared pending approval and permissions survive device parsing',
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = await authenticatedService(
        (request) async => json([
          {
            'id': 'canonical',
            'machine_id': 'machine',
            'tenant_id': 'source',
            'approval_state': 'approved',
            'connectivity_state': 'online',
            'workspace_authorization': {
              'approval_state': 'pending',
              'desired_state': 'present',
            },
            'permissions': {'can_manage_nodes': false},
          },
        ]),
      );
      final devices = await service.fetchManagedDevices(
        accessToken: 'access',
        workspaceId: 'target',
      );
      expect(devices.single.workspaceId, 'source');
      expect(devices.single.approved, isFalse);
      expect(devices.single.canManageNodes, isFalse);
    },
  );
}

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<ConsoleAuthService> authenticatedService(
  Future<http.Response> Function(http.Request) handler,
) async {
  final store = OAuthTokenStore(await SharedPreferences.getInstance());
  await store.save(
    TokenSet(
      accessToken: 'access',
      tokenType: 'Bearer',
      expiresIn: 3600,
      obtainedAt: DateTime.now(),
    ),
  );
  final service = ConsoleAuthService(
    tokenStore: store,
    consoleBaseUrl: 'https://console.test',
    httpClient: MockClient((request) async {
      if (request.url.path == '/api/v1/auth/me') {
        return json({
          'user': {'id': 'account', 'email': 'test@example.com'},
          'tenants': [
            {'id': 'source', 'name': 'Source'},
          ],
        });
      }
      return handler(request);
    }),
  );
  await service.restoreSession();
  return service;
}
