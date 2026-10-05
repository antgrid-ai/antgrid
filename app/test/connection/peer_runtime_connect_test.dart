import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_peer_runtime.dart';

final _peerKey = base64Encode(List.filled(32, 1));
final _peerEndpoint = 'ab' * 32;

Future<String> _localEndpointId() async {
  final key = await Ed25519().newKeyPairFromSeed(Uint8List(32));
  final pub = await key.extractPublicKey();
  return pub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _snapshotJson(String localEndpointId) => jsonEncode({
  'accountId': 'account',
  'deviceId': leaseDeviceId,
  'enrollmentId': 'credential',
  'policyGeneration': '1',
  'registrationGeneration': '1',
  'allowed': true,
  'leaseMs': 60000,
  'endpoint': {'endpointId': localEndpointId, 'generation': '1'},
  'relayUrls': <String>[],
  'peers': [
    {
      'deviceId': leasePeerId,
      'ed25519Pub': _peerKey,
      'endpoint': {'endpointId': _peerEndpoint, 'generation': '1'},
    },
  ],
});

class _FakeLink implements PeerLink {
  bool closed = false;
  @override
  bool get isDispatchAllowed => !closed;
  @override
  Stream<IncomingSessionRecord> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  PeerLinkDiagnostic? get netTap => null;
  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async =>
      PeerSendOutcome.accepted;
  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) => throw UnimplementedError('not exercised by this suite');
  @override
  Future<void> close() async => closed = true;
}

/// Answers the first authorization request at once and parks every later one
/// on [held], so a refetch cannot restore the lease before connect judges it.
class _Harness {
  _Harness._(this.runtime);
  final PeerRuntime runtime;
  final held = Completer<void>();
  final link = _FakeLink();

  static Future<_Harness> create(
    Future<void> Function(_Harness harness, bool Function() authorized) onDial,
  ) async {
    final snapshot = _snapshotJson(await _localEndpointId());
    late final _Harness harness;
    var requests = 0;
    final runtime = PeerRuntime(
      record: leaseRecord(),
      licenseApiUrl: 'https://api.test',
      mintToken: () async => 'token',
      rejectToken: (_) => false,
      fenceOnResume: true,
      httpClient: MockClient((_) async {
        if (requests++ > 0) await harness.held.future;
        return http.Response(snapshot, 200);
      }),
      dialerFor: (_) async =>
          ({required endpointId, required authorized, diagnostic}) async {
            await onDial(harness, authorized);
            return harness.link;
          },
    );
    harness = _Harness._(runtime);
    addTearDown(runtime.dispose);
    return harness;
  }

  Future<PeerLink> connect() => runtime.connect(
    attempt: PeerConnectionAttempt(),
    machineDeviceId: leasePeerId,
    machinePublicKey: _peerKey,
  );
}

Matcher _retryableAuthorizationChange() => isA<PeerConnectionFailure>()
    .having((f) => f.code, 'code', 'AUTHORIZATION_CHANGED_DURING_CONNECT')
    .having((f) => f.terminal, 'terminal', isFalse)
    .having((f) => f.retryable, 'retryable', isTrue);

void main() {
  test('a phone resume that drops the lease mid-dial is retryable', () async {
    Future<bool>? resumed;
    final harness = await _Harness.create((harness, authorized) async {
      expect(authorized(), isTrue);
      resumed = harness.runtime.resume();
      expect(authorized(), isFalse);
    });

    await expectLater(
      harness.connect(),
      throwsA(_retryableAuthorizationChange()),
    );
    expect(harness.link.closed, isTrue);

    harness.held.complete();
    expect(await resumed, isTrue);
    expect(harness.runtime.lease.permits(leasePeerId), isTrue);
  });

  test('a pushed policy change mid-dial is retryable', () async {
    final harness = await _Harness.create((harness, authorized) async {
      expect(authorized(), isTrue);
      harness.runtime.notePolicyGeneration(BigInt.two);
      expect(authorized(), isFalse);
    });

    await expectLater(
      harness.connect(),
      throwsA(_retryableAuthorizationChange()),
    );
    expect(harness.link.closed, isTrue);
  });

  Matcher disposedAfterConnect() => isA<PeerConnectionFailure>()
      .having((f) => f.code, 'code', 'DISPOSED_AFTER_CONNECT')
      .having((f) => f.terminal, 'terminal', isTrue);

  test('disposal that lands inside the dial stays terminal', () async {
    Future<bool>? disposing;
    final harness = await _Harness.create((harness, authorized) async {
      disposing = harness.runtime.dispose();
      // The real dial fails a lapsed lease with this retryable code.
      if (!authorized()) throw authorizationChangedDuringConnect;
    });

    await expectLater(harness.connect(), throwsA(disposedAfterConnect()));
    await disposing;
  });

  test('disposal after the dial returned stays terminal', () async {
    Future<bool>? disposing;
    final harness = await _Harness.create((harness, authorized) async {
      disposing = harness.runtime.dispose();
    });

    await expectLater(harness.connect(), throwsA(disposedAfterConnect()));
    expect(harness.link.closed, isTrue);
    await disposing;
  });

  test('a registration not yet visible after register is retryable', () async {
    final localEndpointId = await _localEndpointId();
    final unregistered = jsonEncode({
      'accountId': 'account',
      'deviceId': leaseDeviceId,
      'enrollmentId': 'credential',
      'policyGeneration': '1',
      'registrationGeneration': '0',
      'allowed': true,
      'leaseMs': 60000,
      'endpoint': null,
      'relayUrls': <String>[],
      'peers': [
        {'deviceId': leasePeerId, 'ed25519Pub': _peerKey, 'endpoint': null},
      ],
    });
    final runtime = PeerRuntime(
      record: leaseRecord(),
      licenseApiUrl: 'https://api.test',
      mintToken: () async => 'token',
      rejectToken: (_) => false,
      httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/account/devices/me/endpoint-challenge':
            return http.Response(
              jsonEncode({
                'challengeId': '00000000-0000-4000-8000-0000000000aa',
                'challenge': '${'A' * 43}=',
                'accountId': 'account',
                'deviceId': leaseDeviceId,
                'enrollmentId': 'credential',
                'endpointId': localEndpointId,
                'expectedGeneration': '0',
              }),
              200,
            );
          case '/account/devices/me/endpoint-registration':
            return http.Response(
              jsonEncode({'endpointId': localEndpointId, 'generation': '1'}),
              200,
            );
          default:
            // The refetch after register is answered from before the
            // registration committed.
            return http.Response(unregistered, 200);
        }
      }),
    );
    addTearDown(runtime.dispose);

    await expectLater(
      runtime.connect(
        attempt: PeerConnectionAttempt(),
        machineDeviceId: leasePeerId,
        machinePublicKey: _peerKey,
      ),
      throwsA(_retryableAuthorizationChange()),
    );
  });

  test('a dial that stays authorized returns a leased link', () async {
    final harness = await _Harness.create((harness, authorized) async {});

    final result = await harness.connect();
    addTearDown(result.close);

    expect(result, isA<LeasedPeerLink>());
    expect(result.isDispatchAllowed, isTrue);
    expect(harness.link.closed, isFalse);
  });
}
