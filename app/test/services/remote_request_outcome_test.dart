import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _OutcomeTransport extends BufferedAgentTransport {
  Future<void> Function(Map<String, dynamic> message)? onSend;
  final sentMethods = <String>[];

  @override
  bool get isLocal => false;

  @override
  Future<void> connect() async => setState(TransportState.connected);

  void disconnect({String code = 'E_SESSION_DOWN'}) {
    setState(TransportState.disconnected);
    failAllPending(code: code, message: 'connection generation ended');
  }

  void establish() {
    setState(TransportState.connected);
    redriveHydrators();
  }

  void reply(String requestId, Map<String, dynamic> result) {
    dispatchDecoded({
      'type': 'response',
      'requestId': requestId,
      'ok': true,
      'result': result,
    }, 'control');
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    final method = message['method'];
    if (method is String) sentMethods.add(method);
    await onSend?.call(message);
  }

  @override
  Future<void> dispose() async {
    failAllPending();
    clearHydrators();
    await outbound.close();
    await stateController.close();
  }
}

void main() {
  test('disconnect before send reports notSent', () async {
    final transport = _OutcomeTransport();
    addTearDown(transport.dispose);
    transport.disconnect();

    final result = await transport.requestWithOutcome('session.create');

    expect(result.outcome, RemoteCommandOutcome.notSent);
    expect(transport.sentMethods, isEmpty);
  });

  test('disconnect during write reports outcomeUnknown', () async {
    final transport = _OutcomeTransport();
    addTearDown(transport.dispose);
    await transport.connect();
    final write = Completer<void>();
    transport.onSend = (_) => write.future;

    final resultFuture = transport.requestWithOutcome('session.create');
    await Future<void>.delayed(Duration.zero);
    write.completeError(StateError('carrier closed during write'));

    final result = await resultFuture;
    expect(result.outcome, RemoteCommandOutcome.outcomeUnknown);
    expect(transport.sentMethods, ['session.create']);
  });

  test(
    'generation loss after execution before reply is outcomeUnknown',
    () async {
      final transport = _OutcomeTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final resultFuture = transport.requestWithOutcome('sessions.delete');
      await Future<void>.delayed(Duration.zero);
      transport.disconnect(code: 'E_GENERATION_REPLACED');

      expect((await resultFuture).outcome, RemoteCommandOutcome.outcomeUnknown);
    },
  );

  test(
    'reconnect replays fresh reads and never replays an interrupted mutation',
    () async {
      final transport = _OutcomeTransport();
      addTearDown(transport.dispose);
      await transport.connect();
      transport.onSend = (message) async {
        if (message['method'] == 'state.snapshot') {
          scheduleMicrotask(
            () => transport.reply(message['requestId'] as String, const {
              'frames': <Object>[],
            }),
          );
        }
      };
      await transport.hydrate(
        'authoritative-state',
        () async => transport.request('state.snapshot'),
      );

      final mutation = transport.requestWithOutcome('terminal.input');
      await Future<void>.delayed(Duration.zero);
      transport.disconnect();
      expect((await mutation).outcome, RemoteCommandOutcome.outcomeUnknown);

      transport.establish();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        transport.sentMethods.where((m) => m == 'terminal.input'),
        hasLength(1),
      );
      expect(
        transport.sentMethods.where((m) => m == 'state.snapshot'),
        hasLength(2),
      );
    },
  );

  test('uncertainty exposes the required user-facing message', () {
    expect(
      remoteCommandOutcomeUnknownMessage,
      'Connection lost; execution could not be confirmed',
    );
  });
}
