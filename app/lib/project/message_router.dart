import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

import '../models/ab_message.dart';
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

  /// Latest durable frame per `checkoutId` → `type`. Populated from the raw
  /// inbound stream — BEFORE tiering — so a frame is retained even when the
  /// tier it belongs to has no subscriber yet. The tier is re-derived from the
  /// TYPE at replay ([replayFor]), never stored: `classifyAbMessage` coerces an
  /// error-bearing frame to status, which would file a `tree:full` where no
  /// heavy subscriber looks.
  ///
  /// This is what makes a per-checkout service bundle recoverable. The
  /// bridge's `state.snapshot` replays one `agent:status` per checkout at
  /// stream attach, but an isolated session's bundle is not created until the
  /// session list lands a round trip later; the tier streams are broadcast with
  /// no replay, so those frames used to be dropped for want of a subscriber and
  /// nothing ever re-sent them — stranding the session on "waiting for agent"
  /// until the app reconnected.
  final Map<String, Map<String, Map<String, dynamic>>> _durable = {};

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

  /// The durable frames seen so far for [checkoutId] on [tier], oldest first.
  /// Callers seed a fresh per-checkout subscriber with these; re-applying one
  /// is idempotent (every type here is a latest-wins full snapshot).
  Iterable<Map<String, dynamic>> replayFor(String checkoutId, MessageTier tier) {
    final byType = _durable[checkoutId];
    if (byType == null) return const [];
    return [
      for (final entry in byType.entries)
        if (classifyAbMessageByType(entry.key) == tier) entry.value,
    ];
  }

  /// The checkouts holding retained frames. [ProjectSession] sweeps against
  /// this rather than its own bundle map: a checkout can produce durable frames
  /// it never gets a bundle for (an archived session still in the bridge's
  /// replay cache), and those entries pin a whole `tree:full` with nothing to
  /// ever evict them.
  Iterable<String> get replayCheckoutIds => _durable.keys;

  /// Forgets a checkout's durable frames. Called when its worktree is gone, so
  /// a deleted checkout's tree/status stop seeding new subscribers.
  void dropCheckoutReplay(String checkoutId) => _durable.remove(checkoutId);

  void _onInbound(InboundMessage raw) {
    if (raw.channel != 'control') return;
    final tier = classifyAbMessage(raw.json);
    _retainIfDurable(raw.json);
    switch (tier) {
      case MessageTier.status:
        _statusCtrl.add(raw.json);
        break;
      case MessageTier.heavy:
        _heavyCtrl.add(raw.json);
        break;
      case MessageTier.ignore:
        assert(
          _isExpectedIgnore(raw.json),
          'Inbound type "${raw.json['type']}" has a parseAbMessage case but '
          'classifies as MessageTier.ignore, so it is being silently dropped. '
          'Classify it (_statusTypes / _heavyTypes) or add it to '
          'kUnroutedInboundTypes — see classification_gate_test.dart.',
        );
        break;
    }
  }

  void _retainIfDurable(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String || !kCheckoutDurableReplayTypes.contains(type)) return;
    // An error-bearing frame is a transient failure, not a latest-wins
    // snapshot. Retaining one would evict the good frame for its type AND —
    // because classifyAbMessage coerces any `error` to the status tier — replay
    // it forever on the tier the heavy subscriber that needs it never reads.
    if (json['error'] != null) return;
    (_durable[checkoutIdForEnvelope(json)] ??= {})[type] = json;
  }

  /// Debug-only backstop for the classification gate: a control-channel frame
  /// whose type the parser recognizes yet the classifier ignores is a silent
  /// drop. Genuinely-ignored session frames (ping/pong/handshake) return null
  /// from [parseAbMessage], so they never trip this; the parseable-but-unrouted
  /// types (preview tunnel, outbound loopback, snapshot requests) are enumerated
  /// in [kUnroutedInboundTypes]. Anchoring on the parser — not the classifier's
  /// broad ignore bucket — is what keeps this free of false positives.
  static bool _isExpectedIgnore(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String || type.isEmpty) return true;
    if (kUnroutedInboundTypes.contains(type)) return true;
    try {
      return parseAbMessage(json) == null;
    } catch (_) {
      // A malformed payload is not a classification bug.
      return true;
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
    _durable.clear();
    await _sub?.cancel();
    await _statusCtrl.close();
    await _heavyCtrl.close();
  }
}
