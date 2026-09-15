import 'dart:async';
import 'dart:typed_data';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:iroh_quic/iroh_quic.dart' as iroh;

// Prototype adapter only: preserves the existing session driver while the
// production peer-link interface remains gated on native qualification.
class IrohSessionLink extends RelayService {
  IrohSessionLink(
    this.connection,
    this.send,
    this.recv,
    this.localId,
    this.peerId,
  ) : super(crypto: CryptoService());

  final iroh.Connection connection;
  final iroh.SendStream send;
  final iroh.RecvStream recv;
  final String localId;
  final String peerId;
  final messages = StreamController<IncomingRouteMessage>.broadcast();
  final states = StreamController<AppState>.broadcast();
  final failure = Completer<void>();
  Future<void> _tail = Future.value();
  bool _closed = false;
  int _queued = 0;
  int sent = 0;
  int received = 0;
  int peakQueuedBytes = 0;

  @override
  Stream<IncomingRouteMessage> get messageStream => messages.stream;
  @override
  Stream<AppState> get stateStream => states.stream;
  @override
  Stream<bool> get peerPresenceStream => const Stream.empty();
  @override
  Stream<ErrorMessage> get errorStream => const Stream.empty();
  @override
  AppState get currentState => AppState(
    connectionState: _closed
        ? RelayConnectionState.disconnected
        : RelayConnectionState.authenticated,
  );

  void start() {
    failure.future.ignore();
    unawaited(_read());
    unawaited(
      connection.acceptBi().then(
        (_) => _fail(StateError('EXTRA_STREAM')),
        onError: (Object _) {},
      ),
    );
    unawaited(
      connection.acceptUni().then(
        (_) => _fail(StateError('EXTRA_STREAM')),
        onError: (Object _) {},
      ),
    );
  }

  Future<void> _read() async {
    try {
      while (!_closed) {
        final prefix = await recv.readExact(4);
        final length = ByteData.sublistView(prefix).getUint32(0, Endian.big);
        if (length < 4 || length > kMaxFramePayload)
          throw StateError('INVALID_RECORD_LENGTH');
        final raw = await recv.readExact(length);
        if (_closed) return;
        final frame = decodeRouteFrame(raw);
        if (frame.header['type'] != 'message' ||
            frame.header['to'] != localId ||
            !['control', 'preview'].contains(frame.header['channel'])) {
          throw StateError('INVALID_ROUTE');
        }
        received++;
        messages.add(
          IncomingRouteMessage(
            from: peerId,
            channel: frame.header['channel'] as String,
            payload: frame.payload,
            kind: frame.kind,
          ),
        );
      }
    } catch (error) {
      if (!_closed) _fail(error);
    }
  }

  @override
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    if (_closed) throw StateError('CONNECTION_LOST');
    if (to != peerId || !['control', 'preview'].contains(channel))
      throw StateError('INVALID_ROUTE');
    final frame = encodeRouteFrame(
      {'type': 'message', 'to': to, 'channel': channel},
      payload,
      kind,
    );
    if (frame.length > kMaxFramePayload)
      throw StateError('INVALID_RECORD_LENGTH');
    final size = frame.length + 4;
    if (_queued + size > kSocketInflightBytes) {
      _fail(StateError('SEND_QUEUE_FULL'));
      throw StateError('SEND_QUEUE_FULL');
    }
    final record = Uint8List(size);
    ByteData.sublistView(record).setUint32(0, frame.length, Endian.big);
    record.setRange(4, size, frame);
    _queued += size;
    if (_queued > peakQueuedBytes) peakQueuedBytes = _queued;
    _tail = _tail
        .then((_) async {
          try {
            if (_closed) return;
            await send.writeAll(record);
            sent++;
          } finally {
            _queued -= size;
          }
        })
        .catchError((Object error) {
          _fail(error);
        });
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    connection.close(errorCode: 1);
    states.add(currentState);
    if (!failure.isCompleted) failure.completeError(error);
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    connection.close();
    await _tail;
    await messages.close();
    await states.close();
    super.dispose();
  }
}
