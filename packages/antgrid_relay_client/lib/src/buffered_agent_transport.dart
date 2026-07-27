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

  /// Tier-3 hydrator registry: idempotent view-state pulls (session list,
  /// config, the reopened file, the transcript) re-driven on every
  /// (re)establishment — the reconciliation checkpoint. Keyed so a re-register
  /// supersedes rather than duplicates; torn down with the transport.
  final _hydrators = <String, Future<void> Function()>{};

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
      if (completer != null) {
        final ok = json['ok'] == true;
        if (ok) {
          final result =
              (json['result'] as Map?)?.cast<String, dynamic>() ?? const {};
          completer.complete(result);
        } else {
          final err = (json['error'] as Map?)?.cast<String, dynamic>();
          completer.completeError(
            RpcException(
              err?['code'] as String? ?? 'E_UNKNOWN',
              err?['message'] as String? ?? '',
            ),
          );
        }
      }
      return;
    }
    outbound.add(InboundMessage(channel, json));
  }

  /// `true` once the transport can carry an RPC (and hence a hydrator's pull).
  /// The base answer — "connected" — is right for [LocalTransport] (born
  /// established, no handshake). [StreamTransport] overrides it with the E2E
  /// session's live establishment, since a stream stays `connected` across a
  /// session-down window where a send would silently drop.
  bool get isEstablished => _currentState == TransportState.connected;

  /// Tier-3: register [run] as the hydrator for [key] and, when the transport
  /// is already established, invoke it now. Re-invoked on every future
  /// (re)establishment via [redriveHydrators] — that replay is the whole point:
  /// a reconnect re-pulls this view-state instead of leaving it stale. A
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

  /// Tier-2: a one-shot user action expecting a reply (search, command:run,
  /// git:diff/checkout, create/rename/delete). Runs [run] bounded by [timeout]
  /// and surfaces the outcome so the caller's flag lifecycle ALWAYS settles —
  /// no reply-clears-the-flag stranding. NOT re-driven on reconnect (a user
  /// action is one-shot; only tier-3 [hydrate] re-drives).
  ///
  /// STREAMING actions (N replies terminated by a `*-done`, e.g. command:run
  /// that runs for minutes) MUST pass a [run] whose bound is an IDLE-timeout or
  /// send-failure-only — never a wall-clock cap, which would wrongly kill a
  /// long-running command. In that case leave [timeout] as the outer safety net
  /// (or `null`) and let [run] own the idle bound.
  Future<T> action<T>(
    Future<T> Function() run, {
    Duration? timeout = const Duration(seconds: 15),
  }) {
    final f = run();
    return timeout == null ? f : f.timeout(timeout);
  }

  /// Replay every registered hydrator. Subclasses call this on each
  /// (re)establishment: [LocalTransport] once after connect (born established),
  /// a [StreamTransport] on each handshake establishment (from
  /// `refreshSnapshot`). One failing hydrator never blocks the others.
  void redriveHydrators() {
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

  /// Drop all registered hydrators. Call from a subclass [dispose] so the
  /// registry lifetime tracks the transport (and the warm-LRU eviction that
  /// disposes it).
  void clearHydrators() => _hydrators.clear();

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
