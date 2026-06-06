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

  group('AndroidCoreRuntime native events', () {
    late StreamController<Object?> nativeEvents;
    late MethodChannel methodChannel;
    late AndroidCoreRuntime runtime;
    late List<MethodCall> calls;
    var vpnPrepared = true;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      nativeEvents = StreamController<Object?>.broadcast();
      methodChannel = const MethodChannel('test.easytier/core_runtime');
      calls = <MethodCall>[];
      vpnPrepared = true;

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
                return jsonEncode({
                  'instances': [
                    {
                      'instance_name': 'network-a',
                      'running': true,
                      'ipv4_cidr': '10.10.0.2/24',
                      'routes': [
                        {'address': '10.20.0.0', 'prefix': 16},
                      ],
                      'dns_servers': ['10.10.0.1'],
                    },
                  ],
                });
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
        containsAllInOrder(['prepareNotifications', 'prepareVpn']),
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
          'routes': ['10.20.0.0/16'],
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
