import 'dart:convert';

import 'core_json_value.dart';

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
    this.featureFlag,
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
  final CorePeerFeatureFlag? featureFlag;

  bool get isLocal => cost.toLowerCase() == 'local';
  bool get isCredentialPeer => featureFlag?.isCredentialPeer != false;

  factory CorePeerStatus.fromJson(Map<String, dynamic> json) {
    final cidr = _readCidr(json['cidr']);
    final rawIpv4 = _readCidr(json['ipv4']);
    final ipv4 = normalizeCorePeerIpv4(rawIpv4.isEmpty ? cidr : rawIpv4);
    final featureFlag = _readFeatureFlag(json);
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
      featureFlag: featureFlag,
    );
  }
}

class CorePeerFeatureFlag {
  const CorePeerFeatureFlag({this.isCredentialPeer});

  final bool? isCredentialPeer;

  factory CorePeerFeatureFlag.fromJson(Map<String, dynamic> json) {
    return CorePeerFeatureFlag(
      isCredentialPeer: _readBool(
        json['is_credential_peer'] ?? json['isCredentialPeer'],
      ),
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
    final status = CorePeerStatus.fromJson(_peerStatusJsonFromItem(item));
    if (status.ipv4.isEmpty || !status.isCredentialPeer) {
      continue;
    }
    statuses[status.ipv4] = status;
  }

  return statuses;
}

CorePeerStatus? parseCoreLocalPeerStatusFromNodeInfoJson(String output) {
  final decoded = jsonDecode(output);
  final item = _extractNodeInfoItem(decoded);
  if (item == null) {
    return null;
  }
  final status = CorePeerStatus.fromJson(
    _localPeerStatusJsonFromNodeInfo(item),
  );
  if (status.ipv4.isEmpty || !status.isCredentialPeer) {
    return null;
  }
  return status;
}

Map<String, CorePeerStatus> filterCredentialPeerStatuses(
  Map<String, CorePeerStatus> statuses,
) {
  final visible = <String, CorePeerStatus>{};
  for (final entry in statuses.entries) {
    if (entry.value.isCredentialPeer) {
      visible[entry.key] = entry.value;
    }
  }
  return visible;
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

Map<String, dynamic> _peerStatusJsonFromItem(Map<String, dynamic> item) {
  final route = _readMap(
    item['route'] ?? item['route_info'] ?? item['routeInfo'],
  );
  if (route == null) {
    return item;
  }

  final peer = _readMap(item['peer']);
  final cidr = _readCidr(
    route['ipv4_addr'] ??
        route['ipv4Addr'] ??
        route['ipv4'] ??
        route['address'],
  );
  final peerInfo = peer == null
      ? const <String, dynamic>{}
      : _peerInfoJson(peer);
  final normalized = <String, dynamic>{
    ...peerInfo,
    'cidr': cidr,
    'ipv4': cidr,
    'hostname': _firstString([
      route['hostname'],
      route['hostName'],
      peer?['hostname'],
      peer?['name'],
    ]),
    'cost': _routeCostText(route),
    if (_readString(peerInfo['lat_ms']).isEmpty)
      'lat_ms': _firstString([
        route['path_latency_latency_first'],
        route['pathLatencyLatencyFirst'],
        route['path_latency'],
        route['pathLatency'],
      ]),
    'nat_type': _natTypeText(_readMap(route['stun_info'] ?? route['stunInfo'])),
    'peer_id': _readString(route['peer_id'] ?? route['peerId']),
    'id': _readString(route['peer_id'] ?? route['peerId']),
    'version': _firstString([route['version'], peer?['version']]),
    'feature_flag':
        route['feature_flag'] ??
        route['featureFlag'] ??
        peer?['feature_flag'] ??
        peer?['featureFlag'],
  };
  normalized.removeWhere((key, value) {
    if (key == 'feature_flag') {
      return value == null;
    }
    return _readString(value).isEmpty;
  });
  return normalized;
}

Map<String, dynamic> _localPeerStatusJsonFromNodeInfo(
  Map<String, dynamic> nodeInfo,
) {
  final cidr = _readCidr(
    nodeInfo['virtual_ipv4'] ??
        nodeInfo['virtualIpv4'] ??
        nodeInfo['ipv4_addr'] ??
        nodeInfo['ipv4Addr'] ??
        nodeInfo['ipv4'] ??
        nodeInfo['address'],
  );
  return <String, dynamic>{
    'cidr': cidr,
    'ipv4': cidr,
    'hostname': _firstString([
      nodeInfo['hostname'],
      nodeInfo['hostName'],
      nodeInfo['name'],
    ]),
    'cost': 'Local',
    'lat_ms': '-',
    'loss_rate': '-',
    'rx_bytes': '-',
    'tx_bytes': '-',
    'tunnel_proto': '-',
    'nat_type': _natTypeText(
      _readMap(nodeInfo['stun_info'] ?? nodeInfo['stunInfo']),
    ),
    'peer_id': _readString(nodeInfo['peer_id'] ?? nodeInfo['peerId']),
    'id': _readString(nodeInfo['peer_id'] ?? nodeInfo['peerId']),
    'version': _firstString([nodeInfo['version']]),
    'feature_flag': nodeInfo['feature_flag'] ?? nodeInfo['featureFlag'],
  }..removeWhere((key, value) {
    if (key == 'feature_flag') {
      return value == null;
    }
    return _readString(value).isEmpty;
  });
}

Map<String, dynamic> _peerInfoJson(Map<String, dynamic> peer) {
  final conn = _selectedPeerConn(peer);
  final stats = _readMap(conn?['stats']);
  final tunnel = _readMap(conn?['tunnel']);
  return <String, dynamic>{
    'peer_id': _readString(peer['peer_id'] ?? peer['peerId']),
    'id': _readString(peer['peer_id'] ?? peer['peerId']),
    'lat_ms': _latencyText(stats, conn),
    'loss_rate': _firstString([
      conn?['loss_rate'],
      conn?['lossRate'],
      stats?['loss_rate'],
      stats?['lossRate'],
    ]),
    'rx_bytes': _readString(stats?['rx_bytes'] ?? stats?['rxBytes']),
    'tx_bytes': _readString(stats?['tx_bytes'] ?? stats?['txBytes']),
    'tunnel_proto': _firstString([
      tunnel?['tunnel_type'],
      tunnel?['tunnelType'],
      conn?['tunnel_proto'],
      conn?['tunnelProto'],
    ]),
  }..removeWhere((_, value) => _readString(value).isEmpty);
}

Map<String, dynamic>? _selectedPeerConn(Map<String, dynamic> peer) {
  final conns = _readList(peer['conns'] ?? peer['connections']);
  for (final conn in conns) {
    final map = _readMap(conn);
    if (map != null) {
      return map;
    }
  }
  return null;
}

String _readCidr(Object? value) => CoreJsonValue.readCidr(value);

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

Map<String, dynamic>? _extractNodeInfoItem(Object? decoded) {
  if (decoded is List<dynamic>) {
    for (final item in decoded) {
      final map = _readMap(item);
      final result = _readMap(map?['result']);
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  final map = _readMap(decoded);
  if (map == null) {
    return null;
  }
  return _readMap(map['result']) ?? map;
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

Map<String, dynamic>? _readMap(Object? value) {
  final map = CoreJsonValue.readMap(value);
  return map == null ? null : Map<String, dynamic>.from(map);
}

List<dynamic> _readList(Object? value) {
  return List<dynamic>.from(CoreJsonValue.readList(value));
}

String _readString(Object? value) {
  return CoreJsonValue.readString(value);
}

String _firstString(Iterable<Object?> values) {
  return CoreJsonValue.firstString(values);
}

String _latencyText(Map<String, dynamic>? stats, Map<String, dynamic>? conn) {
  final text = _firstString([
    conn?['lat_ms'],
    conn?['latMs'],
    conn?['latency_ms'],
    conn?['latencyMs'],
    stats?['lat_ms'],
    stats?['latMs'],
    stats?['latency_ms'],
    stats?['latencyMs'],
  ]);
  if (text.isNotEmpty) {
    return text;
  }
  final latencyUs = num.tryParse(
    _readString(stats?['latency_us'] ?? stats?['latencyUs']),
  );
  if (latencyUs == null) {
    return '';
  }
  return (latencyUs / 1000).toStringAsFixed(2);
}

String _natTypeText(Map<String, dynamic>? stunInfo) {
  return _firstString([
    stunInfo?['udp_nat_type'],
    stunInfo?['udpNatType'],
    stunInfo?['nat_type'],
    stunInfo?['natType'],
  ]);
}

String _routeCostText(Map<String, dynamic> route) {
  final cost = int.tryParse(_readString(route['cost']));
  if (cost == null) {
    return _readString(route['cost']);
  }
  return switch (cost) {
    0 => 'Local',
    1 => 'p2p',
    _ => cost.toString(),
  };
}

CorePeerFeatureFlag? _readFeatureFlag(Map<String, dynamic> json) {
  final value = json['feature_flag'] ?? json['featureFlag'];
  if (value is Map<String, dynamic>) {
    return CorePeerFeatureFlag.fromJson(value);
  }
  if (value is Map) {
    return CorePeerFeatureFlag.fromJson(
      value.map((key, value) => MapEntry(key.toString(), value)),
    );
  }
  return null;
}

bool? _readBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final text = value?.toString().trim().toLowerCase();
  if (text == null || text.isEmpty) {
    return null;
  }
  if (text == 'true' || text == '1' || text == 'yes') {
    return true;
  }
  if (text == 'false' || text == '0' || text == 'no') {
    return false;
  }
  return null;
}
