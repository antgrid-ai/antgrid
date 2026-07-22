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
