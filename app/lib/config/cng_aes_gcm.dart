import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart'
    show FlutterAesGcm;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../util/ab_log.dart';

/// AES-256-GCM backed by Windows CNG (`bcrypt.dll`), exposed as a
/// `package:cryptography` [AesGcm] so it can be handed to
/// `E2eTransportDart.useAlgorithm`.
///
/// Exists for Windows only. `cryptography_flutter` ships no Windows plugin, so
/// `FlutterAesGcm` degrades to a pure Dart cipher — measured ~12 MB/s, on the
/// UI isolate below its ~10 KB compute threshold. CNG reaches AES-NI through an
/// OS DLL that is already resident in every Windows process: no build step, no
/// toolchain prerequisite, no redistributed crypto.
///
/// Wire contract is the transport's, not this class's: 12-byte nonce, 128-bit
/// tag, `nonce ‖ ciphertext ‖ tag`, byte-compatible with node:crypto's
/// `aes-256-gcm` in `bridge/src/e2e/transport.ts`. CNG keeps ciphertext and tag
/// in separate buffers, which is the shape [SecretBox] wants, so unlike a Web
/// Crypto adapter there is no split to do.
///
/// **No size threshold, deliberately.** A CNG call costs ~1 µs whatever the
/// payload, so it beats the Dart cipher at every size from 64 B up — an FFI
/// cipher with a heavier call floor (BoringSSL measured ~24 µs) needs one and
/// this does not. `test/config/cipher_bench.dart` reproduces the curve.
///
/// Runs on the calling isolate, which is the UI isolate — same as any FFI
/// cipher. 2 MB costs ~4.4 ms there, inside a frame budget, where the pure Dart
/// cipher's ~164 ms was not. Statics below are per-isolate: a background isolate
/// that never calls [CngAesGcm.probe] silently gets the default Dart cipher,
/// which is correct output at the old speed.
class CngAesGcm extends AesGcm {
  CngAesGcm() : super.constructor();

  static const int _tagBytes = 16;
  static const int _keyBytes = 32;

  @override
  int get nonceLength => AesGcm.defaultNonceLength;

  @override
  int get secretKeyLength => _keyBytes;

  /// True once a runtime status told us CNG is unusable on this machine.
  ///
  /// A `STATUS_NOT_SUPPORTED` (a FIPS-policy provider with no GCM) or a
  /// `STATUS_INVALID_HANDLE` (our own lifecycle bug) must degrade the whole
  /// process to the Dart cipher rather than kill every frame from here on.
  static bool _disabled = false;

  static final AesGcm _fallback = FlutterAesGcm(secretKeyLength: 32);

  /// Verifies at install time that this machine can actually do CNG AES-GCM,
  /// so a failure surfaces once at startup rather than as an opaque dropped
  /// frame five hundred frames in — `E2eTransportDart.open` catches broadly, so
  /// anything thrown from here would otherwise be invisible.
  ///
  /// Checks the hand-written struct layout, then runs a compiled-in known-answer
  /// test: a hooked or FIPS-restricted provider passes the API calls and returns
  /// the wrong bytes, and that is the failure worth catching before a wire frame
  /// depends on it. Microseconds, once.
  static bool probe() {
    if (!Platform.isWindows) return false;
    try {
      if (sizeOf<IntPtr>() == 8 && sizeOf<_AuthInfo>() != _authInfoSizeX64) {
        throw StateError('BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO is '
            '${sizeOf<_AuthInfo>()} bytes, expected $_authInfoSizeX64');
      }
      if (_ensureProvider() == 0) throw StateError('provider unavailable');
      final sealed = _cryptSync(
        _katKey,
        _katNonce,
        _katPlain,
        const <int>[],
        encrypt: true,
      );
      if (sealed == null || !_constantTimeEquals(sealed, _katSealed)) {
        throw StateError('known-answer test mismatch');
      }
      // Clears a latch a previous run's runtime status may have set: a passing
      // known-answer test is proof the provider works now.
      _disabled = false;
      return true;
    } catch (e) {
      _disabled = true;
      AbLog.warn('CngAesGcm', 'probe failed, falling back to the Dart cipher',
          fields: {'error': e.toString()});
      return false;
    }
  }

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) async {
    final iv = nonce ?? newNonce();
    // Extract BEFORE the synchronous section: `SecretKey.extract` returns a
    // Future, and an await between the key-cache lookup and the FFI call is a
    // use-after-free on a kernel handle (see `_cryptSync`).
    final keyBytes = (await secretKey.extract()).bytes;
    if (_disabled) {
      return _fallback.encrypt(clearText,
          secretKey: secretKey,
          nonce: iv,
          aad: aad,
          possibleBuffer: possibleBuffer);
    }
    _checkParameters(keyBytes.length, iv.length);
    final sealed = _cryptSync(keyBytes, iv, clearText, aad, encrypt: true)!;
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
    final keyBytes = (await secretKey.extract()).bytes;
    if (_disabled) {
      return _fallback.decrypt(secretBox,
          secretKey: secretKey, aad: aad, possibleBuffer: possibleBuffer);
    }
    _checkParameters(keyBytes.length, secretBox.nonce.length);
    // The mac length comes off the wire. CNG's GCM accepts any tag from 12 to
    // 16 bytes and will happily verify a TRUNCATED one, where every other
    // implementation of this interface rejects it — accepting a 12-byte tag
    // here would silently drop forgery resistance from 2^-128 to 2^-96.
    if (secretBox.mac.bytes.length != _tagBytes) {
      throw SecretBoxAuthenticationError();
    }
    final joined = Uint8List(secretBox.cipherText.length + _tagBytes)
      ..setAll(0, secretBox.cipherText)
      ..setAll(secretBox.cipherText.length, secretBox.mac.bytes);
    final opened = _cryptSync(
      keyBytes,
      secretBox.nonce,
      joined,
      aad,
      encrypt: false,
    );
    if (opened == null) throw SecretBoxAuthenticationError();
    return opened;
  }

  /// CNG selects AES-128/192/256 purely from the key length and rejects any
  /// nonce but 12 bytes with an opaque NTSTATUS. Both are caught here so a
  /// caller gets a readable error rather than a hex status — and so a 16-byte
  /// key can never produce a valid AES-128 frame the bridge cannot open.
  void _checkParameters(int keyLength, int nonceLen) {
    if (keyLength != _keyBytes) {
      throw ArgumentError.value(
          keyLength, 'secretKey', 'must be $_keyBytes bytes');
    }
    if (nonceLen != AesGcm.defaultNonceLength) {
      throw ArgumentError.value(
          nonceLen, 'nonce', 'must be ${AesGcm.defaultNonceLength} bytes');
    }
  }

  /// Drops every cached key handle, destroying it in CNG.
  ///
  /// `SessionKeys.zeroize` clears the Dart-side bytes but cannot reach a kernel
  /// key object, so retired key material stays live here until it is evicted by
  /// age. Call this wherever a session's key material is retired.
  static void evictImportedKeys() {
    for (final entry in _cache) {
      entry.destroy();
    }
    _cache.clear();
  }

  @visibleForTesting
  static int get importedKeyCount => _cache.length;

  /// Byte size the kernel expects for `BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO`
  /// on 64-bit Windows. Exposed so a test can pin the hand-written struct
  /// layout: CNG validates `cbSize` against the info class, so a drifted layout
  /// fails at runtime with nothing but a swallowed warning.
  @visibleForTesting
  static int get authCipherModeInfoSize => sizeOf<_AuthInfo>();

  @visibleForTesting
  static const int authInfoSizeX64 = _authInfoSizeX64;
}

const int _authInfoSizeX64 = 88;

// NTSTATUS values. Named here rather than pulled from package:win32 to keep the
// dependency surface at `dart:ffi` + an allocator — package:win32 exposes no
// BCrypt bindings anyway.
const int _statusSuccess = 0;
const int _statusAuthTagMismatch = 0xC000A002;
const int _statusNotSupported = 0xC00000BB;
const int _statusInvalidHandle = 0xC0000008;
const int _authModeInfoVersion = 1;

/// Every BCrypt entry point returns NTSTATUS through `Int32`, so a failure
/// arrives NEGATIVE and a bare `st == 0xC000A002` never matches. Route every
/// status through here: without it a tampered frame throws instead of dropping.
int _nt(int raw) => raw & 0xffffffff;

/// `BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO`.
///
/// `pbMacContext`/`cbMacContext`, `cbAAD` and `cbData` are chained-call state,
/// meaningful only under `BCRYPT_AUTH_MODE_CHAIN_CALLS`. They must stay zero
/// here, and they are what makes a cached key handle safe to use concurrently:
/// in one-shot mode all per-call state lives in this struct, not in the handle.
final class _AuthInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwInfoVersion;
  external Pointer<Uint8> pbNonce;
  @Uint32()
  external int cbNonce;
  external Pointer<Uint8> pbAuthData;
  @Uint32()
  external int cbAuthData;
  external Pointer<Uint8> pbTag;
  @Uint32()
  external int cbTag;
  external Pointer<Uint8> pbMacContext;
  @Uint32()
  external int cbMacContext;
  @Uint32()
  external int cbAAD;
  @Uint64()
  external int cbData;
  @Uint32()
  external int dwFlags;
}

// Native side takes IntPtr for handles; the Dart side of the same typedef takes
// plain `int` or the lookup fails to compile.
typedef _OpenAlgC = Int32 Function(
    Pointer<IntPtr>, Pointer<Uint16>, Pointer<Uint16>, Uint32);
typedef _OpenAlg = int Function(
    Pointer<IntPtr>, Pointer<Uint16>, Pointer<Uint16>, int);
typedef _SetPropC = Int32 Function(
    IntPtr, Pointer<Uint16>, Pointer<Uint8>, Uint32, Uint32);
typedef _SetProp = int Function(int, Pointer<Uint16>, Pointer<Uint8>, int, int);
typedef _GenKeyC = Int32 Function(
    IntPtr, Pointer<IntPtr>, Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Uint32);
typedef _GenKey = int Function(
    int, Pointer<IntPtr>, Pointer<Uint8>, int, Pointer<Uint8>, int, int);
typedef _CryptC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Void>,
    Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>, Uint32);
typedef _Crypt = int Function(int, Pointer<Uint8>, int, Pointer<Void>,
    Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint32>, int);
typedef _DestroyKeyC = Int32 Function(IntPtr);
typedef _DestroyKey = int Function(int);

/// Resolved once per process, not per call: `DynamicLibrary.open` is a
/// `LoadLibrary` with no matching `FreeLibrary`, and the symbol lookups are not
/// free either. Lazy, so none of it runs off Windows — every entry point checks
/// `Platform.isWindows` or `_disabled` before touching them.
final DynamicLibrary _bcrypt = DynamicLibrary.open('bcrypt.dll');
final _openAlgorithmProvider = _bcrypt
    .lookupFunction<_OpenAlgC, _OpenAlg>('BCryptOpenAlgorithmProvider');
final _setProperty =
    _bcrypt.lookupFunction<_SetPropC, _SetProp>('BCryptSetProperty');
final _generateSymmetricKey = _bcrypt
    .lookupFunction<_GenKeyC, _GenKey>('BCryptGenerateSymmetricKey');
final _encryptFn = _bcrypt.lookupFunction<_CryptC, _Crypt>('BCryptEncrypt');
final _decryptFn = _bcrypt.lookupFunction<_CryptC, _Crypt>('BCryptDecrypt');
final _destroyKeyFn =
    _bcrypt.lookupFunction<_DestroyKeyC, _DestroyKey>('BCryptDestroyKey');

/// The AES-GCM algorithm provider, or 0 once opening it has failed.
///
/// One per isolate, opened lazily and deliberately never closed — it is a single
/// reference held for the process lifetime and released by the kernel at exit.
/// Closing it is the dangerous direction, not leaving it open: closing a
/// provider while keys generated from it are still alive is undefined, so no
/// close path is exposed at all. Same reasoning as `_job` in
/// `launcher/windows_job_object.dart`.
int _provider = -1;

int _ensureProvider() {
  if (_provider != -1) return _provider;
  return using((arena) {
    final phAlg = arena<IntPtr>();
    final algId = 'AES'.toNativeUtf16(allocator: arena);
    var st = _nt(_openAlgorithmProvider(phAlg, algId.cast<Uint16>(), nullptr, 0));
    if (st != _statusSuccess) {
      AbLog.warn('CngAesGcm', 'BCryptOpenAlgorithmProvider failed',
          fields: {'status': st.toRadixString(16)});
      return _provider = 0;
    }
    const mode = 'ChainingModeGCM';
    final propName = 'ChainingMode'.toNativeUtf16(allocator: arena);
    final propVal = mode.toNativeUtf16(allocator: arena);
    // Length in BYTES of the UTF-16 string including its terminator — derived,
    // not hardcoded, because CNG reads exactly this many bytes.
    st = _nt(_setProperty(phAlg.value, propName.cast<Uint16>(),
        propVal.cast<Uint8>(), (mode.length + 1) * 2, 0));
    if (st != _statusSuccess) {
      AbLog.warn('CngAesGcm', 'BCryptSetProperty(ChainingModeGCM) failed',
          fields: {'status': st.toRadixString(16)});
      return _provider = 0;
    }
    return _provider = phAlg.value;
  }, malloc);
}

/// Cached key handles, newest last.
///
/// Generating a key measured ~15 µs, an order above a small-frame decrypt, and
/// `E2eTransportDart` is stateless by design — it constructs a transport, and so
/// reaches this cipher, once per frame. Without this cache every frame pays it.
///
/// A session holds two directional keys and a rekey briefly adds two more, so
/// four entries covers steady state without pinning key material from sessions
/// that have moved on.
final List<_CachedKey> _cache = <_CachedKey>[];
const int _cacheSize = 4;

class _CachedKey {
  _CachedKey(this.bytes, this.handle);

  final Uint8List bytes;
  final int handle;

  void destroy() {
    final st = _nt(_destroyKeyFn(handle));
    if (st != _statusSuccess) {
      AbLog.error('CngAesGcm', 'BCryptDestroyKey failed',
          fields: {'status': st.toRadixString(16)});
    }
    bytes.fillRange(0, bytes.length, 0);
  }
}

int _keyHandle(List<int> keyBytes) {
  for (var i = _cache.length - 1; i >= 0; i--) {
    if (_constantTimeEquals(_cache[i].bytes, keyBytes)) return _cache[i].handle;
  }
  final provider = _ensureProvider();
  if (provider == 0) throw StateError('CNG provider unavailable');
  // Copy: the caller's list is the live session key, and `zeroize` fills it with
  // zeros in place. Holding the reference would let a zeroized entry answer a
  // later lookup for a genuinely all-zero key with a live handle for the WRONG
  // key. A stale handle here is not a stale object a GC will collect: it is a
  // live kernel key that really encrypts.
  final owned = Uint8List.fromList(keyBytes);
  final handle = using((arena) {
    final phKey = arena<IntPtr>();
    final pKey = arena<Uint8>(owned.length);
    pKey.asTypedList(owned.length).setRange(0, owned.length, owned);
    // NULL key object: the primitive provider allocates it itself and
    // `BCryptDestroyKey` frees it. The textbook `BCryptGetProperty(OBJECT_LENGTH)`
    // + caller-owned buffer variant has a use-after-free built in — that buffer
    // must outlive the handle.
    final st = _nt(_generateSymmetricKey(
        provider, phKey, nullptr, 0, pKey, owned.length, 0));
    _wipe(pKey, owned.length);
    if (st != _statusSuccess) {
      throw StateError('BCryptGenerateSymmetricKey 0x${st.toRadixString(16)}');
    }
    return phKey.value;
  }, malloc);
  _cache.add(_CachedKey(owned, handle));
  if (_cache.length > _cacheSize) _cache.removeAt(0).destroy();
  return handle;
}

/// The whole FFI section, deliberately synchronous.
///
/// **An `await` added anywhere below this line is a use-after-free on a kernel
/// handle, not a latency regression.** A suspension between the cache lookup and
/// the BCrypt call lets a second frame miss the cache, insert, and evict — and
/// eviction calls `BCryptDestroyKey`, whose handle value the kernel may then
/// reuse for a different key. Best case an invalid-handle status; worst case
/// real plaintext encrypted under the wrong key and put on the wire.
///
/// [input] is plaintext when encrypting and `ciphertext ‖ tag` when not; the
/// return is `ciphertext ‖ tag`, or the plaintext, or null for a tag mismatch.
Uint8List? _cryptSync(
  List<int> keyBytes,
  List<int> nonce,
  List<int> input,
  List<int> aad, {
  required bool encrypt,
}) {
  final hKey = _keyHandle(keyBytes);
  final dataLen = encrypt ? input.length : input.length - CngAesGcm._tagBytes;
  if (dataLen < 0) return null;
  // malloc, not calloc: package:ffi zeroes a calloc block with a byte-at-a-time
  // Dart loop, which for a 2 MB frame is millions of native writes into buffers
  // that are about to be fully overwritten. Every field below is set explicitly
  // for the same reason.
  return using((arena) {
    final n = dataLen == 0 ? 1 : dataLen;
    final pIn = arena<Uint8>(n);
    final pOut = arena<Uint8>(n);
    final pNonce = arena<Uint8>(nonce.length);
    final pTag = arena<Uint8>(CngAesGcm._tagBytes);
    final pAad = aad.isEmpty ? nullptr : arena<Uint8>(aad.length);
    final pcb = arena<Uint32>();
    final info = arena<_AuthInfo>();
    try {
      // pbInput must be non-NULL even at cbInput == 0, which is reachable from
      // the network: a 28-byte frame decrypts to an empty plaintext.
      // setRange, not setAll over a lazy `take`/`skip`: both sides are typed
      // here, so this is a memmove rather than 2 MB of per-element dispatch.
      if (dataLen > 0) {
        pIn.asTypedList(dataLen).setRange(0, dataLen, input);
      } else {
        pIn.value = 0;
      }
      pNonce.asTypedList(nonce.length).setRange(0, nonce.length, nonce);
      if (encrypt) {
        pTag.asTypedList(CngAesGcm._tagBytes).fillRange(0, CngAesGcm._tagBytes, 0);
      } else {
        pTag
            .asTypedList(CngAesGcm._tagBytes)
            .setRange(0, CngAesGcm._tagBytes, input, dataLen);
      }
      if (aad.isNotEmpty) {
        pAad.asTypedList(aad.length).setRange(0, aad.length, aad);
      }

      info.ref
        ..cbSize = sizeOf<_AuthInfo>()
        ..dwInfoVersion = _authModeInfoVersion
        ..pbNonce = pNonce
        ..cbNonce = nonce.length
        ..pbAuthData = pAad
        ..cbAuthData = aad.length
        ..pbTag = pTag
        ..cbTag = CngAesGcm._tagBytes
        ..pbMacContext = nullptr
        ..cbMacContext = 0
        ..cbAAD = 0
        ..cbData = 0
        ..dwFlags = 0;

      // pbIV must be NULL for one-shot GCM (the nonce travels in the struct
      // above), and dwFlags must never carry BCRYPT_BLOCK_PADDING — GCM is a
      // stream mode and padding it corrupts the frame.
      final call = encrypt ? _encryptFn : _decryptFn;
      final st = _nt(call(hKey, pIn, dataLen, info.cast<Void>(), nullptr, 0,
          pOut, dataLen, pcb, 0));
      if (!encrypt && st == _statusAuthTagMismatch) return null;
      if (st != _statusSuccess) throw _statusError(st, encrypt, dataLen);
      if (pcb.value != dataLen) {
        // Impossible for one-shot GCM, and silent if unchecked: the tail of a
        // short write would ship as frame content under a valid tag.
        throw _fail('short write', encrypt,
            {'wrote': pcb.value, 'expected': dataLen});
      }

      if (encrypt) {
        final out = Uint8List(dataLen + CngAesGcm._tagBytes);
        if (dataLen > 0) out.setRange(0, dataLen, pOut.asTypedList(dataLen));
        out.setRange(dataLen, out.length, pTag.asTypedList(CngAesGcm._tagBytes));
        return out;
      }
      // Never hand back `pOut.asTypedList(...)` itself — the view aliases arena
      // memory that is freed on the way out of this function, and a
      // read-after-free usually still holds the right bytes, so it passes tests
      // and corrupts frames in the field.
      final out = Uint8List(dataLen);
      if (dataLen > 0) out.setRange(0, dataLen, pOut.asTypedList(dataLen));
      return out;
    } finally {
      // Plaintext lives in pIn on the encrypt path and pOut on the decrypt one;
      // the repo zeroizes key material elsewhere (`SessionKeys.zeroize`) and a
      // freed CoTaskMem block holding a decrypted frame is the same hazard.
      _wipe(pIn, n);
      _wipe(pOut, n);
    }
  }, malloc);
}

Object _statusError(int st, bool encrypt, int len) {
  if (st == _statusNotSupported || st == _statusInvalidHandle) {
    // Permanent: either the provider cannot do GCM, or our handle lifetime is
    // broken. Degrade the whole process rather than kill every frame. The cache
    // is dropped WITHOUT destroying — on an invalid handle a double destroy is
    // how a reused handle value becomes a wrong-key encrypt.
    CngAesGcm._disabled = true;
    _cache.clear();
    _provider = 0;
  }
  return _fail('0x${st.toRadixString(16)}', encrypt, {'bytes': len});
}

/// Logged before it is thrown: `E2eTransportDart.open` catches broadly, so an
/// unlogged throw from here reaches the user as a connection that looks hung
/// with nothing in the log to point at. Never the payload, only its length.
StateError _fail(String what, bool encrypt, Map<String, Object?> fields) {
  final op = encrypt ? 'BCryptEncrypt' : 'BCryptDecrypt';
  AbLog.error('CngAesGcm', '$op $what', fields: fields);
  return StateError('$op $what');
}

void _wipe(Pointer<Uint8> p, int len) =>
    p.asTypedList(len).fillRange(0, len, 0);

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// NIST-style known-answer vector for AES-256-GCM, checked at install time. A
// provider that answers every API call and returns the wrong bytes is exactly
// what a layout drift or a hooked bcrypt.dll looks like.
final Uint8List _katKey =
    Uint8List.fromList(List<int>.generate(32, (i) => i));
final Uint8List _katNonce =
    Uint8List.fromList(List<int>.generate(12, (i) => 0xa0 + i));
final Uint8List _katPlain =
    Uint8List.fromList(List<int>.generate(16, (i) => 0x10 + i));
final Uint8List _katSealed = Uint8List.fromList(<int>[
  0xf6, 0x09, 0x6e, 0x3e, 0x51, 0xde, 0x14, 0xa8, //
  0x7a, 0x7c, 0x9d, 0xc8, 0x1b, 0x67, 0xde, 0xc1,
  0x7c, 0x06, 0x49, 0x41, 0x3c, 0xee, 0x30, 0x68,
  0x83, 0xc3, 0x69, 0x3a, 0x89, 0x95, 0x7a, 0x3d,
]);
