import 'dart:async';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _Native implements PeerConnectionContract {
  final _events = StreamController<PeerConnectionEvent>.broadcast(sync: true);
  bool payload = false;
  bool established = false;
  int coordsCalls = 0;
  int payloadCalls = 0;
  int establishCalls = 0;
  int releaseCalls = 0;
  int forceCalls = 0;
  int fenceCalls = 0;
  int payloadFailures = 0;
  Completer<ConnCoords?>? coordsGate;
  Completer<void>? releaseGate;
  Completer<void>? forceGate;
  Object? releaseError;
  Object? forceError;

  @override
  Stream<PeerConnectionEvent> get events => _events.stream;

  @override
  Future<ConnCoords?> resolveCoords() {
    coordsCalls++;
    return coordsGate?.future ??
        Future.value(
          const ConnCoords(
            relayUrl: 'wss://central.example',
            agentEd25519PubB64: 'agent-key',
          ),
        );
  }

  @override
  Future<void> connectPayload(ConnCoords coords) async {
    payloadCalls++;
    if (payloadFailures > 0) {
      payloadFailures--;
      throw StateError('native unavailable');
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
  void fenceDispatch() {
    fenceCalls++;
  }

  @override
  Future<void> release() async {
    releaseCalls++;
    if (releaseError case final error?) throw error;
    await releaseGate?.future;
    payload = false;
    established = false;
  }

  @override
  Future<void> forceClose() async {
    forceCalls++;
    if (forceError case final error?) throw error;
    await forceGate?.future;
  }
}

class _Central implements CentralControlContract {
  final auth = StreamController<String>.broadcast(sync: true);
  bool reconnect = true;
  bool fail = false;
  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  Stream<String> get authErrorStream => auth.stream;
  @override
  bool get needsReconnect => reconnect;
  @override
  Future<void> connect(ConnCoords coords) async {
    connectCalls++;
    if (fail) throw StateError('central unavailable');
    reconnect = false;
  }

  @override
  void disconnect() {
    disconnectCalls++;
    reconnect = true;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

NativeConnectionSupervisor _supervisor(
  _Native native, {
  DateTime Function()? now,
  Duration graceful = const Duration(milliseconds: 10),
  Duration forced = const Duration(milliseconds: 10),
}) => NativeConnectionSupervisor(
  native,
  backoffBaseMs: 0,
  backoffCapMs: 0,
  jitter: (_) => 0,
  now: now,
  gracefulStopTimeout: graceful,
  forcedStopTimeout: forced,
);

void main() {
  test('native ladder climbs coords, payload, established', () async {
    final native = _Native();
    final supervisor = _supervisor(native);
    supervisor.setWanted(true);
    await _settle();

    expect(supervisor.status, const Connected());
    expect(native.coordsCalls, 1);
    expect(native.payloadCalls, 1);
    expect(native.establishCalls, 1);
    expect(await supervisor.stop(), NativeStopResult.stopped);
  });

  test('central supersession is sticky and leaves native healthy', () async {
    final native = _Native();
    final nativeSupervisor = _supervisor(native);
    final central = _Central();
    final centralSupervisor = CentralControlSupervisor(
      central,
      backoffBaseMs: 0,
      backoffCapMs: 0,
      jitter: (_) => 0,
    );
    const coords = ConnCoords(
      relayUrl: 'wss://central.example',
      agentEd25519PubB64: 'agent-key',
    );
    nativeSupervisor.setWanted(true);
    centralSupervisor.noteCoords(coords);
    centralSupervisor.setWanted(true);
    await _settle();

    expect(nativeSupervisor.status, const Connected());
    central.reconnect = true;
    centralSupervisor.noteRelayError('SUPERSEDED');
    final calls = central.connectCalls;
    centralSupervisor.noteStateChanged();
    await _settle();
    expect(centralSupervisor.conflict, isTrue);
    expect(central.connectCalls, calls);
    expect(nativeSupervisor.status, const Connected());

    centralSupervisor.retry();
    await _settle();
    expect(centralSupervisor.conflict, isFalse);
    expect(central.connectCalls, greaterThan(calls));
    await centralSupervisor.stop();
    await nativeSupervisor.stop();
  });

  test('presence accelerates only bounded offline-to-online edges', () async {
    var now = DateTime(2026);
    final native = _Native()..payloadFailures = 4;
    final supervisor = NativeConnectionSupervisor(
      native,
      backoffBaseMs: 100000,
      backoffCapMs: 100000,
      jitter: (_) => 0,
      now: () => now,
    );
    supervisor.setWanted(true);
    await _settle();
    expect(native.payloadCalls, 1);

    supervisor.notePresence(true);
    await _settle();
    expect(native.payloadCalls, 2);
    supervisor.notePresence(false);
    supervisor.notePresence(true);
    await _settle();
    expect(native.payloadCalls, 2);

    now = now.add(const Duration(seconds: 31));
    supervisor.notePresence(false);
    supervisor.notePresence(true);
    await _settle();
    expect(native.payloadCalls, 3);
    supervisor.noteResume();
    await _settle();
    expect(native.coordsCalls, 2, reason: 'presence did not reset failures');
    await supervisor.stop();
  });

  test('duplicate stop shares completion and releases once', () async {
    final native = _Native();
    final supervisor = _supervisor(native);
    supervisor.setWanted(true);
    await _settle();

    final first = supervisor.stop();
    final second = supervisor.stop();
    expect(identical(first, second), isTrue);
    expect(await first, NativeStopResult.stopped);
    expect(native.releaseCalls, 1);
    expect(native.fenceCalls, 1);
  });

  test('release errors are not reported as successful cleanup', () async {
    final native = _Native()
      ..releaseError = StateError('release failed')
      ..forceError = StateError('force failed');
    final supervisor = _supervisor(native);

    expect(await supervisor.stop(), NativeStopResult.cleanupIncomplete);
    expect(native.forceCalls, 1);
  });

  test(
    'never-settling teardown returns cleanupIncomplete within bounds',
    () async {
      final native = _Native()
        ..releaseGate = Completer<void>()
        ..forceGate = Completer<void>();
      final supervisor = _supervisor(
        native,
        graceful: const Duration(milliseconds: 5),
        forced: const Duration(milliseconds: 5),
      );
      final elapsed = Stopwatch()..start();

      expect(await supervisor.stop(), NativeStopResult.cleanupIncomplete);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(native.forceCalls, 1);
    },
  );

  test('paused status listener cannot hold a completed stop open', () async {
    final native = _Native();
    final supervisor = _supervisor(native);
    final subscription = supervisor.statusStream.listen((_) {})..pause();

    expect(
      await supervisor.stop().timeout(const Duration(seconds: 1)),
      NativeStopResult.stopped,
    );
    await subscription.cancel();
  });

  test(
    'late coordinate completion cannot publish readiness after stop',
    () async {
      final native = _Native()..coordsGate = Completer<ConnCoords?>();
      final supervisor = _supervisor(
        native,
        graceful: const Duration(milliseconds: 5),
        forced: const Duration(milliseconds: 5),
      );
      supervisor.setWanted(true);
      await _settle();

      expect(await supervisor.stop(), NativeStopResult.cleanupIncomplete);
      native.coordsGate!.complete(
        const ConnCoords(
          relayUrl: 'wss://late.example',
          agentEd25519PubB64: 'late-key',
        ),
      );
      await _settle();
      expect(supervisor.status, isNot(const Connected()));
      expect(native.payloadCalls, 0);
    },
  );
}
