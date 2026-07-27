import 'dart:async';

import 'package:test/test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Minimal [BufferedAgentTransport] exercising the tier-2/tier-3 contract in
/// isolation (no sockets, no E2E). [connect] flips to `connected` (which the
/// base treats as established); [redriveHydrators] is invoked directly to
/// simulate a (re)establishment the way `StreamTransport.refreshSnapshot` does.
class _TestTransport extends BufferedAgentTransport {
  final List<Map<String, dynamic>> sent = [];

  @override
  bool get isLocal => false;

  @override
  Future<void> connect() async => setState(TransportState.connected);

  /// Drop back below established without a full teardown (mimics a session-down
  /// window the base would still report `connected` for — here we drive state
  /// directly since the base's establishment == connected).
  void goDown() => setState(TransportState.disconnected);

  /// Publicly re-drive, standing in for a handshake re-establishment.
  void reestablish() {
    setState(TransportState.connected);
    redriveHydrators();
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    sent.add(message);
  }

  @override
  Future<void> dispose() async {
    clearHydrators();
    await outbound.close();
    await stateController.close();
  }
}

void main() {
  group('hydrate (tier-3)', () {
    test('fires immediately when already established', () async {
      final t = _TestTransport();
      await t.connect();
      var calls = 0;
      await t.hydrate('k', () async => calls++);
      expect(calls, 1, reason: 'established → fires now');
    });

    test('does NOT fire before establishment, fires on re-drive', () async {
      final t = _TestTransport(); // connecting, not established
      var calls = 0;
      await t.hydrate('k', () async => calls++);
      expect(calls, 0, reason: 'not established → registered, not run');
      t.reestablish();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'first establishment re-drives it');
    });

    test(
      're-fires on every re-establishment (reconciliation checkpoint)',
      () async {
        final t = _TestTransport();
        await t.connect();
        var calls = 0;
        await t.hydrate('k', () async => calls++);
        expect(calls, 1);
        t.goDown();
        t.reestablish();
        await Future<void>.delayed(Duration.zero);
        expect(calls, 2, reason: 'each re-establishment re-pulls view-state');
        t.goDown();
        t.reestablish();
        await Future<void>.delayed(Duration.zero);
        expect(calls, 3);
      },
    );

    test(
      'a re-register under the same key supersedes (no duplicate)',
      () async {
        final t = _TestTransport();
        await t.connect();
        var a = 0, b = 0;
        await t.hydrate('k', () async => a++);
        await t.hydrate('k', () async => b++); // supersedes
        a = 0;
        b = 0;
        t.reestablish();
        await Future<void>.delayed(Duration.zero);
        expect(a, 0, reason: 'superseded run is gone');
        expect(b, 1, reason: 'only the latest run for a key survives');
      },
    );

    test('unhydrate stops the re-drive', () async {
      final t = _TestTransport();
      await t.connect();
      var calls = 0;
      await t.hydrate('k', () async => calls++);
      expect(calls, 1);
      t.unhydrate('k');
      t.reestablish();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'deregistered → not re-driven');
    });

    test(
      'one failing hydrator does not block the others on re-drive',
      () async {
        final t = _TestTransport();
        await t.connect();
        var good = 0;
        await t.hydrate('bad', () async => throw StateError('boom'));
        await t.hydrate('good', () async => good++);
        good = 0;
        // reestablish must not throw even though 'bad' throws.
        t.reestablish();
        await Future<void>.delayed(Duration.zero);
        expect(good, 1, reason: 'a throwing hydrator is isolated');
      },
    );

    test('dispose clears hydrators — no re-drive after teardown', () async {
      final t = _TestTransport();
      await t.connect();
      var calls = 0;
      await t.hydrate('k', () async => calls++);
      expect(calls, 1);
      await t.dispose();
      // redriveHydrators is a no-op now (registry cleared); calling it must not
      // resurrect the pull.
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'dispose deregisters everything');
    });
  });

  group('action (tier-2)', () {
    test('returns the run result when it completes in time', () async {
      final t = _TestTransport();
      final r = await t.action(() async => 42);
      expect(r, 42);
    });

    test('times out a run that never completes', () async {
      final t = _TestTransport();
      final never = Completer<int>();
      await expectLater(
        t.action(() => never.future, timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test(
      'timeout: null leaves the run unbounded (streaming idle-timeout owns it)',
      () async {
        final t = _TestTransport();
        final gate = Completer<int>();
        final f = t.action(() => gate.future, timeout: null);
        // Would have thrown by now if a default cap applied; complete it late.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        gate.complete(7);
        expect(await f, 7, reason: 'null timeout = no wall-clock cap');
      },
    );

    test('is NOT re-driven on re-establishment (one-shot)', () async {
      final t = _TestTransport();
      await t.connect();
      var runs = 0;
      await t.action(() async => runs++);
      expect(runs, 1);
      t.reestablish();
      await Future<void>.delayed(Duration.zero);
      expect(runs, 1, reason: 'actions never re-drive; only hydrate does');
    });
  });
}
