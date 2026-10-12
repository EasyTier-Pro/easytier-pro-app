import 'dart:async';
import 'dart:convert';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.ios/runtime');
  const bootstrap = CoreBootstrapConfig(
    version: '999.0.0',
    configServer: 'tcp://console.test:22020/base/',
    bootstrapToken: 'token/with space',
  );
  late StreamController<Object?> events;
  late IosCoreRuntime runtime;
  late List<MethodCall> calls;
  late Map<String, Object?> status;
  late Map<String, Object?> snapshot;
  String? failure;

  setUp(() {
    events = StreamController<Object?>.broadcast();
    calls = [];
    failure = null;
    status = {
      'running': true,
      'machine_id': 'stable-machine',
      'core_version': '2.7.0',
    };
    snapshot = {
      'network_name': 'authorized-network',
      'instance_name': 'actual-instance',
      'instances': {
        'actual-instance': {
          'running': true,
          'my_node_info': {'virtual_ipv4': '10.1.0.2/24', 'hostname': 'phone'},
          'peer_route_pairs': [],
        },
      },
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getMachineId':
              return 'stable-machine';
            case 'getHostname':
              return 'iPhone-stable';
            case 'readStatus':
              return status;
            case 'ensureRunning':
              if (failure != null) throw PlatformException(code: failure!);
              return status;
            case 'collectNetworkInfos':
              return jsonEncode(snapshot);
            case 'callJsonRpc':
              return jsonEncode({
                'metrics': [
                  {'name': 'traffic_bytes_self_rx', 'value': 42},
                  {'name': 'traffic_bytes_self_tx', 'value': 21},
                  {'name': 'traffic_bytes_forward_rx', 'value': 999},
                ],
              });
            case 'stopRuntime':
              return null;
          }
          throw StateError('Unexpected method ${call.method}');
        });
    runtime = IosCoreRuntime(
      methodChannel: channel,
      eventChannel: _Events(events.stream),
    );
  });

  tearDown(() async {
    await runtime.dispose();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'starts the extension with encoded credentials and its actual core version',
    () async {
      final result = await runtime.ensureRunning(
        bootstrap,
        forceReinstall: false,
      );
      expect(result.phase, CoreRunPhase.running);
      expect(result.machineId, 'stable-machine');
      expect(result.coreVersion, '2.7.0');
      expect(
        calls.singleWhere((call) => call.method == 'ensureRunning').arguments,
        {
          'url': 'tcp://console.test:22020/base/token%2Fwith%20space',
          'token': 'token/with space',
          'hostname': 'iPhone-stable',
          'forceReinstall': false,
        },
      );
    },
  );

  test(
    'restoration checks the current bootstrap instead of trusting another account VPN',
    () async {
      expect(await runtime.readStatus(bootstrap), isNotNull);
      expect(calls.single.arguments, {
        'url': 'tcp://console.test:22020/base/token%2Fwith%20space',
        'token': 'token/with space',
      });
      status['running'] = false;
      expect(await runtime.readStatus(bootstrap), isNull);
    },
  );

  test(
    'permission denial requests authorization but other startup errors propagate',
    () async {
      failure = 'VPN_PERMISSION_DENIED';
      expect(
        (await runtime.ensureRunning(bootstrap, forceReinstall: false)).phase,
        CoreRunPhase.needsVpnPermission,
      );
      failure = 'IOS_RUNTIME_ERROR';
      await expectLater(
        runtime.ensureRunning(bootstrap, forceReinstall: false),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'reads only the selected network and queries stats by actual instance name',
    () async {
      expect(
        await runtime.isNetworkInstanceRunning('authorized-network'),
        isTrue,
      );
      expect(await runtime.isNetworkInstanceRunning('other-network'), isFalse);
      final totals = await runtime.readNetworkTrafficTotals();
      expect(totals['authorized-network']?.downloadBytes, 42);
      expect(totals['authorized-network']?.uploadBytes, 21);
      final args =
          calls.singleWhere((call) => call.method == 'callJsonRpc').arguments
              as Map;
      expect(jsonDecode(args['payloadJson'] as String), {
        'instance': {
          'instance_selector': {'name': 'actual-instance'},
        },
      });
    },
  );

  test(
    'cleared network returns empty traffic without making a stale RPC',
    () async {
      snapshot = {'instances': {}};
      expect(await runtime.readNetworkTrafficTotals(), isEmpty);
      expect(calls.where((call) => call.method == 'callJsonRpc'), isEmpty);
    },
  );

  test(
    'forwards native lifecycle events and preserves the VPN on Flutter disposal',
    () async {
      final received = runtime.events.first;
      events.add({
        'type': 'config_server_stopped',
        'payload': {'reason': 'revoked'},
      });
      final event = await received;
      expect(event.type, CoreRuntimeEventTypes.configServerStopped);
      expect(event.data['platform'], 'iOS');
      await runtime.dispose();
      expect(calls.where((call) => call.method == 'stopRuntime'), isEmpty);
    },
  );

  test('explicit disconnect stops the native extension', () async {
    await runtime.stop();
    expect(calls.single.method, 'stopRuntime');
  });
}

class _Events extends EventChannel {
  _Events(this.events) : super('test.ios/events');
  final Stream<Object?> events;
  @override
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) => events;
}
