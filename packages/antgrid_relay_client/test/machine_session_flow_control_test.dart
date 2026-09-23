// How MachineSession hands outbound traffic to the socket: one drain loop, so
// a channel's frames reach the wire in the order they were handed over and a
// fragment set is never interleaved with anything; session frames written
// directly, so liveness still runs while a channel cannot drain; a send future
// that resolves at hand-off, so a caller waiting on one learns when the frame
// actually left rather than when it was copied into a buffer; and the credit
// windows that bound how much either side may have in flight unacknowledged.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

/// The bare session frames among [frames], decoded, in send order. Anything
/// that turns out to be an app envelope or a fragment is left out.
List<Map<String, dynamic>> _sessionFrames(List<SentFrame> frames) {
  final out = <Map<String, dynamic>>[];
  for (final f in frames) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(decodeFromPhone(f.payload)) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (json['type'] is String) out.add(json);
  }
  return out;
}

/// One line per captured frame, in send order: `session:<type>` for a bare
/// session frame, `frag:<id>#<i>` for one fragment, `app:<type>` for a whole
/// envelope.
List<String> _labels(List<SentFrame> frames) {
  final out = <String>[];
  for (final f in frames) {
    final json = jsonDecode(decodeFromPhone(f.payload)) as Map<String, dynamic>;
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
  late FakeHandshaker handshaker;

  setUp(() {
    relay = FakeLiveRelay();
    handshaker = FakeHandshaker();
  });

  Future<MachineSession> establish({
    Duration pingSilence = const Duration(seconds: kPingSilenceSeconds),
    int? channelWindowBytes,
    int? socketInflightBytes,
    int creditBatchBytes = kCreditBatchBytes,
    RelayLogger? logger,
  }) async {
    final session = await establishSession(
      relay,
      handshaker: handshaker,
      pingSilence: pingSilence,
      channelWindowBytes: channelWindowBytes,
      socketInflightBytes: socketInflightBytes,
      creditBatchBytes: creditBatchBytes,
      logger: logger,
    );
    addTearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });
    return session;
  }

  test('a stalled send gate reaches the logger', () async {
    // The scheduler was built without a `log:` for its whole life, so this
    // canary fired into null and the app could not see its own stalls. Pin the
    // wiring, not the wording.
    final logged = <String>[];
    final session = await establish(
      channelWindowBytes: 64,
      logger: (level, message, {fields}) =>
          logged.add('${level.name}: $message'),
    );
    final s = session.debugScheduler;

    // Goes out under the scheduler's "nothing outstanding" deadlock guard, and
    // stays uncredited because the fake relay never credits.
    await session.sendOnStream(kControlStreamId, {
      'type': 'project:list',
    }, 'control');
    expect(s.unacked('control'), greaterThan(0));

    // Unawaited: its head blocks the channel, which is the state being tested.
    unawaited(
      session.sendOnStream(kControlStreamId, {
        'type': 'project:list',
      }, 'control'),
    );
    // Backdate rather than idle out the real 5s.
    s.blockedSince['control'] = DateTime.now().subtract(
      const Duration(milliseconds: kWindowStallWarnMs + 1000),
    );
    s.kick();

    await _waitUntil(
      () =>
          logged.any((l) => l.startsWith('warn: send gate stalled on control')),
    );
  });

  test('a send with no session reaches the logger', () async {
    // Every drop on this path was reported only to a netwatch tap, so a session
    // that never came back was indistinguishable in the logs from one nobody
    // had typed into. Pin the wiring, not the wording.
    final logged = <String>[];
    final session = MachineSession(
      relay: relay,
      machineDeviceId: 'machine-1',
      handshaker: handshaker,
      logger: (level, message, {fields}) =>
          logged.add('${level.name}: $message'),
    );
    addTearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });

    // Deliberately never established — the state a terminal is typed into
    // while the ladder is still climbing.
    await session.sendOnStream('s1', {'type': 'terminal:input'}, 'control');

    expect(
      logged,
      anyElement(startsWith('info: send dropped — no session')),
    );
  });

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

    // Two unanswered pings declare the session dead and close the link, and
    // there is nothing to read once it does. So take the first tick as the
    // proof liveness runs and get on with it, rather than sleeping into the
    // third.
    await _waitUntil(() => relay.sent.length >= 3);
    final held = _labels(relay.sent);
    expect(
      held,
      contains('session:ping'),
      reason: 'liveness must still be running',
    );
    expect(
      held,
      everyElement(startsWith('session:')),
      reason: 'a session frame never queues behind app traffic',
    );
    expect(previewDone, isFalse);

    s.hold = false;
    s.kick();
    await Future.wait([preview, control]);
    expect(previewDone, isTrue);

    final all = _labels(relay.sent);
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

      final labels = _labels(relay.sent);
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

  // --- credit windows -------------------------------------------------------

  /// A preview message whose frame runs a little over 50 KB, so three of them
  /// fill the 200 KB window the cases below shrink the channel to and the
  /// fourth cannot go.
  Map<String, dynamic> bulk(int i) => {
    'type': 'tunnel:http-response',
    'requestId': 'r$i',
    'body': 'x' * 50000,
  };

  /// A control-plane envelope of roughly [pad] bytes — inbound filler for the
  /// consumed counter, addressed to the control plane so no stream has to exist
  /// for it.
  String filler(int pad) => jsonEncode({
    'm': {'type': 'agent:tools', 'pad': 'x' * pad},
  });

  void injectFromAgent(String channel, String plaintext) {
    relay.inject(
      IncomingPeerFrame(channel: channel, payload: encodeFromAgent(plaintext)),
    );
  }

  Future<void> injectCredit(String channel, int consumed) async {
    injectFromAgent(
      'control',
      jsonEncode({'type': 'credit', 'channel': channel, 'consumed': consumed}),
    );
  }

  /// Establishes on a shrunken window and hands five [bulk] messages to the
  /// preview channel, three of which fit. Returns the session and the five
  /// pending sends.
  Future<(MachineSession, List<Future<void>>)> withFullPreviewWindow() async {
    final session = await establish(
      channelWindowBytes: 200000,
      socketInflightBytes: 300000,
      creditBatchBytes: 100000,
    );
    final sends = [
      for (var i = 0; i < 5; i++)
        session.sendOnStream('proj-1', bulk(i), 'preview'),
    ];
    await _waitUntil(() => relay.sent.length >= 3);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      relay.sent,
      hasLength(3),
      reason: 'the window holds three frames, and nothing has credited them',
    );
    return (session, sends);
  }

  test('the sender stops at the channel window and resumes on a cumulative '
      'credit', () async {
    final (session, sends) = await withFullPreviewWindow();
    final unacked = relay.sent.fold<int>(0, (n, f) => n + f.payload.length);

    await session.sendOnStream(kControlStreamId, {
      'type': 'project:list',
    }, 'control');
    expect(
      relay.sent,
      hasLength(4),
      reason: 'a full preview window never blocks control',
    );

    await injectCredit('preview', unacked);
    await _waitUntil(
      () => relay.sent.length >= 6,
      within: const Duration(milliseconds: 300),
    );
    expect(relay.sent, hasLength(6));
    await Future.wait(sends);
  });

  test('a credit that does not advance releases nothing, and the next larger '
      'one heals the gap', () async {
    final (_, sends) = await withFullPreviewWindow();
    final unacked = relay.sent.fold<int>(0, (n, f) => n + f.payload.length);

    await injectCredit('preview', 0);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      relay.sent,
      hasLength(3),
      reason: 'a stale or duplicated credit is not new information',
    );

    // The credit for the first frame alone never arrived; the cumulative count
    // in this one carries it.
    await injectCredit('preview', unacked);
    await _waitUntil(
      () => relay.sent.length >= 5,
      within: const Duration(milliseconds: 300),
    );
    expect(relay.sent, hasLength(5));
    await Future.wait(sends);
  });

  test('the receiver credits once a batch has arrived, counting the frames it '
      'could not decode and the session frames alike', () async {
    await establish(creditBatchBytes: 100000);

    // The consumed count is over the frame's wire bytes, so it has to be
    // summed from the frames as they are sent, not from their plaintext.
    var preview = 0;
    void feedPreview(String plaintext) {
      final payload = encodeFromAgent(plaintext);
      preview += payload.length;
      relay.inject(IncomingPeerFrame(channel: 'preview', payload: payload));
    }

    for (var i = 0; i < 3; i++) {
      feedPreview(filler(40000));
    }
    await _waitUntil(() => relay.sent.isNotEmpty);
    var credits = _sessionFrames(
      relay.sent,
    ).where((j) => j['type'] == 'credit').toList();
    expect(credits, hasLength(1));
    expect(credits.single, {
      'type': 'credit',
      'channel': 'preview',
      'consumed': preview,
    });

    // A frame that is not valid UTF-8 still cost the agent its window, so it
    // has to be credited back like any other frame the wire delivered.
    final garbage = Uint8List(40000)..fillRange(0, 40000, 0x80);
    preview += garbage.length;
    relay.inject(IncomingPeerFrame(channel: 'preview', payload: garbage));
    feedPreview(filler(70000));
    await _waitUntil(() => relay.sent.length >= 2);
    credits = _sessionFrames(
      relay.sent,
    ).where((j) => j['type'] == 'credit').toList();
    expect(credits.last['consumed'], preview);

    var control = 0;
    void feedControl(String plaintext) {
      final payload = encodeFromAgent(plaintext);
      control += payload.length;
      relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
    }

    feedControl(jsonEncode({'type': 'ping'}));
    feedControl(filler(100000));
    await _waitUntil(
      () => relay.sent.length >= 4,
      within: const Duration(milliseconds: 300),
    );
    final decoded = _sessionFrames(relay.sent);
    expect(
      decoded.map((j) => j['type']),
      contains('pong'),
      reason: 'a session frame is dispatched as well as counted',
    );
    final controlCredits = decoded
        .where((j) => j['type'] == 'credit' && j['channel'] == 'control')
        .toList();
    expect(controlCredits, isNotEmpty);
    expect(
      controlCredits.last['consumed'],
      control,
      reason: "the ping's own bytes are part of what the agent charged",
    );
  });

  test("every liveness tick re-sends both channels' credits, whether or not "
      'anything new arrived', () async {
    // Far above anything this test feeds it, so only the tick can credit.
    await establish(
      pingSilence: const Duration(milliseconds: 60),
      creditBatchBytes: 10000000,
    );
    final payload = encodeFromAgent(filler(10000));
    relay.inject(IncomingPeerFrame(channel: 'preview', payload: payload));

    List<String> creditsIn(List<SentFrame> frames) => _sessionFrames(frames)
        .where((j) => j['type'] == 'credit')
        .map((j) => "${j['channel']}=${j['consumed']}")
        .toList();

    await _waitUntil(
      () => relay.sent.length >= 2,
      within: const Duration(milliseconds: 200),
    );
    final firstTick = relay.sent.length;
    expect(creditsIn(relay.sent), ['control=0', 'preview=${payload.length}']);

    await _waitUntil(
      () => relay.sent.length >= firstTick + 2,
      within: const Duration(milliseconds: 200),
    );
    expect(creditsIn(relay.sent.sublist(firstTick)), [
      'control=0',
      'preview=${payload.length}',
    ]);
  });

  test('credits arriving from the agent keep the session alive on their own — '
      'no ping, no reconnect', () async {
    await establish(
      pingSilence: const Duration(milliseconds: 60),
      creditBatchBytes: 10000000,
    );
    for (var i = 1; i <= 10; i++) {
      await injectCredit('preview', i);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    final types = _sessionFrames(relay.sent).map((j) => j['type']).toSet();
    expect(
      types,
      isNot(contains('ping')),
      reason: 'a credit is a frame from the peer, so it is proof of life too',
    );
    expect(
      relay.closeCalled,
      isFalse,
      reason: 'no missed pong, no reconnect',
    );
    expect(handshaker.performCalls, 1);
  });

  test('a socket loss drops what the gate was holding, and the next '
      'establishment starts from a fresh window', () async {
    handshaker = FakeHandshaker.sequence([true, true]);
    final session = await establish(
      channelWindowBytes: 200000,
      socketInflightBytes: 300000,
    );
    final s = session.debugScheduler;

    // Fill the dead session's window first: nothing ever credits these, so if
    // the counters carried across the break the frames below could not go.
    final filled = [
      for (var i = 0; i < 3; i++)
        session.sendOnStream('proj-1', bulk(i), 'preview'),
    ];
    await Future.wait(filled);
    expect(relay.sent, hasLength(3));

    s.hold = true;
    final held = [
      for (var i = 3; i < 6; i++)
        session.sendOnStream('proj-1', bulk(i), 'preview'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(relay.sent, hasLength(3));

    relay.setState(
      const AppState(connectionState: RelayConnectionState.disconnected),
    );
    await Future.wait(held);
    expect(
      relay.sent,
      hasLength(3),
      reason:
          'frames the gate held die with the session that would have sent '
          'them',
    );

    s.hold = false;
    relay.setState(
      const AppState(connectionState: RelayConnectionState.authenticated),
    );
    await session.ensureEstablished();
    final fresh = [
      for (var i = 6; i < 9; i++)
        session.sendOnStream('proj-1', bulk(i), 'preview'),
    ];
    // Polled rather than awaited: counters carried across the break would gate
    // the first of these forever, and a stuck window should report itself as a
    // count, not as a test that never returns.
    await _waitUntil(
      () => relay.sent.length >= 6,
      within: const Duration(milliseconds: 300),
    );
    expect(
      relay.sent,
      hasLength(6),
      reason: 'a full window goes out before the agent has credited anything',
    );
    expect(
      decodeFromPhone(relay.sent.last.payload),
      isNotEmpty,
      reason: 'a plain frame, readable on the new session as on the old',
    );
    await Future.wait(fresh);
  });

  test('a send the socket accepts only after the session was replaced is not '
      "charged to the new session's window", () async {
    // The outcome of an in-flight write lands after a teardown and a fresh
    // hello. A bool fence reads "established" again and would bill the new
    // session for bytes its peer never receives, so that window never drains.
    final gated = _GatedRelay();
    relay = gated;
    handshaker = FakeHandshaker.sequence([true, true]);
    final session = await establish();
    final s = session.debugScheduler;

    gated.gate = Completer<void>();
    final inFlight = session.sendOnStream(kControlStreamId, {
      'type': 'project:list',
    }, 'preview');
    await _waitUntil(() => gated.sent.isNotEmpty);
    expect(gated.sent, hasLength(1));

    relay.setState(
      const AppState(connectionState: RelayConnectionState.disconnected),
    );
    await Future<void>.delayed(Duration.zero);
    relay.setState(
      const AppState(connectionState: RelayConnectionState.authenticated),
    );
    await session.ensureEstablished();
    expect(handshaker.performCalls, 2, reason: 'a second hello established');
    expect(s.unacked('preview'), 0);

    gated.gate!.complete();
    await inFlight;
    expect(s.unacked('preview'), 0);
  });
}

class _GatedRelay extends FakeLiveRelay {
  Completer<void>? gate;

  @override
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload) async {
    final outcome = await super.sendFrame(channel, payload);
    final g = gate;
    if (channel == 'preview' && g != null) await g.future;
    return outcome;
  }
}
