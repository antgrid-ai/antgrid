// Cross-language pin for the relay control envelopes: this package mirrors
// the antgrid-wire Zod schemas BY HAND, and this test runs the shared golden
// fixture through that mirror. The TS side
// (packages/antgrid-wire/tests/relay-envelope-vectors.test.ts) guarantees the
// fixture covers every union variant and ErrorCode, so a wire-schema change
// that isn't mirrored here fails at test time instead of at runtime on a
// device. Regenerate the fixture:
//   cd packages/antgrid-wire && bun run scripts/gen-envelope-vectors.ts
import 'dart:convert';
import 'dart:io';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  final v =
      jsonDecode(
            File(
              '../../evals/fixtures/relay-envelope-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  final server = (v['server'] as List).cast<Map<String, dynamic>>();
  final client = (v['client'] as List).cast<Map<String, dynamic>>();

  group('server vectors (relay → client)', () {
    for (final vec in server) {
      final name = vec['name'] as String;
      final dart = vec['dart'] as String;
      final json = (vec['json'] as Map<String, dynamic>);

      test('$name → $dart', () {
        final parsed = parseRelayMessage(json);
        if (dart == 'tolerated') {
          // Agent-only frames: the tolerance contract says fall through to
          // null, never throw — an app must ignore what it doesn't speak.
          expect(parsed, isNull);
          return;
        }
        expect(parsed, isNotNull, reason: 'mirror failed to parse $name');
        switch (json['type'] as String) {
          case 'welcome':
            final m = parsed as WelcomeMessage?;
            expect(m!.deviceId, json['deviceId']);
            expect(m.epoch, json['epoch']);
            expect(m.serverTime, json['serverTime']);
          case 'stream-opened':
            expect(
              (parsed as StreamOpenedMessage?)!.streamId,
              json['streamId'],
            );
          case 'stream-closed':
            expect(
              (parsed as StreamClosedMessage?)!.streamId,
              json['streamId'],
            );
          case 'error':
            final m = parsed as ErrorMessage?;
            expect(m!.code, json['code']);
            expect(m.message, json['message']);
            expect(m.retryable, json['retryable']);
            expect(m.ref, json['ref']);
            expect(m.serverTime, json['serverTime']);
          case 'peer-online':
            expect((parsed as PeerOnlineMessage?)!.peerId, json['peerId']);
          case 'peer-offline':
            expect((parsed as PeerOfflineMessage?)!.peerId, json['peerId']);
          default:
            fail(
              'vector $name marked parsed but has no field assertions — '
              'add a case when mirroring a new server frame',
            );
        }
      });
    }
  });

  group('client vectors (client → relay)', () {
    for (final vec in client.where((c) => c['dartEmits'] == true)) {
      final name = vec['name'] as String;
      final json = (vec['json'] as Map<String, dynamic>);

      test('$name emitted byte-identical', () {
        final Map<String, dynamic> emitted = switch (json['type'] as String) {
          'hello' => HelloMessage(
            deviceType: json['deviceType'] as String,
            deviceId: json['deviceId'] as String,
            name: json['name'] as String,
            publicKey: json['publicKey'] as String,
            epoch: json['epoch'] as int,
            licenseToken: json['licenseToken'] as String,
            ts: json['ts'] as String,
            nonce: json['nonce'] as String,
            sig: json['sig'] as String,
          ).toJson(),
          'stream-open' => StreamOpenMessage(
            streamId: json['streamId'] as String,
          ).toJson(),
          'stream-close' => StreamCloseMessage(
            streamId: json['streamId'] as String,
          ).toJson(),
          _ => fail(
            'vector $name marked dartEmits but has no constructor '
            'case — add one when the Dart client learns to send it',
          ),
        };
        expect(emitted, equals(json));
      });
    }
  });
}
