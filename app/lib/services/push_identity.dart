import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/storage_scope.dart';
import '../util/ab_log.dart';
import 'shared_keychain.dart';

/// Shared Keychain account under which the raw X25519 seed is mirrored on iOS
/// so the Notification Service Extension (a separate process) can read it. The
/// stored value is base64 of the 32-byte seed; the NSE base64-decodes it. Keep
/// in lockstep with the NSE's SecItem query in NotificationService.swift.
const _kSharedSeedAccount = 'push_priv_x25519_v1';

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
  static final privStorageKey = scopedStorageKey('antgrid.push_priv.x25519.v1');

  /// Secure-storage key for the public key.
  @visibleForTesting
  static final pubStorageKey = scopedStorageKey('antgrid.push_pub.x25519.v1');
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
      // Write-through is idempotent: ensure the iOS NSE always has a readable
      // copy of the seed even for a keypair generated before this mirror path
      // existed.
      await _mirrorSeedToSharedKeychain(priv);
      return PushKeypair(pubkeyB64: pub, privSeed: base64Decode(priv));
    }
    final kp = await _generate();
    final privB64 = base64Encode(kp.privSeed);
    await _storage.write(key: PushIdentity.privStorageKey, value: privB64);
    await _storage.write(key: PushIdentity.pubStorageKey, value: kp.pubkeyB64);
    await _mirrorSeedToSharedKeychain(privB64);
    return kp;
  }

  /// iOS: mirror the base64 seed into the shared Keychain Access Group so the
  /// NSE can decrypt push blobs. No-op off iOS. Guarded — the channel is absent
  /// in unit tests / on unsupported platforms and must never throw here.
  ///
  /// The shared account is unscoped — native NSE code can't read the Dart-side
  /// storage-scope prefix — so a scoped (dev/test-instance) build must never
  /// write it: doing so would overwrite the release app's seed and break its
  /// push decryption until it next foregrounds and re-mirrors.
  Future<void> _mirrorSeedToSharedKeychain(String seedB64) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (storageScopePrefix.isNotEmpty) return;
    try {
      await SharedKeychain().write(_kSharedSeedAccount, seedB64);
    } catch (e) {
      AbLog.warn(
        'PushIdentity',
        'push seed shared-keychain mirror failed',
        fields: {'error': '$e'},
      );
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: PushIdentity.privStorageKey);
    await _storage.delete(key: PushIdentity.pubStorageKey);
    // Same scoping rule as the mirror above: only the release identity may
    // touch the shared (unscoped) keychain account.
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        storageScopePrefix.isEmpty) {
      try {
        await SharedKeychain().delete(_kSharedSeedAccount);
      } catch (e) {
        AbLog.warn(
          'PushIdentity',
          'push seed shared-keychain delete failed',
          fields: {'error': '$e'},
        );
      }
    }
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
    return _inFlight ??= _generate()
        .then((kp) {
          _kp = kp;
          return kp;
        })
        .whenComplete(() => _inFlight = null);
  }

  @override
  Future<void> clear() async {
    _kp = null;
  }
}
