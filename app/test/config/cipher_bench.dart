// Throughput comparison for the E2E transport cipher. Deliberately NOT named
// `*_test.dart`: it is a measurement, not a gate, and has no business in a
// suite sweep. Run it explicitly:
//
//   cd app && flutter test test/config/cipher_bench.dart
//
// Numbers are only meaningful against each other on one machine — the ratio is
// the finding, never the absolute MB/s. The size sweep is what settles whether
// a cipher needs a size threshold. A flat per-call floor is what forces one —
// at ~24us an FFI cipher is a regression under ~512 B; CNG's ~1us floor is why
// it needs none.
//
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid/config/cng_aes_gcm.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

Future<double> _microsPerOp(AesGcm cipher, int payloadBytes, int iterations)
    async {
  final key = SecretKeyData(Uint8List(32)..fillRange(0, 32, 9));
  final data = Uint8List(payloadBytes)..fillRange(0, payloadBytes, 0x41);
  final box = await cipher.encrypt(data, secretKey: key);

  // Warm every size before measuring any of them. Without this the first row
  // read 3.5x slow and invented a small-frame crossover that does not exist.
  for (var i = 0; i < 20; i++) {
    await cipher.decrypt(box, secretKey: key);
  }

  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await cipher.decrypt(box, secretKey: key);
  }
  sw.stop();
  return sw.elapsedMicroseconds / iterations;
}

void main() {
  final ciphers = <String, AesGcm>{
    'DartAesGcm (in-isolate fallback)': AesGcm.with256bits(),
    'FlutterAesGcm (Linux today)': FlutterAesGcm(secretKeyLength: 32),
    if (Platform.isWindows) 'CngAesGcm (bcrypt.dll)': CngAesGcm(),
  };

  final workloads = <String, (int, int)>{
    'small control frame 64 B': (64, 2000),
    'control frame 256 B': (256, 2000),
    'terminal batch 4 KB': (4 * 1024, 2000),
    'terminal batch 64 KB': (64 * 1024, 200),
    'preview asset 2 MB': (2 * 1024 * 1024, 20),
  };

  setUpAll(() {
    if (Platform.isWindows) expect(CngAesGcm.probe(), isTrue);
  });

  for (final w in workloads.entries) {
    test('decrypt throughput — ${w.key}', () async {
      final (size, iterations) = w.value;
      for (final c in ciphers.entries) {
        final us = await _microsPerOp(c.value, size, iterations);
        print(
          '${w.key.padRight(24)} | ${c.key.padRight(34)} | '
          '${us.toStringAsFixed(2).padLeft(9)} us | '
          '${(size / us).toStringAsFixed(1).padLeft(8)} MB/s',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
