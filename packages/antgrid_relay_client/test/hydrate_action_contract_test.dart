import 'package:test/test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Minimal [BufferedAgentTransport] exercising the tier-3 hydrate contract in
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
}
