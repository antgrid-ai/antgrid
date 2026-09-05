import 'dart:convert';
import 'dart:io';

import 'package:antgrid/util/jsonl_sink.dart';
import 'package:antgrid/util/netwatch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String logPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('netwatch_');
    logPath = '${tmp.path}/netwatch.log';
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  List<Map<String, dynamic>> readLines() => !File(logPath).existsSync()
      ? const []
      : File(logPath)
            .readAsLinesSync()
            .where((l) => l.trim().isNotEmpty)
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .toList();

  Netwatch make({int capacity = 512}) =>
      Netwatch(JsonlSink(logPath), capacity: capacity);

  test('writes one JSON line per frame, tagged as the app half', () async {
    final w = make();
    w.record(
      dir: 'tx',
      kind: 'sealed',
      channel: 'control',
      bytes: 412,
      frameId: 'a3f9c2110bd4',
    );
    await w.flush();

    final o = readLines().single;
    expect(o['dir'], 'tx');
    expect(o['kind'], 'sealed');
    expect(o['channel'], 'control');
    expect(o['bytes'], 412);
    expect(o['frameId'], 'a3f9c2110bd4');
    expect(o['transport'], 'relay');
    // The bridge stamps no origin, so the CLI reads a missing one as its own.
    expect(o['origin'], 'app');
    expect(o['at'], isA<int>());
    expect(o['seq'], 1);
    w.dispose();
  });

  test('an annotation lands on the held frame before it is written', () async {
    final w = make();
    w.record(dir: 'tx', kind: 'sealed', frameId: 'abc123');
    w.annotate('abc123', msgType: 'terminal:input', streamId: 'proj-1');
    await w.flush();

    final o = readLines().single;
    expect(o['msgType'], 'terminal:input');
    expect(o['streamId'], 'proj-1');
    w.dispose();
  });

  test('an annotation for an already-written frame is a no-op, not a crash', () async {
    // Capacity 1: the second record forces the first out of the buffer, which
    // is the flood case — a capture must degrade to typeless frames, never
    // stall a send to keep one annotatable.
    final w = make(capacity: 1);
    w.record(dir: 'tx', kind: 'sealed', frameId: 'gone');
    w.record(dir: 'tx', kind: 'sealed', frameId: 'here');
    expect(() => w.annotate('gone', msgType: 'too:late'), returnsNormally);
    await w.flush();

    final lines = readLines();
    expect(lines, hasLength(2));
    expect(lines.first['frameId'], 'gone');
    expect(lines.first.containsKey('msgType'), isFalse);
    w.dispose();
  });

  test('order is preserved and seq is contiguous under eviction', () async {
    final w = make(capacity: 2);
    for (var i = 0; i < 5; i++) {
      w.record(dir: 'rx', kind: 'sealed', frameId: 'f$i');
    }
    await w.flush();

    final lines = readLines();
    expect(lines.map((l) => l['frameId']), ['f0', 'f1', 'f2', 'f3', 'f4']);
    expect(lines.map((l) => l['seq']), [1, 2, 3, 4, 5]);
    expect(w.recorded, 5);
    w.dispose();
  });

  group('relay-package tap adapter', () {
    test('records a frame and then annotates it', () async {
      final w = make();
      w.tap({
        'op': 'frame',
        'dir': 'rx',
        'kind': 'sealed',
        'channel': 'control',
        'bytes': 96,
        'frameId': 'ff00',
      });
      w.tap({
        'op': 'annotate',
        'frameId': 'ff00',
        'msgType': 'terminal:output',
        'streamId': 'proj-9',
      });
      await w.flush();

      final o = readLines().single;
      expect(o['msgType'], 'terminal:output');
      expect(o['streamId'], 'proj-9');
      expect(o['bytes'], 96);
      w.dispose();
    });

    test('carries a drop reason and its detail through', () async {
      final w = make();
      w.tap({
        'op': 'frame',
        'dir': 'tx',
        'kind': 'drop',
        'channel': 'control',
        'msgType': 'file:read',
        'reason': 'no-e2e-session',
        'detail': {'why': 'pre-establishment'},
      });
      await w.flush();

      final o = readLines().single;
      expect(o['kind'], 'drop');
      expect(o['reason'], 'no-e2e-session');
      expect(o['detail'], {'why': 'pre-establishment'});
      w.dispose();
    });

    test('a malformed event costs a line of capture, never a send', () async {
      final w = make();
      // The tap is a boundary: whatever arrives, the path being observed must
      // not fail.
      expect(() => w.tap(<String, Object?>{}), returnsNormally);
      expect(() => w.tap({'op': 'annotate'}), returnsNormally);
      expect(() => w.tap({'op': 'frame', 'dir': 'tx'}), returnsNormally);
      expect(() => w.tap({'op': 'frame', 'dir': 1, 'kind': 2}), returnsNormally);
      await w.flush();

      expect(readLines(), isEmpty);
      w.dispose();
    });
  });

  test('netwatchLogPath is a sibling of host.json, not app.log', () {
    expect(netwatchLogPath(abDir: '/tmp/ag'), '/tmp/ag/netwatch.log');
  });
}
