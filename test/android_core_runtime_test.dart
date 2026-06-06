import 'dart:convert';

import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidCoreRuntime config server URL', () {
    test('appends encoded token without trailing slash', () {
      expect(
        AndroidCoreRuntime.buildConfigServerClientUrl(
          'tcp://host:22020',
          'bootstrap-token',
        ),
        'tcp://host:22020/bootstrap-token',
      );
    });

    test('appends encoded token with trailing slash', () {
      expect(
        AndroidCoreRuntime.buildConfigServerClientUrl(
          'tcp://host:22020/',
          'bootstrap-token',
        ),
        'tcp://host:22020/bootstrap-token',
      );
    });

    test('preserves base path', () {
      expect(
        AndroidCoreRuntime.buildConfigServerClientUrl(
          'tcp://host:22020/base-path',
          'bootstrap-token',
        ),
        'tcp://host:22020/base-path/bootstrap-token',
      );
    });

    test('URL-encodes token path segment', () {
      expect(
        AndroidCoreRuntime.buildConfigServerClientUrl(
          'tcp://host:22020',
          'token/with space',
        ),
        'tcp://host:22020/token%2Fwith%20space',
      );
    });
  });

  group('AndroidNetworkInfoSnapshot', () {
    test('parses running instance with peers', () {
      final snapshot = AndroidNetworkInfoSnapshot.parse(
        jsonEncode({
          'instances': [
            {
              'instance_name': 'network-a',
              'running': true,
              'ipv4_cidr': '10.1.0.1/24',
              'routes': [
                {'address': '10.2.0.0', 'prefix': 24},
              ],
              'dns_servers': ['10.1.0.53'],
              'peers': [
                {'ipv4': '10.1.0.2/24', 'hostname': 'node-a', 'cost': 'Local'},
              ],
            },
          ],
        }),
      );

      final instance = snapshot.instanceNamed('network-a');
      expect(instance, isNotNull);
      expect(instance!.running, isTrue);
      expect(instance.peers, hasLength(1));
      expect(instance.peers.single['hostname'], 'node-a');
      expect(instance.vpnConfig?['addresses'], ['10.1.0.1/24']);
      expect(instance.vpnConfig?['routes'], ['10.2.0.0/24']);
      expect(instance.vpnConfig?['dns'], ['10.1.0.53']);
    });

    test('parses map keyed by instance name', () {
      final snapshot = AndroidNetworkInfoSnapshot.parse(
        jsonEncode({
          'network-a': {
            'status': 'running',
            'peer_list': [
              {'ip': '10.1.0.3', 'name': 'node-b'},
            ],
          },
        }),
      );

      final instance = snapshot.instanceNamed('network-a');
      expect(instance, isNotNull);
      expect(instance!.running, isTrue);
      expect(instance.peers.single['name'], 'node-b');
    });

    test('parses error instance as not running', () {
      final snapshot = AndroidNetworkInfoSnapshot.parse(
        jsonEncode({
          'instances': [
            {'instance_name': 'network-a', 'error': 'tun fd missing'},
          ],
        }),
      );

      final instance = snapshot.instanceNamed('network-a');
      expect(instance, isNotNull);
      expect(instance!.running, isFalse);
      expect(instance.error, 'tun fd missing');
    });

    test('extracts routes from peer-route pairs', () {
      final config = AndroidCoreRuntime.buildVpnConfigFromNetworkInfo({
        'address': {'ip': '10.1.0.1', 'prefixLength': 24},
        'peer_route_pairs': [
          {
            'peer': {'hostname': 'node-a'},
            'route': {'destination': '10.8.0.0', 'prefix_length': 16},
          },
          {
            'peer': {'hostname': 'node-b'},
            'route_info': {'cidr': '10.9.0.0/16'},
          },
        ],
      });

      expect(config['addresses'], ['10.1.0.1/24']);
      expect(config['routes'], ['10.8.0.0/16', '10.9.0.0/16']);
    });
  });
}
