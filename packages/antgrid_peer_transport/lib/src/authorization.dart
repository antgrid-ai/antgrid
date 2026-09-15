import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
  if (number > BigInt.parse('9223372036854775807')) {
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
        accountId.length > 256 ||
        enrollmentId.isEmpty ||
        enrollmentId.length > 256)
      throw const FormatException('Invalid identity');
    if (leaseMs < 0 ||
        leaseMs > 60000 ||
        peers.length > 1024 ||
        relayUrls.length > 16) {
      throw const FormatException('Invalid authorization bounds');
    }
    for (final url in relayUrls) {
      final uri = Uri.parse(url);
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path != '' && uri.path != '/')) {
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

/// An authenticated HTTP client is injected; wall-clock dates never extend a lease.
class AuthorizationLease {
  AuthorizationLease({
    required this.accountId,
    required this.deviceId,
    required this.enrollmentId,
    required this.fetchSnapshot,
    int Function()? nowMs,
  }) {
    final stopwatch = Stopwatch()..start();
    _nowMs = nowMs ?? () => stopwatch.elapsedMilliseconds;
  }
  final String accountId, deviceId, enrollmentId;
  final Future<AuthorizationSnapshot> Function() fetchSnapshot;
  late final int Function() _nowMs;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  AuthorizationSnapshot? _snapshot;
  AuthorizationSnapshot? get snapshot => isValid ? _snapshot : null;
  BigInt? _policy;
  int _deadline = 0;
  int _generation = 0;
  bool _disposed = false;
  Timer? _expiry, _refresh;
  Future<bool>? _pending;
  Future<bool>? _freshPending;
  Object? lastRefreshFailure;
  bool get isValid =>
      !_disposed && _snapshot?.allowed == true && _nowMs() < _deadline;

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
      _pending ??= _runRefresh().whenComplete(() => _pending = null);
  Future<bool> _runRefresh() async {
    lastRefreshFailure = null;
    final generation = _generation;
    final start = _nowMs();
    try {
      final result = await fetchSnapshot().timeout(const Duration(seconds: 60));
      if (_disposed || generation != _generation) return false;
      if (result.accountId != accountId ||
          result.deviceId != deviceId ||
          result.enrollmentId != enrollmentId ||
          (_policy != null && result.policyGeneration < _policy!)) {
        lastRefreshFailure = const PeerAuthorizationDenied();
        invalidate();
        return false;
      }
      _policy = result.policyGeneration;
      final deadline = start + result.leaseMs;
      if (!result.allowed || _nowMs() >= deadline) {
        if (!result.allowed)
          lastRefreshFailure = const PeerAuthorizationDenied();
        invalidate();
        return false;
      }
      _snapshot = result;
      _deadline = deadline;
      _expiry?.cancel();
      _expiry = Timer(Duration(milliseconds: deadline - _nowMs()), invalidate);
      _changes.add(null);
      return true;
    } catch (error) {
      if (_disposed || generation != _generation) return false;
      lastRefreshFailure = error;
      if (error is PeerAuthorizationDenied || error is FormatException) {
        invalidate();
        return false;
      }
      // A failed refresh cannot extend the last authoritative deadline.
      if (!isValid && !_disposed) invalidate();
      return false;
    }
  }

  void notePolicyGeneration(BigInt generation) {
    if (_disposed || (_policy != null && generation <= _policy!)) return;
    _policy = generation;
    invalidate();
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
    _refresh ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(refresh()),
    );
  }

  void stopRefreshing() {
    _refresh?.cancel();
    _refresh = null;
  }

  /// Resume/revocation fences every response already in flight.
  void invalidate() {
    if (_disposed) return;
    _generation++;
    _snapshot = null;
    _deadline = 0;
    _expiry?.cancel();
    _changes.add(null);
  }

  Future<void> dispose() async {
    invalidate();
    _disposed = true;
    stopRefreshing();
    await _changes.close();
  }
}
