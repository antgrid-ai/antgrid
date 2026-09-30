import 'package:antgrid/connection/peer_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_peer_runtime.dart';

PeerRuntime _runtime({required bool fenceOnResume}) => PeerRuntime(
  record: leaseRecord(),
  licenseApiUrl: 'https://api.test',
  mintToken: () async => 'token',
  rejectToken: (_) => false,
  fenceOnResume: fenceOnResume,
  httpClient: MockClient((_) async => http.Response(leaseSnapshotJson, 200)),
);

void main() {
  test(
    'a desktop resume refreshes without dropping the current lease',
    () async {
      final runtime = _runtime(fenceOnResume: false);
      addTearDown(runtime.dispose);
      expect(await runtime.lease.refresh(), isTrue);
      final resumed = runtime.resume();
      expect(runtime.lease.permits(leasePeerId), isTrue);
      expect(await resumed, isTrue);
      expect(runtime.lease.permits(leasePeerId), isTrue);
    },
  );

  test('a phone resume drops the current lease until a fresh answer', () async {
    final runtime = _runtime(fenceOnResume: true);
    addTearDown(runtime.dispose);
    expect(await runtime.lease.refresh(), isTrue);
    final resumed = runtime.resume();
    expect(runtime.lease.permits(leasePeerId), isFalse);
    expect(await resumed, isTrue);
    expect(runtime.lease.permits(leasePeerId), isTrue);
  });
}
