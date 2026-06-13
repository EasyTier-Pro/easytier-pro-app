import 'package:easytier_pro_app/src/desktop/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
