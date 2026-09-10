import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid/config/cng_aes_gcm.dart';
import 'package:antgrid/config/native_crypto.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // The same fixture `packages/antgrid_relay_client/test/e2e_vectors_test.dart`
  // and `evals/tests/gate-vectors.test.ts` pin, so a cipher that passes here is
  // byte-compatible with what the bridge seals.
  final vectors =
      jsonDecode(
            File(
              '../evals/fixtures/e2e-handshake-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final schedule = vectors['keySchedule'] as Map<String, dynamic>;

  E2eTransportDart phoneTransport() => E2eTransportDart(
    sendKey: _hex(schedule['kP2aHex'] as String),
    recvKey: _hex(schedule['kA2pHex'] as String),
  );

  // Keys are directional, so a transport cannot open what it sealed — the
  // agent's mirror is what reads a phone frame.
  E2eTransportDart agentTransport() => E2eTransportDart(
    sendKey: _hex(schedule['kA2pHex'] as String),
    recvKey: _hex(schedule['kP2aHex'] as String),
  );

  group('CngAesGcm', () {
    setUp(() {
      CngAesGcm.evictImportedKeys();
      expect(CngAesGcm.probe(), isTrue);
      E2eTransportDart.useAlgorithm(CngAesGcm());
    });
    tearDown(() {
      E2eTransportDart.useAlgorithm(AesGcm.with256bits());
      CngAesGcm.evictImportedKeys();
    });

    test('BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO is 88 bytes on x64', () {
      expect(CngAesGcm.authCipherModeInfoSize, CngAesGcm.authInfoSizeX64);
    });

    test('reproduces the golden transport vectors', () async {
      final transport = phoneTransport();
      for (final v
          in (vectors['transport'] as List).cast<Map<String, dynamic>>()) {
        if (v['dir'] == 'a2p') {
          expect(
            await transport.open(_hex(v['sealedHex'] as String)),
            v['plaintext'],
          );
        } else {
          expect(
            _hexOf(
              await transport.seal(
                v['plaintext'] as String,
                fixedNonce: _hex(v['nonceHex'] as String),
              ),
            ),
            v['sealedHex'],
          );
        }
      }
    });

    test('frames interoperate with the default pure Dart cipher', () async {
      // Sized past the point where a preview response stops being a control
      // frame — the payload class the swap exists for. Compared by digest so a
      // regression reports a hash rather than 200 KB of diff.
      final plaintext = 'x' * 200000;
      final digest = sha256.convert(utf8.encode(plaintext)).toString();
      String? digestOf(String? s) =>
          s == null ? null : sha256.convert(utf8.encode(s)).toString();

      final sealedByCng = await phoneTransport().seal(plaintext);
      E2eTransportDart.useAlgorithm(AesGcm.with256bits());
      expect(digestOf(await agentTransport().open(sealedByCng)), digest);

      final sealedByDart = await agentTransport().seal(plaintext);
      E2eTransportDart.useAlgorithm(CngAesGcm());
      expect(digestOf(await phoneTransport().open(sealedByDart)), digest);
    });

    test('an empty payload round-trips', () async {
      // Reachable from the network: a 28-byte frame decrypts to nothing, and
      // CNG rejects a NULL pbInput even at cbInput == 0.
      final sealed = await phoneTransport().seal('');
      expect(sealed, hasLength(12 + 16));
      expect(await agentTransport().open(sealed), '');
    });

    test('a tampered frame is dropped, not thrown', () async {
      final sealed = await phoneTransport().seal('payload');
      sealed[sealed.length - 1] ^= 1;
      // Pins the NTSTATUS sign masking: BCryptDecrypt returns
      // STATUS_AUTH_TAG_MISMATCH through Int32, so an unmasked comparison never
      // matches and this frame throws a StateError instead of dropping.
      expect(await agentTransport().open(sealed), isNull);
    });

    test('a truncated tag is rejected, not verified short', () async {
      final cipher = CngAesGcm();
      final key = SecretKeyData(Uint8List(32)..fillRange(0, 32, 5));
      final box = await cipher.encrypt(utf8.encode('hello'), secretKey: key);
      final truncated = SecretBox(
        box.cipherText,
        nonce: box.nonce,
        mac: Mac(box.mac.bytes.sublist(0, 12)),
      );
      // CNG's GCM would happily verify a 12-byte tag; every other
      // implementation of this interface refuses one.
      await expectLater(
        cipher.decrypt(truncated, secretKey: key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('AAD is authenticated, not ignored', () async {
      final cipher = CngAesGcm();
      final key = SecretKeyData(Uint8List(32)..fillRange(0, 32, 7));
      final aad = utf8.encode('bound-context');
      final box = await cipher.encrypt(
        utf8.encode('payload'),
        secretKey: key,
        aad: aad,
      );

      // An independent implementation must accept it with the same AAD...
      expect(
        utf8.decode(
          await AesGcm.with256bits().decrypt(box, secretKey: key, aad: aad),
        ),
        'payload',
      );
      // ...and this one must refuse it with different AAD. A cipher that drops
      // AAD on the floor passes its own round trip and fails both of these.
      await expectLater(
        cipher.decrypt(box, secretKey: key, aad: utf8.encode('other')),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a wrong-sized key or nonce is refused in Dart', () async {
      final cipher = CngAesGcm();
      // CNG picks AES-128/192/256 from the key length alone, so a 16-byte key
      // would otherwise produce a valid AES-128 frame the bridge cannot open.
      await expectLater(
        cipher.encrypt(utf8.encode('x'), secretKey: SecretKeyData(Uint8List(16))),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        cipher.encrypt(
          utf8.encode('x'),
          secretKey: SecretKeyData(Uint8List(32)),
          nonce: Uint8List(16),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the key cache survives a caller zeroizing its key in place', () async {
      final cipher = CngAesGcm();
      final live = Uint8List(32)..fillRange(0, 32, 0x11);
      final nonce = Uint8List(12)..fillRange(0, 12, 0x22);

      await cipher.encrypt(
        utf8.encode('first'),
        secretKey: SecretKeyData(live),
        nonce: nonce,
      );
      // What SessionKeys.zeroize does to the buffer the cache was keyed on.
      live.fillRange(0, live.length, 0);

      final zeroKey = Uint8List(32);
      final box = await cipher.encrypt(
        utf8.encode('second'),
        secretKey: SecretKeyData(zeroKey),
        nonce: nonce,
      );

      // Decrypted by an independent implementation: if the cache had handed
      // back the 0x11 handle, this would fail its tag.
      expect(
        utf8.decode(
          await AesGcm.with256bits().decrypt(
            box,
            secretKey: SecretKeyData(zeroKey),
          ),
        ),
        'second',
      );
    });

    test('the cache is bounded and eviction destroys the handle', () async {
      final cipher = CngAesGcm();
      for (var i = 0; i < 6; i++) {
        await cipher.encrypt(
          utf8.encode('x'),
          secretKey: SecretKeyData(Uint8List(32)..fillRange(0, 32, i + 1)),
        );
      }
      expect(CngAesGcm.importedKeyCount, 4);
      // An evicted handle was destroyed, so re-using its key must generate a
      // fresh one rather than resurrect the old value.
      await cipher.encrypt(
        utf8.encode('x'),
        secretKey: SecretKeyData(Uint8List(32)..fillRange(0, 32, 1)),
      );
      expect(CngAesGcm.importedKeyCount, 4);
    });

    test('overlapping frames cannot evict a handle mid-call', () async {
      // The eviction hazard is structural, not hypothetical: if anything ever
      // puts an await between the cache lookup and the BCrypt call, one of these
      // destroys the other's handle before it is used.
      final cipher = CngAesGcm();
      final keys = List.generate(
        8,
        (i) => SecretKeyData(Uint8List(32)..fillRange(0, 32, 0x30 + i)),
      );
      final boxes = await Future.wait([
        for (var i = 0; i < keys.length; i++)
          cipher.encrypt(utf8.encode('frame $i'), secretKey: keys[i]),
      ]);
      for (var i = 0; i < keys.length; i++) {
        expect(
          utf8.decode(
            await AesGcm.with256bits().decrypt(boxes[i], secretKey: keys[i]),
          ),
          'frame $i',
        );
      }
    });
  }, skip: Platform.isWindows ? false : 'Windows-only');

  test('off Windows the transport keeps the cryptography_flutter cipher', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Must not throw: nothing in the CNG path may be touched off Windows.
    installNativeE2eCipher();
    E2eTransportDart.useAlgorithm(AesGcm.with256bits());
  });
}
