import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:test/test.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Stands in for the host-installed native cipher: delegates to the real
/// algorithm, but records whether the transport routed through this instance.
/// Delegation rather than `extends DartAesGcm` — that class marks
/// encrypt/decrypt `@nonVirtual`.
class _CountingAesGcm extends AesGcm {
  _CountingAesGcm() : super.constructor();

  final AesGcm _inner = DartAesGcm(secretKeyLength: 32);

  int encrypts = 0;
  int decrypts = 0;

  @override
  int get nonceLength => _inner.nonceLength;

  @override
  int get secretKeyLength => _inner.secretKeyLength;

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) {
    encrypts++;
    return _inner.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const <int>[],
    Uint8List? possibleBuffer,
  }) {
    decrypts++;
    return _inner.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }
}

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  E2eTransportDart transport() =>
      E2eTransportDart(sendKey: Uint8List.fromList(key), recvKey: Uint8List.fromList(key));

  tearDown(() => E2eTransportDart.useAlgorithm(AesGcm.with256bits()));

  test('useAlgorithm routes seal and open through the installed cipher', () async {
    final counting = _CountingAesGcm();
    E2eTransportDart.useAlgorithm(counting);

    final t = transport();
    final sealed = await t.seal('hello');
    expect(await t.open(sealed), 'hello');
    expect(counting.encrypts, 1);
    expect(counting.decrypts, 1);
  });

  // The bridge half is node:crypto's aes-256-gcm and never learns which
  // implementation the app installed, so an installed cipher that isn't
  // byte-compatible with the default would break the session, not slow it down.
  test('an installed cipher stays wire-compatible with the default', () async {
    final plaintext = 'x' * 5000;

    E2eTransportDart.useAlgorithm(_CountingAesGcm());
    final sealedByInstalled = await transport().seal(plaintext);

    E2eTransportDart.useAlgorithm(AesGcm.with256bits());
    expect(await transport().open(sealedByInstalled), plaintext);

    final sealedByDefault = await transport().seal(plaintext);
    E2eTransportDart.useAlgorithm(_CountingAesGcm());
    expect(await transport().open(sealedByDefault), plaintext);
  });

  test('open still returns null for a corrupt frame', () async {
    E2eTransportDart.useAlgorithm(_CountingAesGcm());
    final t = transport();
    final sealed = await t.seal('payload');
    sealed[sealed.length - 1] ^= 1;
    expect(await t.open(sealed), isNull);
  });
}
