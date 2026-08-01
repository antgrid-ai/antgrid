import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  group('frag helpers', () {
    test('accepts and rejects fragment envelopes', () {
      expect(
        isFragEnvelope({
          '__frag': {'id': 'a', 'i': 0, 'n': 2},
          'data': 'x',
        }),
        isTrue,
      );
      expect(isFragEnvelope({'type': 'file:content', 'path': 'a'}), isFalse);
      expect(isFragEnvelope(null), isFalse);
      expect(
        isFragEnvelope({
          '__frag': {'id': 'a', 'i': 0, 'n': 1},
        }),
        isFalse,
      );
      expect(
        isFragEnvelope({
          '__frag': {'id': 'a', 'i': '0', 'n': 1},
          'data': 'x',
        }),
        isFalse,
      );
    });

    test('exposes budget constants', () {
      expect(kMaxFramePayload, 1500000);
      expect(kFragThreshold, 1400000);
      expect(kFragDataBudget, 1400000);
      expect(kMaxTransferBytes, 33554432);
      expect(kTransferTimeoutMs, 10000);
      expect(kGlobalReassemblyBudget, 67108864);
      expect(kMaxRerequests, 1);
    });

    test('split rejoins exactly and does not split emoji', () {
      final s = '😀😀😀';
      final slices = splitForJsonData(s, 5);
      expect(slices, ['😀', '😀', '😀']);
      expect(slices.join(), s);
    });

    test('split counts escaped quote and backslash budget', () {
      final s = '${List.filled(4, '\\').join()}${List.filled(4, '"').join()}';
      final slices = splitForJsonData(s, 4);
      expect(slices, ['\\\\', '\\\\', '""', '""']);
      expect(slices.join(), s);
    });

    test('split preserves lone surrogates and respects escaped budget', () {
      final loneHigh = String.fromCharCode(0xd800);
      final loneLow = String.fromCharCode(0xdc00);
      final s = 'a${loneHigh}b${loneLow}c';
      final slices = splitForJsonData(s, 6);

      expect(slices.join(), s);
      expect(slices, ['a', loneHigh, 'b', loneLow, 'c']);
      for (final slice in slices) {
        expect(_jsonStringEscapedBytes(slice), lessThanOrEqualTo(6));
      }
    });

    test('buildFragments repeats hint on later fragments', () {
      final json = jsonEncode({
        'type': 'file:content',
        'path': 'a.png',
        'content': List.filled(2500, 'x').join(),
      });
      final frames = buildFragments(
        json,
        'tid',
        const FragHint('file:content', 'a.png'),
        1000,
      );
      final parsed = frames
          .map((f) => jsonDecode(f) as Map<String, dynamic>)
          .toList();
      expect(parsed.length, greaterThan(1));
      expect(parsed[0]['__frag'], containsPair('id', 'tid'));
      expect(parsed[0]['__frag'], containsPair('i', 0));
      expect(parsed[0]['__frag'], containsPair('n', parsed.length));
      expect(parsed[1]['__frag']['hint'], {
        'type': 'file:content',
        'key': 'a.png',
      });
      expect(parsed.map((p) => p['data'] as String).join(), json);
    });

    // The reassembly budget is charged with this instead of
    // `utf8.encode(data).length`, and the bridge charges the same transfer via
    // Buffer.byteLength — so agreeing with the encoder is the whole contract.
    group('utf8ByteLength matches utf8.encode', () {
      for (final sample in {
        'empty': '',
        'ascii': 'export const a = 1;',
        'two-byte': 'héllo wörld — ünïcode',
        'three-byte': '日本語のテキスト ☃',
        'astral': '𝄞 𝕳𝖊𝖑𝖑𝖔 👨‍👩‍👧‍👦 🇯🇵',
        'mixed': 'a é 日 𝄞 z',
        'json payload': '{"body":"const x = \\"quoted\\";\\n\\t"}',
      }.entries) {
        test(sample.key, () {
          expect(
            utf8ByteLength(sample.value),
            utf8.encode(sample.value).length,
            reason: sample.key,
          );
        });
      }

      // Dart's encoder substitutes U+FFFD (3 bytes) for a surrogate it cannot
      // pair. Undercounting these would let a hostile peer sit above the global
      // reassembly budget without ever tripping it.
      test('unpaired surrogates', () {
        for (final s in [
          '\ud800', // lone high, at end of string
          '\udc00', // lone low
          'a\ud800b', // lone high, followed by a non-surrogate
          '\ud800\ud800', // high followed by another high
          '😀', // a REAL pair — must stay 4 bytes, not 6
        ]) {
          expect(utf8ByteLength(s), utf8.encode(s).length, reason: s.codeUnits.toString());
        }
      });
    });
  });

  group('FragReassembler', () {
    test('reassembles in-order fragments', () {
      final json = jsonEncode({
        'type': 'x',
        'blob': List.filled(2500, 'y').join(),
      });
      final done = <String>[];
      final r = FragReassembler(
        timeoutMs: 1000,
        globalBudgetBytes: 10000000,
        onComplete: (json, _) => done.add(json),
        onAbort: (_) {},
        now: () => 0,
      );

      for (final f in buildFragments(json, 't1', null, 1000)) {
        expect(r.accept(f), isTrue);
      }

      expect(done, [json]);
    });

    test('returns false for non-fragment plaintext', () {
      final r = FragReassembler(
        timeoutMs: 1000,
        globalBudgetBytes: 10000000,
        onComplete: (_, __) {},
        onAbort: (_) {},
        now: () => 0,
      );
      expect(r.accept(jsonEncode({'type': 'file:content'})), isFalse);
    });

    test('consumes malformed fragment marker with invalid JSON', () {
      final done = <String>[];
      final r = FragReassembler(
        timeoutMs: 1000,
        globalBudgetBytes: 10000000,
        onComplete: (json, _) => done.add(json),
        onAbort: (_) {},
        now: () => 0,
      );

      expect(r.accept('{"__frag":'), isTrue);
      expect(done, isEmpty);
    });

    test('consumes malformed fragment marker with invalid envelope shape', () {
      final done = <String>[];
      final r = FragReassembler(
        timeoutMs: 1000,
        globalBudgetBytes: 10000000,
        onComplete: (json, _) => done.add(json),
        onAbort: (_) {},
        now: () => 0,
      );

      expect(r.accept('{"__frag":{"id":"a","i":0,"n":1},"data":1}'), isTrue);
      expect(done, isEmpty);
    });

    test('rejects an envelope whose n exceeds kMaxFragmentCount', () {
      final done = <String>[];
      final r = FragReassembler(
        timeoutMs: 1000,
        globalBudgetBytes: 10000000,
        onComplete: (json, _) => done.add(json),
        onAbort: (_) {},
        now: () => 0,
      );

      final hostile = jsonEncode({
        '__frag': {'id': 'h', 'i': 0, 'n': 1000000000},
        'data': 'x',
      });
      expect(r.accept(hostile), isTrue);
      expect(done, isEmpty);
    });

    test('handles out-of-order and duplicate fragments', () {
      final json = jsonEncode({
        'type': 'x',
        'blob': List.filled(2500, 'z').join(),
      });
      final frames = buildFragments(json, 't2', null, 1000);
      final done = <String>[];
      final r = FragReassembler(
        timeoutMs: 1000,
        globalBudgetBytes: 10000000,
        onComplete: (json, _) => done.add(json),
        onAbort: (_) {},
        now: () => 0,
      );

      r.accept(frames[2]);
      r.accept(frames[0]);
      r.accept(frames[0]);
      r.accept(frames[1]);

      expect(done, [json]);
    });

    test('timeout abort emits preserved hint', () {
      final json = jsonEncode({
        'type': 'file:content',
        'path': 'a.png',
        'blob': List.filled(2500, 'q').join(),
      });
      final frames = buildFragments(
        json,
        't3',
        const FragHint('file:content', 'a.png'),
        1000,
      );
      final aborts = <FragHint?>[];
      var clock = 0;
      final r = FragReassembler(
        timeoutMs: 1000,
        globalBudgetBytes: 10000000,
        onComplete: (_, __) {},
        onAbort: aborts.add,
        now: () => clock,
      );

      r.accept(frames[0]);
      clock = 2000;
      r.sweep();

      expect(aborts.single?.type, 'file:content');
      expect(aborts.single?.key, 'a.png');
    });
  });
}

int _jsonStringEscapedBytes(String s) {
  final encoded = jsonEncode(s);
  return utf8.encode(encoded).length - 2;
}
