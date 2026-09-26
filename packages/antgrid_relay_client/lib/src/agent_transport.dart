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
  /// Each transport implements correlation by `requestId`. On a remote project
  /// transport, a timeout counts toward that stream's own health accounting —
  /// three consecutive ones reset and reopen the stream (never the link). On
  /// the control transport and on loopback, a timeout is only a failed call.
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  });

  /// Sends one RPC while preserving the distinction between a request that
  /// never left, an application-confirmed result, and an interrupted mutation
  /// whose execution cannot be determined. Every call is treated as a
  /// mutation: not established short-circuits to [RemoteRequestResult.notSent],
  /// an application-level refusal ([RpcException] carrying the bridge's typed
  /// error) rethrows, and any other transport failure or timeout reports
  /// [RemoteRequestResult.outcomeUnknown].
  Future<RemoteRequestResult<Map<String, dynamic>>> requestWithOutcome(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  });

  /// `true` once the transport can carry an RPC — a local session from the
  /// start, a native stream transport once its session is established (and,
  /// for a project, its stream is bound). Distinct from [currentState] ==
  /// connected: a project transport stays connected while its stream is
  /// unbound, where a send would silently drop.
  bool get isEstablished;

  /// Counts establishments: the session's own for the control transport, each
  /// stream bind for a project transport. A revision number a service obtained
  /// from the agent is only comparable against the SAME establishment: a
  /// project stream can reopen onto a restarted project core whose counters
  /// restarted, so a claim carried across one could match by coincidence and
  /// have stale state confirmed. Services that cache a server-issued seq record this beside it
  /// and re-claim only while it still matches.
  int get establishmentEpoch;

  /// Tier-3: register [run] as the hydrator for [key], invoking it now when the
  /// transport is already established and re-invoking it on every future
  /// establishment (the reconciliation checkpoint — a reopened project stream
  /// re-pulls idempotent view-state instead of leaving it stale). A re-register under
  /// [key] supersedes. [run] owns its own bounded wait + flag lifecycle.
  Future<void> hydrate(String key, Future<void> Function() run);

  /// Deregister the hydrator for [key]. No-op if absent.
  void unhydrate(String key);

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
