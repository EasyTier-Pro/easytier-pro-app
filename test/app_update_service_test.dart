import 'dart:async';

import 'package:easytier_pro_app/src/desktop/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AppUpdateService', () {
    test('serializes startup and manual update checks', () async {
      final requestedUrls = <String>[];
      final updateDriver = _RecordingAppUpdateDriver();
      final service = AppUpdateService(
        supportedPlatformName: () => 'Windows',
        updateDriver: updateDriver,
        httpClient: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          return http.Response(
            '<rss><channel><item><enclosure url="https://example/download" /></item></channel></rss>',
            200,
          );
        }),
      );

      final initialize = service.initialize();
      await updateDriver.backgroundCheckStarted.future;

      final manualCheck = service.checkForUpdates();
      await Future<void>.delayed(Duration.zero);

      expect(updateDriver.manualCheckStarted.isCompleted, isFalse);
      expect(updateDriver.calls, <String>[
        'setFeedURL:https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml',
        'setScheduledCheckInterval:3600',
        'checkForUpdates:true',
      ]);

      updateDriver.backgroundCheckRelease.complete();
      await initialize;

      final result = await manualCheck;

      expect(result.status, AppUpdateCheckStatus.started);
      expect(updateDriver.manualCheckStarted.isCompleted, isTrue);
      expect(updateDriver.calls, <String>[
        'setFeedURL:https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml',
        'setScheduledCheckInterval:3600',
        'checkForUpdates:true',
        'setFeedURL:https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml',
        'checkForUpdates:false',
      ]);
      expect(requestedUrls, <String>[
        'https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml',
        'https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml',
      ]);
    });
  });

  group('AppcastFeedResolver', () {
    test('parses feed URL list with priority order and removes duplicates', () {
      expect(
        AppcastFeedResolver.parseFeedUrls(
          ' https://gitee.example/appcast.xml ;'
          'https://oss.example/appcast.xml\n'
          'https://github.example/appcast.xml,'
          'https://oss.example/appcast.xml ',
        ),
        <String>[
          'https://gitee.example/appcast.xml',
          'https://oss.example/appcast.xml',
          'https://github.example/appcast.xml',
        ],
      );
    });

    test('resolves the first reachable appcast feed', () async {
      final requestedUrls = <String>[];
      final resolver = AppcastFeedResolver(
        timeout: const Duration(seconds: 1),
        client: MockClient((request) async {
          requestedUrls.add(request.url.toString());
          if (request.url.host == 'gitee.example') {
            return http.Response('', 404);
          }
          return http.Response(
            '<rss><channel><item><enclosure url="https://example/download" /></item></channel></rss>',
            200,
          );
        }),
      );

      final feedUrl = await resolver.resolve(const <String>[
        'https://gitee.example/appcast.xml',
        'https://oss.example/appcast.xml',
        'https://github.example/appcast.xml',
      ]);

      expect(feedUrl, 'https://oss.example/appcast.xml');
      expect(requestedUrls, <String>[
        'https://gitee.example/appcast.xml',
        'https://oss.example/appcast.xml',
      ]);
    });

    test(
      'rejects successful responses that do not look like appcast XML',
      () async {
        final resolver = AppcastFeedResolver(
          timeout: const Duration(seconds: 1),
          client: MockClient((_) async => http.Response('<html></html>', 200)),
        );

        expect(
          await resolver.isReachableAppcast(
            'https://gitee.example/appcast.xml',
          ),
          isFalse,
        );
      },
    );
  });
}

class _RecordingAppUpdateDriver implements AppUpdateDriver {
  final List<String> calls = <String>[];
  final Completer<void> backgroundCheckStarted = Completer<void>();
  final Completer<void> backgroundCheckRelease = Completer<void>();
  final Completer<void> manualCheckStarted = Completer<void>();

  @override
  Future<void> setFeedURL(String feedUrl) async {
    calls.add('setFeedURL:$feedUrl');
  }

  @override
  Future<void> setScheduledCheckInterval(int interval) async {
    calls.add('setScheduledCheckInterval:$interval');
  }

  @override
  Future<void> checkForUpdates({bool? inBackground}) async {
    calls.add('checkForUpdates:$inBackground');
    if (inBackground == true) {
      backgroundCheckStarted.complete();
      await backgroundCheckRelease.future;
      return;
    }
    manualCheckStarted.complete();
  }
}
