import 'dart:convert';

class CorePeerStatus {
  const CorePeerStatus({
    required this.cidr,
    required this.ipv4,
    required this.hostname,
    required this.cost,
    required this.latencyText,
    required this.lossText,
    required this.rxBytes,
    required this.txBytes,
    required this.tunnelProto,
    required this.natType,
    required this.peerId,
    required this.version,
  });

  final String cidr;
  final String ipv4;
  final String hostname;
  final String cost;
  final String latencyText;
  final String lossText;
  final String rxBytes;
  final String txBytes;
  final String tunnelProto;
  final String natType;
  final String peerId;
  final String version;

  bool get isLocal => cost.toLowerCase() == 'local';

  factory CorePeerStatus.fromJson(Map<String, dynamic> json) {
    final cidr = _readString(json['cidr']);
    final rawIpv4 = _readString(json['ipv4']);
    final ipv4 = normalizeCorePeerIpv4(rawIpv4.isEmpty ? cidr : rawIpv4);
    return CorePeerStatus(
      cidr: cidr,
      ipv4: ipv4,
      hostname: _readString(json['hostname']),
      cost: _readString(json['cost']),
      latencyText: _readString(json['lat_ms']),
      lossText: _readString(json['loss_rate']),
      rxBytes: _readString(json['rx_bytes']),
      txBytes: _readString(json['tx_bytes']),
      tunnelProto: _readString(json['tunnel_proto']),
      natType: _readString(json['nat_type']),
      peerId: _readString(json['id'] ?? json['peer_id']),
      version: _readString(json['version']),
    );
  }
}

Map<String, CorePeerStatus> parseCorePeerStatusesFromJson(String output) {
  final decoded = jsonDecode(output);
  final items = _extractPeerItems(decoded);
  final statuses = <String, CorePeerStatus>{};

  for (final item in items) {
    if (item is! Map<String, dynamic>) {
      continue;
    }
    final status = CorePeerStatus.fromJson(item);
    if (status.ipv4.isEmpty) {
      continue;
    }
    statuses[status.ipv4] = status;
  }

  return statuses;
}

String normalizeCorePeerIpv4(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final withoutCidr = trimmed.split('/').first.trim();
  final withoutWhitespace = withoutCidr.split(RegExp(r'\s+')).first.trim();
  return withoutWhitespace;
}

List<dynamic> _extractPeerItems(Object? decoded) {
  if (decoded is List<dynamic>) {
    if (_looksLikeMultiInstanceResult(decoded)) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .expand((item) {
            final result = item['result'];
            return result is List<dynamic> ? result : const <dynamic>[];
          })
          .toList(growable: false);
    }
    return decoded;
  }

  if (decoded is Map<String, dynamic>) {
    final result = decoded['result'];
    if (result is List<dynamic>) {
      return result;
    }
  }

  throw const FormatException('easytier-cli peer JSON 必须是数组');
}

bool _looksLikeMultiInstanceResult(List<dynamic> items) {
  if (items.isEmpty) {
    return false;
  }
  return items.every((item) {
    if (item is! Map<String, dynamic>) {
      return false;
    }
    return item.containsKey('result') &&
        (item.containsKey('instance_id') || item.containsKey('instance_name'));
  });
}

String _readString(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text;
}
