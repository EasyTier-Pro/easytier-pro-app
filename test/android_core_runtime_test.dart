import 'dart:async';
import 'dart:convert';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:flutter/services.dart';
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
      expect(instance.vpnConfig?['routes'], ['10.1.0.0/24', '10.2.0.0/24']);
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
            'route': {
              'destination': '10.8.0.0',
              'prefix_length': 16,
              'proxy_cidrs': ['192.168.50.0/24'],
            },
          },
          {
            'peer': {'hostname': 'node-b'},
            'route_info': {'cidr': '10.9.0.0/16'},
          },
        ],
      });

      expect(config['addresses'], ['10.1.0.1/24']);
      expect(config['routes'], [
        '10.1.0.0/24',
        '10.8.0.0/16',
        '192.168.50.0/24',
        '10.9.0.0/16',
      ]);
    });

    test('extracts peer virtual routes and subnet route aliases', () {
      final config = AndroidCoreRuntime.buildVpnConfigFromNetworkInfo({
        'address': '10.10.0.2/32',
        'peer_route_pairs': [
          {
            'route': {
              'ipv4_addr': {
                'address': {'addr': 168427523},
                'network_length': 32,
              },
              'subnet_cidrs': ['192.168.50.0/24'],
            },
          },
        ],
        'proxy_cidrs': ['172.20.0.0/16'],
      });

      expect(config['addresses'], ['10.10.0.2/32']);
      expect(config['routes'], [
        '10.10.0.2/32',
        '10.10.0.3/32',
        '192.168.50.0/24',
        '172.20.0.0/16',
      ]);
    });

    test('preserves configured Android VPN disallowed applications', () {
      final config = AndroidCoreRuntime.buildVpnConfigFromNetworkInfo({
        'address': '10.10.0.2/24',
        'disallowed_applications': ['com.example.extra'],
      });

      expect(config['disallowedApplications'], ['com.example.extra']);
    });

    test('merges nested VPN config with outer peer and subnet routes', () {
      final config = AndroidCoreRuntime.buildVpnConfigFromNetworkInfo({
        'vpn_config': {
          'addresses': ['10.10.0.2/32'],
          'routes': ['10.30.0.0/16'],
          'dns': ['10.10.0.53'],
          'disallowedApplications': ['com.example.extra-a'],
          'mtu': 1280,
        },
        'routes': [
          {
            'proxy_cidrs': ['10.20.0.0/16'],
          },
        ],
        'peer_route_pairs': [
          {
            'route': {
              'ipv4_addr': {
                'address': {'addr': 168427523},
                'network_length': 32,
              },
              'subnet_cidrs': ['192.168.50.0/24'],
            },
          },
        ],
        'proxy_cidrs': ['172.20.0.0/16'],
        'dns_servers': ['10.10.0.54'],
        'disallowed_applications': ['com.example.extra-b'],
      });

      expect(config['addresses'], ['10.10.0.2/32']);
      expect(config['routes'], [
        '10.10.0.2/32',
        '10.30.0.0/16',
        '10.20.0.0/16',
        '10.10.0.3/32',
        '192.168.50.0/24',
        '172.20.0.0/16',
      ]);
      expect(config['dns'], ['10.10.0.53', '10.10.0.54']);
      expect(config['disallowedApplications'], [
        'com.example.extra-a',
        'com.example.extra-b',
      ]);
      expect(config['mtu'], 1280);
    });

    test('parses upstream running info map for Android VPN config', () {
      final snapshot = AndroidNetworkInfoSnapshot.parse(
        jsonEncode({
          'map': {
            'network-a': {
              'running': true,
              'my_node_info': {
                'virtual_ipv4': {
                  'address': {'addr': 168427522},
                  'network_length': 24,
                },
              },
              'routes': [
                {
                  'proxy_cidrs': ['10.20.0.0/16', '172.16.8.0/24'],
                },
              ],
            },
          },
        }),
      );

      final instance = snapshot.instanceNamed('network-a');
      expect(instance, isNotNull);
      expect(instance!.running, isTrue);
      expect(instance.vpnConfig?['addresses'], ['10.10.0.2/24']);
      expect(instance.vpnConfig?['routes'], [
        '10.10.0.0/24',
        '10.20.0.0/16',
        '172.16.8.0/24',
      ]);
    });
  });

  group('AndroidCoreRuntime native events', () {
    late StreamController<Object?> nativeEvents;
    late MethodChannel methodChannel;
    late AndroidCoreRuntime runtime;
    late List<MethodCall> calls;
    late Map<String, Object?> networkInfos;
    var vpnPrepared = true;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      nativeEvents = StreamController<Object?>.broadcast();
      methodChannel = const MethodChannel('test.easytier/core_runtime');
      calls = <MethodCall>[];
      vpnPrepared = true;
      networkInfos = {
        'instances': [
          {
            'instance_id': 'instance-a',
            'instance_name': 'network-a',
            'running': true,
            'ipv4_cidr': '10.10.0.2/24',
            'routes': [
              {'address': '10.20.0.0', 'prefix': 16},
            ],
            'dns_servers': ['10.10.0.1'],
          },
        ],
      };

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
            calls.add(call);
            switch (call.method) {
              case 'getMachineId':
                return 'android-machine';
              case 'getHostname':
                return 'android-host';
              case 'startConfigServerClient':
              case 'retainNetworkInstance':
              case 'startVpn':
              case 'stopVpn':
              case 'stopConfigServerClient':
                return null;
              case 'prepareNotifications':
                return true;
              case 'prepareVpn':
                return vpnPrepared;
              case 'collectNetworkInfos':
                return jsonEncode(networkInfos);
              default:
                fail('Unexpected Android method call: ${call.method}');
            }
          });

      runtime = AndroidCoreRuntime(
        methodChannel: methodChannel,
        eventChannel: _FakeEventChannel(nativeEvents.stream),
        networkInfoCacheDuration: Duration.zero,
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      await runtime.dispose();
      await nativeEvents.close();
    });

    test('starts VPN when config server requests a network instance', () async {
      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      expect(
        calls.map((call) => call.method),
        containsAllInOrder([
          'prepareNotifications',
          'startConfigServerClient',
          'prepareVpn',
        ]),
      );

      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'payload': {
            'event': 'run_network_instance',
            'instance_name': 'network-a',
          },
        },
      });

      final startVpn = await _waitForCall(calls, 'startVpn');
      final retain = calls.where(
        (call) => call.method == 'retainNetworkInstance',
      );
      expect(retain, isNotEmpty);
      expect(retain.last.arguments, {
        'instanceNames': ['network-a'],
      });
      expect(startVpn.arguments, {
        'instanceName': 'network-a',
        'vpnConfig': {
          'addresses': ['10.10.0.2/24'],
          'routes': ['10.10.0.0/24', '10.20.0.0/16'],
          'dns': ['10.10.0.1'],
        },
      });
    });

    test('uses low-frequency Android runtime polling intervals', () {
      expect(runtime.networkTrafficPollInterval, const Duration(seconds: 15));
      expect(runtime.peerStatusPollInterval, const Duration(seconds: 15));
    });

    test('caches network info reads to reduce JNI polling', () async {
      final cachedRuntime = AndroidCoreRuntime(
        methodChannel: methodChannel,
        eventChannel: _FakeEventChannel(nativeEvents.stream),
      );
      addTearDown(cachedRuntime.dispose);

      await cachedRuntime.readNetworkPeerStatuses('network-a');
      await cachedRuntime.isNetworkInstanceRunning('network-a');

      final collectCalls = calls.where(
        (call) => call.method == 'collectNetworkInfos',
      );
      expect(collectCalls, hasLength(1));
    });

    test('resolves instance id events before starting VPN', () async {
      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'payload': {
            'event': 'run_network_instance',
            'instance_id': 'instance-a',
          },
        },
      });

      final startVpn = await _waitForCall(calls, 'startVpn');
      expect(startVpn.arguments, {
        'instanceName': 'network-a',
        'vpnConfig': {
          'addresses': ['10.10.0.2/24'],
          'routes': ['10.10.0.0/24', '10.20.0.0/16'],
          'dns': ['10.10.0.1'],
        },
      });
    });

    test('maps upstream running info to peer statuses', () async {
      networkInfos = {
        'map': {
          'network-a': {
            'running': true,
            'my_node_info': {
              'virtual_ipv4': {
                'address': {'addr': 168427522},
                'network_length': 24,
              },
              'hostname': 'android-phone',
              'peer_id': 123,
              'version': '2.6.4',
              'stun_info': {'udp_nat_type': 3},
            },
            'peer_route_pairs': [
              {
                'route': {
                  'peer_id': 456,
                  'ipv4_addr': {
                    'address': {'addr': 168427523},
                    'network_length': 24,
                  },
                  'hostname': 'desktop-peer',
                  'cost': 1,
                  'path_latency': 4,
                  'version': '2.6.4',
                  'stun_info': {'udp_nat_type': 6},
                },
                'peer': {
                  'peer_id': 456,
                  'conns': [
                    {
                      'stats': {
                        'rx_bytes': 1024,
                        'tx_bytes': 2048,
                        'latency_us': 3452,
                      },
                      'loss_rate': 0.01,
                      'tunnel': {'tunnel_type': 'udp'},
                    },
                  ],
                },
              },
            ],
          },
        },
      };

      final statuses = await runtime.readNetworkPeerStatuses('network-a');

      expect(statuses.keys, containsAll(['10.10.0.2', '10.10.0.3']));
      final local = statuses['10.10.0.2']!;
      expect(local.hostname, 'android-phone');
      expect(local.isLocal, isTrue);
      expect(local.peerId, '123');
      expect(local.natType, 'FullCone');

      final remote = statuses['10.10.0.3']!;
      expect(remote.hostname, 'desktop-peer');
      expect(remote.peerId, '456');
      expect(remote.cost, '1');
      expect(remote.latencyText, '3.452');
      expect(remote.lossText, '0.01');
      expect(remote.rxBytes, '1024');
      expect(remote.txBytes, '2048');
      expect(remote.tunnelProto, 'udp');
      expect(remote.natType, 'Symmetric');
      expect(remote.version, '2.6.4');
    });

    test('derives Android traffic totals from peer connection stats', () async {
      networkInfos = {
        'map': {
          'network-a': {
            'running': true,
            'my_node_info': {
              'virtual_ipv4': {
                'address': {'addr': 168427522},
                'network_length': 24,
              },
              'peer_id': 123,
            },
            'peer_route_pairs': [
              {
                'route': {
                  'peer_id': 456,
                  'ipv4_addr': {
                    'address': {'addr': 168427523},
                    'network_length': 24,
                  },
                },
                'peer': {
                  'peer_id': 456,
                  'conns': [
                    {
                      'stats': {'rx_bytes': 1024, 'tx_bytes': 2048},
                    },
                  ],
                },
              },
            ],
          },
        },
      };

      final totals = await runtime.readNetworkTrafficTotals();

      expect(totals.keys, ['network-a']);
      expect(totals['network-a']!.downloadBytes, 1024);
      expect(totals['network-a']!.uploadBytes, 2048);
    });

    test(
      'falls back to the only collected instance for id-only events',
      () async {
        networkInfos = {
          'map': {
            'network-a': {
              'running': true,
              'my_node_info': {
                'virtual_ipv4': {
                  'address': {'addr': 168427522},
                  'network_length': 24,
                },
              },
              'routes': [
                {
                  'proxy_cidrs': ['10.20.0.0/16'],
                },
              ],
            },
          },
        };

        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_id': '8af8e8c8-4dd4-4f82-8e74-aaaaaaaaaaaa',
          },
        });

        final startVpn = await _waitForCall(calls, 'startVpn');
        expect(startVpn.arguments, {
          'instanceName': 'network-a',
          'vpnConfig': {
            'addresses': ['10.10.0.2/24'],
            'routes': ['10.10.0.0/24', '10.20.0.0/16'],
            'dns': <String>[],
          },
        });
      },
    );

    test('reports failed config server events without starting VPN', () async {
      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      final eventFuture = runtime.events.firstWhere(
        (event) => event.type == CoreRuntimeEventTypes.error,
      );

      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'run_network_instance',
          'instance_id': 'instance-a',
          'success': false,
          'error': 'config build failed',
        },
      });

      final event = await eventFuture;
      expect(event.data['error'], 'config build failed');
      expect(event.data['event'], 'run_network_instance');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.where((call) => call.method == 'startVpn'), isEmpty);
    });

    test(
      'reports missing VPN address without exposing long id in message',
      () async {
        networkInfos = {
          'map': {
            'network-a': {
              'running': true,
              'routes': [
                {
                  'proxy_cidrs': ['10.20.0.0/16'],
                },
              ],
            },
          },
        };
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        final eventFuture = runtime.events.firstWhere(
          (event) => event.type == CoreRuntimeEventTypes.error,
        );
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_id': '8af8e8c8-4dd4-4f82-8e74-aaaaaaaaaaaa',
          },
        });

        final event = await eventFuture;
        expect(event.data['error'], 'Android VPN 缺少虚拟 IP 配置');
        expect(event.data['instance_name'], 'network-a');
        expect(event.data['instance_key'], contains('8af8e8c8'));
        expect(event.data['known_instances'], ['network-a']);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls.where((call) => call.method == 'startVpn'), isEmpty);
      },
    );

    test(
      'starts VPN again after native stopped event clears active state',
      () async {
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_id': 'instance-a',
          },
        });
        await _waitForCall(calls, 'startVpn');

        nativeEvents.add({
          'type': CoreRuntimeEventTypes.vpnStopped,
          'payload': {'instanceName': 'network-a'},
        });
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_id': 'instance-a',
          },
        });

        await _waitForCallCount(calls, 'startVpn', 2);
      },
    );

    test(
      'stops active VPN when config server deletes by instance id',
      () async {
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_id': 'instance-a',
          },
        });
        await _waitForCall(calls, 'startVpn');

        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'delete_network_instance',
            'instance_id': 'instance-a',
          },
        });

        await _waitForCallCount(calls, 'stopVpn', 1);
      },
    );

    test('refreshes active VPN when same instance routes change', () async {
      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'run_network_instance',
          'instance_name': 'network-a',
          'vpn_config': {
            'addresses': ['10.10.0.2/24'],
            'routes': ['10.20.0.0/16'],
          },
        },
      });
      await _waitForCall(calls, 'startVpn');

      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'run_network_instance',
          'instance_name': 'network-a',
          'vpn_config': {
            'addresses': ['10.10.0.2/24'],
            'routes': ['10.30.0.0/16'],
          },
        },
      });

      await _waitForCallCount(calls, 'startVpn', 2);
      final startVpnCalls = calls.where((call) => call.method == 'startVpn');
      expect(startVpnCalls.last.arguments, {
        'instanceName': 'network-a',
        'vpnConfig': {
          'addresses': ['10.10.0.2/24'],
          'routes': ['10.10.0.0/24', '10.30.0.0/16'],
          'dns': <String>[],
        },
      });
    });

    test('refreshes active VPN when proxy routes sync after startup', () async {
      await runtime.dispose();
      runtime = AndroidCoreRuntime(
        methodChannel: methodChannel,
        eventChannel: _FakeEventChannel(nativeEvents.stream),
        networkInfoCacheDuration: Duration.zero,
        vpnRouteRefreshFastInterval: const Duration(milliseconds: 10),
        vpnRouteRefreshSteadyInterval: const Duration(milliseconds: 10),
        vpnRouteRefreshFastLimit: 2,
      );
      networkInfos = {
        'instances': [
          {
            'instance_id': 'instance-a',
            'instance_name': 'network-a',
            'running': true,
            'ipv4_cidr': '10.10.0.2/24',
            'routes': <Map<String, Object?>>[],
            'dns_servers': ['10.10.0.1'],
          },
        ],
      };

      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'run_network_instance',
          'instance_name': 'network-a',
        },
      });

      final firstStartVpn = await _waitForCall(calls, 'startVpn');
      expect(firstStartVpn.arguments, {
        'instanceName': 'network-a',
        'vpnConfig': {
          'addresses': ['10.10.0.2/24'],
          'routes': ['10.10.0.0/24'],
          'dns': ['10.10.0.1'],
        },
      });

      networkInfos = {
        'instances': [
          {
            'instance_id': 'instance-a',
            'instance_name': 'network-a',
            'running': true,
            'ipv4_cidr': '10.10.0.2/24',
            'routes': [
              {'address': '10.20.0.0', 'prefix': 16},
            ],
            'dns_servers': ['10.10.0.1'],
          },
        ],
      };

      await _waitForCallCount(calls, 'startVpn', 2);
      final startVpnCalls = calls.where((call) => call.method == 'startVpn');
      expect(startVpnCalls.last.arguments, {
        'instanceName': 'network-a',
        'vpnConfig': {
          'addresses': ['10.10.0.2/24'],
          'routes': ['10.10.0.0/24', '10.20.0.0/16'],
          'dns': ['10.10.0.1'],
        },
      });
    });

    test('waits for VPN permission before starting pending instance', () async {
      vpnPrepared = false;
      final result = await runtime.ensureRunning(
        _androidBootstrap(),
        forceReinstall: false,
      );
      expect(result.phase, CoreRunPhase.needsVpnPermission);

      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'run_network_instance',
          'instance_name': 'network-a',
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.where((call) => call.method == 'startVpn'), isEmpty);

      nativeEvents.add({
        'type': CoreRuntimeEventTypes.vpnPermissionGranted,
        'payload': {'granted': true},
      });

      final startVpn = await _waitForCall(calls, 'startVpn');
      expect(startVpn.arguments, containsPair('instanceName', 'network-a'));
    });

    test(
      'keeps only the latest pending VPN before permission is granted',
      () async {
        vpnPrepared = false;
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);

        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_name': 'network-a',
            'vpn_config': {
              'addresses': ['10.10.0.2/24'],
            },
          },
        });
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_name': 'network-b',
            'vpn_config': {
              'addresses': ['10.20.0.2/24'],
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls.where((call) => call.method == 'startVpn'), isEmpty);

        nativeEvents.add({
          'type': CoreRuntimeEventTypes.vpnPermissionGranted,
          'payload': {'granted': true},
        });

        final startVpn = await _waitForCall(calls, 'startVpn');
        expect(startVpn.arguments, {
          'instanceName': 'network-b',
          'vpnConfig': {
            'addresses': ['10.20.0.2/24'],
            'routes': ['10.20.0.0/24'],
            'dns': <String>[],
          },
        });

        nativeEvents.add({
          'type': CoreRuntimeEventTypes.vpnPermissionGranted,
          'payload': {'granted': true},
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls.where((call) => call.method == 'startVpn'), hasLength(1));
      },
    );

    test('does not start VPN after native permission denial', () async {
      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      nativeEvents.add({
        'type': CoreRuntimeEventTypes.vpnPermissionDenied,
        'payload': {'granted': false},
      });
      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'run_network_instance',
          'instance_name': 'network-a',
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.where((call) => call.method == 'startVpn'), isEmpty);

      nativeEvents.add({
        'type': CoreRuntimeEventTypes.vpnPermissionGranted,
        'payload': {'granted': true},
      });
      final startVpn = await _waitForCall(calls, 'startVpn');
      expect(startVpn.arguments, containsPair('instanceName', 'network-a'));
    });

    test('stops active VPN when config server deletes the instance', () async {
      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'run_network_instance',
          'instance_name': 'network-a',
          'vpn_config': {
            'addresses': ['10.10.0.2/24'],
          },
        },
      });
      await _waitForCall(calls, 'startVpn');

      nativeEvents.add({
        'type': CoreRuntimeEventTypes.configServer,
        'payload': {
          'event': 'delete_network_instance',
          'instance_name': 'network-a',
        },
      });

      await _waitForCallCount(calls, 'stopVpn', 1);
    });
  });
}

CoreBootstrapConfig _androidBootstrap() {
  return const CoreBootstrapConfig(
    version: '2.6.4',
    configServer: 'tcp://127.0.0.1:22020',
    bootstrapToken: 'bootstrap-token',
  );
}

Future<MethodCall> _waitForCall(
  List<MethodCall> calls,
  String method, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final matches = calls.where((call) => call.method == method);
    if (matches.isNotEmpty) {
      return matches.last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'Timed out waiting for $method. Calls: ${calls.map((c) => c.method).toList()}',
  );
}

Future<void> _waitForCallCount(
  List<MethodCall> calls,
  String method,
  int count, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (calls.where((call) => call.method == method).length >= count) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'Timed out waiting for $method count $count. Calls: ${calls.map((c) => c.method).toList()}',
  );
}

class _FakeEventChannel extends EventChannel {
  _FakeEventChannel(this._events) : super('test.easytier/core_runtime_events');

  final Stream<Object?> _events;

  @override
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) {
    return _events;
  }
}
