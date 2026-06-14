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
    final platform = _supportedPlatformName;
    if (platform == null) {
      return;
    }

    try {
      final preparation = await _prepareUpdater();
      if (!preparation.ready) {
        _logPreparationFailure(platform, preparation);
        return;
      }

      final interval = _normalizedCheckIntervalSeconds;
      AppLogger.instance.info(
        'app.update',
        'Initializing $platform app updater',
        context: {
          'feed_url': preparation.feedUrl,
          'interval_seconds': interval,
          'platform': platform,
        },
      );
      await autoUpdater.setScheduledCheckInterval(interval);
      await autoUpdater.checkForUpdates(inBackground: true);
    } catch (error, stack) {
      AppLogger.instance.error(
        'app.update',
        error.toString(),
        context: {'stack': stack.toString()},
      );
    }
  }

  Future<AppUpdateCheckResult> checkForUpdates() async {
    final platform = _supportedPlatformName;
    if (platform == null) {
      return const AppUpdateCheckResult(
        AppUpdateCheckStatus.unsupportedPlatform,
      );
    }

    try {
      final preparation = await _prepareUpdater();
      if (!preparation.ready) {
        _logPreparationFailure(platform, preparation);
        return AppUpdateCheckResult(preparation.status);
      }

      AppLogger.instance.info(
        'app.update',
        'Manually checking $platform app updates',
        context: {'feed_url': preparation.feedUrl, 'platform': platform},
      );
      await autoUpdater.checkForUpdates(inBackground: false);
      return AppUpdateCheckResult(
        AppUpdateCheckStatus.started,
        feedUrl: preparation.feedUrl,
      );
    } catch (error, stack) {
      AppLogger.instance.error(
        'app.update',
        'Manual update check failed',
        context: {'error': error.toString(), 'stack': stack.toString()},
      );
      return AppUpdateCheckResult(AppUpdateCheckStatus.failed, error: error);
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

  String? get _supportedPlatformName {
    if (Platform.isMacOS) {
      return 'macOS';
    }
    if (Platform.isWindows) {
      return 'Windows';
    }
    return null;
  }

  Future<_AppUpdatePreparation> _prepareUpdater() async {
    final feedUrls = _configuredAppcastFeedUrls;
    if (feedUrls.isEmpty) {
      return const _AppUpdatePreparation(
        status: AppUpdateCheckStatus.noFeedConfigured,
      );
    }

    final client = httpClient ?? http.Client();
    try {
      final feedUrl = await _selectReachableFeedUrl(
        client: client,
        feedUrls: feedUrls,
      );
      if (feedUrl == null) {
        return const _AppUpdatePreparation(
          status: AppUpdateCheckStatus.noReachableFeed,
        );
      }

      await autoUpdater.setFeedURL(feedUrl);
      return _AppUpdatePreparation(
        status: AppUpdateCheckStatus.started,
        feedUrl: feedUrl,
      );
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  void _logPreparationFailure(
    String platform,
    _AppUpdatePreparation preparation,
  ) {
    switch (preparation.status) {
      case AppUpdateCheckStatus.noFeedConfigured:
        AppLogger.instance.info(
          'app.update',
          '$platform app updater disabled because no appcast feed URLs are configured',
        );
        break;
      case AppUpdateCheckStatus.noReachableFeed:
        AppLogger.instance.warn(
          'app.update',
          '$platform app updater disabled because no appcast feed was reachable',
          context: {'feed_urls': _configuredAppcastFeedUrls},
        );
        break;
      case AppUpdateCheckStatus.started:
      case AppUpdateCheckStatus.unsupportedPlatform:
      case AppUpdateCheckStatus.failed:
        break;
    }
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

enum AppUpdateCheckStatus {
  started,
  unsupportedPlatform,
  noFeedConfigured,
  noReachableFeed,
  failed,
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult(this.status, {this.feedUrl, this.error});

  final AppUpdateCheckStatus status;
  final String? feedUrl;
  final Object? error;
}

class _AppUpdatePreparation {
  const _AppUpdatePreparation({required this.status, this.feedUrl});

  final AppUpdateCheckStatus status;
  final String? feedUrl;

  bool get ready =>
      status == AppUpdateCheckStatus.started && feedUrl?.isNotEmpty == true;
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
