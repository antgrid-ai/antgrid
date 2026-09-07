// How MachineSession hands outbound traffic to the socket: one drain loop, so
// a channel's frames reach the wire in the order they were handed over and a
// fragment set is never interleaved with anything; session frames written
// directly, so liveness still runs while a channel cannot drain; and a send
// future that resolves at hand-off, so a caller waiting on one learns when the
// frame actually left rather than when it was copied into a buffer.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

Future<String?> _openFromPhone(SessionKeys keys, Uint8List payload) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).open(payload);

/// A detached copy of the session's key material. The session zeroizes its own
/// keys in place on teardown and on rekey, which would take the test's ability
/// to read what it captured down with it.
SessionKeys _copyOf(SessionKeys k) => SessionKeys(
  a2p: Uint8List.fromList(k.a2p),
  p2a: Uint8List.fromList(k.p2a),
  confirm: Uint8List.fromList(k.confirm),
);

/// One line per captured frame, in send order: `session:<type>` for a bare
/// session frame, `frag:<id>#<i>` for one fragment, `app:<type>` for a whole
/// envelope.
Future<List<String>> _labels(SessionKeys keys, List<SentFrame> frames) async {
  final out = <String>[];
  for (final f in frames) {
    final plaintext = await _openFromPhone(keys, f.payload);
    if (plaintext == null) {
      out.add('undecryptable');
      continue;
    }
    final json = jsonDecode(plaintext) as Map<String, dynamic>;
    final type = json['type'];
    if (type is String) {
      out.add('session:$type');
      continue;
    }
    final frag = json['__frag'];
    if (frag is Map) {
      out.add('frag:${frag['id']}#${frag['i']}');
      continue;
    }
    final m = json['m'];
    out.add('app:${m is Map ? m['type'] : '?'}');
  }
  return out;
}

/// Polls until [ready] holds, or gives up quietly after [within]. Cheaper and
/// steadier than sleeping a fixed span for a timer-driven event: the caller
/// proceeds the instant the event lands, which matters when the same timer goes
/// on to do something the test cannot survive.
Future<void> _waitUntil(
  bool Function() ready, {
  Duration within = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(within);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeLiveRelay relay;
  late SessionKeys keys;
  late SessionKeys readKeys;
  late FakeHandshaker handshaker;

  setUp(() {
    relay = FakeLiveRelay();
    keys = fixedKeys(1);
    readKeys = _copyOf(keys);
    handshaker = FakeHandshaker(keys);
  });

  Future<MachineSession> establish({
    Duration pingSilence = const Duration(seconds: kPingSilenceSeconds),
  }) async {
    final session = MachineSession(
      relay: relay,
      machineDeviceId: 'machine-1',
      handshaker: handshaker,
      pingSilence: pingSilence,
    );
    session.start();
    await session.ensureEstablished();
    addTearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });
    return session;
  }

  test('a session ping is written while app frames are held, and the control '
      'envelope precedes them all once the gate opens', () async {
    final session = await establish(
      pingSilence: const Duration(milliseconds: 50),
    );
    final s = session.debugScheduler;
    s.hold = true;

    var previewDone = false;
    final preview = session
        .sendOnStream('proj-1', {
          'type': 'tunnel:http-response',
          'body': 'x' * 4096,
        }, 'preview')
        .then((_) => previewDone = true);
    final control = session.sendOnStream(kControlStreamId, {
      'type': 'project:list',
    }, 'control');

    // Two unanswered pings declare the session dead and rekey it, which
    // zeroizes the keys this test reads its captured frames back with. So take
    // the first tick as the proof liveness runs and get on with it, rather than
    // sleeping into the third.
    await _waitUntil(() => relay.sent.isNotEmpty);
    final held = await _labels(readKeys, relay.sent);
    expect(held, isNotEmpty, reason: 'liveness must still be running');
    expect(
      held,
      everyElement('session:ping'),
      reason: 'a session frame never queues behind app traffic',
    );
    expect(previewDone, isFalse);

    s.hold = false;
    s.kick();
    await Future.wait([preview, control]);
    expect(previewDone, isTrue);

    final all = await _labels(readKeys, relay.sent);
    final app = all.where((l) => !l.startsWith('session:')).toList();
    expect(app, ['app:project:list', 'app:tunnel:http-response']);
  });

  test(
    'one message\'s fragments precede a later message on the same channel',
    () async {
      final session = await establish();
      final big = {
        'type': 'file:content',
        'path': 'big.bin',
        'content': 'y' * 2000000,
      };

      final first = session.sendOnStream('proj-1', big, 'preview');
      final second = session.sendOnStream('proj-1', {
        'type': 'terminal:input',
        'data': 'z',
      }, 'preview');
      await Future.wait([first, second]);

      final labels = await _labels(readKeys, relay.sent);
      expect(
        labels.length,
        greaterThan(2),
        reason: 'the big message fragments',
      );
      expect(labels.last, 'app:terminal:input');
      final frags = labels.sublist(0, labels.length - 1);
      expect(frags, everyElement(startsWith('frag:')));
      // One transfer, in order: a second seal must never overtake a first.
      final ids = frags.map((l) => l.split('#').first).toSet();
      expect(ids, hasLength(1));
      expect(
        frags.map((l) => int.parse(l.split('#').last)),
        List<int>.generate(frags.length, (i) => i),
      );
    },
  );

  test('a queued send completes at hand-off, when its stream is removed, and '
      'on session teardown', () async {
    final session = await establish();
    final s = session.debugScheduler;

    s.hold = true;
    var handedOff = false;
    final onHandOff = session
        .sendOnStream('proj-1', {'type': 'a'}, 'control')
        .then((_) => handedOff = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(handedOff, isFalse);
    s.hold = false;
    s.kick();
    await onHandOff;
    expect(relay.sent, hasLength(1));

    s.hold = true;
    var onDetach = false;
    final detached = session
        .sendOnStream('doomed', {'type': 'b'}, 'control')
        .then((_) => onDetach = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(onDetach, isFalse);
    session.removeStream('doomed');
    await detached;
    expect(
      relay.sent,
      hasLength(1),
      reason: "a detached stream's backlog is dropped, not written",
    );

    var onDown = false;
    final torn = session
        .sendOnStream('proj-1', {'type': 'c'}, 'control')
        .then((_) => onDown = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(onDown, isFalse);
    relay.setState(
      const AppState(connectionState: RelayConnectionState.disconnected),
    );
    await torn;
    expect(relay.sent, hasLength(1));
  });

  test(
    'bindProject times out instead of hanging while control cannot drain',
    () async {
      final session = await establish();
      session.debugScheduler.hold = true;

      final started = DateTime.now();
      await expectLater(
        session.bindProject('proj-1', {
          'type': 'project:start',
          'projectId': 'proj-1',
        }, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(milliseconds: 400)),
        reason: 'one deadline spans the send and the stream-ready wait',
      );
    },
  );
}
