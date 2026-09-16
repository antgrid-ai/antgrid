import 'dart:convert';
import 'dart:io';

import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  test(
    'TS and Dart sign identical endpoint registration transcripts',
    () async {
      final fixture =
          jsonDecode(
                await File(
                  '../../evals/fixtures/endpoint-registration-vectors.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final bytes = endpointChallengeBytes(
        fixture['challenge'] as Map<String, dynamic>,
      );
      expect(
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        fixture['transcriptHex'],
      );
      final algorithm = Ed25519();
      for (final prefix in ['device', 'endpoint']) {
        final key = await algorithm.newKeyPairFromSeed(
          base64Decode(fixture['${prefix}Seed'] as String),
        );
        final signature = await algorithm.sign(bytes, keyPair: key);
        expect(base64Encode(signature.bytes), fixture['${prefix}Signature']);
      }
    },
  );
}
