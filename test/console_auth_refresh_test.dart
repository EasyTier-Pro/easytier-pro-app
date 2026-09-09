import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';

void main() {
  test('restores an expired session by refreshing its token', () async {
    final store = await _expiredTokenStore();
    final requests = <http.Request>[];
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/v1/auth/device/refresh') {
          expect(request.bodyFields['refresh_token'], 'refresh-old');
          return _jsonResponse({
            'access_token': 'access-new',
            'refresh_token': 'refresh-new',
            'token_type': 'Bearer',
            'expires_in': 3600,
          });
        }
        if (request.url.path == '/api/v1/auth/me') {
          expect(request.headers['authorization'], 'Bearer access-new');
          return _userResponse();
        }
        return _jsonResponse({'message': 'not found'}, 404);
      }),
    );

    final session = await service.restoreSession();

    expect(session?.tokenSet.accessToken, 'access-new');
    expect(session?.tokenSet.refreshToken, 'refresh-new');
    expect((await store.load())?.accessToken, 'access-new');
    expect(requests.map((request) => request.url.path), [
      '/api/v1/auth/device/refresh',
      '/api/v1/auth/me',
    ]);
  });

  test('keeps the previous refresh token when rotation is omitted', () async {
    final store = await _expiredTokenStore();
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/device/refresh') {
          return _jsonResponse({
            'access_token': 'access-new',
            'token_type': 'Bearer',
            'expires_in': 3600,
          });
        }
        if (request.url.path == '/api/v1/auth/me') {
          return _userResponse();
        }
        return _jsonResponse({'message': 'not found'}, 404);
      }),
    );

    final session = await service.restoreSession();

    expect(session?.tokenSet.refreshToken, 'refresh-old');
    expect((await store.load())?.refreshToken, 'refresh-old');
  });

  test('retries concurrent unauthorized requests with one refresh', () async {
    final store = await _activeTokenStore();
    final bothUnauthorized = Completer<void>();
    var unauthorizedCount = 0;
    var refreshCount = 0;
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/me') {
          return _userResponse();
        }
        if (request.url.path == '/api/v1/auth/device/refresh') {
          refreshCount++;
          await bothUnauthorized.future;
          return _jsonResponse({
            'access_token': 'access-new',
            'refresh_token': 'refresh-new',
            'token_type': 'Bearer',
            'expires_in': 3600,
          });
        }
        if (request.url.path == '/api/v1/regions') {
          if (request.headers['authorization'] == 'Bearer access-old') {
            unauthorizedCount++;
            if (unauthorizedCount == 2 && !bothUnauthorized.isCompleted) {
              bothUnauthorized.complete();
            }
            return _jsonResponse({'message': 'unauthorized'}, 401);
          }
          expect(request.headers['authorization'], 'Bearer access-new');
          return _jsonResponse({
            'regions': [
              {
                'id': 'region-1',
                'code': 'ap-east',
                'display_name': '华东',
                'status': 'active',
              },
            ],
          });
        }
        return _jsonResponse({'message': 'not found'}, 404);
      }),
    );
    final session = await service.restoreSession();

    final results = await Future.wait([
      service.fetchRegions(accessToken: session!.tokenSet.accessToken),
      service.fetchRegions(accessToken: session.tokenSet.accessToken),
    ]);

    expect(refreshCount, 1);
    expect(results[0].single.code, 'ap-east');
    expect(results[1].single.code, 'ap-east');
  });

  test('notifies the app when an API refresh token is rejected', () async {
    final store = await _activeTokenStore();
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/me') {
          return _userResponse();
        }
        if (request.url.path == '/api/v1/regions') {
          return _jsonResponse({'message': 'unauthorized'}, 401);
        }
        if (request.url.path == '/api/v1/auth/device/refresh') {
          return _jsonResponse({
            'error': 'invalid_grant',
            'error_description': 'refresh token expired',
          }, 400);
        }
        return _jsonResponse({'message': 'not found'}, 404);
      }),
    );
    final session = await service.restoreSession();
    final expiration = service.sessionExpirations.first;

    await expectLater(
      service.fetchRegions(accessToken: session!.tokenSet.accessToken),
      throwsA(isA<SessionExpiredException>()),
    );

    expect(
      await expiration.timeout(const Duration(seconds: 1)),
      isA<SessionExpiredException>(),
    );
    expect(await store.load(), isNull);
  });

  test('does not replay a stale request with a new session token', () async {
    final store = await _activeTokenStore();
    final requestStarted = Completer<void>();
    final releaseRequest = Completer<void>();
    final regionAuthorizations = <String?>[];
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/me') {
          return _userResponse();
        }
        if (request.url.path == '/api/v1/regions') {
          regionAuthorizations.add(request.headers['authorization']);
          if (!requestStarted.isCompleted) {
            requestStarted.complete();
          }
          await releaseRequest.future;
          return _jsonResponse({'message': 'unauthorized'}, 401);
        }
        return _jsonResponse({'message': 'not found'}, 404);
      }),
    );
    final sessionA = await service.restoreSession();
    final staleRequest = expectLater(
      service.fetchRegions(accessToken: sessionA!.tokenSet.accessToken),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          contains('登录状态已更新'),
        ),
      ),
    );
    await requestStarted.future;

    await service.logout();
    await store.save(_activeTokenSet('access-b', 'refresh-b'));
    final sessionB = await service.restoreSession();
    releaseRequest.complete();

    await staleRequest;
    await expectLater(
      service.fetchRegions(accessToken: sessionA.tokenSet.accessToken),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          contains('登录状态已更新'),
        ),
      ),
    );
    expect(sessionB?.tokenSet.accessToken, 'access-b');
    expect(regionAuthorizations, ['Bearer access-old']);
    expect((await store.load())?.accessToken, 'access-b');
  });

  test('a stale invalid grant does not clear the new session', () async {
    final store = await _activeTokenStore();
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();
    final expirations = <SessionExpiredException>[];
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/me') {
          return _userResponse();
        }
        if (request.url.path == '/api/v1/regions') {
          return _jsonResponse({'message': 'unauthorized'}, 401);
        }
        if (request.url.path == '/api/v1/auth/device/refresh') {
          refreshStarted.complete();
          await releaseRefresh.future;
          return _jsonResponse({
            'error': 'invalid_grant',
            'error_description': 'refresh token expired',
          }, 400);
        }
        return _jsonResponse({'message': 'not found'}, 404);
      }),
    );
    final expirationSubscription = service.sessionExpirations.listen(
      expirations.add,
    );
    addTearDown(expirationSubscription.cancel);
    final sessionA = await service.restoreSession();
    final staleRequest = expectLater(
      service.fetchRegions(accessToken: sessionA!.tokenSet.accessToken),
      throwsA(isA<SessionExpiredException>()),
    );
    await refreshStarted.future;

    await service.logout();
    await store.save(_activeTokenSet('access-b', 'refresh-b'));
    final sessionB = await service.restoreSession();
    releaseRefresh.complete();

    await staleRequest;
    await Future<void>.delayed(Duration.zero);
    expect(sessionB?.tokenSet.accessToken, 'access-b');
    expect((await store.load())?.accessToken, 'access-b');
    expect(expirations, isEmpty);
  });

  test('clears a session only when the refresh token is rejected', () async {
    final store = await _expiredTokenStore();
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/v1/auth/device/refresh');
        return _jsonResponse({
          'error': 'invalid_grant',
          'error_description': 'refresh token expired',
        }, 400);
      }),
    );

    expect(await service.restoreSession(), isNull);
    expect(await store.load(), isNull);
  });

  test(
    'keeps the session when token refresh is temporarily unavailable',
    () async {
      final store = await _expiredTokenStore();
      final service = ConsoleAuthService(
        tokenStore: store,
        consoleBaseUrl: 'https://console.test',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/auth/device/refresh');
          return _jsonResponse({
            'error': 'temporarily_unavailable',
            'error_description': 'try again',
          }, 503);
        }),
      );

      await expectLater(
        service.restoreSession(),
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            contains('暂时无法刷新'),
          ),
        ),
      );
      expect((await store.load())?.refreshToken, 'refresh-old');
    },
  );

  test('does not restore a token when logout races with refresh', () async {
    final store = await _expiredTokenStore();
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();
    final service = ConsoleAuthService(
      tokenStore: store,
      consoleBaseUrl: 'https://console.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/v1/auth/device/refresh');
        refreshStarted.complete();
        await releaseRefresh.future;
        return _jsonResponse({
          'access_token': 'access-new',
          'refresh_token': 'refresh-new',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      }),
    );

    final restore = service.restoreSession();
    await refreshStarted.future;
    await service.logout();
    releaseRefresh.complete();

    expect(await restore, isNull);
    expect(await store.load(), isNull);
  });
}

Future<OAuthTokenStore> _expiredTokenStore() async {
  final store = await _tokenStore();
  await store.save(
    TokenSet(
      accessToken: 'access-old',
      refreshToken: 'refresh-old',
      tokenType: 'Bearer',
      expiresIn: 3600,
      obtainedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
    ),
  );
  return store;
}

Future<OAuthTokenStore> _activeTokenStore() async {
  final store = await _tokenStore();
  await store.save(_activeTokenSet('access-old', 'refresh-old'));
  return store;
}

TokenSet _activeTokenSet(String accessToken, String refreshToken) {
  return TokenSet(
    accessToken: accessToken,
    refreshToken: refreshToken,
    tokenType: 'Bearer',
    expiresIn: 3600,
    obtainedAt: DateTime.now().toUtc(),
  );
}

Future<OAuthTokenStore> _tokenStore() async {
  SharedPreferences.setMockInitialValues({});
  return OAuthTokenStore(await SharedPreferences.getInstance());
}

http.Response _userResponse() {
  return _jsonResponse({
    'user': {'email': 'tester@example.com', 'display_name': 'Tester'},
    'tenants': [
      {'id': 'tenant-1', 'name': 'Test Workspace'},
    ],
  });
}

http.Response _jsonResponse(Object body, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
