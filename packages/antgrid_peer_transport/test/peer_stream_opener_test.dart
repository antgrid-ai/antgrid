import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

class _FakeSend implements PeerStreamSend {
  final writeAllCalls = <Uint8List>[];
  final resetCalls = <int>[];
  Future<void> Function(List<int> bytes)? beforeWriteAll;

  @override
  Future<void> writeAll(List<int> bytes) async {
    await beforeWriteAll?.call(bytes);
    writeAllCalls.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> reset(int errorCode) async {
    resetCalls.add(errorCode);
  }

  @override
  Future<void> finish() async {}
}

class _FakeRecv implements PeerStreamRecv {
  @override
  Future<Uint8List> readExact(int length) => Completer<Uint8List>().future;
}

Map<String, dynamic> _decodeOpenFrame(Uint8List written) {
  final length = ByteData.sublistView(written).getUint32(0, Endian.big);
  return jsonDecode(utf8.decode(written.sublist(4, 4 + length)))
      as Map<String, dynamic>;
}

Future<void> _noFatal(PeerStreamFatalCause _) async {}

void main() {
  test('writes the StreamOpen frame before handing the stream back', () async {
    final send = _FakeSend();
    final opener = PeerStreamOpener(() async => (send, _FakeRecv()));
    const open = ProjectStreamOpen('project-1');
    final stream = await opener.open(
      open,
      authorized: () => true,
      maxRecordBytes: 4096,
      maxQueuedBytes: 4096,
      onConnectionFatal: _noFatal,
    );
    addTearDown(stream.reset);

    expect(_decodeOpenFrame(send.writeAllCalls.single), open.toJson());
  });

  test('authorization denied up front never calls openBi', () async {
    var openBiCalls = 0;
    final opener = PeerStreamOpener(() async {
      openBiCalls++;
      return (_FakeSend(), _FakeRecv());
    });
    await expectLater(
      opener.open(
        const SessionStreamOpen(),
        authorized: () => false,
        maxRecordBytes: 4096,
        maxQueuedBytes: 4096,
        onConnectionFatal: _noFatal,
      ),
      throwsA(
        isA<PeerConnectionFailure>().having(
          (e) => e.code,
          'code',
          'AUTHORIZATION_DENIED',
        ),
      ),
    );
    expect(openBiCalls, 0);
  });

  test(
    'authorization revoked during openBi: the open frame is never written, '
    'the stream is reset and the connection retired',
    () async {
      final send = _FakeSend();
      var authorized = true;
      final opener = PeerStreamOpener(() async {
        authorized = false;
        return (send, _FakeRecv());
      });
      final fatal = <PeerStreamFatalCause>[];
      await expectLater(
        opener.open(
          const SessionStreamOpen(),
          authorized: () => authorized,
          maxRecordBytes: 4096,
          maxQueuedBytes: 4096,
          onConnectionFatal: (cause) async => fatal.add(cause),
        ),
        throwsA(
          isA<PeerConnectionFailure>().having(
            (e) => e.code,
            'code',
            'STREAM_OPEN_FAILED',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(send.writeAllCalls, isEmpty);
      expect(send.resetCalls, [0]);
      expect(fatal, [PeerStreamFatalCause.unauthorized]);
    },
  );

  test('an oversized open frame is refused before any native open', () async {
    var openBiCalls = 0;
    final opener = PeerStreamOpener(() async {
      openBiCalls++;
      return (_FakeSend(), _FakeRecv());
    });
    await expectLater(
      opener.open(
        ProjectStreamOpen('p' * 10000),
        authorized: () => true,
        maxRecordBytes: 4096,
        maxQueuedBytes: 1 << 16,
        onConnectionFatal: _noFatal,
      ),
      throwsA(
        isA<PeerConnectionFailure>().having(
          (e) => e.code,
          'code',
          'STREAM_OPEN_TOO_LARGE',
        ),
      ),
    );
    expect(openBiCalls, 0);
  });

  test('a native write failure on the open frame fails the open', () async {
    final send = _FakeSend();
    send.beforeWriteAll = (_) async => throw StateError('native write failed');
    final opener = PeerStreamOpener(() async => (send, _FakeRecv()));
    await expectLater(
      opener.open(
        const SessionStreamOpen(),
        authorized: () => true,
        maxRecordBytes: 4096,
        maxQueuedBytes: 4096,
        onConnectionFatal: _noFatal,
      ),
      throwsA(
        isA<PeerConnectionFailure>().having(
          (e) => e.code,
          'code',
          'STREAM_OPEN_FAILED',
        ),
      ),
    );
  });

  test(
    'the pending-opens semaphore bounds in-flight opens and hands a freed '
    'slot to the next waiter',
    () async {
      final gates = <Completer<void>>[];
      var started = 0;
      final opener = PeerStreamOpener(() async {
        started++;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return (_FakeSend(), _FakeRecv());
      }, maxPendingOpens: 2);

      Future<PeerStream> launch() => opener.open(
        const SessionStreamOpen(),
        authorized: () => true,
        maxRecordBytes: 4096,
        maxQueuedBytes: 4096,
        onConnectionFatal: _noFatal,
      );

      final futures = [launch(), launch(), launch()];
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(started, 2);

      gates[0].complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(started, 3);

      // A fourth caller arriving now must not jump the queue past the
      // slot the third already holds.
      final fourth = launch();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(started, 3);

      gates[1].complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(started, 4);
      gates[2].complete();
      gates[3].complete();
      for (final stream in await Future.wait([...futures, fourth])) {
        await stream.reset();
      }
    },
  );

  test(
    'encodeStreamOpenFrame is the exact body the opener writes as the first '
    'record',
    () async {
      final send = _FakeSend();
      final opener = PeerStreamOpener(() async => (send, _FakeRecv()));
      const open = ProjectStreamOpen('project-1');
      final stream = await opener.open(
        open,
        authorized: () => true,
        maxRecordBytes: 4096,
        maxQueuedBytes: 4096,
        onConnectionFatal: _noFatal,
      );
      addTearDown(stream.reset);

      final body = send.writeAllCalls.single.sublist(4);
      expect(body, encodeStreamOpenFrame(open));
    },
  );

  test('encodeStreamOpenFrame throws STREAM_OPEN_TOO_LARGE past kStreamOpenMaxBytes', () {
    expect(
      () => encodeStreamOpenFrame(ProjectStreamOpen('p' * 10000)),
      throwsA(
        isA<PeerConnectionFailure>().having(
          (e) => e.code,
          'code',
          'STREAM_OPEN_TOO_LARGE',
        ),
      ),
    );
  });

  test('the default pending-open bound is the D7 constant', () async {
    final gates = <Completer<void>>[];
    final opener = PeerStreamOpener(() async {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      return (_FakeSend(), _FakeRecv());
    });
    final futures = [
      for (var i = 0; i < kStreamMaxPendingOpensPerPeer + 1; i++)
        opener.open(
          const SessionStreamOpen(),
          authorized: () => true,
          maxRecordBytes: 4096,
          maxQueuedBytes: 4096,
          onConnectionFatal: _noFatal,
        ),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(gates.length, kStreamMaxPendingOpensPerPeer);
    for (var i = 0; i < gates.length; i++) {
      gates[i].complete();
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
    gates.last.complete();
    await Future.wait(futures);
  });
}
