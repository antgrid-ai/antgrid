// A restart is the fresh attempt for a machine that is still wanted (refresh,
// the eager resume kick). Unlike a release it keeps the connection object, so
// projects already bound to it are told to rebind instead of being stranded on
// a connection nothing will ever bring back up.
import 'dart:async';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/peer_runtime.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixed_peer_connector.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_license_token_minter.dart';
import '../helpers/test_peer_runtime.dart';
import '../helpers/test_store_overrides.dart';

const _machine = 'machine-uuid';

/// Fails naming [what] instead of falling through to an assertion that blames
/// the wrong step. Under the native stop's 5 s graceful timeout, so a stop that
/// times out can never be what satisfies a wait.
Future<void> _waitFor(String what, bool Function() until) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!until()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Starts [_machine]'s connection with its coords rung parked on [gate]. Native
/// stop waits out an in-flight rung, so a restart of this connection stays in
/// flight, with the stopping supervisor still in place, until [gate] completes.
Future<MachineConnection> _startParked(
  MachineConnectionManager mgr,
  Completer<void> gate,
) async {
  addTearDown(() {
    if (!gate.isCompleted) gate.complete();
  });
  final reached = Completer<void>();
  final conn = mgr.connectionFor(_machine)
    ..ensureStarted(
      mechanisms: PeerConnectionMechanisms(
        peerRuntime: FixedPeerConnector.stub(),
        machineDeviceId: _machine,
        resolveCoords: () async {
          if (!reached.isCompleted) reached.complete();
          await gate.future;
          return null;
        },
      ),
    );
  await _waitFor('the coords rung', () => reached.isCompleted);
  return conn;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MachineConnection.restart', () {
    late MachineConnectionManager mgr;

    setUp(() {
      mgr = MachineConnectionManager(crypto: CryptoService());
      addTearDown(mgr.disposeAll);
    });

    test('keeps the connection, tells bound projects to rebind as it begins, '
        'and leaves the next ensureStarted a fresh ladder', () async {
      final gate = Completer<void>();
      final conn = await _startParked(mgr, gate);
      final old = conn.supervisor;
      var replacements = 0;
      conn.sessionReplacements.listen((_) => replacements++);

      final restarting = mgr.restart(_machine);
      await pumpEventQueue();
      expect(replacements, 1, reason: 'emitted before the stop settles');
      expect(conn.restarting, isNotNull);
      expect(conn.supervisor, same(old), reason: 'still stopping');

      gate.complete();
      expect(await restarting, NativeStopResult.stopped);
      expect(conn.restarting, isNull);
      expect(conn.isDisposed, isFalse);
      expect(conn.supervisor, isNull);
      expect(mgr.peek(_machine), same(conn), reason: 'never released');

      conn.ensureStarted(
        mechanisms: PeerConnectionMechanisms(
          peerRuntime: FixedPeerConnector.stub(),
          machineDeviceId: _machine,
          resolveCoords: () async => null,
        ),
      );
      expect(conn.supervisor, isNotNull);
      expect(conn.supervisor, isNot(same(old)));
      expect(replacements, 1);
    });

    test('a transport parked in awaitSession is told to rebind before the '
        'stopping ladder fails it', () async {
      final gate = Completer<void>();
      final conn = await _startParked(mgr, gate);
      final order = <String>[];
      conn.sessionReplacements.listen((_) => order.add('replaced'));
      unawaited(
        conn.awaitSession().then<void>(
          (_) => order.add('session'),
          onError: (Object _) => order.add('failed'),
        ),
      );

      final restarting = mgr.restart(_machine);
      await pumpEventQueue();
      expect(order, ['replaced'], reason: 'told while the stop is in flight');
      gate.complete();
      await restarting;
      await pumpEventQueue();
      expect(order, ['replaced', 'failed']);
    });

    test('a connection that was never started has nothing to restart', () async {
      final conn = mgr.connectionFor(_machine);
      var replacements = 0;
      conn.sessionReplacements.listen((_) => replacements++);
      expect(await mgr.restart(_machine), NativeStopResult.stopped);
      await pumpEventQueue();
      expect(replacements, 0);
      expect(conn.isDisposed, isFalse);
    });

    test('a machine with no connection is not dialled by a restart', () async {
      expect(await mgr.restart(_machine), isNull);
      expect(mgr.peek(_machine), isNull);
    });

    test('a dispose landing mid-restart wins: nothing restarts afterwards', () async {
      final gate = Completer<void>();
      final conn = await _startParked(mgr, gate);
      final restarting = mgr.restart(_machine);
      final releasing = mgr.release(_machine);
      gate.complete();
      expect(await restarting, NativeStopResult.stopped);
      expect(await releasing, NativeStopResult.stopped);
      expect(conn.isDisposed, isTrue);
      expect(mgr.peek(_machine), isNull);
    });
  });

  group('the transport build against a restart in flight', () {
    late TestStoreOverrides stores;

    setUp(() async {
      useInMemoryPrefs();
      stores = await buildTestStoreOverrides();
    });

    tearDown(() async {
      await stores.close();
    });

    test('waits the restart out and starts a fresh ladder on the same '
        'connection, never a no-op against the stopping one', () async {
      final runtimeGate = Completer<void>();
      final runtimeRead = Completer<void>();
      final c = ProviderContainer(
        overrides: [
          ...stores.overrides,
          peerRuntimeProvider.overrideWith((ref) async {
            if (!runtimeRead.isCompleted) runtimeRead.complete();
            await runtimeGate.future;
            final runtime = TestPeerRuntime();
            ref.onDispose(runtime.dispose);
            return runtime;
          }),
          accountAgentsProvider.overrideWith(
            (_) async => [
              InventoryAgent(
                deviceUuid: _machine,
                displayName: 'Remote',
                platform: 'linux',
                ed25519Pub: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
                // Refused at once: central control is not what this test is
                // about.
                relayUrl: 'ws://127.0.0.1:1',
              ),
            ],
          ),
          localDeviceUuidProvider.overrideWith((_) async => 'this-device'),
          connectionDeviceRecordProvider.overrideWith(
            (_) async => leaseRecord(),
          ),
          connectionTokenMinterProvider.overrideWith(
            (_) async => TestLicenseTokenMinter(),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(accountAgentsProvider.future);
      final mgr = c.read(relayConnectionManagerProvider);
      final teardownGate = Completer<void>();
      final conn = await _startParked(mgr, teardownGate);
      final stopping = conn.supervisor;

      Object? buildError;
      c.listen(
        agentTransportForProvider(_machine),
        (_, next) => buildError ??= next.error,
      );
      await _waitFor('the build to park', () => runtimeRead.isCompleted);

      final restarting = mgr.restart(_machine);
      runtimeGate.complete();
      await pumpEventQueue();
      expect(conn.supervisor, same(stopping), reason: 'still stopping');
      expect(buildError, isNull);

      teardownGate.complete();
      expect(await restarting, NativeStopResult.stopped);
      await _waitFor(
        'a fresh ladder',
        () => buildError != null || conn.supervisor != null,
      );
      expect(buildError, isNull);
      expect(mgr.peek(_machine), same(conn));
      expect(conn.supervisor, isNot(same(stopping)));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
