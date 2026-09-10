import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid/config/webcrypto_aes_gcm.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
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

  // The golden frames are 16 bytes, well under the production threshold, so a
  // default-configured cipher would answer them from the Dart fallback and
  // prove nothing about BoringSSL. Force the FFI path for these.
  WebcryptoAesGcm alwaysFfi() => WebcryptoAesGcm(minBytesWorthFfi: 0);

  setUp(() {
    WebcryptoAesGcm.evictImportedKeys();
    E2eTransportDart.useAlgorithm(alwaysFfi());
  });
  tearDown(() => E2eTransportDart.useAlgorithm(AesGcm.with256bits()));

  test('BoringSSL cipher reproduces the golden transport vectors', () async {
    final transport = phoneTransport();
    for (final v in (vectors['transport'] as List).cast<Map<String, dynamic>>()) {
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

    final sealedByBoringSsl = await phoneTransport().seal(plaintext);
    E2eTransportDart.useAlgorithm(AesGcm.with256bits());
    expect(digestOf(await agentTransport().open(sealedByBoringSsl)), digest);

    final sealedByDart = await agentTransport().seal(plaintext);
    E2eTransportDart.useAlgorithm(alwaysFfi());
    expect(digestOf(await phoneTransport().open(sealedByDart)), digest);
  });

  test('a tampered frame is dropped, not thrown', () async {
    final sealed = await phoneTransport().seal('payload');
    sealed[sealed.length - 1] ^= 1;
    // BoringSSL reports a bad tag as an OperationError, which extends Error —
    // `open`'s catch would not hold it without the adapter's translation.
    expect(await agentTransport().open(sealed), isNull);
  });

  test('a frame below the threshold never reaches BoringSSL', () async {
    // Observable through the key cache: the Dart fallback imports nothing.
    final cipher = WebcryptoAesGcm();
    final key = SecretKeyData(Uint8List(32)..fillRange(0, 32, 3));

    final small = await cipher.encrypt(
      Uint8List(WebcryptoAesGcm.defaultMinBytesWorthFfi - 1),
      secretKey: key,
    );
    expect(WebcryptoAesGcm.importedKeyCount, 0);
    expect(await cipher.decrypt(small, secretKey: key), hasLength(511));
    expect(WebcryptoAesGcm.importedKeyCount, 0);

    // And the two paths stay wire-compatible across the boundary.
    final big = await cipher.encrypt(
      Uint8List(WebcryptoAesGcm.defaultMinBytesWorthFfi),
      secretKey: key,
    );
    expect(WebcryptoAesGcm.importedKeyCount, 1);
    expect(
      await AesGcm.with256bits().decrypt(big, secretKey: key),
      hasLength(512),
    );
  });

  test('the key cache survives a caller zeroizing its key in place', () async {
    final cipher = alwaysFfi();
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

    // Decrypted by an independent implementation: if the cache had handed back
    // the 0x11 key, this would fail its tag.
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
}
