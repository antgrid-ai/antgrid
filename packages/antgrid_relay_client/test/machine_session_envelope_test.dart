// MachineSession control-plane envelope/fragmentation coverage. Since Stage A
// A4 a project's traffic rides its own native QUIC stream as bare AbMessage
// JSON (see machine_session_project_stream_test.dart) — only the control
// plane (the session stream) still uses the `{s, m}` envelope, and `s` is
// always absent on it now that there is no project id left to carry.
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  late FakeLiveRelay relay;
  late FakeHandshaker handshaker;
  late MachineSession session;

  setUp(() async {
    relay = FakeLiveRelay();
    handshaker = FakeHandshaker();
    session = await establishSession(relay, handshaker: handshaker);
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  group('outbound envelope', () {
    test('sendOnSession wraps as a plaintext {m} envelope with no `s`', () async {
      await session.sendOnSession({'type': 'project:list'}, 'control');
      expect(relay.sent, hasLength(1));
      final plaintext = decodeFromPhone(relay.sent.single.payload);
      final json = jsonDecode(plaintext) as Map<String, dynamic>;
      expect(json.containsKey('s'), isFalse);
      expect(json['m'], {'type': 'project:list'});
    });

    test('a message above the fragmentation threshold is split into '
        'multiple frames, and reassembling them recovers the ENVELOPE', () async {
      final bigContent = List.filled(2000000, 'x').join();
      final message = {
        'type': 'file:content',
        'path': 'a.png',
        'content': bigContent,
      };
      await session.sendOnSession(message, 'control');

      expect(
        relay.sent.length,
        greaterThan(1),
        reason: 'a >1.4MB envelope must fragment',
      );

      final joined = <String>[];
      final reassembler = FragReassembler(
        timeoutMs: kTransferTimeoutMs,
        globalBudgetBytes: kGlobalReassemblyBudget,
        onComplete: (json, _, __, ___) => joined.add(json),
        onAbort: (_) {},
      );
      for (final f in relay.sent) {
        final plaintext = decodeFromPhone(f.payload);
        reassembler.accept(
          plaintext,
          frameId: frameIdOf(f.payload),
          epoch: 1,
        );
      }

      expect(joined, hasLength(1));
      final envelope = jsonDecode(joined.single) as Map<String, dynamic>;
      expect(envelope.containsKey('s'), isFalse);
      expect(envelope['m'], message);
    });
  });

  group(
    'inbound fragment reassembly (replaces relay_transport_frag_test.dart)',
    () {
      test('a fragmented inbound envelope is reassembled and dispatched whole '
          'to the control transport', () async {
        final control = session.control;
        final seen = <Map<String, dynamic>>[];
        final sub = control.messages.listen((m) => seen.add(m.json));

        final bigContent = List.filled(2000000, 'y').join();
        final envelopeJson = jsonEncode({
          'm': {'type': 'file:content', 'path': 'b.png', 'content': bigContent},
        });
        final fragments = buildFragments(
          envelopeJson,
          'transfer-1',
          const FragHint('file:content', 'b.png'),
        );
        expect(fragments.length, greaterThan(1));

        for (final frag in fragments) {
          relay.inject(
            IncomingPeerFrame(
              channel: 'control',
              payload: encodeFromAgent(frag),
            ),
          );
        }

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(seen, hasLength(1));
        expect(seen.single['type'], 'file:content');
        expect(seen.single['content'], bigContent);

        await sub.cancel();
      });

      test('a mismatched fragment count aborts the transfer and surfaces the '
          'hint on fragmentAborts', () async {
        final aborts = <FragHint?>[];
        final sub = session.fragmentAborts.listen(aborts.add);

        const id = 'transfer-bad';
        final hint = const FragHint('file:content', 'c.png');
        final frame0 = jsonEncode({
          '__frag': {
            'id': id,
            'i': 0,
            'n': 2,
            'hint': {'type': hint.type, 'key': hint.key},
          },
          'data': 'part-a',
        });
        // Second fragment claims a DIFFERENT total `n` for the same id — the
        // reassembler discards the whole transfer and reports the hint.
        final frame1 = jsonEncode({
          '__frag': {'id': id, 'i': 0, 'n': 3},
          'data': 'part-b',
        });

        relay.inject(
          IncomingPeerFrame(
            channel: 'control',
            payload: encodeFromAgent(frame0),
          ),
        );
        relay.inject(
          IncomingPeerFrame(
            channel: 'control',
            payload: encodeFromAgent(frame1),
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(aborts, hasLength(1));
        expect(aborts.single?.type, hint.type);
        expect(aborts.single?.key, hint.key);

        await sub.cancel();
      });
    },
  );
}
