// Throughput comparison for the E2E transport cipher. Deliberately NOT named
// `*_test.dart`: it is a measurement, not a gate, and has no business in a
// suite sweep. Run it explicitly:
//
//   cd app && flutter test test/config/webcrypto_bench.dart
//
// Numbers are only meaningful against each other on one machine — the ratio is
// the finding, never the absolute MB/s.
import 'dart:typed_data';

import 'package:antgrid/config/webcrypto_aes_gcm.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

Future<double> _mbPerSecond(
  AesGcm cipher,
  int payloadBytes,
  int iterations,
) async {
  final key = SecretKeyData(Uint8List(32)..fillRange(0, 32, 9));
  final data = Uint8List(payloadBytes)..fillRange(0, payloadBytes, 0x41);
  final box = await cipher.encrypt(data, secretKey: key);

  // Warm the key import and any lazy plugin lookup out of the timed window.
  await cipher.decrypt(box, secretKey: key);

  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await cipher.decrypt(box, secretKey: key);
  }
  sw.stop();
  return (payloadBytes * iterations) /
      (sw.elapsedMicroseconds == 0 ? 1 : sw.elapsedMicroseconds);
}

void main() {
  final ciphers = <String, AesGcm>{
    'DartAesGcm (in-isolate fallback)': AesGcm.with256bits(),
    'FlutterAesGcm (today on Windows/Linux)': FlutterAesGcm(secretKeyLength: 32),
    'WebcryptoAesGcm (BoringSSL)': WebcryptoAesGcm(),
  };

  final workloads = <String, (int, int)>{
    'control frame 256 B': (256, 2000),
    'tree/diff 64 KB': (64 * 1024, 200),
    'preview asset 2 MB': (2 * 1024 * 1024, 10),
  };

  for (final w in workloads.entries) {
    test('decrypt throughput — ${w.key}', () async {
      final (size, iterations) = w.value;
      for (final c in ciphers.entries) {
        final mbps = await _mbPerSecond(c.value, size, iterations);
        // ignore: avoid_print
        print(
          '${w.key.padRight(20)} | ${c.key.padRight(38)} | '
          '${mbps.toStringAsFixed(1).padLeft(8)} MB/s',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
