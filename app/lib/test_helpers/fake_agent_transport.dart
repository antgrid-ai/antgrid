import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// In-memory [AgentTransport] for tests. Construct, hand to the SUT,
/// drive [emit] / [emitJson] to simulate inbound, inspect [sent] for outbound.
class FakeAgentTransport implements AgentTransport {
  final _msgCtrl = StreamController<InboundMessage>.broadcast();
  final _stateCtrl = StreamController<TransportState>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  /// Recorded RPCs issued via [request], in order.
  final List<({String method, Map<String, dynamic>? params})> requests = [];

  /// Optional responder for [request]. When null, `request` throws
  /// `UnimplementedError` (preserving the prior default). Set it to simulate a
  /// `state.snapshot` reply, e.g. `(_, __) => {'frames': [...]}`.
  Map<String, dynamic> Function(String method, Map<String, dynamic>? params)?
  requestHandler;

  TransportState _state = TransportState.connected;
  bool _disposed = false;

  @override
  Stream<InboundMessage> get messages => _msgCtrl.stream;

  @override
  Stream<TransportState> get stateChanges => _stateCtrl.stream;

  @override
  TransportState get currentState => _state;

  @override
  bool get isLocal => false; // tests can override via subclassing if needed

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
