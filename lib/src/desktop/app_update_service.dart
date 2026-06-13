import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:http/http.dart' as http;

import '../logging/app_logger.dart';

const String _appcastFeedUrlsOverride = String.fromEnvironment(
  'EASYTIER_APPCAST_URLS',
);
const int _updateCheckIntervalSeconds = int.fromEnvironment(
  'EASYTIER_UPDATE_CHECK_INTERVAL_SECONDS',
  defaultValue: 3600,
);
const Duration _appcastFeedProbeTimeout = Duration(seconds: 5);
const List<String> _defaultAppcastFeedUrls = [
  'https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml',
  'https://easytier.net/releases/appcast.xml',
  'https://github.com/EasyTier-Pro/easytier-pro-app/releases/latest/download/appcast.xml',
];

class AppUpdateService {
  const AppUpdateService({this.httpClient});

  final http.Client? httpClient;

  Future<void> initialize() async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      return;
    }

    final platform = Platform.isMacOS ? 'macOS' : 'Windows';
    final feedUrls = _configuredAppcastFeedUrls;
    if (feedUrls.isEmpty) {
      AppLogger.instance.info(
        'app.update',
        '$platform app updater disabled because no appcast feed URLs are configured',
      );
      return;
    }

    final client = httpClient ?? http.Client();
    try {
      final feedUrl = await _selectReachableFeedUrl(
        client: client,
        feedUrls: feedUrls,
      );
      if (feedUrl == null) {
        AppLogger.instance.warn(
          'app.update',
          '$platform app updater disabled because no appcast feed was reachable',
          context: {'feed_urls': feedUrls},
        );
        return;
      }

      final interval = _normalizedCheckIntervalSeconds;
      AppLogger.instance.info(
        'app.update',
        'Initializing $platform app updater',
        context: {
          'feed_url': feedUrl,
          'interval_seconds': interval,
          'platform': platform,
        },
      );
      await autoUpdater.setFeedURL(feedUrl);
      await autoUpdater.setScheduledCheckInterval(interval);
      await autoUpdater.checkForUpdates(inBackground: true);
    } catch (error, stack) {
      AppLogger.instance.error(
        'app.update',
        error.toString(),
        context: {'stack': stack.toString()},
      );
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  int get _normalizedCheckIntervalSeconds {
    if (_updateCheckIntervalSeconds == 0) {
      return 0;
    }
    if (_updateCheckIntervalSeconds < 3600) {
      return 3600;
    }
    return _updateCheckIntervalSeconds;
  }

  List<String> get _configuredAppcastFeedUrls {
    final override = _appcastFeedUrlsOverride.trim();
    if (override.isNotEmpty) {
      return AppcastFeedResolver.parseFeedUrls(override);
    }
    return _defaultAppcastFeedUrls;
  }

  Future<String?> _selectReachableFeedUrl({
    required http.Client client,
    required List<String> feedUrls,
  }) async {
    final resolver = AppcastFeedResolver(
      client: client,
      timeout: _appcastFeedProbeTimeout,
    );

    for (final feedUrl in feedUrls) {
      AppLogger.instance.info(
        'app.update',
        'Probing appcast feed',
        context: {'feed_url': feedUrl},
      );
      if (await resolver.isReachableAppcast(feedUrl)) {
        return feedUrl;
      }
    }
    return null;
  }
}

class AppcastFeedResolver {
  const AppcastFeedResolver({
    required this.client,
    this.timeout = _appcastFeedProbeTimeout,
  });

  final http.Client client;
  final Duration timeout;

  static List<String> parseFeedUrls(String value) {
    final seen = <String>{};
    final urls = <String>[];

    for (final part in value.split(RegExp(r'[\s,;]+'))) {
      final url = part.trim();
      if (url.isEmpty || seen.contains(url)) {
        continue;
      }
      seen.add(url);
      urls.add(url);
    }

    return urls;
  }

  Future<bool> isReachableAppcast(String feedUrl) async {
    final uri = Uri.tryParse(feedUrl);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return false;
    }

    try {
      final response = await client
          .get(
            uri,
            headers: const {
              HttpHeaders.acceptHeader: 'application/rss+xml, text/xml, */*',
            },
          )
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      return _looksLikeAppcast(response.body);
    } catch (_) {
      return false;
    }
  }

  Future<String?> resolve(Iterable<String> feedUrls) async {
    for (final feedUrl in feedUrls) {
      if (await isReachableAppcast(feedUrl)) {
        return feedUrl;
      }
    }
    return null;
  }

  bool _looksLikeAppcast(String body) {
    final normalized = body.toLowerCase();
    return normalized.contains('<rss') &&
        normalized.contains('<channel') &&
        normalized.contains('<enclosure');
  }
}
