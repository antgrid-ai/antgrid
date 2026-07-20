import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Single machine-wide X25519 keypair used for push notification encryption.
/// Unlike per-agent phone identities, the same push key is reused across all
/// paired agents on this device.
class PushKeypair {
  PushKeypair({required this.pubkeyB64, required this.privSeed});

  final String pubkeyB64;
  final List<int> privSeed;
}

/// Holds a single machine-wide X25519 keypair for push notification encryption.
/// Implementations must be idempotent: calling [ensureKeypair] twice returns
/// the same keypair.
abstract class PushIdentity {
  Future<PushKeypair> ensureKeypair();

  /// Wipes the machine-wide push keypair.
  Future<void> clear();

  factory PushIdentity.secure() = _SecurePushIdentity;
  factory PushIdentity.inMemory() = _InMemoryPushIdentity;

  /// Secure-storage key for the private seed.
  @visibleForTesting
  static const privStorageKey = 'antgrid.push_priv.x25519.v1';

  /// Secure-storage key for the public key.
  @visibleForTesting
  static const pubStorageKey = 'antgrid.push_pub.x25519.v1';
}

Future<PushKeypair> _generate() async {
  final algo = X25519();
  final kp = await algo.newKeyPair();
  final priv = await kp.extractPrivateKeyBytes(); // 32 bytes
  final pub = await kp.extractPublicKey();
  return PushKeypair(pubkeyB64: base64Encode(pub.bytes), privSeed: priv);
}

class _SecurePushIdentity implements PushIdentity {
  static const _storage = FlutterSecureStorage();

  /// In-flight single-flight guard: the read-then-generate-then-write is not
  /// atomic, so two concurrent callers (e.g. token-refresh + first-launch
  /// registration) could both read "no key", both generate, and one overwrite
  /// the other — leaving a persisted key that differs from one already
  /// registered with an agent. Caching the Future so concurrent callers await
  /// the SAME generation collapses them to one keypair.
  Future<PushKeypair>? _inFlight;

  @override
  Future<PushKeypair> ensureKeypair() {
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<PushKeypair> _load() async {
    final priv = await _storage.read(key: PushIdentity.privStorageKey);
    final pub = await _storage.read(key: PushIdentity.pubStorageKey);
    if (priv != null && pub != null) {
      return PushKeypair(pubkeyB64: pub, privSeed: base64Decode(priv));
    }
    final kp = await _generate();
    await _storage.write(
      key: PushIdentity.privStorageKey,
      value: base64Encode(kp.privSeed),
    );
    await _storage.write(key: PushIdentity.pubStorageKey, value: kp.pubkeyB64);
    return kp;
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: PushIdentity.privStorageKey);
    await _storage.delete(key: PushIdentity.pubStorageKey);
  }
}

class _InMemoryPushIdentity implements PushIdentity {
  PushKeypair? _kp;
  Future<PushKeypair>? _inFlight;

  @override
  Future<PushKeypair> ensureKeypair() {
    final cached = _kp;
    if (cached != null) return Future.value(cached);
    // `_kp ??= await _generate()` races: two concurrent callers both see null,
    // both generate, and the second assignment wins — mirroring the secure
    // variant's TOCTOU. Cache the in-flight Future so concurrent callers share
    // one generation.
    return _inFlight ??= _generate().then((kp) {
      _kp = kp;
      return kp;
    }).whenComplete(() => _inFlight = null);
  }

  @override
  Future<void> clear() async {
    _kp = null;
  }
}
