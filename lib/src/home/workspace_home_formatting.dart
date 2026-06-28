part of 'workspace_home_view.dart';

String _formatTrafficRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) {
    return '计算中';
  }
  return '${_formatBytes(bytesPerSecond)}/s';
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
