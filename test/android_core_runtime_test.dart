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
    test(
      'does not substitute the remaining network for a removed instance',
      () {
        final snapshot = AndroidNetworkInfoSnapshot.parse(
          jsonEncode({
            'instances': [
              {
                'instance_id': 'instance-b',
                'instance_name': 'network-b',
                'running': true,
              },
            ],
          }),
        );
        expect(
          snapshot.instanceMatching(name: 'network-a', id: 'instance-a'),
          isNull,
        );
        expect(
          snapshot.instanceMatching(name: '', id: 'instance-b')?.name,
          'network-b',
        );
      },
    );

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

    test('extracts map keyed routes and subnet route containers', () {
      final config = AndroidCoreRuntime.buildVpnConfigFromNetworkInfo({
        'address': '10.10.0.2/24',
        'routes': {
          'route-a': {'destination': '10.40.0.0', 'prefix': 16},
          'route-b': {
            'route_info': {'cidr': '10.41.0.0/16'},
            'subnet_routes': {
              'branch-a': {'cidr': '192.168.60.0/24'},
              'branch-b': {'address': '192.168.61.0', 'prefix': 24},
            },
          },
        },
        'peer_routes': {
          'peer-a': {
            'ipv4_addr': {
              'address': {'addr': 168427523},
              'network_length': 32,
            },
          },
        },
        'proxy_cidrs': {'site-a': '172.20.0.0/16'},
      });

      expect(config['addresses'], ['10.10.0.2/24']);
      expect(config['routes'], [
        '10.10.0.0/24',
        '10.40.0.0/16',
        '10.41.0.0/16',
        '192.168.60.0/24',
        '192.168.61.0/24',
        '10.10.0.3/32',
        '172.20.0.0/16',
      ]);
    });

    test('extracts mapped proxy routes and nested runtime config routes', () {
      final config = AndroidCoreRuntime.buildVpnConfigFromNetworkInfo({
        'config': {
          'virtual_ipv4': '10.60.0.9',
          'network_length': 24,
          'routes': ['10.61.0.42/24'],
          'proxy_networks': [
            {'cidr': '10.62.0.0/24', 'mapped_cidr': '192.168.62.0/24'},
            '10.63.0.0/24->192.168.63.0/24',
          ],
        },
        'routes': jsonEncode([
          {
            'proxy_cidrs': ['10.64.0.0/24->192.168.64.0/24'],
          },
        ]),
      });

      expect(config['addresses'], ['10.60.0.9/24']);
      expect(config['routes'], [
        '10.60.0.0/24',
        '10.61.0.0/24',
        '192.168.62.0/24',
        '192.168.63.0/24',
        '192.168.64.0/24',
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

    test('parses fixed upstream JNI running info map routes', () {
      final snapshot = AndroidNetworkInfoSnapshot.parse(
        jsonEncode({
          'map': {
            'bce27f42-5c4c-41ff-9a49-2db5fd2560ca': {
              'dev_name': 'network-a',
              'running': true,
              'my_node_info': {
                'virtual_ipv4': {
                  'address': {'addr': 168427522},
                  'network_length': 24,
                },
                'hostname': 'android-phone',
                'peer_id': 101,
              },
              'routes': [
                {
                  'peer_id': 202,
                  'ipv4_addr': {
                    'address': {'addr': 168427523},
                    'network_length': 24,
                  },
                  'proxy_cidrs': ['192.168.50.0/24'],
                  'hostname': 'subnet-router',
                },
                {
                  'peer_id': 303,
                  'ipv4_addr': {
                    'address': {'addr': 168427524},
                    'network_length': 24,
                  },
                  'proxy_cidrs': ['172.16.8.0/24'],
                  'hostname': 'branch-router',
                },
              ],
            },
          },
        }),
      );

      final instance = snapshot.instanceMatching(
        name: '',
        id: 'bce27f42-5c4c-41ff-9a49-2db5fd2560ca',
      );
      expect(instance, isNotNull);
      expect(instance!.running, isTrue);
      expect(instance.id, 'bce27f42-5c4c-41ff-9a49-2db5fd2560ca');
      expect(snapshot.instanceNamed('network-a'), same(instance));
      expect(instance.vpnConfig?['addresses'], ['10.10.0.2/24']);
      expect(instance.vpnConfig?['routes'], [
        '10.10.0.0/24',
        '192.168.50.0/24',
        '172.16.8.0/24',
      ]);
      expect(
        instance.peers.map((peer) => peer['hostname']),
        containsAll(['android-phone', 'subnet-router', 'branch-router']),
      );
    });
  });

  group('AndroidCoreRuntime native events', () {
    late StreamController<Object?> nativeEvents;
    late MethodChannel methodChannel;
    late AndroidCoreRuntime runtime;
    late List<MethodCall> calls;
    late Map<String, Object?> networkInfos;
    Map<String, Object?> vpnState = {};
    Object? vpnPrepared = true;
    var configServerConnected = false;
    Object? notificationResult = true;
    var throwMissingJsonRpcInstances = false;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      nativeEvents = StreamController<Object?>.broadcast();
      methodChannel = const MethodChannel('test.easytier/core_runtime');
      calls = <MethodCall>[];
      vpnState = {
        'instance_ids': ['instance-a'],
        'addresses': ['10.10.0.2/24'],
        'rejected': <Object?>[],
      };
      vpnPrepared = true;
      configServerConnected = false;
      notificationResult = true;
      throwMissingJsonRpcInstances = false;
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

      AndroidNetworkInstanceInfo? jsonRpcInstance(MethodCall call) {
        final arguments = call.arguments as Map<Object?, Object?>?;
        final payloadText = arguments?['payloadJson']?.toString() ?? '{}';
        final payload = jsonDecode(payloadText);
        final instance = payload is Map ? payload['instance'] : null;
        final selector = instance is Map
            ? instance['instance_selector'] ?? instance['instanceSelector']
            : null;
        final targetName = selector is Map
            ? selector['name']?.toString().trim() ?? ''
            : '';
        final snapshot = AndroidNetworkInfoSnapshot.parse(
          jsonEncode(networkInfos),
        );
        if (targetName.isNotEmpty) {
          return snapshot.instanceNamed(targetName) ??
              (snapshot.instances.length == 1
                  ? snapshot.instances.values.single
                  : null);
        }
        return snapshot.instances.values.isEmpty
            ? null
            : snapshot.instances.values.first;
      }

      Map<String, Object?>? jsonRpcInstanceMap(MethodCall call) {
        final arguments = call.arguments as Map<Object?, Object?>?;
        final payloadText = arguments?['payloadJson']?.toString() ?? '{}';
        final payload = jsonDecode(payloadText);
        final instance = payload is Map ? payload['instance'] : null;
        final selector = instance is Map
            ? instance['instance_selector'] ?? instance['instanceSelector']
            : null;
        final targetName = selector is Map
            ? selector['name']?.toString().trim() ?? ''
            : '';

        final maps = <Map<String, Object?>>[];
        void addInstance(Object? value, {String? nameHint, String? idHint}) {
          if (value is List) {
            for (final item in value) {
              addInstance(item);
            }
            return;
          }
          if (value is! Map) {
            return;
          }
          final map = <String, Object?>{
            for (final entry in value.entries)
              entry.key.toString(): entry.value as Object?,
          };
          if (nameHint != null && nameHint.isNotEmpty) {
            map.putIfAbsent('instance_name', () => nameHint);
          }
          if (idHint != null && idHint.isNotEmpty) {
            map.putIfAbsent('instance_id', () => idHint);
          }
          final looksLikeInstance =
              map.containsKey('running') ||
              map.containsKey('my_node_info') ||
              map.containsKey('myNodeInfo') ||
              map.containsKey('routes') ||
              map.containsKey('peer_route_pairs') ||
              map.containsKey('peerRoutePairs') ||
              map.containsKey('vpn_config') ||
              map.containsKey('vpnConfig');
          if (looksLikeInstance) {
            maps.add(map);
          }
          for (final entry in map.entries) {
            final key = entry.key;
            final child = entry.value;
            if (key == 'instances' || key == 'map') {
              addInstance(child);
            } else if (child is Map) {
              addInstance(child, nameHint: key, idHint: key);
            }
          }
        }

        addInstance(networkInfos);
        if (targetName.isNotEmpty) {
          return maps.firstWhere(
            (map) =>
                map['instance_name'] == targetName ||
                map['instanceName'] == targetName ||
                map['dev_name'] == targetName ||
                map['devName'] == targetName ||
                map['name'] == targetName,
            orElse: () =>
                maps.length == 1 ? maps.single : const <String, Object?>{},
          );
        }
        return maps.isEmpty ? null : maps.first;
      }

      String jsonRpcResponse(MethodCall call) {
        final arguments = call.arguments as Map<Object?, Object?>?;
        final serviceName = arguments?['serviceName']?.toString() ?? '';
        final methodName = arguments?['methodName']?.toString() ?? '';
        final instance = jsonRpcInstance(call);
        final instanceMap = jsonRpcInstanceMap(call);
        if (throwMissingJsonRpcInstances && instance == null) {
          throw PlatformException(
            code: 'ANDROID_RUNTIME_ERROR',
            message: 'Instance Not Found RPC ERROR',
          );
        }
        if (serviceName == 'api.instance.PeerManageRpcService' &&
            methodName == 'show_node_info') {
          final rawNodeInfo =
              instanceMap?['my_node_info'] ?? instanceMap?['myNodeInfo'];
          final addresses = instance?.vpnConfig?['addresses'];
          return jsonEncode({
            'node_info':
                rawNodeInfo ??
                {
                  if (addresses is List && addresses.isNotEmpty)
                    'ipv4_addr': addresses.first,
                },
          });
        }
        if (serviceName == 'api.instance.PeerManageRpcService' &&
            methodName == 'list_route') {
          final pairRoutes = <Object?>[];
          for (final item
              in (instanceMap?['peer_route_pairs'] is List
                  ? instanceMap!['peer_route_pairs'] as List
                  : instanceMap?['peerRoutePairs'] is List
                  ? instanceMap!['peerRoutePairs'] as List
                  : const <Object?>[])) {
            if (item is Map && item['route'] != null) {
              pairRoutes.add(item['route']);
            }
          }
          return jsonEncode({
            'routes':
                instanceMap?['routes'] ??
                instanceMap?['route_infos'] ??
                instanceMap?['routeInfos'] ??
                pairRoutes,
          });
        }
        if (serviceName == 'api.instance.PeerManageRpcService' &&
            methodName == 'list_peer') {
          final pairPeers = <Object?>[];
          for (final item
              in (instanceMap?['peer_route_pairs'] is List
                  ? instanceMap!['peer_route_pairs'] as List
                  : instanceMap?['peerRoutePairs'] is List
                  ? instanceMap!['peerRoutePairs'] as List
                  : const <Object?>[])) {
            if (item is Map && item['peer'] != null) {
              pairPeers.add(item['peer']);
            }
          }
          return jsonEncode({
            'my_info':
                instanceMap?['my_node_info'] ?? instanceMap?['myNodeInfo'],
            'peer_infos':
                instanceMap?['peer_infos'] ??
                instanceMap?['peerInfos'] ??
                instanceMap?['peers'] ??
                pairPeers,
          });
        }
        if (serviceName == 'api.instance.StatsRpcService' &&
            methodName == 'get_stats') {
          return jsonEncode({
            'metrics': networkInfos['json_rpc_metrics'] ?? <Object?>[],
          });
        }
        fail('Unexpected JSON RPC call: $serviceName/$methodName');
      }

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
            calls.add(call);
            switch (call.method) {
              case 'getVpnState':
                return vpnState;
              case 'getMachineId':
                return 'android-machine';
              case 'getHostname':
                return 'android-host';
              case 'isConfigServerClientConnected':
                return configServerConnected;
              case 'startConfigServerClient':
              case 'retainNetworkInstance':
              case 'stopNetworkInstances':
              case 'refreshVpn':
              case 'startVpn':
              case 'stopRuntime':
              case 'stopVpn':
              case 'stopConfigServerClient':
                return null;
              case 'prepareNotifications':
                final result = notificationResult;
                if (result is Exception) {
                  throw result;
                }
                return result;
              case 'prepareVpn':
                final result = vpnPrepared;
                if (result is Exception) {
                  throw result;
                }
                return result;
              case 'listInstances':
                final snapshot = AndroidNetworkInfoSnapshot.parse(
                  jsonEncode(networkInfos),
                );
                return jsonEncode({
                  for (final instance in snapshot.instances.values)
                    instance.name: instance.id ?? '',
                });
              case 'callJsonRpc':
                return jsonRpcResponse(call);
              default:
                fail('Unexpected Android method call: ${call.method}');
            }
          });

      runtime = AndroidCoreRuntime(
        methodChannel: methodChannel,
        eventChannel: _FakeEventChannel(nativeEvents.stream),
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      await runtime.dispose();
      await nativeEvents.close();
    });

    test('does not report running before VPN permission is prepared', () async {
      configServerConnected = true;

      final status = await runtime.readStatus(_androidBootstrap());

      expect(status, isNull);
      expect(
        calls.where((call) => call.method == 'isConfigServerClientConnected'),
        isEmpty,
      );
    });

    test('reports running after VPN permission is prepared', () async {
      configServerConnected = true;

      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      final status = await runtime.readStatus(_androidBootstrap());

      expect(status?.phase, CoreRunPhase.running);
      expect(
        calls.map((call) => call.method),
        contains('isConfigServerClientConnected'),
      );
    });

    test(
      'does not report running after runtime stop resets VPN preparation',
      () async {
        configServerConnected = true;

        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        await runtime.stop();
        calls.clear();

        final status = await runtime.readStatus(_androidBootstrap());

        expect(status, isNull);
        expect(calls, isEmpty);
      },
    );

    test('continues when notification permission is denied', () async {
      notificationResult = false;

      final result = await runtime.ensureRunning(
        _androidBootstrap(),
        forceReinstall: false,
      );

      expect(result.phase, CoreRunPhase.running);
      expect(
        calls.map((call) => call.method),
        containsAllInOrder([
          'prepareNotifications',
          'startConfigServerClient',
          'prepareVpn',
        ]),
      );
    });

    test('continues when notification permission plugin is missing', () async {
      notificationResult = MissingPluginException('prepareNotifications');

      final result = await runtime.ensureRunning(
        _androidBootstrap(),
        forceReinstall: false,
      );

      expect(result.phase, CoreRunPhase.running);
      expect(
        calls.map((call) => call.method),
        containsAllInOrder([
          'prepareNotifications',
          'startConfigServerClient',
          'prepareVpn',
        ]),
      );
    });

    test('continues when notification permission request is pending', () async {
      notificationResult = PlatformException(
        code: 'NOTIFICATION_PERMISSION_PENDING',
        message: 'Notification permission request is already pending',
      );

      final result = await runtime.ensureRunning(
        _androidBootstrap(),
        forceReinstall: false,
      );

      expect(result.phase, CoreRunPhase.running);
      expect(
        calls.map((call) => call.method),
        containsAllInOrder([
          'prepareNotifications',
          'startConfigServerClient',
          'prepareVpn',
        ]),
      );
    });

    test(
      'reports VPN permission needed when request is already pending',
      () async {
        vpnPrepared = PlatformException(
          code: 'VPN_PERMISSION_PENDING',
          message: 'VPN permission request is already pending',
        );

        final result = await runtime.ensureRunning(
          _androidBootstrap(),
          forceReinstall: false,
        );

        expect(result.phase, CoreRunPhase.needsVpnPermission);
        expect(calls.where((call) => call.method == 'startVpn'), isEmpty);
      },
    );

    test('uses fast traffic and low-frequency peer polling intervals', () {
      expect(runtime.networkTrafficPollInterval, const Duration(seconds: 2));
      expect(runtime.peerStatusPollInterval, const Duration(seconds: 5));
    });

    test('reads Android runtime snapshots through JSON RPC', () async {
      final cachedRuntime = AndroidCoreRuntime(
        methodChannel: methodChannel,
        eventChannel: _FakeEventChannel(nativeEvents.stream),
      );
      addTearDown(cachedRuntime.dispose);

      await cachedRuntime.readNetworkPeerStatuses('network-a');
      await cachedRuntime.isNetworkInstanceRunning('network-a');

      expect(calls.where((call) => call.method == 'listInstances'), isNotEmpty);
      expect(calls.where((call) => call.method == 'callJsonRpc'), isNotEmpty);
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
              {
                'route': {
                  'peer_id': 789,
                  'ipv4_addr': {
                    'address': {'addr': 168427524},
                    'network_length': 24,
                  },
                  'hostname': 'relay-peer',
                  'cost': 2,
                },
                'peer': {'peer_id': 789},
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
      expect(remote.cost, 'p2p');
      expect(remote.latencyText, '3.452');
      expect(remote.lossText, '0.01');
      expect(remote.rxBytes, '1.00 KiB');
      expect(remote.txBytes, '2.00 KiB');
      expect(remote.tunnelProto, 'udp');
      expect(remote.natType, 'Symmetric');
      expect(remote.version, '2.6.4');

      final relay = statuses['10.10.0.4']!;
      expect(relay.hostname, 'relay-peer');
      expect(relay.cost, 'relay(2)');
    });

    test(
      'does not substitute connection traffic for missing business stats',
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

        expect(totals, isEmpty);
      },
    );

    test('derives Android traffic totals from JSON RPC stats', () async {
      networkInfos = {
        'instances': [
          {
            'instance_id': 'instance-a',
            'instance_name': 'network-a',
            'running': true,
            'ipv4_cidr': '10.10.0.2/24',
          },
        ],
        'json_rpc_metrics': [
          {
            'name': 'traffic_bytes_rx',
            'value': '4096',
            'labels': {'network_name': 'network-a'},
          },
          {
            'name': 'traffic_bytes_tx',
            'value': 8192,
            'labels': {'network_name': 'network-a'},
          },
          {
            'name': 'traffic_bytes_self_rx',
            'value': 14096,
            'labels': {'network_name': 'network-a'},
          },
          {
            'name': 'traffic_control_bytes_tx',
            'value': 10000,
            'labels': {'network_name': 'network-a'},
          },
          {
            'name': 'traffic_bytes_tx_by_instance',
            'value': 8192,
            'labels': {'network_name': 'network-a', 'to_instance_id': 'peer-a'},
          },
        ],
      };

      final totals = await runtime.readNetworkTrafficTotals();

      expect(totals.keys, ['network-a']);
      expect(totals['network-a']!.downloadBytes, 4096);
      expect(totals['network-a']!.uploadBytes, 8192);
      expect(calls.map((call) => call.method), contains('callJsonRpc'));
    });

    test(
      'keeps VPN membership in the native service across callbacks',
      () async {
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        for (final id in ['instance-a', 'instance-b']) {
          nativeEvents.add({
            'type': CoreRuntimeEventTypes.configServer,
            'payload': {'event': 'run_network_instance', 'instance_id': id},
          });
        }
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'delete_network_instance',
            'instance_id': 'instance-a',
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          calls.where((call) => call.method == 'retainNetworkInstance'),
          isEmpty,
        );
        expect(calls.where((call) => call.method == 'stopVpn'), isEmpty);
        expect(calls.where((call) => call.method == 'startVpn'), isEmpty);
        expect(
          calls.where((call) => call.method == 'refreshVpn'),
          hasLength(1),
        );
      },
    );

    test('does not report an addressless TUN member as ready', () async {
      networkInfos = {
        'instances': [
          {
            'instance_id': 'instance-a',
            'instance_name': 'network-a',
            'running': true,
          },
        ],
      };
      expect(await runtime.isNetworkInstanceRunning('network-a'), isFalse);
    });

    test(
      'checks per-instance TUN readiness independently of core running',
      () async {
        networkInfos = {
          'instances': [
            {
              'instance_id': 'instance-a',
              'instance_name': 'network-a',
              'running': true,
              'ipv4_cidr': '10.1.0.2/24',
            },
            {
              'instance_id': 'instance-b',
              'instance_name': 'network-b',
              'running': true,
              'ipv4_cidr': '10.2.0.2/24',
            },
          ],
        };
        vpnState = {
          'instance_ids': ['instance-a'],
          'addresses': ['10.1.0.2/24'],
          'rejected': <Object?>[],
        };
        expect(await runtime.isNetworkInstanceRunning('network-a'), isTrue);
        expect(await runtime.isNetworkInstanceRunning('network-b'), isFalse);
        vpnState = {
          'instance_ids': ['instance-a', 'instance-b'],
          'addresses': ['10.1.0.2/24'],
          'rejected': <Object?>[],
        };
        expect(await runtime.isNetworkInstanceRunning('network-b'), isFalse);
        vpnState = {
          'instance_ids': ['instance-a', 'instance-b'],
          'addresses': ['10.1.0.2/24', '10.2.0.2/24'],
          'rejected': <Object?>[],
        };
        expect(await runtime.isNetworkInstanceRunning('network-a'), isTrue);
        expect(await runtime.isNetworkInstanceRunning('network-b'), isTrue);
        vpnState = {
          'instance_ids': ['instance-b'],
          'addresses': ['10.2.0.2/24'],
          'rejected': <Object?>[],
        };
        expect(await runtime.isNetworkInstanceRunning('network-a'), isFalse);
        expect(await runtime.isNetworkInstanceRunning('network-b'), isTrue);
      },
    );

    test(
      'waits for the requested instance and surfaces its rejection',
      () async {
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        expect(
          await runtime.waitForNetworkConnection(
            'network-a',
            readInstanceId: () async => 'instance-a',
          ),
          '10.10.0.2/24',
        );
        vpnState = {
          'instance_ids': ['instance-a'],
          'addresses': ['10.10.0.2/24'],
          'rejected': [
            {'instance_id': 'instance-b', 'error': 'overlapping route'},
          ],
        };
        await expectLater(
          runtime.waitForNetworkConnection(
            'network-b',
            readInstanceId: () async => 'instance-b',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'overlapping route',
            ),
          ),
        );
        expect(await runtime.isNetworkInstanceRunning('network-a'), isTrue);
      },
    );

    test('VPN events wake and confirm the requested network', () async {
      await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
      vpnState = {
        'instance_ids': ['instance-b'],
        'addresses': ['10.20.0.2/24'],
        'rejected': <Object?>[],
      };
      var consoleReads = 0;
      var completed = false;
      final connection = runtime
          .waitForNetworkConnection(
            'network-a',
            readInstanceId: () async {
              consoleReads++;
              return 'instance-a';
            },
          )
          .then((value) {
            completed = true;
            return value;
          });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      nativeEvents.add({'type': CoreRuntimeEventTypes.vpnStarted});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(completed, isFalse);
      expect(consoleReads, 2);

      vpnState = {
        'instance_ids': ['instance-a', 'instance-b'],
        'addresses': ['10.20.0.2/24'],
        'rejected': <Object?>[],
      };
      nativeEvents.add({'type': CoreRuntimeEventTypes.vpnConfigRefreshed});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(completed, isFalse);
      expect(consoleReads, 3);
      vpnState = {
        'instance_ids': ['instance-a', 'instance-b'],
        'addresses': ['10.10.0.2/24', '10.20.0.2/24'],
        'rejected': <Object?>[],
      };
      nativeEvents.add({'type': CoreRuntimeEventTypes.vpnConfigRefreshed});
      expect(
        await connection.timeout(const Duration(milliseconds: 500)),
        '10.10.0.2/24',
      );
      expect(consoleReads, 4);
    });

    test(
      'does not accept a VPN event for a node detached during startup',
      () async {
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        vpnState = {'instance_ids': <String>[], 'rejected': <Object?>[]};
        var reads = 0;
        var completed = false;
        final connection = runtime
            .waitForNetworkConnection(
              'network-a',
              readInstanceId: () async {
                reads++;
                return reads == 1 ? 'instance-a' : null;
              },
            )
            .then((value) {
              completed = true;
              return value;
            });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        vpnState = {
          'instance_ids': ['instance-a'],
          'addresses': ['10.10.0.2/24'],
          'rejected': <Object?>[],
        };
        nativeEvents.add({'type': CoreRuntimeEventTypes.vpnStarted});
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(reads, 2);
        expect(completed, isFalse);
        await runtime.stop();
        await expectLater(connection, throwsStateError);
      },
    );

    test(
      'VPN event refreshes an instance ID not yet reported by console',
      () async {
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        vpnState = {'instance_ids': <String>[], 'rejected': <Object?>[]};
        var reads = 0;
        final connection = runtime.waitForNetworkConnection(
          'network-a',
          readInstanceId: () async => ++reads == 1 ? null : 'instance-a',
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        vpnState = {
          'instance_ids': ['instance-a'],
          'addresses': ['10.10.0.2/24'],
          'rejected': <Object?>[],
        };
        nativeEvents.add({'type': CoreRuntimeEventTypes.vpnStarted});
        expect(
          await connection.timeout(const Duration(milliseconds: 500)),
          '10.10.0.2/24',
        );
        expect(reads, 2);
      },
    );

    test(
      'isolates config server failure to its network until retry succeeds',
      () async {
        await runtime.ensureRunning(_androidBootstrap(), forceReinstall: false);
        final events = <CoreRuntimeEvent>[];
        final subscription = runtime.events.listen(events.add);
        final eventFuture = runtime.events.firstWhere(
          (event) => event.type == 'network_error',
        );

        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_id': 'instance-b',
            'success': false,
            'error': 'config build failed',
          },
        });

        final event = await eventFuture;
        expect(event.data['error'], 'config build failed');
        expect(event.data['event'], 'run_network_instance');
        await expectLater(
          runtime.waitForNetworkConnection(
            'network-b',
            readInstanceId: () async => 'instance-b',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'config build failed',
            ),
          ),
        );
        expect(await runtime.isNetworkInstanceRunning('network-a'), isTrue);
        expect(
          events.where((event) => event.type == CoreRuntimeEventTypes.error),
          isEmpty,
        );
        nativeEvents.add({
          'type': CoreRuntimeEventTypes.configServer,
          'payload': {
            'event': 'run_network_instance',
            'instance_id': 'instance-b',
            'success': true,
          },
        });
        await Future<void>.delayed(Duration.zero);
        // A subsequent success clears the previous error instead of poisoning retries.
        vpnState = {
          'instance_ids': ['instance-a', 'instance-b'],
          'addresses': ['10.10.0.2/24', '10.2.0.2/24'],
          'rejected': <Object?>[],
        };
        networkInfos = {
          'instances': [
            {
              'instance_id': 'instance-b',
              'instance_name': 'network-b',
              'running': true,
              'ipv4_cidr': '10.2.0.2/24',
            },
          ],
        };
        expect(
          await runtime.waitForNetworkConnection(
            'network-b',
            readInstanceId: () async => 'instance-b',
          ),
          '10.2.0.2/24',
        );
        expect(calls.where((call) => call.method == 'startVpn'), isEmpty);
        await subscription.cancel();
      },
    );
  });
}

CoreBootstrapConfig _androidBootstrap() {
  return const CoreBootstrapConfig(
    version: '2.6.4',
    configServer: 'tcp://127.0.0.1:22020',
    bootstrapToken: 'bootstrap-token',
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
