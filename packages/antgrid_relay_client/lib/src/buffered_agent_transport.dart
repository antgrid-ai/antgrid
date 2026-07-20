import 'dart:async';

import 'agent_transport.dart';

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
  }) {
    final requestId = 'r${_nextRequestId++}';
    final completer = Completer<Map<String, dynamic>>();
    pending[requestId] = completer;
    send({
      'type': 'request',
      'id': requestId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'requestId': requestId,
      'method': method,
      if (params != null) 'params': params,
    });
    return completer.future.timeout(timeout, onTimeout: () {
      pending.remove(requestId);
      throw RpcException('E_TIMEOUT', 'request $method timed out');
    });
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
      if (completer != null) {
        final ok = json['ok'] == true;
        if (ok) {
          final result =
              (json['result'] as Map?)?.cast<String, dynamic>() ?? const {};
          completer.complete(result);
        } else {
          final err = (json['error'] as Map?)?.cast<String, dynamic>();
          completer.completeError(RpcException(
            err?['code'] as String? ?? 'E_UNKNOWN',
            err?['message'] as String? ?? '',
          ));
        }
      }
      return;
    }
    outbound.add(InboundMessage(channel, json));
  }

  /// Fail every in-flight request with `E_DISPOSED` and clear the table.
  /// Call first from a subclass [dispose].
  void failAllPending() {
    for (final c in pending.values) {
      if (!c.isCompleted) {
        c.completeError(RpcException('E_DISPOSED', 'transport disposed'));
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
