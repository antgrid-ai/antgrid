// Not a `_test.dart` file - the PeerLink fake the per-kind native-stream
// suites (terminal, tunnel, upload) drive a real MachineSession through.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import 'fake_live_relay.dart';

/// Lets an unawaited async chain (`_StreamExchange.start()`, the send
/// scheduler's drain loop) settle before the next assertion. A real duration,
/// not `Duration.zero`: the scheduler's drain isn't a fixed number of
/// microtasks away.
Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

class NativeStreamLink implements PeerLink {
  final _messages = StreamController<IncomingSessionRecord>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();
  final _failures = StreamController<PeerLinkFailure>.broadcast();

  final List<({StreamOpen open, int maxRecordBytes, int maxQueuedBytes})>
  opens = [];
  final List<NativeTestStream> createdStreams = [];

  /// Overrides the stream a successful [openStream] returns; defaults to a
  /// fresh [NativeTestStream] recorded in [createdStreams].
  NativeTestStream Function(StreamOpen open)? onOpen;

  late MachineSession session;

  /// Binds [projectId] over its own native stream: the ready notice on the
  /// control plane, then the bridge's `stream-ready` as the new stream's
  /// first record. With [clearTracking], [opens] and [createdStreams] are
  /// emptied afterwards so a test's counts reflect only what it drives.
  Future<StreamTransport> bind(
    String projectId, {
    bool clearTracking = true,
  }) async {
    session = MachineSession(
      relay: this,
      machineDeviceId: 'm1',
      handshaker: FakeHandshaker(),
    );
    session.start();
    await session.ensureEstablished();
    final opening = session.openProject(projectId, {
      'type': 'project:start',
      'projectId': projectId,
    });
    await pump();
    final ready = {'type': 'stream-ready', 'projectId': projectId};
    _messages.add(IncomingSessionRecord(payload: encodeFromAgent(jsonEncode(ready))));
    await pump();
    createdStreams.last.emit(ready);
    final transport = await opening;
    if (clearTracking) {
      opens.clear();
      createdStreams.clear();
    }
    return transport;
  }

  @override
  bool get isDispatchAllowed => true;
  @override
  Stream<IncomingSessionRecord> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => _failures.stream;
  @override
  PeerLinkDiagnostic? get netTap => null;

  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async =>
      PeerSendOutcome.accepted;

  @override
  Future<void> close() async {}

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) async {
    opens.add((
      open: open,
      maxRecordBytes: maxRecordBytes,
      maxQueuedBytes: maxQueuedBytes,
    ));
    final stream = onOpen != null ? onOpen!(open) : NativeTestStream();
    createdStreams.add(stream);
    return stream;
  }
}

class NativeTestStream implements PeerStream {
  // Single-subscription on purpose: a record the bridge emits before the
  // exchange starts listening is buffered, as a real stream's would be.
  final _records = StreamController<Uint8List>();
  final List<Uint8List> sent = [];
  final List<Uint8List> sentRaw = [];
  bool resetCalled = false;
  bool finishCalled = false;
  PeerSendOutcome sendRawOutcome = PeerSendOutcome.accepted;

  /// When set, the raw send at index [rawGateAt] waits on this before it
  /// settles — one write still in flight (backpressure or a slow binding).
  Completer<void>? rawGate;
  int rawGateAt = 0;

  /// When true, the gated raw send throws once its gate releases, as a
  /// native write does when the peer stopped the stream.
  bool throwAfterGate = false;

  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    sent.add(record);
    return PeerSendOutcome.accepted;
  }

  @override
  Future<PeerSendOutcome> sendRaw(Uint8List bytes) async {
    final index = sentRaw.length;
    sentRaw.add(bytes);
    final gate = rawGate;
    if (gate != null && index == rawGateAt) {
      await gate.future;
      if (throwAfterGate) throw StateError('stream stopped by peer');
    }
    return sendRawOutcome;
  }

  /// Leaves [records] open: a real [PeerStream]'s records end only on the
  /// peer's end, never because this side reset, and the slot rules depend on
  /// exactly that.
  @override
  Future<void> reset() async {
    resetCalled = true;
  }

  @override
  Future<void> finish() async {
    finishCalled = true;
  }

  void emit(Map<String, dynamic> json) =>
      emitRaw(Uint8List.fromList(utf8.encode(jsonEncode(json))));

  /// A raw body chunk, as it arrives once the stream is past its framed head
  /// — no tag, no framing, straight bytes.
  void emitRaw(Uint8List bytes) {
    if (!_records.isClosed) _records.add(bytes);
  }

  Future<void> endPeer() async {
    if (!_records.isClosed) await _records.close();
  }

  /// Ends the peer's send half with a reset rather than a clean FIN — only
  /// distinguishable once the stream has moved past its framed head.
  Future<void> endWithReset() async {
    if (_records.isClosed) return;
    _records.addError(const PeerStreamReset());
    await _records.close();
  }
}
