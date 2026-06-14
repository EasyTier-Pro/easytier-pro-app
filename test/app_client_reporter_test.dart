import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/telemetry/app_client_reporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reports app installation and throttles unchanged fingerprint', () async {
    SharedPreferences.setMockInitialValues({
      'app_client_installation_id': '11111111-1111-4111-8111-111111111111',
    });
    final preferences = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    var now = DateTime.utc(2026, 6, 14, 1);
    final reporter = AppClientReporter(
      preferences: preferences,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
      environmentLoader: _testEnvironment,
      now: () => now,
    );

    await reporter.reportSessionEstablished(_session('tenant-1'));
    await reporter.reportSessionEstablished(_session('tenant-1'));

    expect(requests, hasLength(1));
    expect(requests.single.method, 'PUT');
    expect(
      requests.single.url.path,
      '/api/v1/tenants/tenant-1/app-installations/11111111-1111-4111-8111-111111111111/report',
    );
    expect(requests.single.headers['Authorization'], 'Bearer access-token');
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['app_name'], 'EasyTier Pro');
    expect(body['app_version'], '1.2.3');
    expect(body['app_build'], '45');
    expect(body['app_platform'], 'windows');
    expect(body['os_name'], 'windows');
    expect(body['os_version'], 'Windows 11');
    expect(body['hostname'], 'desktop-1');
    expect(body.containsKey('machine_id'), isFalse);

    now = now.add(const Duration(hours: 25));
    await reporter.reportSessionEstablished(_session('tenant-1'));

    expect(requests, hasLength(2));
  });

  test('reports machine id immediately after base report', () async {
    SharedPreferences.setMockInitialValues({
      'app_client_installation_id': '22222222-2222-4222-8222-222222222222',
    });
    final preferences = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final reporter = AppClientReporter(
      preferences: preferences,
      consoleBaseUrl: 'https://console.test/',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
      environmentLoader: _testEnvironment,
      now: () => DateTime.utc(2026, 6, 14, 1),
    );

    await reporter.reportSessionEstablished(_session('tenant-1'));
    await reporter.reportMachineReady(
      _session('tenant-1'),
      '33333333-3333-4333-8333-333333333333',
    );

    expect(requests, hasLength(2));
    final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(body['machine_id'], '33333333-3333-4333-8333-333333333333');
  });

  test(
    'does not resend base report immediately after machine report',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_client_installation_id': '44444444-4444-4444-8444-444444444444',
      });
      final preferences = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final reporter = AppClientReporter(
        preferences: preferences,
        consoleBaseUrl: 'https://console.test',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
        environmentLoader: _testEnvironment,
        now: () => DateTime.utc(2026, 6, 14, 1),
      );

      await reporter.reportSessionEstablished(_session('tenant-1'));
      await reporter.reportMachineReady(
        _session('tenant-1'),
        '55555555-5555-4555-8555-555555555555',
      );
      await reporter.reportSessionEstablished(_session('tenant-1'));

      expect(requests, hasLength(2));
    },
  );

  test('reports again when user changes in same tenant', () async {
    SharedPreferences.setMockInitialValues({
      'app_client_installation_id': '66666666-6666-4666-8666-666666666666',
    });
    final preferences = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final reporter = AppClientReporter(
      preferences: preferences,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
      environmentLoader: _testEnvironment,
      now: () => DateTime.utc(2026, 6, 14, 1),
    );

    await reporter.reportSessionEstablished(
      _session('tenant-1', email: 'alice@example.com'),
    );
    await reporter.reportSessionEstablished(
      _session('tenant-1', email: 'bob@example.com'),
    );

    expect(requests, hasLength(2));
  });

  test('serializes same tenant reports so newer user wins', () async {
    SharedPreferences.setMockInitialValues({
      'app_client_installation_id': '77777777-7777-4777-8777-777777777777',
    });
    final preferences = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final responses = <Completer<http.Response>>[];
    final reporter = AppClientReporter(
      preferences: preferences,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) {
        requests.add(request);
        final response = Completer<http.Response>();
        responses.add(response);
        return response.future;
      }),
      environmentLoader: _testEnvironment,
      now: () => DateTime.utc(2026, 6, 14, 1),
    );

    final aliceReport = reporter.reportSessionEstablished(
      _session('tenant-1', email: 'alice@example.com'),
    );
    await _waitForRequests(requests, 1);

    final bobReport = reporter.reportSessionEstablished(
      _session('tenant-1', email: 'bob@example.com'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));

    responses.first.complete(http.Response('{}', 200));
    await _waitForRequests(requests, 2);

    responses.last.complete(http.Response('{}', 200));
    await Future.wait([aliceReport, bobReport]);

    expect(
      preferences.getString('app_client_report_principal_tenant-1'),
      'email:bob@example.com',
    );
  });
}

Future<void> _waitForRequests(List<http.Request> requests, int count) async {
  for (var attempt = 0; attempt < 50 && requests.length < count; attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(requests, hasLength(count));
}

Future<AppClientEnvironment> _testEnvironment() async {
  return const AppClientEnvironment(
    appName: 'EasyTier Pro',
    appVersion: '1.2.3',
    appBuild: '45',
    appPlatform: 'windows',
    osName: 'windows',
    osVersion: 'Windows 11',
    hostname: 'desktop-1',
  );
}

AuthSession _session(String workspaceId, {String email = 'user@example.com'}) {
  return AuthSession(
    user: ConsoleUser(
      email: email,
      displayName: 'User',
      workspaces: [ConsoleWorkspace(id: workspaceId, name: 'Workspace')],
    ),
    tokenSet: TokenSet(
      accessToken: 'access-token',
      tokenType: 'Bearer',
      expiresIn: 3600,
      obtainedAt: DateTime.now().toUtc(),
    ),
  );
}
