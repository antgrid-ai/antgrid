import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

import 'project_message_classification.dart';

/// Splits a transport's inbound control-channel stream into status and heavy
/// tiers. The heavy stream is gated: subscribing sends `client:focus-state
/// {paused: false}` to the agent; the last cancel sends `{paused: true}`.
///
/// Both output streams emit raw JSON envelopes. Downstream consumers parse
/// via the existing `parseAbMessage` helper in `models/ab_message.dart`.
class MessageRouter {
  final AgentTransport transport;
  late final StreamController<Map<String, dynamic>> _statusCtrl;
  late final StreamController<Map<String, dynamic>> _heavyCtrl;
  StreamSubscription<InboundMessage>? _sub;
  bool _disposed = false;
  static const _uuid = Uuid();

  MessageRouter({required this.transport}) {
    _statusCtrl = StreamController<Map<String, dynamic>>.broadcast();
    _heavyCtrl = StreamController<Map<String, dynamic>>.broadcast(
      onListen: _onHeavyListen,
      onCancel: _onHeavyCancel,
    );
    _sub = transport.messages.listen(_onInbound);
  }

  Stream<Map<String, dynamic>> get status => _statusCtrl.stream;
  Stream<Map<String, dynamic>> get heavy => _heavyCtrl.stream;

  void _onInbound(InboundMessage raw) {
    if (raw.channel != 'control') return;
    switch (classifyAbMessage(raw.json)) {
      case MessageTier.status:
        _statusCtrl.add(raw.json);
        break;
      case MessageTier.heavy:
        _heavyCtrl.add(raw.json);
        break;
      case MessageTier.ignore:
        break;
    }
  }

  void _onHeavyListen() => _sendFocusState(paused: false);
  void _onHeavyCancel() => _sendFocusState(paused: true);

  void _sendFocusState({required bool paused}) {
    if (_disposed) return;
    transport.send({
      'id': _uuid.v4(),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'type': 'client:focus-state',
      'paused': paused,
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    await _statusCtrl.close();
    await _heavyCtrl.close();
  }
}
