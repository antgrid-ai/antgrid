import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

import 'agent_transport.dart';
import 'buffered_agent_transport.dart';

/// Thrown when the local agent's WebSocket closes during the handshake.
///
/// [closeCode] is the WS close code from the server (e.g. 4401 = bad token,
/// 4409 = another app already owns the agent).
class LocalTransportHandshakeException implements Exception {
  final int? closeCode;
  final String? closeReason;
  final String message;
  LocalTransportHandshakeException(this.message, {this.closeCode, this.closeReason});
  @override
  String toString() =>
      'LocalTransportHandshakeException($closeCode, $closeReason): $message';
}

/// Concrete [AgentTransport] that talks to a co-located agent over a
/// loopback WebSocket (the agent's `LocalListener`, started by
/// `antgrid serve --local`).
///
/// Wire protocol (mirror of `evals/helpers/local-client.ts`):
///   1. Open WS to ws://127.0.0.1:[port]
///   2. Send `{type:'hello', token, appPid, appVersion}`
///   3. Wait for `{type:'ready'}` (anything else = handshake failure)
///   4. Subsequent frames are `{channel, ...message}` JSON envelopes.
class LocalTransport extends BufferedAgentTransport {
  final int port;
  final String token;
  final int appPid;
  final String appVersion;

  /// Bounds a single loopback WS upgrade attempt in [connect]. Injectable for
  /// tests.
  ///
  /// Sized for headroom, not network latency: the upgrade is a ~2ms loopback
  /// handshake, but on macOS the app process pays a first-connect tax Windows
  /// never does — lazy Network/Security framework init plus Gatekeeper /
  /// local-network evaluation on a freshly-signed bundle — and that lands on
  /// top of cold-start main-isolate saturation, which delays the Dart-side
  /// completion of an already-open socket. A tight 5s budget tripped on the
  /// first project open (`WS connect timed out`) even though the bridge had
  /// accepted the connection; 15s absorbs it, costing nothing on the warm path.
  final Duration connectTimeout;

  IOWebSocketChannel? _ch;
  StreamSubscription? _sub;

  LocalTransport({
    required this.port,
    required this.token,
    required this.appPid,
    this.appVersion = 'app',
    this.connectTimeout = const Duration(seconds: 15),
  });

  @override
  bool get isLocal => true;

  @override
  Future<void> connect() async {
    try {
      await _connect();
    } catch (_) {
      // Any connect failure: tear down so a discarded transport doesn't leak
      // its socket, subscription, or the two broadcast controllers. dispose()
      // is idempotent, so this is the single teardown point and callers needn't
      // dispose on failure themselves.
      await dispose();
      rethrow;
    }
  }

  /// Opens the loopback WS, bounding each attempt by [connectTimeout].
  ///
  /// Bounding matters because the upgrade runs before the `ready` guard, so a
  /// port that accepts the socket but stalls the upgrade would hang the open
  /// forever. We retry once on timeout: `Future.timeout` can't cancel the
  /// in-flight `WebSocket.connect`, so on timeout we attach a continuation that
  /// closes the socket if it connects late — otherwise that orphaned socket
  /// would leak an open FD (the caller has already moved on to the retry). By
  /// the retry the main isolate has usually drained, so the second attempt's
  /// completion is scheduled promptly.
  Future<WebSocket> _connectWebSocket() async {
    const maxAttempts = 2;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      // Named `pendingWs` (not `pending`) to avoid shadowing the inherited
      // BufferedAgentTransport.pending RPC table.
      final pendingWs = WebSocket.connect('ws://127.0.0.1:$port');
      try {
        return await pendingWs.timeout(connectTimeout);
      } on TimeoutException {
        // The timed-out connect keeps running; reap it so a late success
        // doesn't leak an open socket. onError swallows the connect's own
        // failure (already abandoned) without an unhandled-rejection.
        unawaited(pendingWs.then((ws) => ws.close(), onError: (_) {}));
        if (attempt == maxAttempts) {
          throw LocalTransportHandshakeException(
              'WS connect timed out after ${connectTimeout.inMilliseconds}ms'
              ' ($maxAttempts attempts)');
        }
      }
    }
    // Unreachable: the loop either returns or throws on the final attempt.
    throw StateError('unreachable');
  }

  Future<void> _connect() async {
    final ws = await _connectWebSocket();
    _ch = IOWebSocketChannel(ws);

    // IOWebSocketChannel.stream is single-subscription — install one
    // listener that routes to the handshake completer until `ready`,
    // then flips into the regular dispatcher.
    final ready = Completer<void>();
    var handshakeDone = false;

    _sub = _ch!.stream.listen(
      (data) {
        if (!handshakeDone) {
          try {
            final m = jsonDecode(data as String) as Map<String, dynamic>;
            if (m['type'] == 'ready') {
              handshakeDone = true;
              if (!ready.isCompleted) ready.complete();
            } else if (!ready.isCompleted) {
              ready.completeError(StateError('handshake: $m'));
            }
          } catch (e) {
            if (!ready.isCompleted) ready.completeError(e);
          }
          return;
        }
        try {
          final env = jsonDecode(data as String) as Map<String, dynamic>;
          final channel = (env['channel'] as String?) ?? 'control';
          env.remove('channel');
          dispatchDecoded(env, channel);
        } catch (_) {
          // Silently ignore malformed frames.
        }
      },
      onError: (e) {
        if (!ready.isCompleted) {
          ready.completeError(e);
        } else {
          setState(TransportState.error);
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(LocalTransportHandshakeException(
            'socket closed before ready',
            closeCode: _ch?.closeCode,
            closeReason: _ch?.closeReason,
          ));
        } else {
          setState(TransportState.disconnected);
        }
      },
    );

    _ch!.sink.add(jsonEncode({
      'type': 'hello',
      'token': token,
      'appPid': appPid,
      'appVersion': appVersion,
    }));

    try {
      await ready.future.timeout(const Duration(seconds: 3));
    } catch (e) {
      await _sub?.cancel();
      _sub = null;
      setState(TransportState.error);
      await _ch?.sink.close();
      _ch = null;
      rethrow;
    }

    setState(TransportState.connected);

    try {
      final snap = await request(
        'state.snapshot',
        params: {'types': ['*']},
        timeout: const Duration(seconds: 5),
      );
      final frames = (snap['frames'] as List?) ?? const [];
      for (final raw in frames) {
        if (raw is Map) {
          snapshotCache.add(InboundMessage('control', raw.cast<String, dynamic>()));
        }
      }
    } on RpcException {
      // Pre-RPC agent — fall through, subscribers get live frames only.
    }
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    try {
      _ch?.sink.add(jsonEncode({'channel': channel, ...message}));
    } catch (_) {
      // best-effort send
    }
  }

  @override
  Future<void> dispose() async {
    failAllPending();
    snapshotCache.clear();
    await _sub?.cancel();
    await _ch?.sink.close();
    await outbound.close();
    await stateController.close();
  }
}
