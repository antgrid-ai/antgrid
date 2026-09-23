import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

/// Models the `iroh_quic` binding's one mutex per stream: `writeAll`, `reset`
/// and `finish` each hold it for their whole duration, so a `reset` issued
/// while a write is flow-blocked does not run until that write returns. A
/// fake without it passes tests that deadlock on the real binding.
class FakeSend implements PeerStreamSend {
  final writeAllCalls = <Uint8List>[];
  final resetCalls = <int>[];
  int resetRequests = 0;
  int finishCalls = 0;
  final log = <String>[];
  Future<void> _lock = Future.value();

  /// Runs inside the lock before a `writeAll` completes; throw to model a
  /// native failure, or await to model a peer that is not draining.
  Future<void> Function(List<int> bytes)? beforeWriteAll;

  Future<void> _locked(Future<void> Function() body) {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  @override
  Future<void> writeAll(List<int> bytes) => _locked(() async {
    await beforeWriteAll?.call(bytes);
    writeAllCalls.add(Uint8List.fromList(bytes));
    log.add('write');
  });

  @override
  Future<void> reset(int errorCode) {
    resetRequests++;
    return _locked(() async {
      resetCalls.add(errorCode);
      log.add('reset');
    });
  }

  @override
  Future<void> finish() => _locked(() async {
    finishCalls++;
    log.add('finish');
  });
}

/// Serves [chunks] in order, then either ends the stream (a peer FIN) or,
/// with [holdOpen], blocks like a live stream with nothing to read.
class FakeRecv implements PeerStreamRecv {
  FakeRecv(this._chunks, {this.holdOpen = false});
  final List<List<int>> _chunks;
  final bool holdOpen;
  var _index = 0;
  int reads = 0;

  @override
  Future<Uint8List> readExact(int length) async {
    reads++;
    if (_index >= _chunks.length) {
      if (holdOpen) return Completer<Uint8List>().future;
      throw StateError('peer finished');
    }
    final chunk = _chunks[_index++];
    if (chunk.length != length) {
      throw StateError('wanted $length, fake has ${chunk.length}');
    }
    return Uint8List.fromList(chunk);
  }
}

Uint8List _lengthPrefix(int length) =>
    (ByteData(4)..setUint32(0, length, Endian.big)).buffer.asUint8List();

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

NativePeerStream _stream(
  FakeSend send,
  PeerStreamRecv recv, {
  bool Function()? authorized,
  List<PeerStreamFatalCause>? fatal,
  int maxRecordBytes = 1024,
  int maxQueuedBytes = 1 << 16,
}) => NativePeerStream(
  send,
  recv,
  authorized ?? () => true,
  (cause) async => fatal?.add(cause),
  maxRecordBytes: maxRecordBytes,
  maxQueuedBytes: maxQueuedBytes,
);

void main() {
  test('frames a small record as one writeAll call', () async {
    final send = FakeSend();
    final stream = _stream(send, FakeRecv(const []));
    final outcome = await stream.send(Uint8List.fromList([1, 2, 3]));
    expect(outcome, PeerSendOutcome.accepted);
    final written = send.writeAllCalls.single;
    expect(ByteData.sublistView(written).getUint32(0, Endian.big), 3);
    expect(written.sublist(4), [1, 2, 3]);
  });

  test('slices a record larger than the slice bound', () async {
    final send = FakeSend();
    final stream = _stream(
      send,
      FakeRecv(const []),
      maxQueuedBytes: 1 << 21,
    );
    final big = Uint8List(kPeerStreamSliceBytes + 10000);
    for (var i = 0; i < big.length; i++) {
      big[i] = i % 256;
    }
    expect(await stream.send(big), PeerSendOutcome.accepted);
    expect(send.writeAllCalls.length, 2);
    expect(
      send.writeAllCalls.every((s) => s.length <= kPeerStreamSliceBytes),
      isTrue,
    );
    final reassembled = [...send.writeAllCalls[0], ...send.writeAllCalls[1]];
    expect(
      ByteData.sublistView(
        Uint8List.fromList(reassembled.sublist(0, 4)),
      ).getUint32(0, Endian.big),
      big.length,
    );
    expect(reassembled.sublist(4), big);
  });

  test(
    'reset() during a stuck multi-slice record waits for the one slice in '
    'flight and writes no further slice',
    () async {
      final send = FakeSend();
      final release = Completer<void>();
      send.beforeWriteAll = (_) => release.future;
      final stream = _stream(
        send,
        FakeRecv(const []),
        maxQueuedBytes: 1 << 22,
      );
      final sending = stream.send(Uint8List(3 * kPeerStreamSliceBytes));
      await _settle();
      final resetting = stream.reset();
      await _settle();
      expect(send.resetCalls, isEmpty, reason: 'the binding mutex is held');

      release.complete();
      await resetting;
      expect(await sending, PeerSendOutcome.closed);
      expect(send.log, ['write', 'reset']);
    },
  );

  test('authorized() false at send time resets and retires the connection', () async {
    final send = FakeSend();
    final fatal = <PeerStreamFatalCause>[];
    final stream = _stream(
      send,
      FakeRecv(const []),
      authorized: () => false,
      fatal: fatal,
    );
    expect(await stream.send(Uint8List.fromList([1])), PeerSendOutcome.closed);
    await _settle();
    expect(send.resetCalls, [0]);
    expect(fatal, [PeerStreamFatalCause.unauthorized]);
    expect(send.writeAllCalls, isEmpty);
  });

  test(
    'lost authorization retires the connection at once even while a write '
    'holds the binding mutex',
    () async {
      final send = FakeSend();
      send.beforeWriteAll = (_) => Completer<void>().future;
      var authorized = true;
      final fatal = <PeerStreamFatalCause>[];
      final stream = _stream(
        send,
        FakeRecv(const []),
        authorized: () => authorized,
        fatal: fatal,
      );
      unawaited(stream.send(Uint8List.fromList([1])));
      await _settle();

      authorized = false;
      expect(
        await stream.send(Uint8List.fromList([2])),
        PeerSendOutcome.closed,
      );
      await _settle();
      expect(fatal, [PeerStreamFatalCause.unauthorized]);
      expect(send.resetRequests, 1, reason: 'issued, queued on the mutex');
      expect(send.resetCalls, isEmpty);
    },
  );

  test('a full send queue resets only this stream (D3)', () async {
    final send = FakeSend();
    final release = Completer<void>();
    send.beforeWriteAll = (_) => release.future;
    final fatal = <PeerStreamFatalCause>[];
    final stream = _stream(
      send,
      FakeRecv(const []),
      fatal: fatal,
      maxQueuedBytes: 20,
    );
    final first = stream.send(Uint8List.fromList([1, 2, 3]));
    await _settle();

    expect(
      await stream.send(Uint8List.fromList(List.filled(30, 9))),
      PeerSendOutcome.backpressured,
    );
    expect(send.resetRequests, 1);
    release.complete();
    expect(await first, PeerSendOutcome.closed);
    await _settle();
    expect(send.resetCalls, [0]);
    expect(fatal, isEmpty);
  });

  test('a routine write failure ends only this stream, with no reset', () async {
    final send = FakeSend();
    send.beforeWriteAll = (_) async => throw StateError('peer stopped');
    final fatal = <PeerStreamFatalCause>[];
    final stream = _stream(send, FakeRecv(const []), fatal: fatal);
    expect(await stream.send(Uint8List.fromList([1])), PeerSendOutcome.closed);
    await stream.reset();
    expect(fatal, isEmpty);
    expect(send.resetRequests, 0);
  });

  test('an oversized inbound length prefix is a protocol violation', () async {
    final send = FakeSend();
    final fatal = <PeerStreamFatalCause>[];
    final received = <Uint8List>[];
    final done = Completer<void>();
    final stream = _stream(
      send,
      FakeRecv([_lengthPrefix(999999999)], holdOpen: true),
      fatal: fatal,
    );
    stream.records.listen(received.add, onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 2));
    await _settle();
    expect(send.resetCalls, [0]);
    expect(fatal, [PeerStreamFatalCause.protocolViolation]);
    expect(received, isEmpty);
  });

  test('a zero-length inbound record is a protocol violation', () async {
    final send = FakeSend();
    final fatal = <PeerStreamFatalCause>[];
    final stream = _stream(
      send,
      FakeRecv([_lengthPrefix(0)], holdOpen: true),
      fatal: fatal,
    );
    stream.records.listen((_) {});
    await _settle();
    expect(send.resetCalls, [0]);
    expect(fatal, [PeerStreamFatalCause.protocolViolation]);
  });

  test(
    'a protocol violation after this side finished or reset its send half '
    'still retires the connection',
    () async {
      for (final endSendHalf in <Future<void> Function(PeerStream)>[
        (s) => s.finish(),
        (s) => s.reset(),
      ]) {
        final send = FakeSend();
        final gate = Completer<void>();
        final fatal = <PeerStreamFatalCause>[];
        final stream = _stream(
          send,
          _GatedRecv(gate.future, [_lengthPrefix(999999999)]),
          fatal: fatal,
        );
        stream.records.listen((_) {});
        await endSendHalf(stream);
        gate.complete();
        await _settle();
        expect(fatal, [PeerStreamFatalCause.protocolViolation]);
      }
    },
  );

  test('authorization lost while a body is read retires the connection', () async {
    final send = FakeSend();
    final body = [7, 7, 7];
    var authorized = true;
    final fatal = <PeerStreamFatalCause>[];
    final received = <Uint8List>[];
    final stream = _stream(
      send,
      FakeRecv([_lengthPrefix(body.length), body], holdOpen: true),
      authorized: () => authorized,
      fatal: fatal,
    );
    stream.records.listen(received.add);
    authorized = false;
    await _settle();
    expect(received, isEmpty);
    expect(send.resetCalls, [0]);
    expect(fatal, [PeerStreamFatalCause.unauthorized]);
  });

  test('a record that arrives before anyone listens is not lost', () async {
    final body = [4, 2];
    final stream = _stream(
      FakeSend(),
      FakeRecv([_lengthPrefix(body.length), body]),
    );
    await _settle();
    final received = await stream.records.toList().timeout(
      const Duration(seconds: 2),
    );
    expect(received, [body]);
  });

  test('reading waits for a listener and pauses with the subscription', () async {
    final recv = FakeRecv([
      _lengthPrefix(1),
      [1],
      _lengthPrefix(1),
      [2],
    ], holdOpen: true);
    final stream = _stream(FakeSend(), recv);
    await _settle();
    expect(recv.reads, 0);

    final received = <Uint8List>[];
    late StreamSubscription<Uint8List> sub;
    sub = stream.records.listen((record) {
      received.add(record);
      sub.pause();
    });
    await _settle();
    expect(received, [
      [1],
    ]);
    expect(recv.reads, 2, reason: 'no read past the paused record');
    final readsWhilePaused = recv.reads;
    await _settle();
    expect(recv.reads, readsWhilePaused);

    sub.resume();
    await _settle();
    expect(received, [
      [1],
      [2],
    ]);
    await sub.cancel();
  });

  test(
    'reset() (a cancel) ends only the send half; records drain until the '
    'peer ends (D4)',
    () async {
      final send = FakeSend();
      final body = [5, 6];
      final stream = _stream(
        send,
        FakeRecv([_lengthPrefix(body.length), body]),
      );
      final received = <Uint8List>[];
      final done = Completer<void>();
      stream.records.listen(received.add, onDone: done.complete);

      await stream.reset();
      expect(send.resetCalls, [0]);
      await done.future.timeout(const Duration(seconds: 2));
      expect(received, [body]);
    },
  );

  test('finish() FINs after the record in flight, never mid-record', () async {
    final send = FakeSend();
    final release = Completer<void>();
    send.beforeWriteAll = (_) => release.future;
    final stream = _stream(
      send,
      FakeRecv(const []),
      maxQueuedBytes: 1 << 22,
    );
    final first = stream.send(Uint8List(2 * kPeerStreamSliceBytes));
    final second = stream.send(Uint8List.fromList([1]));
    await _settle();
    final finishing = stream.finish();
    expect(
      await stream.send(Uint8List.fromList([2])),
      PeerSendOutcome.closed,
    );

    release.complete();
    await finishing;
    expect(await first, PeerSendOutcome.accepted);
    expect(await second, PeerSendOutcome.accepted);
    expect(send.log, ['write', 'write', 'write', 'write', 'finish']);
    expect(send.resetRequests, 0);
  });

  test('finish() on an idle stream FINs with no reset', () async {
    final send = FakeSend();
    final stream = _stream(send, FakeRecv(const []));
    await stream.finish();
    expect(send.finishCalls, 1);
    expect(send.resetRequests, 0);
    expect(await stream.send(Uint8List.fromList([1])), PeerSendOutcome.closed);
  });
}

/// Holds every read until [gate] completes, then serves [chunks].
class _GatedRecv implements PeerStreamRecv {
  _GatedRecv(this._gate, this._chunks);
  final Future<void> _gate;
  final List<List<int>> _chunks;
  var _index = 0;

  @override
  Future<Uint8List> readExact(int length) async {
    await _gate;
    if (_index >= _chunks.length) return Completer<Uint8List>().future;
    return Uint8List.fromList(_chunks[_index++]);
  }
}
