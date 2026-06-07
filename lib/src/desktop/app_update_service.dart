import 'dart:io';

import 'package:auto_updater/auto_updater.dart';

import '../logging/app_logger.dart';

const String _appcastFeedUrl = String.fromEnvironment('EASYTIER_APPCAST_URL');
const int _updateCheckIntervalSeconds = int.fromEnvironment(
  'EASYTIER_UPDATE_CHECK_INTERVAL_SECONDS',
  defaultValue: 3600,
);

class AppUpdateService {
  const AppUpdateService();

  Future<void> initialize() async {
    if (!Platform.isWindows) {
      return;
    }

    final feedUrl = _appcastFeedUrl.trim();
    if (feedUrl.isEmpty) {
      AppLogger.instance.info(
        'app.update',
        'Windows app updater disabled because EASYTIER_APPCAST_URL is empty',
      );
      return;
    }

    try {
      final interval = _normalizedCheckIntervalSeconds;
      AppLogger.instance.info(
        'app.update',
        'Initializing Windows app updater',
        context: {'feed_url': feedUrl, 'interval_seconds': interval},
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
}
