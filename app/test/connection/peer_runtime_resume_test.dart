import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _device = '00000000-0000-4000-8000-000000000001';
const _peer = '00000000-0000-4000-8000-000000000002';

PeerRuntime _runtime({required bool fenceOnResume}) => PeerRuntime(
  record: DeviceRecord(
    userId: 'account',
    deviceUuid: _device,
    clientId: 'credential',
    clientSecret: 'secret',
    ed25519Pub: base64Encode(Uint8List(32)),
    ed25519Priv: base64Encode(Uint8List(32)),
    x25519Pub: '',
    x25519Priv: '',
    endpointSecret: base64Encode(Uint8List(32)),
  ),
  licenseApiUrl: 'https://api.test',
  mintToken: () async => 'token',
  fenceOnResume: fenceOnResume,
  httpClient: MockClient(
    (_) async => http.Response(
      jsonEncode({
        'accountId': 'account',
        'deviceId': _device,
        'enrollmentId': 'credential',
        'registrationGeneration': '0',
        'policyGeneration': '1',
        'allowed': true,
        'leaseMs': 60000,
        'endpoint': null,
        'relayUrls': <String>[],
        'peers': [
          {
            'deviceId': _peer,
            'ed25519Pub': base64Encode(List.filled(32, 1)),
            'endpoint': null,
          },
        ],
      }),
      200,
    ),
  ),
);

void main() {
  test('a desktop resume refreshes without dropping the current lease', () async {
    final runtime = _runtime(fenceOnResume: false);
    addTearDown(runtime.dispose);
    expect(await runtime.lease.refresh(), isTrue);
    final resumed = runtime.resume();
    expect(runtime.lease.permits(_peer), isTrue);
    expect(await resumed, isTrue);
    expect(runtime.lease.permits(_peer), isTrue);
  });

  test('a phone resume drops the current lease until a fresh answer', () async {
    final runtime = _runtime(fenceOnResume: true);
    addTearDown(runtime.dispose);
    expect(await runtime.lease.refresh(), isTrue);
    final resumed = runtime.resume();
    expect(runtime.lease.permits(_peer), isFalse);
    expect(await resumed, isTrue);
    expect(runtime.lease.permits(_peer), isTrue);
  });
}
