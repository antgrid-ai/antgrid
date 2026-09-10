import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:webcrypto/webcrypto.dart' as webcrypto;

/// AES-256-GCM backed by BoringSSL, exposed as a `package:cryptography` [AesGcm]
/// so it can be handed to `E2eTransportDart.useAlgorithm`.
///
/// Exists for Windows and Linux only. `cryptography_flutter` ships no plugin
/// there, so `FlutterAesGcm` degrades to a pure Dart cipher — a background
/// isolate past its size threshold, the UI isolate below it. `package:webcrypto`
/// bundles BoringSSL and reaches AES-NI on every platform it builds for.
///
/// Wire contract is the transport's, not this class's: 12-byte nonce, 128-bit
/// tag, `nonce ‖ ciphertext ‖ tag`, byte-compatible with node:crypto's
/// `aes-256-gcm` in `bridge/src/e2e/transport.ts`. Web Crypto returns
/// `ciphertext ‖ tag` as one buffer where [SecretBox] wants the two apart, so
/// the split and rejoin below are the whole of the adaptation.
class WebcryptoAesGcm extends AesGcm {
  WebcryptoAesGcm({this.minBytesWorthFfi = defaultMinBytesWorthFfi})
    : super.constructor();

  static const int _tagBytes = 16;

  /// Below this, the pure Dart cipher wins and this class delegates to it.
  ///
  /// A BoringSSL call costs a flat ~24us on the measuring machine whatever the
  /// payload — an FFI hop, a key-cache probe and the buffer copies below —
  /// while the Dart cipher's cost is all throughput. Measured crossover is
  /// ~512 bytes: at 256 B Dart is roughly twice as fast, at 1 KB BoringSSL is
  /// 3x, at 8 KB 28x. `test/config/webcrypto_bench.dart` reproduces the curve.
  ///
  /// Not a knob to raise "to be safe" — above the threshold the gap only
  /// widens, and terminal output, tree pushes and preview bodies all sit above
  /// it. Only tests pass anything else, to force the FFI path on a short
  /// golden vector.
  static const int defaultMinBytesWorthFfi = 512;

  final int minBytesWorthFfi;

  static final DartAesGcm _dartFallback = DartAesGcm(secretKeyLength: 32);

  @override
  int get nonceLength => AesGcm.defaultNonceLength;

  @override
  int get secretKeyLength => 32;

  /// Imported keys, newest last. Importing measured ~15us — comparable to a
  /// whole small-frame decrypt — and `E2eTransportDart` is stateless by design,
  /// constructing a transport, and so reaching this cipher, once per frame.
  /// Without this cache every frame pays that import.
  ///
  /// A session holds two directional keys and a rekey briefly adds two more, so
  /// four entries covers steady state without pinning key material from
  /// sessions that have moved on.
  static final List<_ImportedKey> _cache = <_ImportedKey>[];
  static const int _cacheSize = 4;

  /// Drops every imported key. `SessionKeys.zeroize` clears the Dart-side bytes
  /// but cannot reach into BoringSSL, so a key stays resident here until it is
  /// evicted by age. Call this wherever a session's key material is retired.
  static void evictImportedKeys() => _cache.clear();

  @visibleForTesting
  static int get importedKeyCount => _cache.length;

  static Future<webcrypto.AesGcmSecretKey> _importedKey(List<int> bytes) async {
    for (var i = _cache.length - 1; i >= 0; i--) {
      if (_cache[i].matches(bytes)) return _cache[i].key;
    }
    // Copy: the caller's list is the live session key, and `zeroize` fills it
    // with zeros in place. Holding the reference would let a zeroized entry
    // answer a later lookup for a genuinely all-zero key with the wrong handle.
    final owned = Uint8List.fromList(bytes);
    final key = await webcrypto.AesGcmSecretKey.importRawKey(owned);
    _cache.add(_ImportedKey(owned, key));
    if (_cache.length > _cacheSize) _cache.removeAt(0);
    return key;
  }

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) async {
    if (clearText.length < minBytesWorthFfi) {
      return _dartFallback.encrypt(
        clearText,
        secretKey: secretKey,
        nonce: nonce,
        aad: aad,
        possibleBuffer: possibleBuffer,
      );
    }
    final key = await _importedKey((await secretKey.extract()).bytes);
    final iv = nonce ?? _randomNonce();
    final sealed = await key.encryptBytes(
      clearText,
      iv,
      additionalData: aad.isEmpty ? null : aad,
    );
    return SecretBox(
      sealed.sublist(0, sealed.length - _tagBytes),
      nonce: iv,
      mac: Mac(sealed.sublist(sealed.length - _tagBytes)),
    );
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) async {
    if (secretBox.cipherText.length < minBytesWorthFfi) {
      return _dartFallback.decrypt(
        secretBox,
        secretKey: secretKey,
        aad: aad,
        possibleBuffer: possibleBuffer,
      );
    }
    final key = await _importedKey((await secretKey.extract()).bytes);
    final joined =
        Uint8List(secretBox.cipherText.length + secretBox.mac.bytes.length)
          ..setAll(0, secretBox.cipherText)
          ..setAll(secretBox.cipherText.length, secretBox.mac.bytes);
    try {
      return await key.decryptBytes(
        joined,
        secretBox.nonce,
        additionalData: aad.isEmpty ? null : aad,
      );
    } on webcrypto.OperationError catch (e) {
      // A bad tag reaches callers as the `package:cryptography` error every
      // other implementation throws. BoringSSL signals it as an OperationError,
      // which extends Error, not Exception — an `on Exception` catch upstream
      // would let it escape as a crash instead of a dropped frame.
      throw SecretBoxAuthenticationError(message: e.toString());
    }
  }

  static Uint8List _randomNonce() {
    final iv = Uint8List(AesGcm.defaultNonceLength);
    webcrypto.fillRandomBytes(iv);
    return iv;
  }
}

class _ImportedKey {
  _ImportedKey(this.bytes, this.key);

  final Uint8List bytes;
  final webcrypto.AesGcmSecretKey key;

  bool matches(List<int> other) {
    if (other.length != bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other[i]) return false;
    }
    return true;
  }
}
