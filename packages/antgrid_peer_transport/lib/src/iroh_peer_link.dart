import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;

import 'relay_origin.dart';
import 'selection.dart';

const peerAlpn = 'antgrid/peer/1';
const maxPeerRecordBytes = kMaxFramePayload + 1028;

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
        throw const PeerSelectionFailure('UNAPPROVED_RELAY', terminal: true);
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
    required String localDeviceId,
    required String peerDeviceId,
    required bool Function() authorized,
    List<String> ipAddresses = const [],
    PeerLinkDiagnostic? diagnostic,
  }) async {
    final timer = Stopwatch()..start();
    if (!authorized())
      throw const PeerSelectionFailure('AUTHORIZATION_DENIED', terminal: true);
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
      // Same rule as _fail: only a provable rejection is terminal. Left
      // terminal, an unreachable relay or a dead route denies irohPreferred
      // the WebSocket fallback PeerLinkSelector exists to provide.
      throw const PeerSelectionFailure(
        'NATIVE_CONNECT_UNCLASSIFIED',
        terminal: false,
      );
    }
    if (!authorized() ||
        connection.remoteId.toHex() != endpointId ||
        utf8.decode(connection.alpn, allowMalformed: true) != peerAlpn) {
      connection.close(errorCode: 1);
      throw const PeerSelectionFailure(
        'AUTHENTICATED_ENDPOINT_MISMATCH',
        terminal: true,
      );
    }
    try {
      final (send, recv) = await connection.openBi();
      if (!authorized())
        throw const PeerSelectionFailure(
          'AUTHORIZATION_DENIED',
          terminal: true,
        );
      emitPeerLifecycle(
        diagnostic,
        'peer:iroh-established',
        transport: 'iroh',
        elapsedMs: timer.elapsedMilliseconds,
      );
      return IrohPeerLink._(
        connection,
        send,
        recv,
        localDeviceId,
        peerDeviceId,
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
    this.localDeviceId,
    this.peerDeviceId,
    this._authorized,
    this.netTap,
  );
  final iroh.Connection _connection;
  final iroh.SendStream _send;
  final iroh.RecvStream _recv;
  final String localDeviceId, peerDeviceId;
  final bool Function() _authorized;
  @override
  final PeerLinkDiagnostic? netTap;
  final _messages = StreamController<IncomingRouteMessage>.broadcast(
    sync: true,
  );
  final _states = StreamController<PeerLinkState>.broadcast(sync: true);
  final _failures = StreamController<PeerLinkFailure>.broadcast(sync: true);
  bool _closed = false;
  int _queued = 0;
  Future<void> _tail = Future.value();
  final _pending = <Completer<PeerSendOutcome>>{};
  @override
  bool get isDispatchAllowed => !_closed && _authorized();
  @override
  Stream<IncomingRouteMessage> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerLinkFailure> get failureStream => _failures.stream;
  @override
  Stream<void> get peerRestartStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => _connection.pathEvents().map((event) {
    // Upstream exposes address strings, not a stable typed path classifier.
    netTap?.call({'op': 'path', 'event': event.runtimeType.toString()});
    return PeerPath.unknown;
  });

  void _start() {
    unawaited(_read());
    unawaited(
      _connection.acceptBi().then(
        (_) => _fail('EXTRA_STREAM', false),
        onError: (Object _) {},
      ),
    );
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
        if (length < 4 || length > maxPeerRecordBytes) {
          _fail('INVALID_RECORD_LENGTH', false);
          return;
        }
        final bytes = await _recv.readExact(length);
        if (!isDispatchAllowed) {
          await close();
          return;
        }
        final frame = decodeRouteFrame(bytes);
        if (frame.payload.length > kMaxFramePayload ||
            frame.header['type'] != 'message' ||
            frame.header['to'] != localDeviceId ||
            !['control', 'preview'].contains(frame.header['channel'])) {
          _fail('INVALID_ROUTE', false);
          return;
        }
        _messages.add(
          IncomingRouteMessage(
            from: peerDeviceId,
            channel: frame.header['channel'] as String,
            payload: frame.payload,
            kind: frame.kind,
          ),
        );
      }
    } on FrameException {
      _fail('INVALID_RECORD', false);
    } catch (_) {
      if (!_closed) _fail('NATIVE_CLOSE_UNCLASSIFIED', true);
    }
  }

  @override
  Future<PeerSendOutcome> sendFrame(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    if (!isDispatchAllowed) return Future.value(PeerSendOutcome.closed);
    if (to != peerDeviceId || !['control', 'preview'].contains(channel)) {
      _fail('INVALID_ROUTE', false);
      return Future.value(PeerSendOutcome.failed);
    }
    if (payload.length > kMaxFramePayload)
      return Future.value(PeerSendOutcome.tooLarge);
    final frame = encodeRouteFrame(
      {'type': 'message', 'to': to, 'channel': channel},
      payload,
      kind,
    );
    final size = frame.length + 4;
    if (_queued + size > kSocketInflightBytes)
      return Future.value(PeerSendOutcome.backpressured);
    final record = Uint8List(size);
    ByteData.sublistView(record).setUint32(0, frame.length, Endian.big);
    record.setRange(4, size, frame);
    final completion = Completer<PeerSendOutcome>();
    _pending.add(completion);
    _queued += size;
    final timer = Timer(
      const Duration(seconds: 5),
      () => _fail('WRITE_TIMEOUT', true),
    );
    _tail = _tail.then((_) async {
      try {
        if (!isDispatchAllowed) {
          if (!completion.isCompleted)
            completion.complete(PeerSendOutcome.closed);
          return;
        }
        await _send.writeAll(record);
        if (!completion.isCompleted)
          completion.complete(
            isDispatchAllowed
                ? PeerSendOutcome.accepted
                : PeerSendOutcome.closed,
          );
      } catch (_) {
        _fail('NATIVE_WRITE_UNCLASSIFIED', true);
      } finally {
        timer.cancel();
        _queued -= size;
        _pending.remove(completion);
        record.fillRange(0, record.length, 0);
      }
    });
    return completion.future;
  }

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
