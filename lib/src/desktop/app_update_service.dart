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
  AppUpdateService({
    this.httpClient,
    this.updateDriver = const AutoUpdaterDriver(),
    String? Function()? supportedPlatformName,
  }) : _supportedPlatformNameOverride = supportedPlatformName;

  final http.Client? httpClient;
  final AppUpdateDriver updateDriver;
  final String? Function()? _supportedPlatformNameOverride;
  Future<void> _updateOperation = Future<void>.value();

  Future<void> initialize() async {
    final platform = _supportedPlatformName;
    if (platform == null) {
      return;
    }

    await _runSerialized(
      () async {
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
        await updateDriver.setScheduledCheckInterval(interval);
        await updateDriver.checkForUpdates(inBackground: true);
      },
      onError: (error, stack) {
        AppLogger.instance.error(
          'app.update',
          error.toString(),
          context: {'stack': stack.toString()},
        );
      },
    );
  }

  Future<T?> _runSerialized<T>(
    Future<T> Function() operation, {
    void Function(Object error, StackTrace stack)? onError,
  }) {
    final previousOperation = _updateOperation;
    late final Future<T?> currentOperation;
    currentOperation = previousOperation
        .catchError((_) {
          return null;
        })
        .then((_) => operation())
        .then<T?>((value) => value)
        .catchError((Object error, StackTrace stack) {
          onError?.call(error, stack);
          return null;
        });
    _updateOperation = currentOperation.then<void>((_) {});
    return currentOperation;
  }

  Future<AppUpdateCheckResult> _runSerializedCheck(
    Future<AppUpdateCheckResult> Function() operation,
  ) async {
    final result = await _runSerialized(
      operation,
      onError: (error, stack) {
        AppLogger.instance.error(
          'app.update',
          'Manual update check failed',
          context: {'error': error.toString(), 'stack': stack.toString()},
        );
      },
    );
    return result ?? const AppUpdateCheckResult(AppUpdateCheckStatus.failed);
  }

  Future<AppUpdateCheckResult> _checkForUpdatesOnSupportedPlatform(
    String platform,
  ) async {
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
    await updateDriver.checkForUpdates(inBackground: false);
    return AppUpdateCheckResult(
      AppUpdateCheckStatus.started,
      feedUrl: preparation.feedUrl,
    );
  }

  String? get _supportedPlatformName {
    final override = _supportedPlatformNameOverride;
    if (override != null) {
      return override();
    }
    if (Platform.isMacOS) {
      return 'macOS';
    }
    if (Platform.isWindows) {
      return 'Windows';
    }
    return null;
  }

  Future<AppUpdateCheckResult> checkForUpdates() async {
    final platform = _supportedPlatformName;
    if (platform == null) {
      return const AppUpdateCheckResult(
        AppUpdateCheckStatus.unsupportedPlatform,
      );
    }

    return _runSerializedCheck(
      () => _checkForUpdatesOnSupportedPlatform(platform),
    );
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

      await updateDriver.setFeedURL(feedUrl);
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

abstract class AppUpdateDriver {
  Future<void> setFeedURL(String feedUrl);

  Future<void> setScheduledCheckInterval(int interval);

  Future<void> checkForUpdates({bool? inBackground});
}

class AutoUpdaterDriver implements AppUpdateDriver {
  const AutoUpdaterDriver();

  @override
  Future<void> setFeedURL(String feedUrl) {
    return autoUpdater.setFeedURL(feedUrl);
  }

  @override
  Future<void> setScheduledCheckInterval(int interval) {
    return autoUpdater.setScheduledCheckInterval(interval);
  }

  @override
  Future<void> checkForUpdates({bool? inBackground}) {
    return autoUpdater.checkForUpdates(inBackground: inBackground);
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
