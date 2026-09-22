import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

const _local = '00000000-0000-4000-8000-000000000001';
const _peer = '00000000-0000-4000-8000-000000000002';
const _localEndpoint =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peerEndpoint =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, dynamic> _snapshot({
  int leaseMs = 100,
  String peerGeneration = '1',
}) => {
  'accountId': 'account',
  'deviceId': _local,
  'enrollmentId': 'credential',
  'registrationGeneration': '1',
  'policyGeneration': '1',
  'allowed': true,
  'leaseMs': leaseMs,
  'endpoint': {'endpointId': _localEndpoint, 'generation': '1'},
  'relayUrls': <String>[],
  'peers': [
    {
      'deviceId': _peer,
      'ed25519Pub': base64Encode(List.filled(32, 1)),
      'endpoint': {'endpointId': _peerEndpoint, 'generation': peerGeneration},
    },
  ],
};

class _Handle implements LeaseScheduleHandle {
  _Handle(this.dueMs, this.callback);
  final int dueMs;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

class _Clock {
  int nowMs = 0;
  final tasks = <_Handle>[];
  LeaseScheduleHandle schedule(Duration delay, void Function() callback) {
    final handle = _Handle(nowMs + delay.inMilliseconds, callback);
    tasks.add(handle);
    return handle;
  }

  void elapse(int milliseconds) {
    final target = nowMs + milliseconds;
    final due =
        tasks.where((task) => !task.cancelled && task.dueMs <= target).toList()
          ..sort((a, b) => a.dueMs.compareTo(b.dueMs));
    for (final task in due) {
      if (task.cancelled) continue;
      nowMs = task.dueMs;
      task.cancelled = true;
      task.callback();
    }
    nowMs = target;
  }
}

class _QueuedLink implements PeerLink {
  final gate = Completer<void>();
  bool closed = false;
  int queued = 0;
  int dispatched = 0;

  @override
  bool get isDispatchAllowed => !closed;
  @override
  PeerLinkDiagnostic? get netTap => null;
  @override
  Stream<IncomingPeerFrame> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  Stream<void> get peerRestartStream => const Stream.empty();

  @override
  Future<PeerSendOutcome> sendFrame(
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) async {
    queued++;
    await gate.future;
    if (closed) return PeerSendOutcome.closed;
    dispatched++;
    return PeerSendOutcome.accepted;
  }

  @override
  Future<void> close() async => closed = true;
}

LeasedPeerLink _leased(_QueuedLink inner, AuthorizationLease lease) =>
    LeasedPeerLink(
      inner,
      lease,
      peerId: _peer,
      endpointId: _peerEndpoint,
      registrationGeneration: BigInt.one,
    );

void main() {
  test('lease expiry fences work while it is queued', () async {
    final clock = _Clock();
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: _local,
      enrollmentId: 'credential',
      nowMs: () => clock.nowMs,
      schedule: clock.schedule,
      fetchSnapshot: () async => AuthorizationSnapshot.fromJson(_snapshot()),
    );
    addTearDown(lease.dispose);
    expect(await lease.refresh(), isTrue);
    final inner = _QueuedLink();
    final link = _leased(inner, lease);
    addTearDown(link.close);

    final send = link.sendFrame('control', Uint8List.fromList([1]));
    await Future<void>.delayed(Duration.zero);
    expect(inner.queued, 1);
    clock.elapse(100);
    expect(link.isDispatchAllowed, isFalse);
    expect(inner.closed, isTrue);

    inner.gate.complete();
    expect(await send, PeerSendOutcome.closed);
    expect(inner.dispatched, 0, reason: 'expired queued work cannot dispatch');
  });

  test('peer rotation during reconnect fences the old generation', () async {
    var generation = '1';
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: _local,
      enrollmentId: 'credential',
      fetchSnapshot: () async =>
          AuthorizationSnapshot.fromJson(_snapshot(peerGeneration: generation)),
    );
    addTearDown(lease.dispose);
    expect(await lease.refresh(), isTrue);
    final inner = _QueuedLink();
    final link = _leased(inner, lease);
    addTearDown(link.close);

    final oldGenerationSend = link.sendFrame(
      'control',
      Uint8List.fromList([2]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(inner.queued, 1);

    generation = '2';
    expect(await lease.refresh(), isTrue);
    expect(link.isDispatchAllowed, isFalse);
    expect(inner.closed, isTrue);
    inner.gate.complete();

    expect(await oldGenerationSend, PeerSendOutcome.closed);
    expect(
      inner.dispatched,
      0,
      reason: 'a response from the retired generation cannot leave the queue',
    );
  });
}
