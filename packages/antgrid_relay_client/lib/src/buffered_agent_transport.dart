import 'dart:async';
import 'dart:typed_data';

import 'agent_transport.dart';
import 'terminal_attachment.dart';
import 'tunnel_stream.dart';
import 'upload_stream.dart';

/// Shared scaffolding for [AgentTransport] implementations.
///
/// Holds the request/response correlation table, the snapshot-replay buffer,
/// and the broadcast state/message controllers that the local and relay
/// transports need identically. Subclasses supply only the wire-specific
/// pieces: [connect], [send] (raw JSON vs. encrypted + fragmented), [dispose],
/// and the decode path — which, once it has a decoded frame and its channel,
/// funnels through [dispatchDecoded].
///
/// The non-private members below ([outbound], [snapshotCache],
/// [stateController], [pending], [dispatchDecoded], [failAllPending],
/// [setState]) are protected-by-convention: this class lives in `lib/src/` and
/// is not exported, so they are internal to the package and intended for
/// subclass use only.
abstract class BufferedAgentTransport implements AgentTransport {
  /// Live frames published to [messages] subscribers.
  final outbound = StreamController<InboundMessage>.broadcast();

  /// Durable frames replayed to every subscriber that attaches later
  /// (see [messages]).
  final snapshotCache = <InboundMessage>[];

  final stateController = StreamController<TransportState>.broadcast();

  /// In-flight RPCs keyed by `requestId`, completed by [dispatchDecoded].
  final pending = <String, Completer<Map<String, dynamic>>>{};

  TransportState _currentState = TransportState.connecting;
  int _nextRequestId = 0;

  /// Tier-3 hydrator registry: idempotent view-state pulls (session list,
  /// config, the reopened file, the transcript) re-driven on every
  /// establishment — the reconciliation checkpoint. Keyed so a re-register
  /// supersedes rather than duplicates; torn down with the transport.
  final _hydrators = <String, Future<void> Function()>{};

  /// Socket-path terminal attachments — the default [openTerminalAttachment].
  /// `StreamTransport` (`machine_session.dart`) overrides it to open a native
  /// stream instead when its link supports one, falling back to this over the
  /// same `send`.
  late final SocketTerminalAttachments terminalAttachments =
      SocketTerminalAttachments((m) => send(m));

  @override
  TerminalAttachment openTerminalAttachment({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> subscribe,
  }) => terminalAttachments.open(
    requestId: requestId,
    checkoutId: checkoutId,
    subscribe: subscribe,
  );

  /// Every socket-path transport (`LocalTransport`, `DemoTransport`, the
  /// test subclasses) inherits this: loopback never tunnels, and nothing here
  /// is wired to a stream, so a preview request
  /// against one of these fails at once instead of hanging. `StreamTransport`
  /// overrides both with the real native-stream implementation.
  @override
  TunnelHttpExchange openTunnelHttp({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> head,
    required int bodyLength,
    Stream<List<int>>? body,
  }) => FailedTunnelHttpExchange(
    requestId,
    const TunnelExchangeFailure('NOT_SUPPORTED'),
  );

  @override
  TunnelWsChannel openTunnelWs({
    required String tunnelId,
    required String checkoutId,
    required Map<String, dynamic> open,
  }) => FailedTunnelWsChannel(
    tunnelId,
    const TunnelExchangeFailure('NOT_SUPPORTED'),
  );

  /// Base default: every native-stream transport (`StreamTransport`)
  /// overrides this with the real implementation. `LocalTransport` overrides
  /// it too, with the loopback `file:upload-local` exchange; this stays only
  /// for a test subclass that ignores uploads.
  @override
  UploadExchange openUpload({
    required String requestId,
    required String projectId,
    required String checkoutId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) => FailedUploadExchange(const UploadFailure('NOT_SUPPORTED'));

  @override
  Stream<InboundMessage> get messages {
    final ctrl = StreamController<InboundMessage>();
    StreamSubscription<InboundMessage>? forward;
    ctrl.onListen = () {
      for (final m in snapshotCache) {
        ctrl.add(m);
      }
      forward = outbound.stream.listen(
        ctrl.add,
        onError: ctrl.addError,
        onDone: ctrl.close,
      );
    };
    ctrl.onCancel = () async {
      await forward?.cancel();
    };
    return ctrl.stream;
  }

  @override
  Stream<TransportState> get stateChanges => stateController.stream;

  @override
  TransportState get currentState => _currentState;

  @override
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) => _requestRaw(method, params: params, timeout: timeout);

  @override
  Future<RemoteRequestResult<Map<String, dynamic>>> requestWithOutcome(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!isEstablished) {
      return const RemoteRequestResult.notSent();
    }
    try {
      final value = await _requestRaw(method, params: params, timeout: timeout);
      return RemoteRequestResult.confirmed(value);
    } on _ApplicationRpcException {
      // A negative application response is still authoritative. Preserve the
      // bridge's typed refusal for existing callers instead of turning it into
      // a transport uncertainty.
      rethrow;
    } on RpcException {
      return const RemoteRequestResult.outcomeUnknown();
    }
  }

  Future<Map<String, dynamic>> _requestRaw(
    String method, {
    Map<String, dynamic>? params,
    required Duration timeout,
  }) {
    final requestId = 'r${_nextRequestId++}';
    final completer = Completer<Map<String, dynamic>>();
    pending[requestId] = completer;
    // A send that fails (closed socket, oversized frame) means the reply can
    // never come — fail the RPC now rather than burning the full timeout.
    send({
      'type': 'request',
      'id': requestId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'requestId': requestId,
      'method': method,
      if (params != null) 'params': params,
    }).catchError((Object e) {
      final c = pending.remove(requestId);
      if (c != null && !c.isCompleted) {
        c.completeError(RpcException('E_SEND_FAILED', 'request $method: $e'));
      }
    });
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        pending.remove(requestId);
        throw RpcException('E_TIMEOUT', 'request $method timed out');
      },
    );
  }

  /// Route an already-decoded frame: complete the matching pending request on a
  /// `type: 'response'`, otherwise publish it to [messages] subscribers.
  ///
  /// A late response (whose request already timed out and dropped its
  /// completer) is silently discarded — never leaked to the public stream.
  void dispatchDecoded(Map<String, dynamic> json, String channel) {
    final type = json['type'] as String?;
    if (type == 'response') {
      final requestId = json['requestId'] as String?;
      final completer = requestId != null ? pending.remove(requestId) : null;
      if (completer == null) {
        noteOrphanResponse(requestId, channel);
        return;
      }
      final ok = json['ok'] == true;
      if (ok) {
        final result =
            (json['result'] as Map?)?.cast<String, dynamic>() ?? const {};
        completer.complete(result);
      } else {
        final err = (json['error'] as Map?)?.cast<String, dynamic>();
        completer.completeError(
          _ApplicationRpcException(
            err?['code'] as String? ?? 'E_UNKNOWN',
            err?['message'] as String? ?? '',
          ),
        );
      }
      return;
    }
    // A reply belonging to an open terminal attachment is claimed there
    // instead of reaching the public stream — see [SocketTerminalAttachments.divert].
    if (terminalAttachments.divert(json)) return;
    outbound.add(InboundMessage(channel, json));
  }

  /// A `response` arrived for a request that is already gone — it timed out and
  /// dropped its completer, so the reply is discarded (never leaked to the
  /// public stream). Default no-op; a remote transport overrides it to
  /// record the frame, because "the RPC timed out and the answer landed 200ms
  /// later" is otherwise invisible at BOTH endpoints — the timeout is local,
  /// and the agent only ever saw a request it answered.
  void noteOrphanResponse(String? requestId, String channel) {}

  /// `true` once the transport can carry an RPC (and hence a hydrator's pull).
  /// The base answer — "connected" — is right for [LocalTransport] (born
  /// established, no handshake). [StreamTransport] overrides it with the E2E
  /// session's live establishment, since a stream stays `connected` across a
  /// session-down window where a send would silently drop.
  bool get isEstablished => _currentState == TransportState.connected;

  int _establishmentEpoch = 0;

  @override
  int get establishmentEpoch => _establishmentEpoch;

  /// Tier-3: register [run] as the hydrator for [key] and, when the transport
  /// is already established, invoke it now. Re-invoked on every future
  /// establishment via [redriveHydrators] — that replay is the whole point:
  /// a reopened project stream re-pulls this view-state instead of leaving it
  /// stale. A
  /// re-register under the same [key] supersedes the prior run (e.g. a focus
  /// switch re-registering the same pull). [run] must be idempotent and own its
  /// OWN bounded wait + flag lifecycle (tier-3 pulls are already timed); this
  /// layer adds only the register + establishment re-drive.
  ///
  /// Returns the initial invocation's future, or a completed future when the
  /// transport isn't established yet (the run is registered for the next
  /// establishment).
  Future<void> hydrate(String key, Future<void> Function() run) {
    _hydrators[key] = run;
    if (isEstablished) return _runHydrator(run);
    return Future<void>.value();
  }

  /// Deregister the hydrator for [key] (e.g. a chat session closed). No-op if
  /// absent.
  void unhydrate(String key) => _hydrators.remove(key);

  /// Replay every registered hydrator. Subclasses call this on each
  /// establishment: [LocalTransport] once after connect (born established),
  /// a [StreamTransport] from `refreshSnapshot` — the session's establishment
  /// for the control transport, each bind for a project transport. One failing hydrator never blocks the others.
  void redriveHydrators() {
    // Bumped BEFORE the replay, so a hydrator running as part of this
    // establishment already sees the new epoch and re-pulls unconditionally
    // rather than claiming a revision the previous agent issued.
    _establishmentEpoch++;
    for (final run in _hydrators.values) {
      unawaited(_runHydrator(run));
    }
  }

  Future<void> _runHydrator(Future<void> Function() run) async {
    try {
      await run();
    } catch (_) {
      // The hydrator's own bounded run already surfaced the failure to its
      // service (flag cleared, error state set). Swallow here so one failing
      // pull can't abort the establishment replay of the others.
    }
  }

  /// Drop all registered hydrators, and end every open terminal attachment
  /// [TerminalAttachmentTransportClosed]. Call from a subclass [dispose] so
  /// the registry lifetime tracks the transport (and the warm-LRU eviction
  /// that disposes it) — every subclass already calls this first in its own
  /// [dispose], which is what lets a terminal attachment's teardown live here
  /// instead of needing its own call at each of them.
  void clearHydrators() {
    _hydrators.clear();
    terminalAttachments.closeAll();
  }

  /// Fail every in-flight request and clear the table. Defaults describe a
  /// [dispose] (call it first from a subclass dispose); a session-down teardown
  /// passes its own [code]/[message] so the RPC fails fast with an accurate
  /// reason instead of burning its full timeout.
  void failAllPending({
    String code = 'E_DISPOSED',
    String message = 'transport disposed',
  }) {
    for (final c in pending.values) {
      if (!c.isCompleted) {
        c.completeError(RpcException(code, message));
      }
    }
    pending.clear();
  }

  /// Update [currentState] and emit on [stateChanges] only when it changes.
  void setState(TransportState state) {
    if (_currentState == state) return;
    _currentState = state;
    stateController.add(state);
  }
}

class _ApplicationRpcException extends RpcException {
  _ApplicationRpcException(super.code, super.message);
}
