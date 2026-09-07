// The send scheduler on its own: no session, no crypto, no socket. The sink
// stands in for "seal and write", returning the sealed length the real one
// would have produced, so the window arithmetic here is the arithmetic that
// runs in production. Mirrors `bridge/tests/send-scheduler.test.ts` case for
// case — the two clients must gate identically or one stalls the other.
import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

class _Wire {
  final frames = <QueuedAppFrame>[];

  Future<int?> call(QueuedAppFrame f) async {
    frames.add(f);
    return f.plaintextBytes + kSealOverheadBytes;
  }

  List<String?> get names => [for (final f in frames) f.msgType];
}

QueuedAppFrame _frame(
  String channel,
  int bytes, {
  String streamId = 'stream-1',
  String? name,
}) => QueuedAppFrame(
  channel: channel,
  streamId: streamId,
  plaintext: '',
  plaintextBytes: bytes,
  msgType: name,
);

/// The drain loop awaits its sink, so every observation has to let the
/// microtask queue run out first.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Wire wire;
  late SendScheduler s;

  setUp(() {
    wire = _Wire();
    s = SendScheduler(sink: wire.call);
  });

  test('drains FIFO within a channel and control ahead of preview', () async {
    s.hold = true;
    s.enqueue([_frame('preview', 10, name: 'p1')]);
    s.enqueue([_frame('preview', 10, name: 'p2')]);
    s.enqueue([_frame('control', 10, name: 'c1')]);
    await _settle();
    expect(wire.frames, isEmpty);

    s.hold = false;
    s.kick();
    await _settle();
    expect(wire.names, ['c1', 'p1', 'p2']);
  });

  test('hold parks the drain and nothing is written', () async {
    s.hold = true;
    s.enqueue([
      _frame('preview', 10),
      _frame('preview', 20),
      _frame('preview', 30),
    ]);
    await _settle();
    expect(wire.frames, isEmpty);
    expect(s.queued('preview').frames, 3);
    expect(s.queued('preview').bytes, 60);
  });

  test('window-blocks one channel without blocking the other', () async {
    s.window = 1000;
    s.enqueue([_frame('preview', 600, name: 'p1')]);
    await _settle();
    s.enqueue([_frame('preview', 600, name: 'p2')]);
    await _settle();
    s.enqueue([_frame('control', 100, name: 'c1')]);
    await _settle();

    expect(wire.names, ['p1', 'c1']);
    expect(s.unacked('preview'), 628);
    expect(s.queued('preview').frames, 1);
    expect(s.blockedSince['preview'], isNotNull);
  });

  test('credit releases exactly the delta; a duplicate is a no-op; '
      'over-credit clamps to sent', () async {
    s.window = 1000;
    s.enqueue([_frame('preview', 600, name: 'p1')]);
    await _settle();
    s.enqueue([_frame('preview', 600, name: 'p2')]);
    await _settle();
    expect(wire.names, ['p1']);

    expect(s.credit('preview', 100), isTrue, reason: 'the window advanced');
    await _settle();
    expect(wire.names, [
      'p1',
    ], reason: 'a partial credit releases nothing the frame cannot fit into');

    expect(s.credit('preview', 628), isTrue);
    await _settle();
    expect(wire.names, ['p1', 'p2']);

    expect(s.credit('preview', 628), isFalse, reason: 'duplicate');

    expect(s.credit('preview', 10000), isTrue);
    expect(s.unacked('preview'), 0);
    s.charge('preview', 500);
    expect(
      s.unacked('preview'),
      500,
      reason: 'credit beyond what was sent must not be banked as headroom',
    );
  });

  test('a frame larger than the window goes when nothing is unacked', () async {
    s.window = 100;
    s.enqueue([_frame('preview', 5000, name: 'big1')]);
    await _settle();
    s.enqueue([_frame('preview', 5000, name: 'big2')]);
    await _settle();
    expect(wire.names, ['big1']);
  });

  test('the socket cap bounds both channels together, and control keeps '
      'flowing while preview is full', () async {
    s.window = 2000;
    s.socketCap = 3000;
    s.enqueue([_frame('preview', 1000, name: 'p1')]);
    await _settle();
    s.enqueue([_frame('preview', 900, name: 'p2')]);
    await _settle();
    expect(wire.names, ['p1', 'p2']);
    expect(s.totalUnacked(), 1956);

    s.enqueue([_frame('preview', 100, name: 'p3')]);
    await _settle();
    expect(wire.names, ['p1', 'p2'], reason: "preview's window is full");

    s.enqueue([_frame('control', 900, name: 'c1')]);
    await _settle();
    expect(wire.names, ['p1', 'p2', 'c1']);

    s.enqueue([_frame('control', 200, name: 'c2')]);
    await _settle();
    expect(wire.names, [
      'p1',
      'p2',
      'c1',
    ], reason: 'c2 fits its own window; the socket cap is what holds it');
    expect(s.unacked('control'), 928);

    s.credit('preview', 1956);
    await _settle();
    expect(wire.names, ['p1', 'p2', 'c1', 'c2', 'p3']);
  });

  test('enqueue is all-or-nothing against maxQueuedBytes', () async {
    s.hold = true;
    s.maxQueuedBytes = 1000;
    expect(
      s.enqueue([_frame('preview', 600), _frame('preview', 600)]),
      isFalse,
    );
    expect(s.queued('preview').frames, 0);
    expect(s.enqueue([_frame('preview', 600)]), isTrue);
    expect(s.queued('preview').frames, 1);
  });

  test('dropStream removes only that stream\'s frames; clear returns '
      'everything', () async {
    s.hold = true;
    s.enqueue([_frame('control', 10, streamId: 'a', name: 'a1')]);
    s.enqueue([_frame('control', 20, streamId: 'b', name: 'b1')]);
    s.enqueue([_frame('control', 30, streamId: 'a', name: 'a2')]);
    s.enqueue([_frame('preview', 40, streamId: 'a', name: 'a3')]);
    s.enqueue([_frame('preview', 50, streamId: 'b', name: 'b2')]);

    final gone = s.dropStream('a');
    expect([for (final f in gone) f.msgType], ['a1', 'a2', 'a3']);
    expect(s.queued('control').bytes, 20);
    expect(s.queued('preview').bytes, 50);

    final rest = s.clear();
    expect([for (final f in rest) f.msgType], ['b1', 'b2']);
    expect(s.queued('control').frames, 0);
    expect(s.queued('preview').frames, 0);
  });

  test('resetWindows forgets counters but keeps the queue', () async {
    s.hold = true;
    s.charge('control', 700);
    s.charge('preview', 300);
    s.enqueue([_frame('preview', 10), _frame('preview', 20)]);
    expect(s.totalUnacked(), 1000);

    s.resetWindows();
    expect(s.totalUnacked(), 0);
    expect(s.queued('preview').frames, 2);
    expect(s.queued('preview').bytes, 30);
  });

  test('uncharge reopens a window the relay\'s drops closed', () async {
    s.window = 1000;
    s.enqueue([_frame('preview', 900, name: 'p1')]);
    await _settle();
    expect(s.unacked('preview'), 928);

    s.uncharge('preview', 900);
    expect(s.unacked('preview'), 28);

    s.enqueue([_frame('preview', 900, name: 'p2')]);
    await _settle();
    expect(wire.names, ['p1', 'p2']);
  });

  test('two non-advancing credits with nothing charged since resync the '
      'window', () async {
    final logs = <String>[];
    s = SendScheduler(sink: wire.call, window: 1000, log: logs.add);
    s.enqueue([_frame('preview', 900, name: 'p1')]);
    await _settle();
    s.enqueue([_frame('preview', 500, name: 'p2')]);
    await _settle();
    expect(wire.names, ['p1']);

    expect(s.credit('preview', 0), isFalse, reason: 'bytes were charged since');
    await _settle();
    expect(wire.names, ['p1']);

    expect(s.credit('preview', 0), isTrue);
    expect(s.unacked('preview'), 0);
    await _settle();
    expect(wire.names, ['p1', 'p2']);
    expect(logs.single, contains('window resync'));

    // A charge between two credits is proof the sender is still adding bytes,
    // so the count must start over rather than presume those bytes lost.
    s.credit('preview', 0);
    s.charge('preview', 100);
    expect(s.credit('preview', 0), isFalse);
    expect(s.unacked('preview'), greaterThan(0));
    expect(logs, hasLength(1));
  });

  test(
    'charge counts session bytes toward the gate without gating them',
    () async {
      s.window = 1000;
      s.charge('control', 990);
      s.enqueue([_frame('control', 100, name: 'c1')]);
      await _settle();
      expect(wire.frames, isEmpty);

      s.credit('control', 990);
      await _settle();
      expect(wire.names, ['c1']);
    },
  );

  test('done completes on clear() and on dropStream()', () async {
    s.hold = true;
    final a1 = _frame('control', 10, streamId: 'a');
    final a2 = _frame('preview', 10, streamId: 'a');
    final b1 = _frame('control', 10, streamId: 'b');
    s.enqueue([a1]);
    s.enqueue([a2]);
    s.enqueue([b1]);

    var aDone = 0;
    var bDone = 0;
    unawaited(a1.done.future.then((_) => aDone++));
    unawaited(a2.done.future.then((_) => aDone++));
    unawaited(b1.done.future.then((_) => bDone++));

    s.dropStream('a');
    await _settle();
    expect(aDone, 2);
    expect(bDone, 0);

    s.clear();
    await _settle();
    expect(bDone, 1);
  });
}
