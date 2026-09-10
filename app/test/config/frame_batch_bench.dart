// What a terminal batch costs the app to receive, per byte of terminal output.
// Deliberately NOT named `*_test.dart`: it is a measurement, not a gate. Run it
// explicitly:
//
//   cd app && flutter test test/config/frame_batch_bench.dart
//
// This exists to settle `BATCH_MAX_BYTES` in `bridge/src/terminal-session.ts`
// with numbers instead of arithmetic. The bridge coalesces PTY output into one
// `terminal:output` frame per 4096 bytes or 16 ms, whichever comes first, so
// raising that constant trades FRAME COUNT for FRAME SIZE. Every stage below is
// timed separately because they scale differently: `open` (AES-GCM) and
// `jsonDecode` scale with bytes and so barely move, while the envelope parse,
// the stream lookup and the message parse are FIXED per frame and are the only
// thing a larger batch actually removes.
//
// Reproduces the receive path in `MachineSession._dispatchDecoded`
// (`packages/antgrid_relay_client/lib/src/machine_session.dart`) — the terminal
// write itself is not included, because it is xterm's cost and not the wire's.
//
// The number to read is the LAST column: microseconds of app CPU per KB of
// terminal output. If it is flat across batch sizes, the constant is not a
// lever and the answer is to leave it alone.
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid/config/cng_aes_gcm.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// One second of a chatty build's stdout: mostly printable, with the ANSI and
/// non-ASCII that make a JSON string escape-heavy rather than a memcpy.
String _terminalChunk(int bytes) {
  const line = '\x1b[32m✔\x1b[0m  compiled src/components/Widget.tsx '
      '\x1b[2m(1.4 kB, 12 ms)\x1b[0m\r\n';
  final b = StringBuffer();
  while (b.length < bytes) {
    b.write(line);
  }
  return b.toString().substring(0, bytes);
}

void main() {
  const totalBytes = 4 * 1024 * 1024;
  const batchSizes = [1024, 4096, 8192, 16384, 32768, 65536, 262144];

  test('receive cost per KB of terminal output, by batch size', () async {
    if (Platform.isWindows) {
      expect(CngAesGcm.probe(), isTrue);
      E2eTransportDart.useAlgorithm(CngAesGcm());
      print('cipher: CNG (bcrypt.dll)');
    } else {
      print('cipher: package:cryptography default (pure Dart)');
    }

    final key = Uint8List(32)..fillRange(0, 32, 0x5a);
    final agent = E2eTransportDart(sendKey: key, recvKey: key);
    final app = E2eTransportDart(sendKey: key, recvKey: key);

    print('');
    print('    batch   frames      open   jsonDecode   envelope+parse'
        '        total     us/KB');
    for (final batch in batchSizes) {
      final frames = totalBytes ~/ batch;
      final payload = _terminalChunk(batch);
      // Sealed once per size, not per iteration: the bridge's seal cost is the
      // bridge's, and including it here would measure the wrong process.
      final sealed = await agent.seal(
        jsonEncode({
          's': 'stream-1',
          'm': {
            'type': 'terminal:output',
            'id': 'm1',
            'timestamp': 0,
            'terminalId': 't1',
            'data': payload,
          },
        }),
      );

      for (var i = 0; i < 3; i++) {
        final w = await app.open(sealed);
        parseAbMessage(
          (jsonDecode(w!) as Map<String, dynamic>)['m'] as Map<String, dynamic>,
        );
      }

      var sw = Stopwatch()..start();
      String? plaintext;
      for (var i = 0; i < frames; i++) {
        plaintext = await app.open(sealed);
      }
      sw.stop();
      final openUs = sw.elapsedMicroseconds;

      sw = Stopwatch()..start();
      Map<String, dynamic>? decoded;
      for (var i = 0; i < frames; i++) {
        decoded = jsonDecode(plaintext!) as Map<String, dynamic>;
      }
      sw.stop();
      final jsonUs = sw.elapsedMicroseconds;

      sw = Stopwatch()..start();
      for (var i = 0; i < frames; i++) {
        final env = StreamEnvelope.fromJson(decoded!);
        parseAbMessage(env!.m! as Map<String, dynamic>);
      }
      sw.stop();
      final parseUs = sw.elapsedMicroseconds;

      final total = openUs + jsonUs + parseUs;
      String c(int us) => (us / 1000).toStringAsFixed(1).padLeft(9);
      print('  ${batch.toString().padLeft(7)}  ${frames.toString().padLeft(7)}'
          '  ${c(openUs)}ms ${c(jsonUs)}ms   ${c(parseUs)}ms  ${c(total)}ms'
          '  ${(total / (totalBytes / 1024)).toStringAsFixed(2).padLeft(8)}');
    }

    E2eTransportDart.useAlgorithm(AesGcm.with256bits());
  }, timeout: const Timeout(Duration(minutes: 10)));
}
