/// Transport-agnostic interface for sending and receiving agent messages.
///
/// Two implementations are expected: a native remote transport with E2E
/// encryption and a local-mode transport that talks directly to a co-located agent. Higher-level
/// services (terminal, file, preview, command) consume this interface so
/// they don't care which transport is in use.
///
/// Note: this package is pure Dart (no Flutter dependency) — so the state
/// surface uses a `Stream<TransportState>` plus a `currentState` snapshot
/// instead of Flutter's `ValueListenable`. Consumers that need a
/// `ValueListenable` can wrap `stateChanges` in a `ValueNotifier` at the
/// Flutter layer.
library;

import 'dart:typed_data';

import 'terminal_attachment.dart';
import 'tunnel_stream.dart';
import 'upload_stream.dart';

/// Lifecycle states an [AgentTransport] can be in.
enum TransportState { connecting, connected, disconnected, error }

/// Whether an RPC only observes authoritative state or may change it.
///
/// Classification is allowlist-based: a method added by a newer bridge is
/// treated as mutating until this client explicitly proves it is safe to
/// retry as a read.
enum RemoteRequestKind { readOnly, mutating }

const readOnlyRemoteRequestMethods = <String>{
  'state.snapshot',
  'sessions.list',
  'machine.capability-card',
  'git.branches',
  'git.remote-state',
  'session.transcriptSnapshot',
};

RemoteRequestKind classifyRemoteRequest(String method) =>
    readOnlyRemoteRequestMethods.contains(method)
    ? RemoteRequestKind.readOnly
    : RemoteRequestKind.mutating;

/// What this process can truthfully say about one mutating remote request.
enum RemoteCommandOutcome { notSent, confirmed, outcomeUnknown }

/// A remote request result whose transport outcome is explicit.
class RemoteRequestResult<T> {
  final RemoteCommandOutcome outcome;
  final T? _value;

  const RemoteRequestResult._(this.outcome, this._value);
  const RemoteRequestResult.notSent()
    : this._(RemoteCommandOutcome.notSent, null);
  const RemoteRequestResult.confirmed(T value)
    : this._(RemoteCommandOutcome.confirmed, value);
  const RemoteRequestResult.outcomeUnknown()
    : this._(RemoteCommandOutcome.outcomeUnknown, null);

  T get value {
    if (outcome != RemoteCommandOutcome.confirmed) {
      throw StateError('A $outcome request has no confirmed result');
    }
    return _value as T;
  }
}

const remoteCommandOutcomeUnknownMessage =
    'Connection lost; execution could not be confirmed';

/// Raised by the compatibility [AgentTransport.request] API when a mutation
/// may have executed but no application response arrived.
class RemoteCommandOutcomeException extends RpcException {
  final RemoteCommandOutcome outcome;

  RemoteCommandOutcomeException(this.outcome)
    : super(
        outcome == RemoteCommandOutcome.notSent
            ? 'E_NOT_SENT'
            : 'E_OUTCOME_UNKNOWN',
        outcome == RemoteCommandOutcome.notSent
            ? 'The request was not sent. Reconnect and try again.'
            : remoteCommandOutcomeUnknownMessage,
      );
}

/// A decoded inbound message routed off a specific channel.
class InboundMessage {
  final String channel;
  final Map<String, dynamic> json;
  const InboundMessage(this.channel, this.json);
}

/// Abstraction over the wire used to talk to an agent.
abstract class AgentTransport {
  /// Stream of decoded inbound messages from the agent.
  Stream<InboundMessage> get messages;

  /// Stream of state transitions. Emits each time [currentState] changes.
  Stream<TransportState> get stateChanges;

  /// Latest known state (synchronous snapshot).
  TransportState get currentState;

  /// `true` when the agent runs on the same host as this app. Lets services
  /// skip relay-only machinery (e.g. PreviewProxyServer) when localhost ports
  /// are directly reachable.
  bool get isLocal;

  /// Establish the connection. Safe to call once.
  Future<void> connect();

  /// Send a JSON-encodable message on the named channel.
  /// Defaults to `control`; preview/HTTP-tunnel callers pass `preview`.
  ///
  /// Completes when the message has been handed to the socket, or dropped —
  /// never when a peer has received it. A relay transport writes it behind
  /// whatever is already outbound on that channel, so a caller that cannot
  /// wait out the traffic ahead of it must impose its own timeout.
  Future<void> send(Map<String, dynamic> message, {String channel = 'control'});

  /// Issue a request/response RPC against the agent. Returns the decoded
  /// `result` map on success; throws [RpcException] on `ok: false` or
  /// timeout. Default timeout 10s.
  ///
  /// Each transport implements correlation by `requestId`.
  ///
  /// [countsTowardHealth] gates whether a [StreamTransport] folds this call's
  /// outcome into the session's consecutive-timeout rekey trigger (see
  /// `MachineSession.notifyRpcResult`), success and timeout alike. A caller
  /// that re-issues the SAME pull on every re-establishment — including the
  /// one a rekey itself causes — must pass `false`, or a run of timeouts on a
  /// link that cannot carry the pull forces a rekey, the rekey re-establishes,
  /// the re-establish re-drives the same pull, and the loop never breaks. `LocalTransport` and
  /// `FakeAgentTransport` accept and ignore it (no rekey counter to feed).
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
    bool countsTowardHealth = true,
  });

  /// Sends one RPC while preserving the distinction between a request that
  /// never left, an application-confirmed result, and an interrupted mutation
  /// whose execution cannot be determined. The method name is classified by
  /// [classifyRemoteRequest]; callers cannot opt a mutation into read retries.
  Future<RemoteRequestResult<Map<String, dynamic>>> requestWithOutcome(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
    bool countsTowardHealth = true,
  });

  /// `true` once the transport can carry an RPC — a local session from the
  /// start, a relay stream once its E2E session is established. Distinct from
  /// [currentState] == connected: a relay stream stays connected across a
  /// session-down window where a send would silently drop.
  bool get isEstablished;

  /// Counts (re)establishments. A revision number a service obtained from the
  /// agent is only comparable against the SAME establishment: a reconnect may
  /// have reached a new agent process whose counters restarted, so a claim
  /// carried across one could match by coincidence and have stale state
  /// confirmed. Services that cache a server-issued seq record this beside it
  /// and re-claim only while it still matches.
  int get establishmentEpoch;

  /// Tier-3: register [run] as the hydrator for [key], invoking it now when the
  /// transport is already established and re-invoking it on every future
  /// (re)establishment (the reconciliation checkpoint — a reconnect re-pulls
  /// idempotent view-state instead of leaving it stale). A re-register under
  /// [key] supersedes. [run] owns its own bounded wait + flag lifecycle.
  Future<void> hydrate(String key, Future<void> Function() run);

  /// Deregister the hydrator for [key]. No-op if absent.
  void unhydrate(String key);

  /// Tier-2: run a one-shot user action bounded by [timeout] so the caller's
  /// flag lifecycle always settles (no reply-clears-the-flag stranding). NOT
  /// re-driven on reconnect. STREAMING actions pass a [run] with its own
  /// idle-timeout and leave [timeout] as an outer net (or `null`).
  Future<T> action<T>(
    Future<T> Function() run, {
    Duration? timeout = const Duration(seconds: 15),
  });

  /// Tear down the connection and release resources.
  Future<void> dispose();

  /// Opens one terminal viewer attachment. [subscribe] is the complete
  /// `terminal:subscribe` message, checkoutId already stamped, with
  /// `subscribe['requestId'] == requestId`. Returns synchronously; never
  /// throws — every failure (refusal, a local open error, the transport
  /// closing) is reported through the returned handle's `done`.
  TerminalAttachment openTerminalAttachment({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> subscribe,
  });

  /// Opens one HTTP tunnel exchange. Returns synchronously; never throws —
  /// every failure (refusal, a local open error, `NOT_SUPPORTED` on a
  /// transport with no stream-backed implementation) is reported through the
  /// returned exchange's `head`/`body`.
  ///
  /// [head] is the `tunnel:http-request` head, with `type` and [requestId]
  /// already set. The transport stamps [bodyLength] and [checkoutId] onto it
  /// itself. [body] is null iff `bodyLength == 0`.
  TunnelHttpExchange openTunnelHttp({
    required String requestId,
    required String checkoutId,
    required Map<String, dynamic> head,
    required int bodyLength,
    Stream<List<int>>? body,
  });

  /// Opens one WebSocket tunnel channel. Returns synchronously; never throws
  /// — see [openTunnelHttp].
  ///
  /// [open] is the `tunnel:ws-open` head; the transport stamps `tunnelId`
  /// and [checkoutId] onto it itself.
  TunnelWsChannel openTunnelWs({
    required String tunnelId,
    required String checkoutId,
    required Map<String, dynamic> open,
  });

  /// Opens one file upload. Returns synchronously; never throws — every
  /// failure (refusal, a local open error, `NOT_SUPPORTED` on a transport
  /// with no stream-backed implementation) is reported through the returned
  /// exchange's `result`.
  UploadExchange openUpload({
    required String requestId,
    required String projectId,
    required String checkoutId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  });
}

class RpcException implements Exception {
  final String code;
  final String message;
  RpcException(this.code, this.message);
  @override
  String toString() => 'RpcException($code): $message';
}
