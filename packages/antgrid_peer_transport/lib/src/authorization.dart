import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'relay_origin.dart';

const int peerIdentityMaxChars = 256;
const int maxAuthorizedPeers = 1024;
const int maxPeerRelayUrls = 16;
const String maxPeerGeneration = '9223372036854775807';
const int maxPeerLeaseMs = 60000;

void _exact(Map<String, dynamic> json, List<String> keys) {
  if (json.length != keys.length || keys.any((key) => !json.containsKey(key))) {
    throw const FormatException('Unexpected authorization fields');
  }
}

void _uuid(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value)) {
    throw const FormatException('Invalid device identity');
  }
}

BigInt parseGeneration(Object? value) {
  if (value is! String || !RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(value)) {
    throw const FormatException('Invalid generation');
  }
  final number = BigInt.parse(value);
  if (number > BigInt.parse(maxPeerGeneration)) {
    throw const FormatException('Generation out of range');
  }
  return number;
}

Uint8List endpointChallengeBytes(Map<String, dynamic> challenge) {
  _exact(challenge, [
    'challengeId',
    'challenge',
    'accountId',
    'deviceId',
    'enrollmentId',
    'endpointId',
    'expectedGeneration',
  ]);
  _uuid(challenge['challengeId']);
  _uuid(challenge['deviceId']);
  for (final name in ['accountId', 'enrollmentId']) {
    final value = challenge[name] as String;
    if (value.isEmpty || value.length > 256)
      throw const FormatException('Invalid identity');
  }
  if (!RegExp(
        r'^[A-Za-z0-9+/]{43}=$',
      ).hasMatch(challenge['challenge'] as String) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(challenge['endpointId'] as String)) {
    throw const FormatException('Invalid challenge');
  }
  parseGeneration(challenge['expectedGeneration']);
  final fields = [
    'antgrid/endpoint-registration/1',
    for (final name in [
      'challengeId',
      'challenge',
      'accountId',
      'deviceId',
      'enrollmentId',
      'endpointId',
      'expectedGeneration',
    ])
      challenge[name] as String,
  ];
  final builder = BytesBuilder(copy: false);
  for (final field in fields) {
    final bytes = utf8.encode(field);
    builder.add(
      (ByteData(
        4,
      )..setUint32(0, bytes.length, Endian.big)).buffer.asUint8List(),
    );
    builder.add(bytes);
  }
  return builder.takeBytes();
}

class PeerRegistration {
  PeerRegistration(this.endpointId, this.generation);
  factory PeerRegistration.fromJson(Map<String, dynamic> json) {
    _exact(json, ['endpointId', 'generation']);
    final endpointId = json['endpointId'] as String;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(endpointId)) {
      throw const FormatException('Invalid endpoint');
    }
    return PeerRegistration(endpointId, parseGeneration(json['generation']));
  }
  final String endpointId;
  final BigInt generation;
}

class AuthorizedPeer {
  AuthorizedPeer(this.deviceId, this.ed25519Pub, this.endpoint);
  final String deviceId;
  final String ed25519Pub;
  final PeerRegistration? endpoint;
}

class AuthorizationSnapshot {
  AuthorizationSnapshot.fromJson(Map<String, dynamic> json)
    : accountId = json['accountId'] as String,
      deviceId = json['deviceId'] as String,
      enrollmentId = json['enrollmentId'] as String,
      policyGeneration = parseGeneration(json['policyGeneration']),
      registrationGeneration = parseGeneration(json['registrationGeneration']),
      allowed = json['allowed'] as bool,
      leaseMs = json['leaseMs'] as int,
      endpoint = json['endpoint'] == null
          ? null
          : PeerRegistration.fromJson(
              Map<String, dynamic>.from(json['endpoint'] as Map),
            ),
      peers = List.unmodifiable(
        (json['peers'] as List).map((value) {
          final peer = Map<String, dynamic>.from(value as Map);
          _exact(peer, ['deviceId', 'ed25519Pub', 'endpoint']);
          _uuid(peer['deviceId']);
          final key = peer['ed25519Pub'] as String;
          if (base64Decode(key).length != 32)
            throw const FormatException('Invalid key');
          return AuthorizedPeer(
            peer['deviceId'] as String,
            key,
            peer['endpoint'] == null
                ? null
                : PeerRegistration.fromJson(
                    Map<String, dynamic>.from(peer['endpoint'] as Map),
                  ),
          );
        }),
      ),
      relayUrls = List.unmodifiable(
        (json['relayUrls'] as List).cast<String>(),
      ) {
    _exact(json, [
      'accountId',
      'deviceId',
      'enrollmentId',
      'policyGeneration',
      'registrationGeneration',
      'allowed',
      'leaseMs',
      'endpoint',
      'peers',
      'relayUrls',
    ]);
    _uuid(deviceId);
    if (accountId.isEmpty ||
        accountId.length > peerIdentityMaxChars ||
        enrollmentId.isEmpty ||
        enrollmentId.length > peerIdentityMaxChars)
      throw const FormatException('Invalid identity');
    if (leaseMs < 0 ||
        leaseMs > maxPeerLeaseMs ||
        peers.length > maxAuthorizedPeers ||
        relayUrls.length > maxPeerRelayUrls) {
      throw const FormatException('Invalid authorization bounds');
    }
    for (final url in relayUrls) {
      if (!isApprovedRelayOrigin(url)) {
        throw const FormatException('Invalid approved relay');
      }
    }
  }
  final String accountId, deviceId, enrollmentId;
  final BigInt policyGeneration, registrationGeneration;
  final bool allowed;
  final int leaseMs;
  final PeerRegistration? endpoint;
  final List<AuthorizedPeer> peers;
  final List<String> relayUrls;
}

class PeerAuthorizationDenied implements Exception {
  const PeerAuthorizationDenied();
}

abstract interface class LeaseScheduleHandle {
  void cancel();
}

typedef LeaseScheduler =
    LeaseScheduleHandle Function(Duration delay, void Function() callback);

class _TimerScheduleHandle implements LeaseScheduleHandle {
  _TimerScheduleHandle(Duration delay, void Function() callback)
    : _timer = Timer(delay, callback);
  final Timer _timer;
  @override
  void cancel() => _timer.cancel();
}

/// An authenticated HTTP client is injected. The wall clock never extends a
/// lease, but can end one: on most platforms the monotonic clock stops across
/// a device suspend, and alone would carry a lease through a sleep of any length.
class AuthorizationLease {
  AuthorizationLease({
    required this.accountId,
    required this.deviceId,
    required this.enrollmentId,
    required this.fetchSnapshot,
    int Function()? nowMs,
    LeaseScheduler? schedule,
    double Function()? random,
    int Function()? wallMs,
  }) {
    final stopwatch = Stopwatch()..start();
    _nowMs = nowMs ?? () => stopwatch.elapsedMilliseconds;
    _wallMs = wallMs ?? () => DateTime.now().millisecondsSinceEpoch;
    _schedule = schedule ?? _TimerScheduleHandle.new;
    _random = random ?? math.Random.secure().nextDouble;
  }
  final String accountId, deviceId, enrollmentId;
  final Future<AuthorizationSnapshot> Function() fetchSnapshot;
  late final int Function() _nowMs;
  late final int Function() _wallMs;
  late final LeaseScheduler _schedule;
  late final double Function() _random;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  AuthorizationSnapshot? _snapshot;
  AuthorizationSnapshot? get snapshot => isValid ? _snapshot : null;
  BigInt? _policy;
  int _deadline = 0;
  int _wallDeadline = 0;
  int _generation = 0;
  int _policyChanges = 0;
  bool _disposed = false;
  LeaseScheduleHandle? _expiry, _refresh;
  bool _refreshing = false;
  int _retryAttempt = 0;
  Future<bool>? _pending;
  Future<bool>? _freshPending;
  Object? lastRefreshFailure;
  bool get isValid =>
      !_disposed && _snapshot?.allowed == true && _leftMs() > 0;
  int get remainingMs => math.max(0, _leftMs());
  int _leftMs() =>
      math.min(_deadline - _nowMs(), _wallDeadline - _wallMs());

  bool permits(String peerId, {String? endpointId, BigInt? generation}) =>
      isValid &&
      _snapshot!.peers.any(
        (peer) =>
            peer.deviceId == peerId &&
            (endpointId == null ||
                (peer.endpoint?.endpointId == endpointId &&
                    peer.endpoint?.generation == generation)),
      );

  Future<bool> refresh() => _freshPending ?? _refreshCurrent();

  Future<bool> _refreshCurrent() =>
      _pending ??= _refreshUntilCurrent().whenComplete(() => _pending = null);

  /// Every caller joined to the request gets an answer from after the last
  /// pushed policy change, not the one that change superseded.
  Future<bool> _refreshUntilCurrent() async {
    while (true) {
      final outcome = await _runRefresh();
      if (outcome != null) return outcome;
    }
  }

  /// Null when a policy change pushed while in flight superseded the answer.
  Future<bool?> _runRefresh() async {
    lastRefreshFailure = null;
    final generation = _generation;
    final policyChanges = _policyChanges;
    final start = _nowMs();
    final startWall = _wallMs();
    final timeoutMs = isValid ? math.min(10000, remainingMs) : 10000;
    if (timeoutMs <= 0) {
      invalidate();
      return false;
    }
    try {
      final result = await fetchSnapshot().timeout(
        Duration(milliseconds: timeoutMs),
      );
      if (_disposed || generation != _generation) return false;
      final stale = _policy != null && result.policyGeneration < _policy!;
      // Read before a policy change that was pushed while it was in flight:
      // superseded, not denied.
      if (stale && policyChanges != _policyChanges) return null;
      if (result.accountId != accountId ||
          result.deviceId != deviceId ||
          result.enrollmentId != enrollmentId ||
          stale) {
        lastRefreshFailure = const PeerAuthorizationDenied();
        invalidate();
        return false;
      }
      _policy = result.policyGeneration;
      final deadline = start + result.leaseMs;
      final wallDeadline = startWall + result.leaseMs;
      if (!result.allowed ||
          _nowMs() >= deadline ||
          _wallMs() >= wallDeadline) {
        if (!result.allowed)
          lastRefreshFailure = const PeerAuthorizationDenied();
        invalidate();
        return false;
      }
      _snapshot = result;
      _deadline = deadline;
      _wallDeadline = wallDeadline;
      _expiry?.cancel();
      _expiry = _schedule(Duration(milliseconds: remainingMs), invalidate);
      _retryAttempt = 0;
      if (_refreshing) _scheduleNormalRefresh(result.leaseMs);
      _changes.add(null);
      return true;
    } catch (error) {
      // An error carries no policy generation, so one that lands after a policy
      // change cannot show which side of it the server answered from.
      if (_disposed || generation != _generation) return false;
      if (policyChanges != _policyChanges) return null;
      lastRefreshFailure = error;
      if (error is PeerAuthorizationDenied || error is FormatException) {
        invalidate();
        return false;
      }
      // A failed refresh cannot extend the last authoritative deadline.
      if (!isValid && !_disposed) {
        invalidate();
      } else if (_refreshing) {
        _scheduleTransientRetry();
      }
      return false;
    }
  }

  int _jittered(int milliseconds) {
    final factor = 0.9 + 0.2 * _random().clamp(0.0, 1.0);
    return math.max(1, (milliseconds * factor).round());
  }

  void _scheduleRefresh(int delayMs) {
    _refresh?.cancel();
    final bounded = math.min(delayMs, remainingMs);
    if (!_refreshing || !isValid || bounded <= 0) {
      _refresh = null;
      return;
    }
    _refresh = _schedule(Duration(milliseconds: bounded), () {
      _refresh = null;
      unawaited(refresh());
    });
  }

  void _scheduleNormalRefresh(int leaseMs) {
    _scheduleRefresh(_jittered(math.max(1, leaseMs ~/ 3)));
  }

  void _scheduleTransientRetry() {
    final exponent = math.min(_retryAttempt++, 4);
    final baseMs = math.min(500 * (1 << exponent), 5000);
    _scheduleRefresh(_jittered(baseMs));
  }

  /// Drops the current snapshot but lets a request already in flight finish:
  /// its answer is judged by the policy generation the server read, so one
  /// that already reflects this change is kept. Fencing it by request instead
  /// discarded the answer to this device's own endpoint registration, whose
  /// policy change is pushed back to it while that answer is still on the way.
  void notePolicyGeneration(BigInt generation) {
    if (_disposed || (_policy != null && generation <= _policy!)) return;
    _policy = generation;
    _policyChanges++;
    _dropSnapshot();
  }

  Future<bool> refreshFresh() {
    final existing = _freshPending;
    if (existing != null) return existing;
    final result = Completer<bool>();
    // Publish before invalidation: synchronous lease listeners may immediately
    // request admission, which must wait for the post-resume snapshot.
    _freshPending = result.future;
    invalidate();
    final generation = _generation;
    result.complete(_refreshAfterPending(generation));
    return result.future.whenComplete(() => _freshPending = null);
  }

  Future<bool> _refreshAfterPending(int generation) async {
    await _pending;
    if (_disposed || generation != _generation) return false;
    return _refreshCurrent();
  }

  void startRefreshing() {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    final leaseMs = _snapshot?.leaseMs;
    if (leaseMs != null && isValid) _scheduleNormalRefresh(leaseMs);
  }

  void stopRefreshing() {
    _refreshing = false;
    _refresh?.cancel();
    _refresh = null;
  }

  /// Resume/revocation fences every response already in flight.
  void invalidate() {
    if (_disposed) return;
    _generation++;
    _dropSnapshot();
  }

  void _dropSnapshot() {
    if (_disposed) return;
    _snapshot = null;
    _deadline = 0;
    _wallDeadline = 0;
    _expiry?.cancel();
    _expiry = null;
    _refresh?.cancel();
    _refresh = null;
    _changes.add(null);
  }

  Future<void> dispose() async {
    invalidate();
    _disposed = true;
    stopRefreshing();
    await _changes.close();
  }
}
