// The remote half of the capture: what a phone ships back, and — more
// importantly — what it refuses to ship. Every test here is about a bound.
//
// The recorder holds each event for an annotation window and, under
// FLUTTER_TEST, drains only when asked — so `recorder.flush()` is what stands in
// for "time passed" throughout.
import 'package:antgrid/util/netwatch.dart';
import 'package:antgrid/util/netwatch_uploader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Netwatch recorder;
  late List<Map<String, Object?>> sent;
  late List<bool> arms;

  setUp(() {
    // Fileless, which is the phone's case: hostDir() has nowhere useful to
    // write and nothing would ever read it.
    recorder = Netwatch(null);
    sent = [];
    arms = [];
  });

  tearDown(() => recorder.dispose());

  NetwatchUploader make({
    int maxPerBatch = 250,
    int bytesPerSecond = 32 * 1024,
    Duration flushEvery = const Duration(hours: 1),
  }) => NetwatchUploader(
    recorder: recorder,
    send: sent.add,
    onArmedChanged: arms.add,
    maxPerBatch: maxPerBatch,
    bytesPerSecond: bytesPerSecond,
    // Far out of reach: every test below drives the flush through dispose(),
    // so nothing depends on wall-clock timing.
    flushEvery: flushEvery,
  );

  void frame(String type, {String? id}) => recorder
    ..record(dir: 'tx', kind: 'sealed', frameId: id ?? type, msgType: type);

  test('ships what the recorder drained, once armed', () async {
    final up = make()..configure(enabled: true, ttl: const Duration(minutes: 5));
    frame('terminal:input');
    await recorder.flush();
    up.dispose();

    final batch = sent.single;
    final events = batch['events']! as List;
    expect(events, hasLength(1));
    expect((events.single as Map)['msgType'], 'terminal:input');
    expect((events.single as Map)['origin'], 'app');
    // The bridge shifts the whole batch onto its own clock with this.
    expect(batch['sentAt'], isA<int>());
    expect(batch.containsKey('dropped'), isFalse);
  });

  test('records nothing before it is armed', () async {
    final up = make();
    frame('terminal:input');
    await recorder.flush();
    up.configure(enabled: true, ttl: const Duration(minutes: 5));
    up.dispose();

    // A remote capture is not retrospective — the events that matured before
    // the arm are gone, and inventing them would be worse than saying so.
    expect(sent, isEmpty);
  });

  test('never ships its own uploads', () async {
    final up = make()..configure(enabled: true, ttl: const Duration(minutes: 5));
    frame('terminal:input');
    frame('netwatch:events');
    await recorder.flush();
    up.dispose();

    // Unfiltered, a batch is itself a frame the tap records, and the capture
    // becomes its own traffic generator.
    final events = sent.single['events']! as List;
    expect(events.map((e) => (e as Map)['msgType']), ['terminal:input']);
  });

  test('drops past the per-batch cap and says how many', () async {
    final up = make(maxPerBatch: 2)
      ..configure(enabled: true, ttl: const Duration(minutes: 5));
    for (var i = 0; i < 5; i++) {
      frame('terminal:output', id: 'f$i');
    }
    await recorder.flush();
    up.dispose();

    expect((sent.single['events']! as List), hasLength(2));
    // A gap in the app's own seq must never be readable as a frame lost on the
    // wire, which is exactly what this count exists to rule out.
    expect(sent.single['dropped'], 3);
  });

  test('drops past the byte budget rather than queueing behind it', () async {
    // One byte per second: the bucket starts at two seconds' worth, so the
    // first event's own size already exhausts it.
    final up = make(bytesPerSecond: 1)
      ..configure(enabled: true, ttl: const Duration(minutes: 5));
    frame('terminal:output', id: 'a');
    frame('terminal:output', id: 'b');
    await recorder.flush();
    up.dispose();

    expect((sent.single['events']! as List), isEmpty);
    expect(sent.single['dropped'], 2);
  });

  test('re-asserts the tap on every arm, and removes it once on disarm', () async {
    final up = make()
      ..configure(enabled: true, ttl: const Duration(minutes: 5))
      ..configure(enabled: true, ttl: const Duration(minutes: 5));
    // The arm is an assignment on the socket, not an event, so a watcher's
    // heartbeat re-asserting it costs nothing — and it is the only way back
    // from a tap cleared without this class being told (a rebuilt
    // RelayService), which otherwise leaves an uploader reporting itself armed
    // while it flushes empty batches for the life of the connection.
    expect(arms, [true, true]);

    up
      ..configure(enabled: false)
      ..configure(enabled: false);
    // The disarm half stays once-only: it is what tears down the subscription
    // and the flush timer, and running that twice would ship the tail twice.
    expect(arms, [true, true, false]);
    up.dispose();
    expect(arms, [true, true, false]);
  });

  test('a disarm ships the tail it was holding', () async {
    final up = make()..configure(enabled: true, ttl: const Duration(minutes: 5));
    frame('git:status');
    await recorder.flush();
    expect(sent, isEmpty, reason: 'nothing flushed on the hour-long timer yet');

    up.configure(enabled: false);
    // Whatever the watcher was looking at when it stopped still arrives — and
    // the send itself cannot restart the loop, because the tap is already gone.
    expect((sent.single['events']! as List), hasLength(1));
  });

  test('lapses on its own when the arm is not renewed', () async {
    final up = make()
      ..configure(enabled: true, ttl: const Duration(milliseconds: 20));
    expect(up.armed, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    // The dead-man switch: a watcher killed with SIGKILL sends no disarm, and
    // nothing on the device can turn a capture off by hand.
    expect(up.armed, isFalse);
    expect(arms, [true, false]);
    up.dispose();
  });

  test('a renewal extends the window instead of stacking a second lapse', () async {
    final up = make()
      ..configure(enabled: true, ttl: const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    up.configure(enabled: true, ttl: const Duration(milliseconds: 200));

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(up.armed, isTrue, reason: 'the first ttl must not have fired');
    up.dispose();
  });

  test('a send that throws cannot fail the connection it observes', () async {
    final up = NetwatchUploader(
      recorder: recorder,
      send: (_) => throw StateError('socket gone'),
      onArmedChanged: arms.add,
      flushEvery: const Duration(hours: 1),
    )..configure(enabled: true, ttl: const Duration(minutes: 5));
    frame('terminal:input');
    await recorder.flush();

    expect(up.dispose, returnsNormally);
  });

  group('ensureNetwatch', () {
    test('hands back one fileless recorder for repeat callers', () {
      // Two machines can both ask to be watched; they must share the recorder,
      // or the same frame is captured twice.
      configureNetwatchForTest(null);
      final a = ensureNetwatch();
      expect(identical(ensureNetwatch(), a), isTrue);
      configureNetwatchForTest(null);
    });
  });
}
