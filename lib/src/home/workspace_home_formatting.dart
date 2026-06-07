part of 'workspace_home_view.dart';

String _formatTotalTraffic(_NetworkTrafficSnapshot? traffic) {
  if (traffic == null) {
    return '流量统计暂不可用';
  }
  return '下载 ${_formatBytes(traffic.downloadBytes)} / 上传 ${_formatBytes(traffic.uploadBytes)}';
}

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
