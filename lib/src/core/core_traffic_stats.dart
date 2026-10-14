part of 'core_lifecycle_service.dart';

Map<String, CoreNetworkTrafficTotals> _parseNetworkTrafficTotals(
  Iterable<Object?> metrics, {
  String defaultRuntimeNetworkName = '',
  DateTime? sampledAt,
}) {
  final collected = <String, _MutableNetworkTrafficTotals>{};
  for (final item in metrics) {
    final metric = CoreJsonValue.readMap(item);
    if (metric == null) continue;
    final metricName = CoreJsonValue.readString(metric['name']);
    // The legacy self counters include peer RPC traffic. Only the data-plane
    // counters share the traffic classification used by the core and console.
    if (metricName != 'traffic_bytes_rx' && metricName != 'traffic_bytes_tx') {
      continue;
    }

    final labels = CoreJsonValue.readMap(metric['labels']);
    final labelNetworkName = CoreJsonValue.readString(labels?['network_name']);
    final runtimeNetworkName = labelNetworkName.isNotEmpty
        ? labelNetworkName
        : defaultRuntimeNetworkName;
    if (runtimeNetworkName.isEmpty || runtimeNetworkName == '__access__') {
      continue;
    }
    // Protobuf JSON omits the value field when the counter is zero.
    final value = metric.containsKey('value')
        ? CoreJsonValue.readInt(metric['value'])
        : 0;
    if (value == null || value < 0) continue;

    final totals = collected.putIfAbsent(
      runtimeNetworkName,
      _MutableNetworkTrafficTotals.new,
    );
    if (metricName == 'traffic_bytes_rx') {
      totals.downloadBytes = value;
      totals.hasDownloadBytes = true;
    } else {
      totals.uploadBytes = value;
      totals.hasUploadBytes = true;
    }
  }

  final sampleTime = sampledAt ?? DateTime.now();
  return collected.map((runtimeNetworkName, totals) {
    return MapEntry(
      runtimeNetworkName,
      CoreNetworkTrafficTotals(
        runtimeNetworkName: runtimeNetworkName,
        downloadBytes: totals.hasDownloadBytes ? totals.downloadBytes : 0,
        uploadBytes: totals.hasUploadBytes ? totals.uploadBytes : 0,
        sampledAt: sampleTime,
      ),
    );
  });
}
