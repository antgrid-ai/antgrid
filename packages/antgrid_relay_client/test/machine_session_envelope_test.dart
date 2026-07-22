// MachineSession envelope/fragmentation/stream-demux coverage — the
// replacement for the deleted relay_transport_test.dart /
// relay_transport_frag_test.dart suites, now exercised at the MachineSession
// level (one E2E session multiplexing project streams via sealed `{s, m}`
// envelopes, per design §2/§7.1) instead of the old socket-per-project
// RelayTransport.
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_paired_relay.dart';

/// Opens the payload MachineSession sealed with the phone's send key (p2a) —
/// i.e. the transport's perspective when reading what MachineSession sent.
Future<String?> _openFromPhone(SessionKeys keys, Uint8List payload) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).open(payload);

/// Seals a plaintext as if it came from the agent (a2p) — what an inbound
/// IncomingRouteMessage's payload must look like for MachineSession to accept
/// it (`_decryptAndDispatch` decrypts with recvKey: a2p).
Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

void main() {
  late FakePairedRelay relay;
  late FakeHandshaker handshaker;
  late SessionKeys keys;
  late MachineSession session;

  setUp(() async {
    relay = FakePairedRelay();
    keys = fixedKeys(1);
    handshaker = FakeHandshaker(keys);
    session = MachineSession(
      relay: relay,
      machineDeviceId: 'machine-1',
      handshaker: handshaker,
    );
    session.start();
    await session.ready;
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  group('outbound envelope', () {
    test('sendOnStream wraps as sealed {s, m} addressed to the machine',
        () async {
      await session.sendOnStream('proj-1', {'type': 'ping'}, 'control');
      expect(relay.sent, hasLength(1));
      final frame = relay.sent.single;
      expect(frame.to, 'machine-1');
      expect(frame.kind, FrameKind.sealed);

      final plaintext = await _openFromPhone(keys, frame.payload);
      expect(plaintext, isNotNull);
      final json = jsonDecode(plaintext!) as Map<String, dynamic>;
      expect(json['s'], 'proj-1');
      expect(json['m'], {'type': 'ping'});
    });

    test('the control stream ("0") omits `s` entirely', () async {
      await session.sendOnStream(
          kControlStreamId, {'type': 'project:list'}, 'control');
      final plaintext = await _openFromPhone(keys, relay.sent.single.payload);
      final json = jsonDecode(plaintext!) as Map<String, dynamic>;
      expect(json.containsKey('s'), isFalse);
      expect(json['m'], {'type': 'project:list'});
    });

    test('a message above the fragmentation threshold is split into '
        'multiple frames, and reassembling them recovers the ENVELOPE '
        '(streamId `s` survives fragmentation)', () async {
      final bigContent = List.filled(2000000, 'x').join();
      final message = {
        'type': 'file:content',
        'path': 'a.png',
        'content': bigContent,
      };
      await session.sendOnStream('proj-1', message, 'control');

      expect(relay.sent.length, greaterThan(1),
          reason: 'a >1.4MB envelope must fragment');
      for (final f in relay.sent) {
        expect(f.kind, FrameKind.sealed);
      }

      final joined = <String>[];
      final reassembler = FragReassembler(
        timeoutMs: kTransferTimeoutMs,
        globalBudgetBytes: kGlobalReassemblyBudget,
        onComplete: (json, _) => joined.add(json),
        onAbort: (_) {},
      );
      for (final f in relay.sent) {
        final plaintext = await _openFromPhone(keys, f.payload);
        expect(plaintext, isNotNull);
        reassembler.accept(plaintext!);
      }

      expect(joined, hasLength(1));
      final envelope = jsonDecode(joined.single) as Map<String, dynamic>;
      expect(envelope['s'], 'proj-1',
          reason: 'the streamId must survive fragmentation intact');
      expect(envelope['m'], message);
    });
  });

  group('StreamTransport isolation', () {
    test('two streams on one session never cross-deliver', () async {
      final s1 = session.streamFor('proj-1');
      final s2 = session.streamFor('proj-2');
      expect(identical(s1, s2), isFalse);

      final seen1 = <Map<String, dynamic>>[];
      final seen2 = <Map<String, dynamic>>[];
      final sub1 = s1.messages.listen((m) => seen1.add(m.json));
      final sub2 = s2.messages.listen((m) => seen2.add(m.json));

      relay.inject(IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(
            keys, jsonEncode({'s': 'proj-1', 'm': {'type': 'a'}})),
      ));
      relay.inject(IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(
            keys, jsonEncode({'s': 'proj-2', 'm': {'type': 'b'}})),
      ));

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(seen1.map((j) => j['type']), ['a']);
      expect(seen2.map((j) => j['type']), ['b']);

      await sub1.cancel();
      await sub2.cancel();
    });

    test(
      'a control-plane envelope with `s` absent (or "0") routes to the '
      'control stream, not a project stream',
      () async {
        final control = session.streamFor(kControlStreamId);
        final seen = <Map<String, dynamic>>[];
        final sub = control.messages.listen((m) => seen.add(m.json));

        // `s` absent entirely.
        relay.inject(IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await _sealFromAgent(
              keys, jsonEncode({'m': {'type': 'agent:projects'}})),
        ));
        // `s` explicitly "0".
        relay.inject(IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await _sealFromAgent(keys,
              jsonEncode({'s': '0', 'm': {'type': 'agent:tools'}})),
        ));

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(seen.map((j) => j['type']),
            ['agent:projects', 'agent:tools']);
        await sub.cancel();
      },
    );
  });

  group('inbound fragment reassembly (replaces relay_transport_frag_test.dart)',
      () {
    test('a fragmented inbound envelope is reassembled and dispatched whole '
        'to the addressed stream', () async {
      final stream = session.streamFor('proj-1');
      final seen = <Map<String, dynamic>>[];
      final sub = stream.messages.listen((m) => seen.add(m.json));

      final bigContent = List.filled(2000000, 'y').join();
      final envelopeJson = jsonEncode({
        's': 'proj-1',
        'm': {'type': 'file:content', 'path': 'b.png', 'content': bigContent},
      });
      final fragments = buildFragments(
          envelopeJson, 'transfer-1', const FragHint('file:content', 'b.png'));
      expect(fragments.length, greaterThan(1));

      for (final frag in fragments) {
        relay.inject(IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await _sealFromAgent(keys, frag),
        ));
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

      relay.inject(IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(keys, frame0),
      ));
      relay.inject(IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(keys, frame1),
      ));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(aborts, hasLength(1));
      expect(aborts.single?.type, hint.type);
      expect(aborts.single?.key, hint.key);

      await sub.cancel();
    });
  });
}
