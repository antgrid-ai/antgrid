import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import 'authorization.dart';

/// Fences native payload dispatch with the authoritative enrollment lease.
class LeasedPeerLink implements PeerLink {
  LeasedPeerLink(
    this.inner,
    this.lease, {
    required this.peerId,
    this.endpointId,
    this.registrationGeneration,
  }) {
    final local = lease.snapshot?.endpoint;
    _localEndpoint = local?.endpointId;
    _localGeneration = local?.generation;
    _peerKey = _currentPeerKey;
    _sub = lease.changes.listen((_) {
      if (!isDispatchAllowed) unawaited(close());
    });
  }
  final PeerLink inner;
  final AuthorizationLease lease;
  final String peerId;
  final String? endpointId;
  final BigInt? registrationGeneration;
  String? _peerKey;
  String? get _currentPeerKey {
    for (final peer in lease.snapshot?.peers ?? <AuthorizedPeer>[]) {
      if (peer.deviceId == peerId) return peer.ed25519Pub;
    }
    return null;
  }

  String? _localEndpoint;
  BigInt? _localGeneration;
  late final StreamSubscription<void> _sub;
  bool _closed = false;
  bool _emittingState = false;
  void _emitState(PeerLinkState state) {
    if (_emittingState) {
      scheduleMicrotask(() => _emitState(state));
      return;
    }
    if (_states.isClosed) return;
    _emittingState = true;
    try {
      _states.add(state);
    } finally {
      _emittingState = false;
    }
  }

  final _states = StreamController<PeerLinkState>.broadcast(sync: true);
  StreamSubscription<PeerLinkState>? _innerStates;
  @override
  bool get isDispatchAllowed =>
      !_closed &&
      inner.isDispatchAllowed &&
      _currentPeerKey == _peerKey &&
      lease.permits(
        peerId,
        endpointId: endpointId,
        generation: registrationGeneration,
      ) &&
      lease.snapshot?.endpoint?.endpointId == _localEndpoint &&
      lease.snapshot?.endpoint?.generation == _localGeneration;
  @override
  Stream<IncomingPeerFrame> get messageStream =>
      inner.messageStream.where((_) => isDispatchAllowed);
  @override
  Stream<PeerLinkState> get payloadStateStream {
    _innerStates ??= inner.payloadStateStream.listen((state) {
      if (!_closed) _emitState(state);
    });
    return _states.stream;
  }

  @override
  Stream<PeerPath> get pathStream => inner.pathStream;
  @override
  Stream<PeerLinkFailure> get failureStream => inner.failureStream;
  @override
  PeerLinkDiagnostic? get netTap => inner.netTap;
  @override
  Future<PeerSendOutcome> sendFrame(
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) async {
    if (!isDispatchAllowed) return PeerSendOutcome.closed;
    return inner.sendFrame(channel, payload, kind: kind);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _emitState(PeerLinkState.closed);
    final closing = inner.close();
    await _sub.cancel();
    await _innerStates?.cancel();
    await closing;
    await Future<void>.value();
    await _states.close();
  }
}
