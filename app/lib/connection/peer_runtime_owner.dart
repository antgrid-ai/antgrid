import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The durable identity of an enrollment-scoped native runtime.
///
/// The endpoint secret participates by digest so ownership decisions detect a
/// rotated endpoint key without retaining another plaintext copy of it.
final class PeerRuntimeIdentity {
  PeerRuntimeIdentity({
    required this.accountId,
    required this.enrollmentId,
    required String endpointSecret,
  }) : endpointSecretIdentity = sha256
           .convert(utf8.encode(endpointSecret))
           .toString();

  final String accountId;
  final String enrollmentId;
  final String endpointSecretIdentity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerRuntimeIdentity &&
          other.accountId == accountId &&
          other.enrollmentId == enrollmentId &&
          other.endpointSecretIdentity == endpointSecretIdentity;

  @override
  int get hashCode =>
      Object.hash(accountId, enrollmentId, endpointSecretIdentity);

  @override
  String toString() =>
      'PeerRuntimeIdentity(accountId: $accountId, enrollmentId: $enrollmentId)';
}

final class PeerRuntimeCleanupResult {
  const PeerRuntimeCleanupResult.complete() : complete = true, reason = null;

  const PeerRuntimeCleanupResult.incomplete([this.reason]) : complete = false;

  final bool complete;
  final Object? reason;
}

final class PeerRuntimeCleanupFailure {
  const PeerRuntimeCleanupFailure({
    required this.identity,
    required this.reason,
    this.stackTrace,
  });

  final PeerRuntimeIdentity identity;
  final Object reason;
  final StackTrace? stackTrace;
}

final class PeerRuntimeOwnerLockedException implements Exception {
  const PeerRuntimeOwnerLockedException(this.failure);

  final PeerRuntimeCleanupFailure failure;

  @override
  String toString() =>
      'PeerRuntimeOwnerLockedException(${failure.identity}, ${failure.reason})';
}

typedef PeerRuntimeFactory<T extends Object, A> = FutureOr<T> Function(A value);
typedef PeerRuntimeDisposer<T extends Object> =
    Future<PeerRuntimeCleanupResult> Function(T runtime);

/// Serializes ownership of one enrollment-scoped native runtime.
///
/// A failed teardown keeps the old runtime referenced and locks all creation.
/// [clear] may be retried to confirm cleanup and unlock the owner.
final class PeerRuntimeOwner<T extends Object, A> {
  PeerRuntimeOwner({
    required PeerRuntimeFactory<T, A> create,
    required PeerRuntimeDisposer<T> dispose,
  }) : _create = create,
       _dispose = dispose;

  final PeerRuntimeFactory<T, A> _create;
  final PeerRuntimeDisposer<T> _dispose;

  Future<void> _tail = Future<void>.value();
  T? _runtime;
  PeerRuntimeIdentity? _identity;
  PeerRuntimeCleanupFailure? _cleanupFailure;

  PeerRuntimeIdentity? get identity => _identity;
  T? get runtime => _runtime;
  PeerRuntimeCleanupFailure? get cleanupFailure => _cleanupFailure;
  bool get isLocked => _cleanupFailure != null;

  Future<T> obtain(PeerRuntimeIdentity identity, A value) =>
      _serialize(() async {
        _throwIfLocked();
        final current = _runtime;
        if (current != null && _identity == identity) return current;
        if (current != null) await _disposeOrLock();
        return _createCurrent(identity, value);
      });

  Future<T> replace(PeerRuntimeIdentity identity, A value) =>
      _serialize(() async {
        _throwIfLocked();
        if (_runtime != null) await _disposeOrLock();
        return _createCurrent(identity, value);
      });

  Future<PeerRuntimeCleanupResult> clear() => _serialize(() async {
    if (_runtime == null) {
      _identity = null;
      _cleanupFailure = null;
      return const PeerRuntimeCleanupResult.complete();
    }
    return _disposeCurrent();
  });

  Future<T> _createCurrent(PeerRuntimeIdentity identity, A value) async {
    final runtime = await _create(value);
    _runtime = runtime;
    _identity = identity;
    return runtime;
  }

  Future<void> _disposeOrLock() async {
    final result = await _disposeCurrent();
    if (!result.complete) {
      throw PeerRuntimeOwnerLockedException(_cleanupFailure!);
    }
  }

  Future<PeerRuntimeCleanupResult> _disposeCurrent() async {
    final runtime = _runtime;
    final identity = _identity;
    if (runtime == null || identity == null) {
      return const PeerRuntimeCleanupResult.complete();
    }
    PeerRuntimeCleanupResult result;
    StackTrace? stackTrace;
    try {
      result = await _dispose(runtime);
    } catch (error, stack) {
      result = PeerRuntimeCleanupResult.incomplete(error);
      stackTrace = stack;
    }
    if (result.complete) {
      _runtime = null;
      _identity = null;
      _cleanupFailure = null;
      return result;
    }
    _cleanupFailure = PeerRuntimeCleanupFailure(
      identity: identity,
      reason: result.reason ?? StateError('Peer runtime cleanup incomplete'),
      stackTrace: stackTrace,
    );
    return result;
  }

  void _throwIfLocked() {
    final failure = _cleanupFailure;
    if (failure != null) throw PeerRuntimeOwnerLockedException(failure);
  }

  Future<R> _serialize<R>(FutureOr<R> Function() operation) {
    final result = Completer<R>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}
