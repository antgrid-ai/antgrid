import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _Mechanisms implements PeerConnectionContract, CentralControlMechanisms {
  bool payload = false;
  bool established = false;
  bool reconnectNeeded = false;
  bool centralFails = false;
  int coordsCalls = 0;
  int payloadCalls = 0;
  int payloadFailuresRemaining = 0;
  int establishCalls = 0;
  int centralCalls = 0;
  int releaseCalls = 0;

  @override
  Future<ConnCoords?> resolveCoords() async {
    coordsCalls++;
    return const ConnCoords(
      relayUrl: 'wss://central.example',
      agentEd25519PubB64: 'agent-key',
    );
  }

  @override
  Future<void> connectPayload(ConnCoords coords) async {
    payloadCalls++;
    if (payloadFailuresRemaining > 0) {
      payloadFailuresRemaining--;
      throw StateError('native peer unavailable');
    }
    payload = true;
  }

  @override
  bool get payloadConnected => payload;

  @override
  Future<void> establishSession() async {
    establishCalls++;
    established = true;
  }

  @override
  bool get sessionEstablished => established;

  @override
  Future<void> release() async {
    releaseCalls++;
    payload = false;
    established = false;
  }

  @override
  bool get centralControlNeedsReconnect => reconnectNeeded;

  @override
  Future<void> reconnectCentral(ConnCoords coords) async {
    centralCalls++;
    if (centralFails) throw StateError('central unavailable');
    reconnectNeeded = false;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('native ladder climbs coords, payload, established', () async {
    final mechanisms = _Mechanisms();
    final supervisor = ConnectionSupervisor(
      mechanisms,
      backoffBaseMs: 0,
      backoffCapMs: 0,
      jitter: (_) => 0,
    );
    addTearDown(supervisor.dispose);

    supervisor.setWanted(true);
    await _settle();

    expect(supervisor.status, const Connected());
    expect(mechanisms.coordsCalls, 1);
    expect(mechanisms.payloadCalls, 1);
    expect(mechanisms.establishCalls, 1);
  });

  test('native payload failures re-resolve registered coordinates', () async {
    final mechanisms = _Mechanisms()..payloadFailuresRemaining = 3;
    final supervisor = ConnectionSupervisor(
      mechanisms,
      backoffBaseMs: 0,
      backoffCapMs: 0,
      jitter: (_) => 0,
    );
    addTearDown(supervisor.dispose);

    supervisor.setWanted(true);
    await _settle();
    await _settle();

    expect(supervisor.status, const Connected());
    expect(mechanisms.payloadCalls, 4);
    expect(mechanisms.coordsCalls, 2);
  });
  test(
    'central control reconnect is independent of payload establishment',
    () async {
      final mechanisms = _Mechanisms()
        ..reconnectNeeded = true
        ..centralFails = true;
      final supervisor = ConnectionSupervisor(
        mechanisms,
        backoffBaseMs: 100000,
        backoffCapMs: 100000,
        jitter: (_) => 0,
      );
      addTearDown(supervisor.dispose);

      supervisor.setWanted(true);
      await _settle();

      expect(supervisor.status, const Connected());
      expect(mechanisms.payload, isTrue);
      expect(mechanisms.established, isTrue);
      expect(mechanisms.centralCalls, 1);
    },
  );

  test(
    'SUPERSEDED stops central retry without disturbing native session',
    () async {
      final mechanisms = _Mechanisms()..reconnectNeeded = true;
      final supervisor = ConnectionSupervisor(
        mechanisms,
        backoffBaseMs: 0,
        backoffCapMs: 0,
        jitter: (_) => 0,
      );
      addTearDown(supervisor.dispose);

      supervisor.setWanted(true);
      await _settle();
      expect(supervisor.status, const Connected());

      mechanisms.reconnectNeeded = true;
      supervisor.noteRelayError('SUPERSEDED', retryable: false);
      await _settle();
      final callsAtConflict = mechanisms.centralCalls;

      expect(supervisor.centralConflict, isTrue);
      expect(supervisor.status, const Connected());
      expect(mechanisms.payload, isTrue);

      supervisor.noteFreshToken();
      supervisor.notePresence(true);
      await _settle();
      expect(mechanisms.centralCalls, callsAtConflict);
      expect(supervisor.centralConflict, isTrue);

      supervisor.retry();
      await _settle();
      expect(supervisor.centralConflict, isFalse);
      expect(mechanisms.centralCalls, greaterThan(callsAtConflict));
    },
  );

  test(
    'presence loss does not close or rekey an established native session',
    () async {
      final mechanisms = _Mechanisms();
      final supervisor = ConnectionSupervisor(
        mechanisms,
        backoffBaseMs: 0,
        backoffCapMs: 0,
        jitter: (_) => 0,
      );
      addTearDown(supervisor.dispose);

      supervisor.setWanted(true);
      await _settle();
      final payloadCalls = mechanisms.payloadCalls;
      final establishCalls = mechanisms.establishCalls;

      supervisor.notePresence(false);
      await _settle();

      expect(supervisor.status, const Connected());
      expect(mechanisms.payloadCalls, payloadCalls);
      expect(mechanisms.establishCalls, establishCalls);
    },
  );

  test('release tears down the native payload', () async {
    final mechanisms = _Mechanisms();
    final supervisor = ConnectionSupervisor(
      mechanisms,
      backoffBaseMs: 0,
      backoffCapMs: 0,
      jitter: (_) => 0,
    );
    addTearDown(supervisor.dispose);

    supervisor.setWanted(true);
    await _settle();
    supervisor.setWanted(false);
    await _settle();

    expect(supervisor.status, const Released());
    expect(mechanisms.releaseCalls, greaterThan(0));
    expect(mechanisms.payload, isFalse);
  });
}
