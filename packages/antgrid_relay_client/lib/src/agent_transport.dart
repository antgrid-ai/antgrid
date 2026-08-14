/// Transport-agnostic interface for sending and receiving agent messages.
///
/// Two implementations are expected: a relay-backed transport (existing
/// `RelayService`-style WebSocket + E2E encryption) and a local-mode
/// transport that talks directly to a co-located agent. Higher-level
/// services (terminal, file, preview, command) consume this interface so
/// they don't care which transport is in use.
///
/// Note: this package is pure Dart (no Flutter dependency) — so the state
/// surface uses a `Stream<TransportState>` plus a `currentState` snapshot
/// instead of Flutter's `ValueListenable`. Consumers that need a
/// `ValueListenable` can wrap `stateChanges` in a `ValueNotifier` at the
/// Flutter layer.
library;

/// Lifecycle states an [AgentTransport] can be in.
enum TransportState { connecting, connected, disconnected, error }

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

  /// Emits when the relay reports that it DROPPED a frame on this transport's
  /// socket (`MESSAGE_RATE_LIMITED`).
  ///
  /// The relay tells only the SENDER and identifies no frame — the route header
  /// carries no message id — so a listener learns that something in flight died,
  /// never which one. It is therefore a hint to re-issue work that is safe to
  /// repeat, not a per-request failure: a service that cannot re-issue safely
  /// must ignore it. Recovering here is what keeps a dropped frame from costing
  /// a full request timeout. Never fires on a local transport — no relay, so
  /// nothing to drop.
  Stream<void> get droppedFrames;

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
  Future<void> send(Map<String, dynamic> message, {String channel = 'control'});

  /// Issue a request/response RPC against the agent. Returns the decoded
  /// `result` map on success; throws [RpcException] on `ok: false` or
  /// timeout. Default timeout 10s.
  ///
  /// Each transport implements correlation by `requestId`.
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  });

  /// `true` once the transport can carry an RPC — a local session from the
  /// start, a relay stream once its E2E session is established. Distinct from
  /// [currentState] == connected: a relay stream stays connected across a
  /// session-down window where a send would silently drop.
  bool get isEstablished;

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
}

class RpcException implements Exception {
  final String code;
  final String message;
  RpcException(this.code, this.message);
  @override
  String toString() => 'RpcException($code): $message';
}
