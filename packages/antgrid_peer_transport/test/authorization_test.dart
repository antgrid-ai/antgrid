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

class _Scheduled implements LeaseScheduleHandle {
  _Scheduled(this.dueMs, this.callback);
  final int dueMs;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

class _FakeScheduler {
  int nowMs = 0;
  final tasks = <_Scheduled>[];
  LeaseScheduleHandle schedule(Duration delay, void Function() callback) {
    final task = _Scheduled(nowMs + delay.inMilliseconds, callback);
    tasks.add(task);
    return task;
  }

  void elapse(int milliseconds) {
    final target = nowMs + milliseconds;
    while (true) {
      final due = tasks
          .where((task) => !task.cancelled && task.dueMs <= target)
          .toList()
        ..sort((a, b) => a.dueMs.compareTo(b.dueMs));
      if (due.isEmpty) break;
      final task = due.first;
      task.cancelled = true;
      nowMs = task.dueMs;
      task.callback();
    }
    nowMs = target;
  }

  List<int> get activeDelays => tasks
      .where((task) => !task.cancelled)
      .map((task) => task.dueMs - nowMs)
      .toList()
    ..sort();
}

void main() {
  test(
    'resume admission waits for fresh authorization, not the old request',
    () async {
      final old = Completer<AuthorizationSnapshot>();
      final fresh = Completer<AuthorizationSnapshot>();
      var calls = 0;
      final lease = AuthorizationLease(
        accountId: 'account',
        deviceId: local,
        enrollmentId: 'credential',
        fetchSnapshot: () => ++calls == 1 ? old.future : fresh.future,
      );
      addTearDown(lease.dispose);
      final beforeResume = lease.refresh();
      final resume = lease.refreshFresh();
      final admission = lease.refresh();
      var admissionFinished = false;
      admission.then((_) => admissionFinished = true);
      old.complete(AuthorizationSnapshot.fromJson(snapshot()));
      expect(await beforeResume, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(admissionFinished, isFalse);
      expect(lease.permits(peer), isFalse);
      expect(calls, 2);
      fresh.complete(AuthorizationSnapshot.fromJson(snapshot()));
      expect(await resume, isTrue);
      expect(await admission, isTrue);
      expect(lease.permits(peer), isTrue);
    },
  );

  test(
    'overlapping fresh requests share admission and remain revocation fenced',
    () async {
      final fresh = Completer<AuthorizationSnapshot>();
      var calls = 0;
      final lease = AuthorizationLease(
        accountId: 'account',
        deviceId: local,
        enrollmentId: 'credential',
        fetchSnapshot: () {
          calls++;
          return fresh.future;
        },
      );
      addTearDown(lease.dispose);
      final a = lease.refreshFresh();
      await Future<void>.delayed(Duration.zero);
      final b = lease.refreshFresh();
      final admission = lease.refresh();
      lease.notePolicyGeneration(BigInt.two);
      fresh.complete(AuthorizationSnapshot.fromJson(snapshot()));
      expect(await a, isFalse);
      expect(await b, isFalse);
      expect(await admission, isFalse);
      expect(calls, 1);
      expect(lease.permits(peer), isFalse);
    },
  );

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

  test('refreshes after one third of the accepted lease with jitter', () async {
    final clock = _FakeScheduler();
    var calls = 0;
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: local,
      enrollmentId: 'credential',
      nowMs: () => clock.nowMs,
      schedule: clock.schedule,
      random: () => 0.5,
      fetchSnapshot: () async {
        calls++;
        return AuthorizationSnapshot.fromJson(snapshot());
      },
    );
    lease.startRefreshing();
    expect(await lease.refresh(), isTrue);
    expect(clock.activeDelays, containsAll([20000, 60000]));
    clock.elapse(19999);
    expect(calls, 1);
    clock.elapse(1);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    await lease.dispose();
  });

  test('transient refresh failures retry without extending the deadline', () async {
    final clock = _FakeScheduler();
    var calls = 0;
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: local,
      enrollmentId: 'credential',
      nowMs: () => clock.nowMs,
      schedule: clock.schedule,
      random: () => 0.5,
      fetchSnapshot: () async {
        calls++;
        if (calls == 2) throw StateError('backend unavailable');
        return AuthorizationSnapshot.fromJson(snapshot());
      },
    );
    lease.startRefreshing();
    expect(await lease.refresh(), isTrue);
    clock.elapse(20000);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    expect(lease.remainingMs, 40000);
    expect(clock.activeDelays, contains(500));
    clock.elapse(500);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 3);
    expect(lease.remainingMs, 60000);
    await lease.dispose();
  });

  test('request timeout is bounded by remaining lease and late data is fenced', () async {
    final clock = _FakeScheduler();
    final late = Completer<AuthorizationSnapshot>();
    var calls = 0;
    final lease = AuthorizationLease(
      accountId: 'account',
      deviceId: local,
      enrollmentId: 'credential',
      nowMs: () => clock.nowMs,
      schedule: clock.schedule,
      random: () => 0.5,
      fetchSnapshot: () {
        calls++;
        if (calls == 1) {
          return Future.value(
            AuthorizationSnapshot.fromJson({...snapshot(), 'leaseMs': 10}),
          );
        }
        return late.future;
      },
    );
    expect(await lease.refresh(), isTrue);
    clock.elapse(9);
    expect(await lease.refresh(), isFalse);
    clock.elapse(1);
    expect(lease.isValid, isFalse);
    late.complete(AuthorizationSnapshot.fromJson(snapshot(policy: '2')));
    await Future<void>.delayed(Duration.zero);
    expect(lease.isValid, isFalse);
    await lease.dispose();
  });
}
