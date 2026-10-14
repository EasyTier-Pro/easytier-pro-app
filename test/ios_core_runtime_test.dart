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
  late List<Map<String, Object?>> trafficMetrics;
  Future<Object?> Function(MethodCall)? waitForConnection;
  Future<Object?> Function()? readStatus;
  String? failure;

  setUp(() {
    events = StreamController<Object?>.broadcast();
    calls = [];
    failure = null;
    waitForConnection = null;
    readStatus = null;
    status = {
      'running': true,
      'vpn_ready': true,
      'network_name': 'authorized-network',
      'instance_id': 'actual-instance-id',
      'virtual_ipv4': '10.1.0.2',
      'machine_id': 'stable-machine',
      'core_version': '2.7.0',
    };
    snapshot = {
      'vpn_ready': true,
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
    trafficMetrics = [
      {'name': 'traffic_bytes_rx', 'value': 42},
      {'name': 'traffic_bytes_tx', 'value': 21},
      {'name': 'traffic_bytes_self_rx', 'value': 10042},
      {'name': 'traffic_bytes_self_tx', 'value': 10021},
      {'name': 'traffic_control_bytes_rx', 'value': 10000},
      {'name': 'traffic_control_bytes_tx', 'value': 10000},
      {'name': 'traffic_bytes_forwarded', 'value': 999},
      {
        'name': 'traffic_bytes_rx',
        'value': 999,
        'labels': {'network_name': 'other-network'},
      },
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getMachineId':
              return 'stable-machine';
            case 'getHostname':
              return 'iPhone-stable';
            case 'readStatus':
              if (readStatus != null) return readStatus!();
              return status;
            case 'ensureRunning':
              if (failure != null) throw PlatformException(code: failure!);
              return status;
            case 'collectNetworkInfos':
              return jsonEncode(snapshot);
            case 'callJsonRpc':
              return jsonEncode({'metrics': trafficMetrics});
            case 'beginNetworkConnection':
              return null;
            case 'waitForNetworkConnection':
              if (waitForConnection != null) return waitForConnection!(call);
              return {
                'instance_id': status['instance_id'],
                'virtual_ipv4': status['virtual_ipv4'],
                'session_id': 'vpn-session',
                'event_id': 1,
              };
            case 'endNetworkConnection':
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
    'starts foreground control with encoded credentials and its actual core version',
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
      expect(totals.keys, ['authorized-network']);
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

  test('control traffic growth leaves idle business traffic at zero', () async {
    for (final controlBytes in [1000, 2000]) {
      trafficMetrics = [
        {'name': 'traffic_bytes_rx'},
        {'name': 'traffic_bytes_tx'},
        {'name': 'traffic_bytes_self_rx', 'value': controlBytes},
        {'name': 'traffic_bytes_self_tx', 'value': controlBytes},
        {'name': 'traffic_control_bytes_rx', 'value': controlBytes},
        {'name': 'traffic_control_bytes_tx', 'value': controlBytes},
      ];
      final totals = await runtime.readNetworkTrafficTotals();
      expect(totals['authorized-network']?.downloadBytes, 0);
      expect(totals['authorized-network']?.uploadBytes, 0);
    }
  });

  test(
    'reads initial zero counters before the first business packet',
    () async {
      trafficMetrics = [
        {'name': 'traffic_bytes_rx'},
        {'name': 'traffic_bytes_tx'},
      ];
      final idle = await runtime.readNetworkTrafficTotals();
      expect(idle.keys, ['authorized-network']);
      expect(idle['authorized-network']?.downloadBytes, 0);
      expect(idle['authorized-network']?.uploadBytes, 0);

      trafficMetrics = [
        {'name': 'traffic_bytes_rx', 'value': '4096'},
        {'name': 'traffic_bytes_tx', 'value': '1024'},
      ];
      final active = await runtime.readNetworkTrafficTotals();
      expect(active['authorized-network']?.downloadBytes, 4096);
      expect(active['authorized-network']?.uploadBytes, 1024);

      final settled = await runtime.readNetworkTrafficTotals();
      expect(settled['authorized-network']?.downloadBytes, 4096);
      expect(settled['authorized-network']?.uploadBytes, 1024);
    },
  );

  test('missing business counters do not produce a zero sample', () async {
    trafficMetrics = [
      {'name': 'traffic_bytes_self_rx', 'value': 1000},
      {'name': 'traffic_control_bytes_rx', 'value': 1000},
    ];
    expect(await runtime.readNetworkTrafficTotals(), isEmpty);
  });

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

  test(
    'a running core instance is not ready until its system VPN data path is ready',
    () async {
      snapshot['vpn_ready'] = false;
      expect(
        await runtime.isNetworkInstanceRunning('authorized-network'),
        isFalse,
      );
      expect(await runtime.readNetworkTrafficTotals(), isEmpty);
      await expectLater(
        runtime.readNetworkPeerStatuses('authorized-network'),
        throwsStateError,
      );
      expect(calls.where((call) => call.method == 'callJsonRpc'), isEmpty);
    },
  );

  test(
    'network activation holds native background time and waits for the requested network',
    () async {
      await runtime.beginNetworkConnection();
      expect(
        await runtime.waitForNetworkConnection(
          ' authorized-network ',
          readInstanceId: () async => 'actual-instance-id',
        ),
        '10.1.0.2',
      );
      await runtime.endNetworkConnection();
      expect(calls.map((call) => call.method), [
        'beginNetworkConnection',
        'waitForNetworkConnection',
        'readStatus',
        'endNetworkConnection',
      ]);
      final args = calls[1].arguments as Map;
      expect(args['networkName'], 'authorized-network');
      expect(args['timeoutSeconds'], inExclusiveRange(0, 40.001));
      expect(args.containsKey('after'), isFalse);
    },
  );

  test('same-name old runtime cannot complete a new node connection', () async {
    status['instance_id'] = 'old-instance';
    final next = Completer<Object?>();
    var wakeups = 0;
    var lookups = 0;
    waitForConnection = (call) async {
      if (++wakeups == 1) {
        return {
          'instance_id': 'old-instance',
          'session_id': 'old-session',
          'event_id': 7,
        };
      }
      return next.future;
    };
    var completed = false;
    final connection = runtime
        .waitForNetworkConnection(
          'authorized-network',
          readInstanceId: () async {
            lookups += 1;
            return 'new-instance';
          },
        )
        .then((value) {
          completed = true;
          return value;
        });
    await pumpEventQueue();
    expect(completed, isFalse);
    expect(lookups, 1);
    final waits = calls.where(
      (call) => call.method == 'waitForNetworkConnection',
    );
    expect(waits.length, 2);
    expect((waits.last.arguments as Map)['after'], {
      'session_id': 'old-session',
      'event_id': 7,
    });
    status['instance_id'] = 'new-instance';
    next.complete({
      'instance_id': 'new-instance',
      'session_id': 'new-session',
      'event_id': 2,
    });
    expect(await connection, '10.1.0.2');
    expect(lookups, 2);
  });

  test(
    'late node allocation waits for a native wakeup before querying again',
    () async {
      final next = Completer<Object?>();
      var wakeups = 0;
      var lookups = 0;
      waitForConnection = (call) async {
        if (++wakeups == 1) {
          return {'session_id': 'vpn-session', 'event_id': 3};
        }
        return next.future;
      };
      final connection = runtime.waitForNetworkConnection(
        'authorized-network',
        readInstanceId: () async =>
            ++lookups == 1 ? null : 'actual-instance-id',
      );
      await pumpEventQueue();
      expect(lookups, 1);
      expect(calls.where((call) => call.method == 'readStatus'), isEmpty);
      await pumpEventQueue();
      expect(lookups, 1);
      next.complete({'session_id': 'vpn-session', 'event_id': 4});
      expect(await connection, '10.1.0.2');
      expect(lookups, 2);
    },
  );

  test(
    'a replacement during the console lookup invalidates the earlier readiness',
    () async {
      final lookup = Completer<String?>();
      final next = Completer<Object?>();
      var wakeups = 0;
      var lookups = 0;
      waitForConnection = (call) async {
        if (++wakeups == 1) {
          return {'session_id': 'vpn-session', 'event_id': 3};
        }
        return next.future;
      };
      var completed = false;
      final connection = runtime
          .waitForNetworkConnection(
            'authorized-network',
            readInstanceId: () async =>
                ++lookups == 1 ? lookup.future : 'replacement',
          )
          .then((value) {
            completed = true;
            return value;
          });
      await pumpEventQueue();
      status['instance_id'] = 'replacement';
      lookup.complete('actual-instance-id');
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(lookups, 1);
      next.complete({'session_id': 'vpn-session', 'event_id': 4});
      expect(await connection, '10.1.0.2');
    },
  );

  testWidgets(
    'a hung identity lookup times out and cannot later complete the join',
    (tester) async {
      final lookup = Completer<String?>();
      final connection = runtime.waitForNetworkConnection(
        'authorized-network',
        readInstanceId: () => lookup.future,
      );
      final failed = expectLater(connection, throwsA(isA<TimeoutException>()));
      await tester.pump();
      expect(
        calls.where((call) => call.method == 'waitForNetworkConnection').length,
        1,
      );
      await tester.pump(const Duration(seconds: 41));
      await failed;
      lookup.complete('actual-instance-id');
      await tester.pump();
      expect(calls.where((call) => call.method == 'readStatus'), isEmpty);
    },
  );

  testWidgets('a hung status recheck shares the connection timeout', (
    tester,
  ) async {
    final snapshot = Completer<Object?>();
    readStatus = () => snapshot.future;
    final connection = runtime.waitForNetworkConnection(
      'authorized-network',
      readInstanceId: () async => 'actual-instance-id',
    );
    final failed = expectLater(connection, throwsA(isA<TimeoutException>()));
    await tester.pump();
    expect(calls.where((call) => call.method == 'readStatus').length, 1);
    await tester.pump(const Duration(seconds: 41));
    await failed;
    snapshot.complete(status);
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'waitForNetworkConnection').length,
      1,
    );
  });

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
