import 'dart:convert';

class CoreJsonValue {
  const CoreJsonValue._();

  static Map<String, Object?>? readMap(Object? value) {
    if (value is Map) {
      return stringObjectMap(value);
    }
    if (value is String) {
      final decoded = tryDecodeJson(value);
      return decoded is Map ? stringObjectMap(decoded) : null;
    }
    return null;
  }

  static List<Object?> readList(Object? value) {
    if (value is List) {
      return value;
    }
    if (value is String && value.trim().isNotEmpty) {
      final decoded = tryDecodeJson(value);
      if (decoded is List) {
        return decoded;
      }
      if (decoded is Map) {
        return <Object?>[decoded];
      }
      return <Object?>[value.trim()];
    }
    return const <Object?>[];
  }

  static Object? tryDecodeJson(String value) {
    final text = value.trim();
    if ((!text.startsWith('{') || !text.endsWith('}')) &&
        (!text.startsWith('[') || !text.endsWith(']'))) {
      return null;
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static Map<String, Object?> stringObjectMap(Map<dynamic, dynamic> value) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static Map<String, dynamic> stringDynamicMap(Map<dynamic, dynamic> value) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static String readString(Object? value) {
    return value?.toString().trim() ?? '';
  }

  static String? readScalarString(Object? value) {
    if (value is Map || value is List) {
      return null;
    }
    final text = readString(value);
    return text.isEmpty ? null : text;
  }

  static int? readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(readString(value));
  }

  static String? firstScalarString(Iterable<Object?> values) {
    for (final value in values) {
      final text = readScalarString(value);
      if (text != null) {
        return text;
      }
    }
    return null;
  }

  static String? firstNonEmptyString(Iterable<Object?> values) {
    for (final value in values) {
      final text = readString(value);
      if (text.isNotEmpty) {
        return text;
      }
    }
    return null;
  }

  static String firstString(Iterable<Object?> values) {
    return firstNonEmptyString(values) ?? '';
  }

  static List<String> readStringList(Object? value) {
    return readList(value)
        .map(readString)
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> readCidrList(Object? value) {
    if (value is Map) {
      final cidr = readCidr(value);
      return cidr.isEmpty ? const <String>[] : <String>[cidr];
    }
    return readList(value)
        .map(readCidr)
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  static String readCidr(Object? value) {
    if (value is Map) {
      final map = stringObjectMap(value);
      final nested = map['route'] ?? map['route_info'] ?? map['routeInfo'];
      if (nested is Map) {
        return readCidr(nested);
      }

      final ipv4Inet = ipv4InetCidrFromMap(map);
      if (ipv4Inet.isNotEmpty) {
        return ipv4Inet;
      }

      for (final key in const <String>[
        'ipv4_addr',
        'ipv4Addr',
        'ipv4_address',
        'ipv4Address',
        'virtual_ip',
        'virtualIp',
        'virtual_ipv4',
        'virtualIpv4',
      ]) {
        final nested = map[key];
        if (nested == null) {
          continue;
        }
        final nestedCidr = readCidr(nested);
        if (nestedCidr.isNotEmpty) {
          if (!nestedCidr.contains('/')) {
            final prefix = firstScalarString([
              map['network_length'],
              map['networkLength'],
              map['prefix'],
              map['prefix_length'],
              map['prefixLength'],
              map['mask'],
            ]);
            if (prefix != null) {
              return '$nestedCidr/$prefix';
            }
          }
          return nestedCidr;
        }
      }

      final cidr = firstScalarString([
        map['cidr'],
        map['ipv4_cidr'],
        map['ipv4Cidr'],
        map['ip_cidr'],
        map['ipCidr'],
        map['destination'],
        map['dest'],
        map['address'],
        map['ip'],
        map['ipv4'],
      ]);
      if (cidr == null) {
        return '';
      }
      if (cidr.contains('/')) {
        return cidr;
      }
      final prefix = firstScalarString([
        map['network_length'],
        map['networkLength'],
        map['prefix'],
        map['prefix_length'],
        map['prefixLength'],
        map['prefix_len'],
        map['prefixLen'],
        map['mask'],
      ]);
      return prefix == null ? cidr : '$cidr/$prefix';
    }
    return readString(value);
  }

  static String ipv4InetCidrFromMap(Map<String, Object?> map) {
    final address = ipv4AddressFromValue(map['address'] ?? map['addr']);
    if (address == null || address.isEmpty) {
      return '';
    }
    if (address.contains('/')) {
      return address;
    }
    final prefix = firstScalarString([
      map['network_length'],
      map['networkLength'],
      map['prefix'],
      map['prefix_length'],
      map['prefixLength'],
      map['prefix_len'],
      map['prefixLen'],
      map['mask'],
    ]);
    return '$address/${prefix ?? 32}';
  }

  static String? ipv4AddressFromValue(Object? value) {
    if (value is Map) {
      final map = stringObjectMap(value);
      final numeric = readInt(map['addr'] ?? map['value']);
      if (numeric != null) {
        return ipv4FromUint32(numeric);
      }
      return firstScalarString([map['address'], map['ip'], map['ipv4']]);
    }
    final numeric = readInt(value);
    if (numeric != null) {
      return ipv4FromUint32(numeric);
    }
    return readScalarString(value);
  }

  static String ipv4FromUint32(int value) {
    final unsigned = value & 0xffffffff;
    return [
      (unsigned >> 24) & 0xff,
      (unsigned >> 16) & 0xff,
      (unsigned >> 8) & 0xff,
      unsigned & 0xff,
    ].join('.');
  }
}
