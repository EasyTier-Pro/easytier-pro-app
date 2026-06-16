part of 'workspace_home_view.dart';

String _formatTrafficRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) {
    return '计算中';
  }
  return '${_formatBytes(bytesPerSecond)}/s';
}

String _formatCompactTrafficRate(num? bytesPerSecond) {
  if (bytesPerSecond == null) {
    return '计算中';
  }
  return '${_formatCompactBytes(bytesPerSecond)}/s';
}

String _formatCompactBytes(num bytes) {
  const units = <String>['B', 'K', 'M', 'G', 'T'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value = value / 1024;
    unitIndex++;
  }
  if (unitIndex == 0) {
    return '${value.round()}${units[unitIndex]}';
  }
  final decimals = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)}${units[unitIndex]}';
}

String _formatBytes(num bytes) {
  const units = <String>['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value = value / 1024;
    unitIndex++;
  }
  if (unitIndex == 0) {
    return '${value.round()} ${units[unitIndex]}';
  }
  final decimals = value >= 10 ? 1 : 2;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

String _coreEngineActionLabel(CoreEngineVersionStatus status) {
  if (status.updateAvailable) {
    final consoleVersion = status.consoleVersion;
    if (consoleVersion != null && consoleVersion.isNotEmpty) {
      return '更新连接引擎至 $consoleVersion';
    }
    return '更新连接引擎';
  }
  return '重装连接引擎';
}

String _coreEngineSettingsActionLabel(CoreEngineVersionStatus status) {
  return status.updateAvailable ? '更新连接引擎' : '重装连接引擎';
}

String? _coreEngineVersionHint(CoreEngineVersionStatus status) {
  final installedVersion = status.installedVersion;
  final consoleVersion = status.consoleVersion;
  return switch (status.relation) {
    CoreEngineVersionRelation.updateAvailable =>
      installedVersion != null && consoleVersion != null
          ? '当前版本 $installedVersion，控制台推荐版本 $consoleVersion。'
          : '控制台推荐版本已有更新。',
    CoreEngineVersionRelation.current =>
      installedVersion != null
          ? '当前版本 $installedVersion，已是控制台推荐版本。'
          : '连接引擎已是控制台推荐版本。',
    CoreEngineVersionRelation.aheadOfConsole =>
      installedVersion != null && consoleVersion != null
          ? '当前版本 $installedVersion，控制台推荐版本 $consoleVersion。'
          : '当前连接引擎版本与控制台推荐版本不一致。',
    CoreEngineVersionRelation.unknown =>
      consoleVersion != null ? '控制台推荐版本 $consoleVersion。' : null,
  };
}
