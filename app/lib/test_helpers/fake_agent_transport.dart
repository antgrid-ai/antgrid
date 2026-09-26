import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// In-memory [AgentTransport] for tests. Construct, hand to the SUT,
/// drive [emit] / [emitJson] to simulate inbound, inspect [sent] for outbound.
class FakeAgentTransport implements AgentTransport {
  final _msgCtrl = StreamController<InboundMessage>.broadcast();
  final _stateCtrl = StreamController<TransportState>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  /// Recorded RPCs issued via [request], in order. [timeout] is recorded too:
  /// a verb that must override the transport default (sessions.delete) is only
  /// testable from the caller's side.
  final List<({String method, Map<String, dynamic>? params, Duration timeout})>
  requests = [];

  /// Optional responder for [request]. When null, `request` throws
  /// `UnimplementedError` (preserving the prior default). Set it to simulate a
  /// `state.snapshot` reply, e.g. `(_, __) => {'frames': [...]}`.
  ///
  /// `FutureOr` so a test can hold a request in flight — return
  /// `Completer<Map<String, dynamic>>().future` to simulate a call nothing ever
  /// answers, exercising [request]'s own [timeout] bound (or, more often, the
  /// caller's `_disposed`/generation guard once the SUT is torn down).
  FutureOr<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic>? params,
  )?
  requestHandler;

  /// In-flight [request] calls: their completer plus the timer enforcing
  /// [timeout]. Tracked so [dispose] can cancel every timer outright rather
  /// than hoping the completing error propagates before the test ends.
  final List<({Completer<Map<String, dynamic>> completer, Timer timer})>
  _pendingRpcs = [];

  TransportState _state = TransportState.connected;
  bool _established = true;
  bool _disposed = false;

  /// Socket-path terminal attachments over this transport's own [send], so a
  /// subscribe still lands in [sent] exactly as it did before attachments
  /// existed.
  late final SocketTerminalAttachments _terminalAttachments =
      SocketTerminalAttachments(send);

  /// When true, attachments report `isStream` and everything sent on them
  /// (the subscribe included) lands in [attachmentSent] instead of [sent],
  /// as it would on a native terminal stream rather than the project stream.
  bool terminalAttachmentsAsStream = false;

  final List<Map<String, dynamic>> attachmentSent = [];

  late final SocketTerminalAttachments _streamTerminalAttachments =
      SocketTerminalAttachments((message) async => attachmentSent.add(message));

  /// Every [openTunnelHttp] call, in order, so a test can both assert on the
  /// arguments and drive the returned fake's head/body.
  final List<FakeTunnelHttpExchange> tunnelHttpOpens = [];

  /// Every [openTunnelWs] call, in order.
  final List<FakeTunnelWsChannel> tunnelWsOpens = [];

  @override
  TunnelHttpExchange openTunnelHttp({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> head,
    required int bodyLength,
    Stream<List<int>>? body,
  }) {
    final exchange = FakeTunnelHttpExchange(
      requestId: requestId,
      checkoutId: checkoutId,
      requestHead: head,
      bodyLength: bodyLength,
      requestBody: body,
    );
    tunnelHttpOpens.add(exchange);
    return exchange;
  }

  /// Every [openUpload] call, in order, so a test can both assert on the
  /// arguments and drive the returned fake's result.
  final List<FakeUploadExchange> uploadCalls = [];

  @override
  UploadExchange openUpload({
    required String requestId,
    required String projectId,
    required String checkoutId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) {
    final exchange = FakeUploadExchange(
      requestId: requestId,
      projectId: projectId,
      checkoutId: checkoutId,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      onProgress: onProgress,
    );
    uploadCalls.add(exchange);
    return exchange;
  }

  @override
  TunnelWsChannel openTunnelWs({
    required String tunnelId,
    required String checkoutId,
    required Map<String, dynamic> open,
  }) {
    final channel = FakeTunnelWsChannel(
      tunnelId: tunnelId,
      checkoutId: checkoutId,
      open: open,
    );
    tunnelWsOpens.add(channel);
    return channel;
  }

  @override
  TerminalAttachment openTerminalAttachment({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> subscribe,
  }) {
    if (!terminalAttachmentsAsStream) {
      return _terminalAttachments.open(
        requestId: requestId,
        checkoutId: checkoutId,
        subscribe: subscribe,
      );
    }
    return _StreamFlaggedAttachment(
      _streamTerminalAttachments.open(
        requestId: requestId,
        checkoutId: checkoutId,
        subscribe: subscribe,
      ),
    );
  }

  /// Test control: end [requestId]'s attachment as the transport would —
  /// `PeerEnded`, `Refused`, `Failed`, `TransportClosed` or `ClosedLocally`.
  void endTerminalAttachment(String requestId, TerminalAttachmentEnd end) {
    _terminalAttachments.endAttachment(requestId, end);
    _streamTerminalAttachments.endAttachment(requestId, end);
  }

  @override
  Stream<InboundMessage> get messages => _msgCtrl.stream;

  @override
  Stream<TransportState> get stateChanges => _stateCtrl.stream;

  @override
  TransportState get currentState => _state;

  @override
  bool get isLocal => false; // tests can override via subclassing if needed

  @override
  bool get isEstablished => _established;

  int _establishmentEpoch = 0;

  @override
  int get establishmentEpoch => _establishmentEpoch;

  /// Test control: simulate the peer session (un)establishing independently of
  /// the socket state — a relay stream can be `connected` yet not yet
  /// established (a send would seal-and-vanish). Transitioning to established
  /// re-drives hydrators, exactly as [StreamTransport.refreshSnapshot] does on
  /// each handshake.
  void setEstablished(bool value) {
    _established = value;
    if (value) redriveHydrators();
  }

  /// Moves [isEstablished] WITHOUT the hydrator re-drive, so a test can prove
  /// a recovery path carries its own sync rather than inheriting one from the
  /// re-drive that usually accompanies it.
  void setEstablishedQuietly(bool value) => _established = value;

  /// Test control: drive the transport's lifecycle state directly — the
  /// signal `ProjectSession`'s pending-reply registry keys its down/up edges
  /// on for a non-relay transport. Deliberately does not touch
  /// [redriveHydrators] or [_established]: those model the peer session, an
  /// orthogonal axis to the socket-level state this simulates.
  void emitState(TransportState value) {
    _state = value;
    _stateCtrl.add(value);
  }

  final Map<String, Future<void> Function()> _hydrators = {};

  @override
  Future<void> hydrate(String key, Future<void> Function() run) {
    _hydrators[key] = run;
    if (isEstablished) return _runHydrator(run);
    return Future<void>.value();
  }

  @override
  void unhydrate(String key) => _hydrators.remove(key);

  /// Mirrors [BufferedAgentTransport]'s swallow: one failing hydrator is
  /// isolated, so a constructor-registered hydrator whose pull fails (e.g. its
  /// pending reply is failed on dispose) never surfaces as an unhandled error.
  Future<void> _runHydrator(Future<void> Function() run) async {
    try {
      await run();
    } catch (_) {
      // Isolated on purpose — see doc above.
    }
  }

  @override
  Future<T> action<T>(
    Future<T> Function() run, {
    Duration? timeout = const Duration(seconds: 15),
  }) {
    final f = run();
    return timeout == null ? f : f.timeout(timeout);
  }

  /// Test helper: simulate a (re)establishment, re-driving every registered
  /// hydrator (what StreamTransport.refreshSnapshot does on each handshake).
  void redriveHydrators() {
    // Mirrors [BufferedAgentTransport.redriveHydrators]: epoch first, so a
    // hydrator replayed by this establishment sees it.
    _establishmentEpoch++;
    for (final run in _hydrators.values) {
      unawaited(_runHydrator(run));
    }
  }

  @override
  Future<void> connect() async {
    _state = TransportState.connected;
    _stateCtrl.add(_state);
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    sent.add(message);
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    requests.add((method: method, params: params, timeout: timeout));
    // Appended on the same ordinal as `send`, so an ordering assertion over
    // `sent` (e.g. a declaration that must precede every pull it triggers)
    // stays honest once a pull moves from a message to this RPC.
    sent.add(<String, dynamic>{
      'type': 'request',
      'id': 'fake-r${requests.length}',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'requestId': 'fake-r${requests.length}',
      'method': method,
      'params': ?params,
    });
    final handler = requestHandler;
    if (handler == null) {
      throw UnimplementedError('FakeAgentTransport.request not implemented');
    }
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          RpcException('E_TIMEOUT', 'request $method timed out'),
        );
      }
    });
    final entry = (completer: completer, timer: timer);
    _pendingRpcs.add(entry);
    unawaited(
      Future<Map<String, dynamic>>.sync(
        () async => await handler(method, params),
      ).then(
        (result) {
          if (!completer.isCompleted) completer.complete(result);
        },
        onError: (Object error, StackTrace stack) {
          if (completer.isCompleted) return;
          completer.completeError(
            error is RpcException ? error : RpcException('E_HANDLER', '$error'),
            stack,
          );
        },
      ),
    );
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      _pendingRpcs.remove(entry);
    }
  }

  @override
  Future<RemoteRequestResult<Map<String, dynamic>>> requestWithOutcome(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final mutating =
        classifyRemoteRequest(method) == RemoteRequestKind.mutating;
    if (mutating && !isEstablished) {
      return const RemoteRequestResult.notSent();
    }
    try {
      final value = await request(method, params: params, timeout: timeout);
      return RemoteRequestResult.confirmed(value);
    } on RpcException catch (error) {
      if (mutating && _transportFailureCodes.contains(error.code)) {
        return const RemoteRequestResult.outcomeUnknown();
      }
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Settle every outstanding RPC so its timer cannot outlive this test —
    // a test that holds a request in flight (via `requestHandler` returning a
    // Future nothing completes) would otherwise leave a live `Timer` running
    // for up to its full [Duration] after the test body has moved on.
    for (final pending in List.of(_pendingRpcs)) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          RpcException('E_DISPOSED', 'transport disposed'),
        );
      }
    }
    await _msgCtrl.close();
    await _stateCtrl.close();
  }

  /// Push a raw JSON map onto the inbound stream on the given channel. A
  /// reply belonging to an open terminal attachment is diverted there first
  /// (see [SocketTerminalAttachments.divert]) and never reaches [messages].
  void emitJson(Map<String, dynamic> json, {String channel = 'control'}) {
    if (_terminalAttachments.divert(json)) return;
    if (_streamTerminalAttachments.divert(json)) return;
    _msgCtrl.add(InboundMessage(channel, json));
  }

  /// Emit a AbMessage-shaped envelope with [type] and [extra] fields.
  void emit(String type, [Map<String, dynamic> extra = const {}]) {
    emitJson({
      'id': '00000000-0000-0000-0000-000000000000',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'type': type,
      ...extra,
    });
  }

  void clearSent() => sent.clear();
}

const _transportFailureCodes = <String>{
  'E_TIMEOUT',
  'E_SEND_FAILED',
  'E_SESSION_DOWN',
  'E_DISPOSED',
  'E_SOCKET_CLOSED',
  'E_SUPERSEDED',
};

/// Test double for [TunnelHttpExchange]. Every argument [openTunnelHttp] was
/// called with is recorded; the test then drives [completeHead]/[addBody]/
/// [endBody]/[failWith] to simulate the bridge's side.
class FakeTunnelHttpExchange implements TunnelHttpExchange {
  FakeTunnelHttpExchange({
    required this.requestId,
    required this.checkoutId,
    required this.requestHead,
    required this.bodyLength,
    this.requestBody,
  });

  final String checkoutId;

  /// The `tunnel:http-request` head this exchange was opened with.
  final Map<String, dynamic> requestHead;

  /// Byte length of the request body [openTunnelHttp] was called with.
  final int bodyLength;

  /// The request body stream [openTunnelHttp] was called with, if any.
  final Stream<List<int>>? requestBody;

  @override
  final String requestId;

  bool cancelled = false;

  final _headCompleter = Completer<TunnelHttpHead>();
  final _bodyController = StreamController<Uint8List>();

  @override
  Future<TunnelHttpHead> get head => _headCompleter.future;

  @override
  Stream<Uint8List> get body => _bodyController.stream;

  void completeHead(TunnelHttpHead head) {
    if (!_headCompleter.isCompleted) _headCompleter.complete(head);
  }

  void addBody(Uint8List chunk) {
    if (!_bodyController.isClosed) _bodyController.add(chunk);
  }

  void endBody() {
    unawaited(_bodyController.close());
  }

  void failWith(TunnelExchangeFailure failure) {
    if (!_headCompleter.isCompleted) {
      _headCompleter.future.ignore();
      _headCompleter.completeError(failure);
    }
    if (!_bodyController.isClosed) {
      _bodyController.addError(failure);
      unawaited(_bodyController.close());
    }
  }

  @override
  void cancel() {
    cancelled = true;
  }
}

/// Test double for [TunnelWsChannel]. The test drives [emit]/[closeFromPeer]
/// to simulate frames and a close arriving from the bridge, and inspects
/// [sent]/[closedWith]/[aborted] to see what the app sent.
class FakeTunnelWsChannel implements TunnelWsChannel {
  FakeTunnelWsChannel({
    required this.tunnelId,
    required this.checkoutId,
    required this.open,
  });

  final String checkoutId;

  /// The `tunnel:ws-open` head this channel was opened with.
  final Map<String, dynamic> open;

  @override
  final String tunnelId;

  /// Every frame [send] was called with, in call order.
  final List<TunnelWsFrame> sent = [];

  /// Set by [close]; null if the channel ended some other way.
  ({int? code, String? reason})? closedWith;

  bool aborted = false;

  final _framesController = StreamController<TunnelWsFrame>();
  final _doneCompleter = Completer<TunnelWsEnd>();

  @override
  Stream<TunnelWsFrame> get frames => _framesController.stream;

  @override
  Future<TunnelWsEnd> get done => _doneCompleter.future;

  /// Simulate a frame arriving from the bridge.
  void emit(TunnelWsFrame frame) {
    if (!_framesController.isClosed) _framesController.add(frame);
  }

  /// Simulate the bridge's side closing.
  void closeFromPeer({int? code, String? reason}) {
    _end(TunnelWsClosedByPeer(code, reason));
  }

  void failWith(TunnelExchangeFailure failure) {
    _end(TunnelWsFailed(failure));
  }

  void _end(TunnelWsEnd end) {
    if (_doneCompleter.isCompleted) return;
    _doneCompleter.complete(end);
    unawaited(_framesController.close());
  }

  @override
  Future<bool> send(TunnelWsFrame frame) async {
    sent.add(frame);
    return !aborted && !_doneCompleter.isCompleted;
  }

  @override
  void close({int? code, String? reason}) {
    closedWith = (code: code, reason: reason);
    _end(const TunnelWsClosedLocally());
  }

  @override
  void abort() {
    aborted = true;
    _end(const TunnelWsClosedLocally());
  }
}

/// Test double for [UploadExchange]. Every [openUpload] argument is recorded;
/// the test then drives [complete]/[fail] to simulate the bridge's result, and
/// [progress] to simulate a byte-level write completing.
class FakeUploadExchange implements UploadExchange {
  FakeUploadExchange({
    required this.requestId,
    required this.projectId,
    required this.checkoutId,
    required this.fileName,
    required this.bytes,
    this.mimeType,
    this.onProgress,
  });

  final String projectId;
  final String checkoutId;
  final String fileName;
  final Uint8List bytes;
  final String? mimeType;
  final void Function(int sent, int total)? onProgress;

  @override
  final String requestId;

  bool cancelled = false;

  final _resultCompleter = Completer<UploadStreamResult>();

  @override
  Future<UploadStreamResult> get result => _resultCompleter.future;

  /// Simulate a write completing — the stream path's only progress signal.
  void progress(int sent, int total) => onProgress?.call(sent, total);

  void complete(UploadStreamResult result) {
    if (!_resultCompleter.isCompleted) _resultCompleter.complete(result);
  }

  void fail(UploadFailure failure) {
    if (!_resultCompleter.isCompleted) _resultCompleter.completeError(failure);
  }

  @override
  void cancel() {
    cancelled = true;
  }
}

class _StreamFlaggedAttachment implements TerminalAttachment {
  _StreamFlaggedAttachment(this._inner);

  final TerminalAttachment _inner;

  @override
  bool get isStream => true;
  @override
  String get requestId => _inner.requestId;
  @override
  String get checkoutId => _inner.checkoutId;
  @override
  Stream<Map<String, dynamic>> get messages => _inner.messages;
  @override
  Future<TerminalAttachmentEnd> get done => _inner.done;
  @override
  Future<void> send(Map<String, dynamic> message) => _inner.send(message);
  @override
  Future<void> close() => _inner.close();
}
