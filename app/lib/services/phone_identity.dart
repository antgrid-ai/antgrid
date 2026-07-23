import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/storage_scope.dart';

/// Per-agent Ed25519 keypair held by the phone. The pubkey is what the agent
/// signs over in `pair-approval`; the privSeed is used to sign phone-side
/// challenges. The privSeed is the raw 32-byte Ed25519 seed; pubkeyB64 is
/// base64 of the raw 32-byte public key (no DER/SPKI wrapper).
class PhoneKeypair {
  PhoneKeypair({required this.pubkeyB64, required this.privSeed});

  final String pubkeyB64;
  final List<int> privSeed;
}

/// Holds a separate Ed25519 keypair per paired agent. Implementations must be
/// idempotent: calling [ensureKeypair] twice with the same `agentDeviceId`
/// returns the same keypair.
abstract class PhoneIdentity {
  Future<PhoneKeypair> ensureKeypair(String agentDeviceId);

  /// Wipes the per-machine phone keypair for one bare agent deviceUuid.
  Future<void> deleteKeypair(String agentDeviceId);

  /// Wipes ALL per-agent phone keypairs. Used by hard sign-out: once the
  /// account device is deprovisioned, the phone's pairing keys are orphaned
  /// (same-account autoOpen no longer verifies), so they must not linger.
  Future<void> clearAll();

  factory PhoneIdentity.secure() = _SecurePhoneIdentity;
  factory PhoneIdentity.inMemory() = _InMemoryPhoneIdentity;

  /// Secure-storage key for the private seed. Keyed by the BARE agent
  /// deviceUuid — there is no `.projectId` suffix; the trust anchor is the
  /// bare uuid.
  @visibleForTesting
  static String privStorageKey(String id) =>
      scopedStorageKey('antgrid.phone_priv.$id');

  /// Secure-storage key for the public key. Keyed by the BARE agent deviceUuid.
  @visibleForTesting
  static String pubStorageKey(String id) =>
      scopedStorageKey('antgrid.phone_pub.$id');
}

class _SecurePhoneIdentity implements PhoneIdentity {
  _SecurePhoneIdentity();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final Ed25519 _algo = Ed25519();

  String _privKey(String id) => PhoneIdentity.privStorageKey(id);
  String _pubKey(String id) => PhoneIdentity.pubStorageKey(id);

  @override
  Future<PhoneKeypair> ensureKeypair(String agentDeviceId) async {
    final existingPriv = await _storage.read(key: _privKey(agentDeviceId));
    final existingPub = await _storage.read(key: _pubKey(agentDeviceId));
    if (existingPriv != null && existingPub != null) {
      return PhoneKeypair(
        pubkeyB64: existingPub,
        privSeed: base64Decode(existingPriv),
      );
    }

    final keyPair = await _algo.newKeyPair();
    final privSeed = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();
    final pubB64 = base64Encode(pub.bytes);

    await _storage.write(
      key: _privKey(agentDeviceId),
      value: base64Encode(privSeed),
    );
    await _storage.write(key: _pubKey(agentDeviceId), value: pubB64);

    return PhoneKeypair(pubkeyB64: pubB64, privSeed: privSeed);
  }

  @override
  Future<void> deleteKeypair(String agentDeviceId) async {
    await _storage.delete(key: _privKey(agentDeviceId));
    await _storage.delete(key: _pubKey(agentDeviceId));
  }

  @override
  Future<void> clearAll() async {
    // Per-agent keys are stored under `antgrid.phone_priv.*`/`antgrid.phone_pub.*`
    // (scope-prefixed, so a dev build only sweeps its own). Enumerate and delete
    // only those — `deleteAll()` would also nuke unrelated secure-storage entries
    // (session cookie, device record handled elsewhere). Prefixes come from the
    // same builders that write the keys (empty id = the bare prefix) so a
    // future key-shape change can't silently desync the sweep from the write.
    final privPrefix = PhoneIdentity.privStorageKey('');
    final pubPrefix = PhoneIdentity.pubStorageKey('');
    final all = await _storage.readAll();
    for (final key in all.keys) {
      if (key.startsWith(privPrefix) || key.startsWith(pubPrefix)) {
        await _storage.delete(key: key);
      }
    }
  }
}

class _InMemoryPhoneIdentity implements PhoneIdentity {
  _InMemoryPhoneIdentity();

  final Ed25519 _algo = Ed25519();
  final Map<String, PhoneKeypair> _cache = {};

  @override
  Future<PhoneKeypair> ensureKeypair(String agentDeviceId) async {
    final cached = _cache[agentDeviceId];
    if (cached != null) return cached;

    final keyPair = await _algo.newKeyPair();
    final privSeed = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();
    final kp = PhoneKeypair(
      pubkeyB64: base64Encode(pub.bytes),
      privSeed: privSeed,
    );
    _cache[agentDeviceId] = kp;
    return kp;
  }

  @override
  Future<void> deleteKeypair(String agentDeviceId) async {
    _cache.remove(agentDeviceId);
  }

  @override
  Future<void> clearAll() async => _cache.clear();
}
