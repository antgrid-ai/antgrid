import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

import 'project_message_classification.dart';

/// Splits a transport's inbound control-channel stream into status and heavy
/// tiers. The heavy stream is gated by `client:focus-state`, whose `paused` is
/// the union of two inputs: no heavy subscriber, or [setLifecyclePaused] (the
/// app backgrounded).
///
/// Both output streams emit raw JSON envelopes. Downstream consumers parse
/// via the existing `parseAbMessage` helper in `models/ab_message.dart`.
class MessageRouter {
  final AgentTransport transport;
  late final StreamController<Map<String, dynamic>> _statusCtrl;
  late final StreamController<Map<String, dynamic>> _heavyCtrl;
  StreamSubscription<InboundMessage>? _sub;
  bool _disposed = false;
  bool _heavyListened = false;
  bool _lifecyclePaused = false;
  bool? _sentPaused;
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

  void _onHeavyListen() {
    _heavyListened = true;
    _syncFocusState();
  }

  void _onHeavyCancel() {
    _heavyListened = false;
    _syncFocusState();
  }

  /// Declares whether the whole app is backgrounded, independent of heavy-stream
  /// subscription. Mobile keeps the focused project's subscription alive across a
  /// background, so subscription presence alone never reports the phone as
  /// unable to render — and the agent would skip the fallback push. See
  /// `appFocusPaused` in the bridge's conn-state.ts.
  void setLifecyclePaused(bool paused) {
    _lifecyclePaused = paused;
    _syncFocusState();
  }

  /// Re-declare the focus state to an agent that has just become reachable.
  ///
  /// [_sendFocusState] is best-effort: the relay transport silently drops sends
  /// until session keys are installed, and the agent starts every connection
  /// with `appFocusPaused: false`. Without this the app would sit on a
  /// `_sentPaused` it only *believes* the agent has — a phone backgrounding
  /// across a reconnect (the OS suspends the socket exactly then) leaves the
  /// agent reading "foreground" and skipping the fallback push, permanently:
  /// the dedup blocks every later re-send.
  ///
  /// Only re-asserts what the app already declared; before the first declaration
  /// there is nothing to restate.
  void resyncFocusState() {
    if (_sentPaused == null) return;
    _sentPaused = null;
    _syncFocusState();
  }

  /// The agent holds ONE `appFocusPaused` flag fed by two independent inputs, so
  /// send their union — otherwise a heavy re-subscribe while backgrounded reads
  /// as "foreground" and clobbers the pause.
  void _syncFocusState() {
    final paused = _lifecyclePaused || !_heavyListened;
    if (paused == _sentPaused) return;
    _sentPaused = paused;
    _sendFocusState(paused: paused);
  }

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
