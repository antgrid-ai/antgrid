import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// In-memory [AgentTransport] for tests. Construct, hand to the SUT,
/// drive [emit] / [emitJson] to simulate inbound, inspect [sent] for outbound.
class FakeAgentTransport implements AgentTransport {
  final _msgCtrl = StreamController<InboundMessage>.broadcast();
  final _stateCtrl = StreamController<TransportState>.broadcast();
  final _dropCtrl = StreamController<void>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  /// Recorded RPCs issued via [request], in order.
  final List<({String method, Map<String, dynamic>? params})> requests = [];

  /// Optional responder for [request]. When null, `request` throws
  /// `UnimplementedError` (preserving the prior default). Set it to simulate a
  /// `state.snapshot` reply, e.g. `(_, __) => {'frames': [...]}`.
  Map<String, dynamic> Function(String method, Map<String, dynamic>? params)?
  requestHandler;

  TransportState _state = TransportState.connected;
  bool _established = true;
  bool _disposed = false;

  @override
  Stream<InboundMessage> get messages => _msgCtrl.stream;

  @override
  Stream<TransportState> get stateChanges => _stateCtrl.stream;

  @override
  Stream<void> get droppedFrames => _dropCtrl.stream;

  /// Test control: simulate the relay reporting `MESSAGE_RATE_LIMITED`.
  void emitDroppedFrame() => _dropCtrl.add(null);

  @override
  TransportState get currentState => _state;

  @override
  bool get isLocal => false; // tests can override via subclassing if needed

  @override
  bool get isEstablished => _established;

  /// Test control: simulate the E2E session (un)establishing independently of
  /// the socket state — a relay stream can be `connected` yet not yet
  /// established (a send would seal-and-vanish). Transitioning to established
  /// re-drives hydrators, exactly as [StreamTransport.refreshSnapshot] does on
  /// each handshake.
  void setEstablished(bool value) {
    _established = value;
    if (value) redriveHydrators();
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
    requests.add((method: method, params: params));
    final handler = requestHandler;
    if (handler == null) {
      throw UnimplementedError('FakeAgentTransport.request not implemented');
    }
    return handler(method, params);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _msgCtrl.close();
    await _stateCtrl.close();
    await _dropCtrl.close();
  }

  /// Push a raw JSON map onto the inbound stream on the given channel.
  void emitJson(Map<String, dynamic> json, {String channel = 'control'}) {
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
