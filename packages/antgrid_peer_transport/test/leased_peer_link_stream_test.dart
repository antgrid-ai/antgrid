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

Map<String, dynamic> _snapshot() => {
  'accountId': 'account',
  'deviceId': _local,
  'enrollmentId': 'credential',
  'registrationGeneration': '1',
  'policyGeneration': '1',
  'allowed': true,
  'leaseMs': 60000,
  'endpoint': {'endpointId': _localEndpoint, 'generation': '1'},
  'relayUrls': <String>[],
  'peers': [
    {
      'deviceId': _peer,
      'ed25519Pub': base64Encode(List.filled(32, 1)),
      'endpoint': {'endpointId': _peerEndpoint, 'generation': '1'},
    },
  ],
};

class _FakePeerStream implements PeerStream {
  final _controller = StreamController<Uint8List>.broadcast(sync: true);
  final sent = <Uint8List>[];
  var resetCalls = 0;
  var finishCalls = 0;

  @override
  Stream<Uint8List> get records => _controller.stream;
  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    sent.add(record);
    return PeerSendOutcome.accepted;
  }

  @override
  Future<PeerSendOutcome> sendRaw(Uint8List bytes) async {
    sent.add(bytes);
    return PeerSendOutcome.accepted;
  }

  @override
  Future<void> reset() async {
    resetCalls++;
  }

  @override
  Future<void> finish() async {
    finishCalls++;
  }

  void emit(Uint8List record) => _controller.add(record);
}

/// A PeerLink that also opens streams — the shape every production
/// `LeasedPeerLink.inner` has, since it always wraps `NativeEndpointOwner.dial`.
class _FakeMultiStreamLink implements PeerLink {
  bool closed = false;
  StreamOpen? lastOpen;
  _FakePeerStream? lastStream;

  /// Simulates the world changing while the native `openBi` await was in
  /// flight — the one window `LeasedPeerLink.openStream`'s post-check exists for.
  void Function()? invalidateDuringOpen;

  @override
  bool get isDispatchAllowed => !closed;
  @override
  PeerLinkDiagnostic? get netTap => null;
  @override
  Stream<IncomingSessionRecord> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async =>
      PeerSendOutcome.accepted;
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) async {
    invalidateDuringOpen?.call();
    lastOpen = open;
    final stream = _FakePeerStream();
    lastStream = stream;
    return stream;
  }
}

LeasedPeerLink _leased(PeerLink inner, AuthorizationLease lease) =>
    LeasedPeerLink(
      inner,
      lease,
      peerId: _peer,
      endpointId: _peerEndpoint,
      registrationGeneration: BigInt.one,
    );

AuthorizationLease _lease() => AuthorizationLease(
  accountId: 'account',
  deviceId: _local,
  enrollmentId: 'credential',
  fetchSnapshot: () async => AuthorizationSnapshot.fromJson(_snapshot()),
);

void main() {
  test(
    'openStream delegates to the inner link, writing the same StreamOpen '
    'and wiring both halves through',
    () async {
      final lease = _lease();
      addTearDown(lease.dispose);
      expect(await lease.refresh(), isTrue);
      final inner = _FakeMultiStreamLink();
      final link = _leased(inner, lease);
      addTearDown(link.close);

      const open = ProjectStreamOpen('proj-1');
      final stream = await link.openStream(
        open,
        maxRecordBytes: 4096,
        maxQueuedBytes: 4096,
      );
      expect(inner.lastOpen, open);

      final received = <Uint8List>[];
      stream.records.listen(received.add);
      inner.lastStream!.emit(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      expect(received, [
        Uint8List.fromList([1]),
      ]);

      await stream.send(Uint8List.fromList([2]));
      expect(inner.lastStream!.sent, [
        Uint8List.fromList([2]),
      ]);
    },
  );

  test(
    'a lease revoked after a stream is open silences its records and refuses '
    'new sends, without itself resetting the native stream',
    () async {
      final lease = _lease();
      addTearDown(lease.dispose);
      expect(await lease.refresh(), isTrue);
      final inner = _FakeMultiStreamLink();
      final link = _leased(inner, lease);
      addTearDown(link.close);

      final stream = await link.openStream(
        const ProjectStreamOpen('p'),
        maxRecordBytes: 1024,
        maxQueuedBytes: 1024,
      );
      final received = <Uint8List>[];
      stream.records.listen(received.add);

      lease.invalidate();
      expect(link.isDispatchAllowed, isFalse);

      inner.lastStream!.emit(Uint8List.fromList([9]));
      await Future<void>.delayed(Duration.zero);
      expect(
        received,
        isEmpty,
        reason: 'the lease fence filters records once revoked',
      );
      expect(
        await stream.send(Uint8List.fromList([1])),
        PeerSendOutcome.closed,
      );
      expect(
        inner.lastStream!.resetCalls,
        0,
        reason:
            'revocation silences the wrapper; resetting the native stream '
            'stays the caller\'s decision, same as PeerLink.close',
      );
    },
  );

  test('openStream throws when the lease is already invalid', () async {
    final lease = _lease();
    addTearDown(lease.dispose);
    // Never refreshed, so isDispatchAllowed is false from construction.
    final inner = _FakeMultiStreamLink();
    final link = _leased(inner, lease);
    addTearDown(link.close);

    await expectLater(
      link.openStream(
        const SessionStreamOpen(),
        maxRecordBytes: 1024,
        maxQueuedBytes: 1024,
      ),
      throwsA(
        isA<PeerConnectionFailure>().having(
          (e) => e.code,
          'code',
          'AUTHORIZATION_DENIED',
        ),
      ),
    );
  });

  test(
    'a lease revoked while the inner open is in flight resets the returned '
    'stream and refuses it to the caller',
    () async {
      final lease = _lease();
      addTearDown(lease.dispose);
      expect(await lease.refresh(), isTrue);
      final inner = _FakeMultiStreamLink()
        ..invalidateDuringOpen = lease.invalidate;
      final link = _leased(inner, lease);
      addTearDown(link.close);

      await expectLater(
        link.openStream(
          const ProjectStreamOpen('p'),
          maxRecordBytes: 1024,
          maxQueuedBytes: 1024,
        ),
        throwsA(
          isA<PeerConnectionFailure>().having(
            (e) => e.code,
            'code',
            'AUTHORIZATION_DENIED',
          ),
        ),
      );
      expect(inner.lastStream!.resetCalls, 1);
    },
  );
}
