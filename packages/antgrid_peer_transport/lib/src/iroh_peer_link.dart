import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;

import 'relay_origin.dart';
import 'connection_attempt.dart';

const peerAlpn = 'antgrid/peer/2';

/// Enrollment-scoped storage implemented by the platform secure credential store.
abstract interface class EndpointKeyStore {
  Future<Uint8List?> read(String enrollmentId);
  Future<void> write(String enrollmentId, Uint8List secret);
  Future<void> delete(String enrollmentId);
}

/// Owned once per process/account enrollment, independently of connection retries.
class NativeEndpointOwner {
  NativeEndpointOwner._(this.endpoint, this.approvedRelays);
  final iroh.Endpoint endpoint;
  final List<String> approvedRelays;
  static Future<NativeEndpointOwner> create({
    required String enrollmentId,
    required EndpointKeyStore keyStore,
    required List<String> approvedRelays,
    Future<void> Function()? initializeNative,
  }) async {
    for (final url in approvedRelays) {
      if (!isApprovedRelayOrigin(url)) {
        throw const PeerConnectionFailure('UNAPPROVED_RELAY', terminal: true);
      }
    }
    await (initializeNative ?? iroh.Iroh.init)();
    var bytes = await keyStore.read(enrollmentId);
    if (bytes == null) {
      bytes = iroh.SecretKey.generate().toBytes();
      await keyStore.write(enrollmentId, bytes);
    }
    try {
      final endpoint = await iroh.Endpoint.bindWithAddressLookup(
        secretKey: iroh.SecretKey.fromBytes(bytes),
        resolve: (_) => null,
        relayMode: approvedRelays.isEmpty
            ? iroh.RelayMode.disabled
            : iroh.RelayMode.custom(iroh.RelayMap.fromUrls(approvedRelays)),
      );
      return NativeEndpointOwner._(endpoint, List.unmodifiable(approvedRelays));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<IrohPeerLink> dial({
    required String endpointId,
    required bool Function() authorized,
    List<String> ipAddresses = const [],
    PeerLinkDiagnostic? diagnostic,
  }) async {
    final timer = Stopwatch()..start();
    if (!authorized())
      throw const PeerConnectionFailure('AUTHORIZATION_DENIED', terminal: true);
    iroh.Connection connection;
    try {
      connection = await endpoint.connect(
        iroh.EndpointAddr(
          iroh.PublicKey.fromHex(endpointId),
          ipAddrs: ipAddresses,
          relayUrls: approvedRelays.map(iroh.RelayUrl.parse).toList(),
        ),
        utf8.encode(peerAlpn),
      );
    } catch (_) {
      // The binding does not distinguish unreachable routes here. Let the
      // supervisor retry Iroh; authorization is checked again on each attempt.
      throw const PeerConnectionFailure(
        'NATIVE_CONNECT_UNCLASSIFIED',
        terminal: false,
      );
    }
    if (!authorized() ||
        connection.remoteId.toHex() != endpointId ||
        utf8.decode(connection.alpn, allowMalformed: true) != peerAlpn) {
      connection.close(errorCode: 1);
      throw const PeerConnectionFailure(
        'AUTHENTICATED_ENDPOINT_MISMATCH',
        terminal: true,
      );
    }
    try {
      final (send, recv) = await connection.openBi();
      if (!authorized())
        throw const PeerConnectionFailure(
          'AUTHORIZATION_DENIED',
          terminal: true,
        );
      // The session stream carries the same open-frame prefix as every later
      // stream, but its I/O stays on this class's reader/writer: the session
      // stream IS the session, so its failures close the whole connection
      // rather than reset one stream among many.
      final body = encodeStreamOpenFrame(const SessionStreamOpen());
      final prefixed = Uint8List(4 + body.length);
      ByteData.sublistView(prefixed).setUint32(0, body.length, Endian.big);
      prefixed.setRange(4, prefixed.length, body);
      await send.writeAll(prefixed);
      emitPeerLifecycle(
        diagnostic,
        'peer:iroh-established',
        transport: 'iroh',
        elapsedMs: timer.elapsedMilliseconds,
      );
      return IrohPeerLink._(
        connection,
        _IrohStreamSend(send),
        recv,
        authorized,
        diagnostic,
      ).._start();
    } catch (_) {
      connection.close(errorCode: 1);
      rethrow;
    }
  }

  Future<void> close() => endpoint.close();
}

class IrohPeerLink implements PeerLink {
  IrohPeerLink._(
    this._connection,
    this._send,
    this._recv,
    this._authorized,
    this.netTap,
  ) : _opener = PeerStreamOpener(
        () async {
          final (send, recv) = await _connection.openBi();
          return (_IrohStreamSend(send), _IrohStreamRecv(recv));
        },
      );
  final iroh.Connection _connection;
  final PeerStreamSend _send;
  final iroh.RecvStream _recv;
  final bool Function() _authorized;
  final PeerStreamOpener _opener;
  @override
  final PeerLinkDiagnostic? netTap;
  final _messages = StreamController<IncomingSessionRecord>.broadcast(sync: true);
  final _states = StreamController<PeerLinkState>.broadcast(sync: true);
  final _failures = StreamController<PeerLinkFailure>.broadcast(sync: true);
  bool _closed = false;
  int _queued = 0;
  Future<void> _tail = Future.value();
  final _pending = <Completer<PeerSendOutcome>>{};
  @override
  bool get isDispatchAllowed => !_closed && _authorized();
  @override
  Stream<IncomingSessionRecord> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerLinkFailure> get failureStream => _failures.stream;
  @override
  Stream<PeerPath> get pathStream => _connection.pathEvents().map((event) {
    // Upstream exposes address strings, not a stable typed path classifier.
    netTap?.call({'op': 'path', 'event': event.runtimeType.toString()});
    return PeerPath.unknown;
  });

  void _start() {
    unawaited(_read());
    unawaited(
      _connection.acceptUni().then(
        (_) => _fail('EXTRA_STREAM', false),
        onError: (Object _) {},
      ),
    );
    unawaited(
      _connection.closed().then(
        (_) => _fail('NATIVE_CLOSE_UNCLASSIFIED', true),
        onError: (Object _) => _fail('NATIVE_CLOSE_UNCLASSIFIED', true),
      ),
    );
  }

  Future<void> _read() async {
    try {
      while (!_closed) {
        final prefix = await _recv.readExact(4);
        final length = ByteData.sublistView(prefix).getUint32(0, Endian.big);
        if (!peerRecordLengthOk(length, kPeerMaxBridgeRecordBytes)) {
          _fail('INVALID_RECORD_LENGTH', false);
          return;
        }
        final bytes = await _readBodyInSlices(length);
        if (!isDispatchAllowed) {
          await close();
          return;
        }
        _messages.add(IncomingSessionRecord(payload: bytes));
      }
    } catch (_) {
      if (!_closed) _fail('NATIVE_CLOSE_UNCLASSIFIED', true);
    }
  }

  /// Reads a body of [length] bytes in `readExact` pieces of at most
  /// [kPeerStreamSliceBytes], mirroring `StreamRecordReader`.
  Future<Uint8List> _readBodyInSlices(int length) async {
    final body = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final chunkLen = math.min(kPeerStreamSliceBytes, length - offset);
      final chunk = await _recv.readExact(chunkLen);
      body.setRange(offset, offset + chunkLen, chunk);
      offset += chunkLen;
    }
    return body;
  }

  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) {
    if (!isDispatchAllowed) return Future.value(PeerSendOutcome.closed);
    if (payload.length > kStreamProjectAppRecordMaxBytes) {
      return Future.value(PeerSendOutcome.tooLarge);
    }
    final size = payload.length + 4;
    if (_queued + size > kSessionStreamMaxQueuedBytes) {
      return Future.value(PeerSendOutcome.backpressured);
    }
    final record = Uint8List(size);
    ByteData.sublistView(record).setUint32(0, payload.length, Endian.big);
    record.setRange(4, size, payload);
    final completion = Completer<PeerSendOutcome>();
    _pending.add(completion);
    _queued += size;
    _tail = _tail.then((_) async {
      try {
        if (!isDispatchAllowed) {
          if (!completion.isCompleted)
            completion.complete(PeerSendOutcome.closed);
          return;
        }
        final wrote = await writeRecordInSlices(
          _send,
          record,
          stop: () => !isDispatchAllowed,
        );
        // A stop can land between slices, leaving a partial record on the
        // session stream; nothing after it could be framed, so the link goes.
        if (!wrote) await close();
        if (!completion.isCompleted) {
          completion.complete(
            wrote && isDispatchAllowed
                ? PeerSendOutcome.accepted
                : PeerSendOutcome.closed,
          );
        }
      } catch (_) {
        _fail('NATIVE_WRITE_UNCLASSIFIED', true);
      } finally {
        _queued -= size;
        _pending.remove(completion);
        record.fillRange(0, record.length, 0);
      }
    });
    return completion.future;
  }

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) => _opener.open(
    open,
    authorized: () => isDispatchAllowed,
    maxRecordBytes: maxRecordBytes,
    maxQueuedBytes: maxQueuedBytes,
    rawAfterRecords: rawAfterRecords,
    // Same outcomes as the session stream's reader: lost authorization
    // closes quietly, a malformed record is a non-retryable violation.
    onConnectionFatal: (cause) async {
      switch (cause) {
        case PeerStreamFatalCause.unauthorized:
          await close();
        case PeerStreamFatalCause.protocolViolation:
          _fail('INVALID_STREAM_RECORD', false);
      }
    },
  );

  /// `retryable: false` is reserved for what a second attempt cannot fix — a
  /// protocol violation by the peer. An unexplained native close or write
  /// error is precisely the case that cannot be classified, and the supervisor
  /// turns any non-retryable failure into a sticky peerRejected block, so
  /// defaulting the unknown to terminal makes a relay restart or an account's
  /// routine retire indistinguishable from a revocation.
  void _fail(String code, bool retryable) {
    if (_closed) return;
    _closed = true;
    _failures.add(PeerLinkFailure(code: code, retryable: retryable));
    unawaited(_finishClose());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _finishClose();
  }

  Future<void> _finishClose() async {
    for (final completion in _pending) {
      if (!completion.isCompleted) completion.complete(PeerSendOutcome.closed);
    }
    _states.add(PeerLinkState.closed);
    _connection.close();
    await Future<void>.value();
    await _messages.close();
    await _states.close();
    await _failures.close();
  }
}

/// Per native `writeAll` call, mirroring the bridge's
/// `STREAM_RECORD_SLICE_BYTES` (`bridge/src/peer/stream-records.ts`).
/// `iroh_quic` holds one mutex per stream across `writeAll`, and `reset`
/// takes the same mutex, so a reset issued while a write is flow-blocked
/// waits for that write; bounding the slice bounds the wait.
const int kPeerStreamSliceBytes = 262144;

const int _kRecordLengthPrefixBytes = 4;

/// A record's length prefix must be positive and within the reader's cap —
/// shared by the session stream's read and [NativePeerStream]'s framed read
/// so the two enforce the same rule.
bool peerRecordLengthOk(int length, int maxRecordBytes) =>
    length > 0 && length <= maxRecordBytes;

/// The send half a [NativePeerStream] writes through — narrower than
/// `iroh.SendStream` so tests can fake it with no native library loaded.
abstract interface class PeerStreamSend {
  Future<void> writeAll(List<int> bytes);
  Future<void> reset(int errorCode);
  Future<void> finish();
}

/// The receive half a [NativePeerStream] reads through.
abstract interface class PeerStreamRecv {
  Future<Uint8List> readExact(int length);

  /// Reads up to [maxLength] bytes; `null` at a clean FIN. Used only once a
  /// stream has moved into its raw phase (`rawAfterRecords`) — the framed
  /// phase reads with [readExact] alone, which cannot tell a FIN from a reset
  /// (both just throw). Rejects on reset or a lost connection, exactly as
  /// `iroh_quic`'s own `RecvStream.read` does.
  Future<Uint8List?> read(int maxLength);
}

/// Raw-phase read size (`bridge/src/peer/stream-records.ts`'s
/// `STREAM_RAW_READ_BYTES`, mirrored). Not a protocol bound — a peer may write
/// smaller or larger native reads than this; it only sizes this side's own
/// `read` calls.
const int kPeerStreamRawReadBytes = 65536;

/// Writes [record] in `writeAll` calls of at most [kPeerStreamSliceBytes]: a
/// cancel or reset then waits on one slice, never a whole record. Returns
/// false if [stop] turned true between slices.
Future<bool> writeRecordInSlices(
  PeerStreamSend send,
  Uint8List record, {
  bool Function()? stop,
}) async {
  for (
    var offset = 0;
    offset < record.length;
    offset += kPeerStreamSliceBytes
  ) {
    if (stop != null && stop()) return false;
    final end = math.min(offset + kPeerStreamSliceBytes, record.length);
    await send.writeAll(record.sublist(offset, end));
  }
  return stop == null || !stop();
}

/// The UTF-8 JSON body of a stream's first record, with no length prefix —
/// the same encoding on the session stream (written inline by [dial]) and on
/// every later stream ([PeerStreamOpener.open]).
Uint8List encodeStreamOpenFrame(StreamOpen open) {
  final body = Uint8List.fromList(utf8.encode(jsonEncode(open.toJson())));
  if (body.length > kStreamOpenMaxBytes) {
    throw const PeerConnectionFailure('STREAM_OPEN_TOO_LARGE', terminal: true);
  }
  return body;
}

/// Why a [NativePeerStream] asks its link to retire the whole connection.
/// These are the only two; overflow, a cancel and a peer's reset or FIN end
/// just the one stream.
enum PeerStreamFatalCause { unauthorized, protocolViolation }

class _IrohStreamSend implements PeerStreamSend {
  _IrohStreamSend(this._inner);
  final iroh.SendStream _inner;
  @override
  Future<void> writeAll(List<int> bytes) => _inner.writeAll(bytes);
  @override
  Future<void> reset(int errorCode) => _inner.reset(errorCode);
  @override
  Future<void> finish() => _inner.finish();
}

class _IrohStreamRecv implements PeerStreamRecv {
  _IrohStreamRecv(this._inner);
  final iroh.RecvStream _inner;
  @override
  Future<Uint8List> readExact(int length) => _inner.readExact(length);
  @override
  Future<Uint8List?> read(int maxLength) => _inner.read(maxLength);
}

class _PendingSend {
  _PendingSend(this.bytes, this.settle);
  final Uint8List bytes;
  final void Function(PeerSendOutcome) settle;
}

/// One opened native stream's `[u32 len][record]` I/O, the Dart counterpart
/// of the bridge's `StreamRecordWriter`/`StreamRecordReader`.
///
/// Reading starts when [records] is first listened to and pauses with the
/// subscription, so an unread stream leaves its data in QUIC flow control
/// rather than in an unbounded Dart buffer.
class NativePeerStream implements PeerStream {
  NativePeerStream(
    this._send,
    this._recv,
    this._authorized,
    this._onConnectionFatal, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) : _maxRecordBytes = maxRecordBytes,
       _maxQueuedBytes = maxQueuedBytes,
       _rawAfterRecords = rawAfterRecords;

  final PeerStreamSend _send;
  final PeerStreamRecv _recv;
  final bool Function() _authorized;
  final Future<void> Function(PeerStreamFatalCause) _onConnectionFatal;
  final int _maxRecordBytes;
  final int _maxQueuedBytes;

  /// Set once this many decoded records have been delivered on [records]:
  /// every later read is raw (see [PeerStreamRecv.read]).
  final int? _rawAfterRecords;
  int _recordsDelivered = 0;
  bool _raw = false;

  // Single-subscription, not broadcast: a broadcast controller drops what
  // arrives before the caller listens, and the first inbound record (an
  // in-band `stream:refused`) can land before `openStream` has returned.
  late final StreamController<Uint8List> _records = StreamController(
    sync: true,
    onListen: () => unawaited(_readLoop()),
    onResume: _wakeReader,
    onCancel: _wakeReader,
  );
  Completer<void>? _resumed;
  final _queue = <_PendingSend>[];
  final _idleWaiters = <Completer<void>>[];
  bool _writing = false;
  bool _writeStopped = false;
  bool _finishing = false;
  bool _resetIssued = false;
  bool _fatal = false;
  int _queuedBytes = 0;

  /// Single-subscription: listen once.
  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) {
    if (_writeStopped || _finishing) {
      return Future.value(PeerSendOutcome.closed);
    }
    if (!_authorized()) {
      _abandon(PeerStreamFatalCause.unauthorized);
      return Future.value(PeerSendOutcome.closed);
    }
    final size = record.length + _kRecordLengthPrefixBytes;
    if (_queuedBytes + size > _maxQueuedBytes) {
      // The caller reopens and resyncs; the connection and every other
      // stream on it are untouched.
      unawaited(reset());
      return Future.value(PeerSendOutcome.backpressured);
    }
    final framed = Uint8List(size);
    ByteData.sublistView(framed).setUint32(0, record.length, Endian.big);
    framed.setRange(_kRecordLengthPrefixBytes, size, record);
    final completer = Completer<PeerSendOutcome>();
    _queue.add(_PendingSend(framed, completer.complete));
    _queuedBytes += size;
    unawaited(_drain());
    return completer.future;
  }

  @override
  Future<PeerSendOutcome> sendRaw(Uint8List bytes) {
    if (_writeStopped || _finishing) {
      return Future.value(PeerSendOutcome.closed);
    }
    if (!_authorized()) {
      _abandon(PeerStreamFatalCause.unauthorized);
      return Future.value(PeerSendOutcome.closed);
    }
    if (bytes.isEmpty) return Future.value(PeerSendOutcome.accepted);
    if (_queuedBytes + bytes.length > _maxQueuedBytes) {
      // The caller reopens and resyncs; the connection and every other
      // stream on it are untouched.
      unawaited(reset());
      return Future.value(PeerSendOutcome.backpressured);
    }
    final completer = Completer<PeerSendOutcome>();
    _queue.add(_PendingSend(bytes, completer.complete));
    _queuedBytes += bytes.length;
    unawaited(_drain());
    return completer.future;
  }

  Future<void> _drain() async {
    if (_writing || _writeStopped) return;
    _writing = true;
    try {
      while (!_writeStopped && _queue.isNotEmpty) {
        if (!_authorized()) {
          _abandon(PeerStreamFatalCause.unauthorized);
          return;
        }
        final pending = _queue.removeAt(0);
        _queuedBytes -= pending.bytes.length;
        try {
          final completed = await _writeInSlices(pending.bytes);
          pending.settle(
            completed ? PeerSendOutcome.accepted : PeerSendOutcome.closed,
          );
        } catch (_) {
          // The peer stopped reading, or the connection went: this stream is
          // over, and there is nothing left to reset.
          pending.settle(PeerSendOutcome.closed);
          _writeStopped = true;
          _resetIssued = true;
          _dropQueue();
          return;
        }
      }
    } finally {
      _writing = false;
      _notifyIdle();
    }
  }

  /// Checks `_writeStopped` between slices, so a cancel or overflow noticed
  /// mid-record stops after the slice already handed to the binding.
  Future<bool> _writeInSlices(Uint8List bytes) =>
      writeRecordInSlices(_send, bytes, stop: () => _writeStopped);

  void _dropQueue() {
    for (final pending in _queue) {
      pending.settle(PeerSendOutcome.closed);
    }
    _queue.clear();
    _queuedBytes = 0;
  }

  void _notifyIdle() {
    if (_writing || (_queue.isNotEmpty && !_writeStopped)) return;
    for (final waiter in _idleWaiters) {
      waiter.complete();
    }
    _idleWaiters.clear();
  }

  void _wakeReader() {
    _resumed?.complete();
    _resumed = null;
  }

  Future<void> _readLoop() async {
    try {
      while (!_records.isClosed) {
        if (_records.isPaused) {
          await (_resumed ??= Completer<void>()).future;
          continue;
        }
        if (_raw) {
          await _readRawChunk();
          continue;
        }
        final prefix = await _recv.readExact(_kRecordLengthPrefixBytes);
        final length = ByteData.sublistView(prefix).getUint32(0, Endian.big);
        if (!peerRecordLengthOk(length, _maxRecordBytes)) {
          _abandon(PeerStreamFatalCause.protocolViolation);
          return;
        }
        final body = await _recv.readExact(length);
        if (!_authorized()) {
          _abandon(PeerStreamFatalCause.unauthorized);
          return;
        }
        if (!_records.isClosed) _records.add(body);
        final threshold = _rawAfterRecords;
        if (threshold != null && ++_recordsDelivered >= threshold) {
          _raw = true;
        }
      }
    } catch (_) {
      // The peer finished or reset this stream, or the connection went.
    } finally {
      _closeRecords();
    }
  }

  /// One iteration of the raw phase: a `null` read is a clean FIN (the outer
  /// loop's normal exit, via [_records].isClosed after [_closeRecords]), and a
  /// thrown read is a reset or a lost connection — distinguishable from a FIN
  /// here in a way record mode never was, so it is surfaced as
  /// [PeerStreamReset] rather than folded into the same silent close.
  Future<void> _readRawChunk() async {
    Uint8List? chunk;
    try {
      chunk = await _recv.read(kPeerStreamRawReadBytes);
    } catch (_) {
      if (!_records.isClosed) _records.addError(const PeerStreamReset());
      _closeRecords();
      return;
    }
    if (chunk == null) {
      _closeRecords();
      return;
    }
    if (chunk.isEmpty) return;
    if (!_authorized()) {
      _abandon(PeerStreamFatalCause.unauthorized);
      return;
    }
    if (!_records.isClosed) _records.add(chunk);
  }

  // Never awaited: a single-subscription close completes only once a
  // listener has taken the done event, which may be never.
  void _closeRecords() {
    if (!_records.isClosed) unawaited(_records.close());
  }

  void _issueReset() {
    if (_resetIssued) return;
    _resetIssued = true;
    unawaited(
      _send.reset(0).catchError((Object _) {
        // The stream, or the connection under it, may already be gone.
      }),
    );
  }

  /// Retires the connection. The native reset is issued but not awaited: it
  /// queues behind any flow-blocked write on the binding's stream mutex, and
  /// only closing the connection preempts that write.
  void _abandon(PeerStreamFatalCause cause) {
    if (_fatal) return;
    _fatal = true;
    _writeStopped = true;
    _dropQueue();
    _notifyIdle();
    _issueReset();
    _closeRecords();
    unawaited(_onConnectionFatal(cause));
  }

  /// Resolves once the native reset has been issued, which can wait for one
  /// in-flight slice to drain (see [kPeerStreamSliceBytes]).
  @override
  Future<void> reset() async {
    if (_resetIssued) return;
    _writeStopped = true;
    _resetIssued = true;
    _dropQueue();
    _notifyIdle();
    try {
      await _send.reset(0);
    } catch (_) {
      // The stream, or the connection under it, may already be gone.
    }
  }

  /// Writes everything already queued, then FINs. A FIN issued while a
  /// record is still going out would end the stream mid-record.
  @override
  Future<void> finish() async {
    if (_writeStopped || _finishing) return;
    _finishing = true;
    if (_writing || _queue.isNotEmpty) {
      final idle = Completer<void>();
      _idleWaiters.add(idle);
      await idle.future;
    }
    if (_writeStopped) return;
    _writeStopped = true;
    _resetIssued = true;
    try {
      await _send.finish();
    } catch (_) {
      // The stream, or the connection under it, may already be gone.
    }
  }
}

/// Opens purpose-specific streams on one connection: bounds concurrent
/// in-flight opens with a semaphore and writes the [StreamOpen] frame as the
/// stream's first record. The QUIC stream limit is the bridge's alone, and
/// an open over it waits in `openBi` with no error, so the local bound is
/// what turns a burst of opens into a queue the app can see.
class PeerStreamOpener {
  PeerStreamOpener(
    this._openBi, {
    int maxPendingOpens = kStreamMaxPendingOpensPerPeer,
  }) : _maxPendingOpens = maxPendingOpens;

  final Future<(PeerStreamSend, PeerStreamRecv)> Function() _openBi;
  final int _maxPendingOpens;
  int _pending = 0;
  final _waiters = <Completer<void>>[];

  Future<PeerStream> open(
    StreamOpen open, {
    required bool Function() authorized,
    required int maxRecordBytes,
    required int maxQueuedBytes,
    required Future<void> Function(PeerStreamFatalCause) onConnectionFatal,
    int? rawAfterRecords,
  }) async {
    final openBytes = encodeStreamOpenFrame(open);
    if (!authorized()) {
      throw const PeerConnectionFailure(
        'AUTHORIZATION_DENIED',
        terminal: true,
      );
    }
    await _acquire();
    try {
      if (!authorized()) {
        throw const PeerConnectionFailure(
          'AUTHORIZATION_DENIED',
          terminal: true,
        );
      }
      final (send, recv) = await _openBi();
      final stream = NativePeerStream(
        send,
        recv,
        authorized,
        onConnectionFatal,
        maxRecordBytes: maxRecordBytes,
        maxQueuedBytes: maxQueuedBytes,
        rawAfterRecords: rawAfterRecords,
      );
      // A fresh Dart stream is invisible to the peer until its first write,
      // so the open frame goes out before the stream is handed to anyone.
      // `send` re-checks authorization, which covers a revocation during
      // `openBi`.
      final outcome = await stream.send(openBytes);
      if (outcome != PeerSendOutcome.accepted) {
        await stream.reset();
        throw const PeerConnectionFailure(
          'STREAM_OPEN_FAILED',
          terminal: false,
        );
      }
      return stream;
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_pending < _maxPendingOpens) {
      _pending++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // The slot passes straight to the head waiter: `complete()` resumes it
      // only in a later microtask, so decrementing here would let a new
      // caller take the slot first.
      _waiters.removeAt(0).complete();
    } else {
      _pending--;
    }
  }
}
