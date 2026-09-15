import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';

const local = '00000000-0000-4000-8000-000000000001';
const peer = '00000000-0000-4000-8000-000000000002';
Map<String, dynamic> snapshot({String policy = '1', bool allowed = true}) => {
  'accountId': 'account',
  'deviceId': local,
  'enrollmentId': 'credential',
  'registrationGeneration': '0',
  'policyGeneration': policy,
  'allowed': allowed,
  'leaseMs': 60000,
  'endpoint': null,
  'relayUrls': <String>[],
  'peers': [
    {
      'deviceId': peer,
      'ed25519Pub': base64Encode(List.filled(32, 1)),
      'endpoint': null,
    },
  ],
};

void main() {
  test(
    'stale denied response cannot overwrite a newer lifecycle fence',
    () async {
      final pending = Completer<AuthorizationSnapshot>();
      final lease = AuthorizationLease(
        accountId: 'account',
        deviceId: local,
        enrollmentId: 'credential',
        fetchSnapshot: () => pending.future,
      );
      var changes = 0;
      final sub = lease.changes.listen((_) => changes++);
      final refresh = lease.refresh();
      lease.notePolicyGeneration(BigInt.two);
      expect(changes, 1);
      pending.completeError(const PeerAuthorizationDenied());
      expect(await refresh, isFalse);
      expect(changes, 1);
      expect(lease.lastRefreshFailure, isNull);
      await sub.cancel();
      await lease.dispose();
    },
  );
  test('central policy highwater rejects older HTTP snapshots', () async {
    var response = snapshot(policy: '1');
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: local,
      enrollmentId: 'credential',
      fetchSnapshot: () async => AuthorizationSnapshot.fromJson(response),
    );
    expect(await lease.refresh(), isTrue);
    lease.notePolicyGeneration(BigInt.two);
    expect(lease.isValid, isFalse);
    expect(await lease.refresh(), isFalse);
    response = snapshot(policy: '2');
    expect(await lease.refresh(), isTrue);
    lease.notePolicyGeneration(BigInt.one);
    expect(lease.isValid, isTrue);
    await lease.dispose();
  });
  test('decimal generations retain precision and reject alternate forms', () {
    expect(
      parseGeneration('9007199254740993'),
      BigInt.parse('9007199254740993'),
    );
    for (final value in [1, '01', '-1', '1e2', '9223372036854775808']) {
      expect(() => parseGeneration(value), throwsFormatException);
    }
  });
  test('delayed authorization cannot add lease time', () async {
    var now = 0;
    final response = Completer<AuthorizationSnapshot>();
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: local,
      enrollmentId: 'credential',
      nowMs: () => now,
      fetchSnapshot: () => response.future,
    );
    final pending = lease.refresh();
    now = 59999;
    response.complete(AuthorizationSnapshot.fromJson(snapshot()));
    expect(await pending, isTrue);
    expect(lease.permits(peer), isTrue);
    now = 60000;
    expect(lease.permits(peer), isFalse);
    await lease.dispose();
  });
  test(
    'refresh serialization and invalidation fence an in-flight response',
    () async {
      var calls = 0;
      final response = Completer<AuthorizationSnapshot>();
      final lease = AuthorizationLease(
        accountId: 'account',
        deviceId: local,
        enrollmentId: 'credential',
        fetchSnapshot: () {
          calls++;
          return response.future;
        },
      );
      final a = lease.refresh();
      final b = lease.refresh();
      expect(calls, 1);
      lease.invalidate();
      response.complete(AuthorizationSnapshot.fromJson(snapshot()));
      expect(await a, isFalse);
      expect(await b, isFalse);
      expect(lease.isValid, isFalse);
      await lease.dispose();
    },
  );
  test('a stale policy snapshot closes the authoritative lease', () async {
    var response = snapshot(policy: '2');
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: local,
      enrollmentId: 'credential',
      fetchSnapshot: () async => AuthorizationSnapshot.fromJson(response),
    );
    expect(await lease.refresh(), isTrue);
    response = snapshot(policy: '1');
    expect(await lease.refresh(), isFalse);
    expect(lease.isValid, isFalse);
    await lease.dispose();
  });
}
