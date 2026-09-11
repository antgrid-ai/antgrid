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

Future<String?> _openFromPhone(SessionKeys keys, Uint8List payload) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).open(payload);

/// Seals a plaintext as if the agent wrote it — what an inbound frame's payload
/// has to look like for the session to open it.
Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

/// The bare session frames among [frames], decoded, in send order. Anything
/// that turns out to be an app envelope or a fragment is left out.
Future<List<Map<String, dynamic>>> _sessionFrames(
  SessionKeys keys,
  List<SentFrame> frames,
) async {
  final out = <Map<String, dynamic>>[];
  for (final f in frames) {
    final plaintext = await _openFromPhone(keys, f.payload);
    if (plaintext == null) continue;
    final json = jsonDecode(plaintext);
    if (json is Map<String, dynamic> && json['type'] is String) out.add(json);
  }
  return out;
}

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
    int? channelWindowBytes,
    int? socketInflightBytes,
    int creditBatchBytes = kCreditBatchBytes,
    RelayLogger? logger,
  }) async {
    final session = MachineSession(
      relay: relay,
      machineDeviceId: 'machine-1',
      handshaker: handshaker,
      pingSilence: pingSilence,
      channelWindowBytes: channelWindowBytes,
      socketInflightBytes: socketInflightBytes,
      creditBatchBytes: creditBatchBytes,
      logger: logger,
    );
    session.start();
    await session.ensureEstablished();
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
      session.sendOnStream(kControlStreamId, {'type': 'project:list'}, 'control'),
    );
    // Backdate rather than idle out the real 5s.
    s.blockedSince['control'] = DateTime.now().subtract(
      const Duration(milliseconds: kWindowStallWarnMs + 1000),
    );
    s.kick();

    await _waitUntil(
      () => logged.any((l) => l.startsWith('warn: send gate stalled on control')),
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
      anyElement(startsWith('info: send dropped — no E2E session')),
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

    // Two unanswered pings declare the session dead and rekey it, which
    // zeroizes the keys this test reads its captured frames back with. So take
    // the first tick as the proof liveness runs and get on with it, rather than
    // sleeping into the third.
    await _waitUntil(() => relay.sent.length >= 3);
    final held = await _labels(readKeys, relay.sent);
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

  // --- credit windows -------------------------------------------------------

  /// A preview message whose sealed frame runs a little over 50 KB, so three of
  /// them fill the 200 KB window the cases below shrink the channel to and the
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

  Future<void> injectFromAgent(String channel, String plaintext) async {
    relay.inject(
      IncomingRouteMessage(
        from: 'machine-1',
        channel: channel,
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(readKeys, plaintext),
      ),
    );
  }

  Future<void> injectCredit(String channel, int consumed) => injectFromAgent(
    'control',
    jsonEncode({'type': 'credit', 'channel': channel, 'consumed': consumed}),
  );

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
      'could not decrypt and the session frames alike', () async {
    await establish(creditBatchBytes: 100000);

    // The consumed count is over SEALED payload bytes, so it has to be summed
    // from the frames as they are sealed, not from their plaintext.
    var preview = 0;
    Future<void> feedPreview(
      String plaintext, {
      SessionKeys? sealedWith,
    }) async {
      final payload = await _sealFromAgent(sealedWith ?? readKeys, plaintext);
      preview += payload.length;
      relay.inject(
        IncomingRouteMessage(
          from: 'machine-1',
          channel: 'preview',
          kind: FrameKind.sealed,
          payload: payload,
        ),
      );
    }

    for (var i = 0; i < 3; i++) {
      await feedPreview(filler(40000));
    }
    await _waitUntil(() => relay.sent.isNotEmpty);
    var credits = (await _sessionFrames(
      readKeys,
      relay.sent,
    )).where((j) => j['type'] == 'credit').toList();
    expect(credits, hasLength(1));
    expect(credits.single, {
      'type': 'credit',
      'channel': 'preview',
      'consumed': preview,
    });

    // A frame sealed under keys this session never held still cost the agent
    // its window, so it has to be credited back like any other.
    await feedPreview(filler(40000), sealedWith: fixedKeys(9));
    await feedPreview(filler(70000));
    await _waitUntil(() => relay.sent.length >= 2);
    credits = (await _sessionFrames(
      readKeys,
      relay.sent,
    )).where((j) => j['type'] == 'credit').toList();
    expect(credits.last['consumed'], preview);

    var control = 0;
    Future<void> feedControl(String plaintext) async {
      final payload = await _sealFromAgent(readKeys, plaintext);
      control += payload.length;
      relay.inject(
        IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: payload,
        ),
      );
    }

    await feedControl(jsonEncode({'type': 'ping'}));
    await feedControl(filler(100000));
    await _waitUntil(
      () => relay.sent.length >= 4,
      within: const Duration(milliseconds: 300),
    );
    final decoded = await _sessionFrames(readKeys, relay.sent);
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
    final payload = await _sealFromAgent(readKeys, filler(10000));
    relay.inject(
      IncomingRouteMessage(
        from: 'machine-1',
        channel: 'preview',
        kind: FrameKind.sealed,
        payload: payload,
      ),
    );

    Future<List<String>> creditsIn(List<SentFrame> frames) async =>
        (await _sessionFrames(readKeys, frames))
            .where((j) => j['type'] == 'credit')
            .map((j) => "${j['channel']}=${j['consumed']}")
            .toList();

    await _waitUntil(
      () => relay.sent.length >= 2,
      within: const Duration(milliseconds: 200),
    );
    final firstTick = relay.sent.length;
    expect(await creditsIn(relay.sent), [
      'control=0',
      'preview=${payload.length}',
    ]);

    await _waitUntil(
      () => relay.sent.length >= firstTick + 2,
      within: const Duration(milliseconds: 200),
    );
    expect(await creditsIn(relay.sent.sublist(firstTick)), [
      'control=0',
      'preview=${payload.length}',
    ]);
  });

  test('credits arriving from the agent keep the session alive on their own — '
      'no ping, no rekey', () async {
    await establish(
      pingSilence: const Duration(milliseconds: 60),
      creditBatchBytes: 10000000,
    );
    for (var i = 1; i <= 10; i++) {
      await injectCredit('preview', i);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    final types = (await _sessionFrames(
      readKeys,
      relay.sent,
    )).map((j) => j['type']).toSet();
    expect(
      types,
      isNot(contains('ping')),
      reason: 'a credit is a sealed frame, so it is proof of life too',
    );
    expect(handshaker.performCalls, 1, reason: 'no missed pong, no rekey');
  });

  test('a socket loss drops what the gate was holding, and the next '
      'establishment starts from a fresh window', () async {
    final k2 = fixedKeys(2);
    final read2 = _copyOf(k2);
    handshaker = FakeHandshaker.sequence([fixedKeys(1), k2]);
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
      reason: 'frames the gate held die with the keys they would have used',
    );

    s.hold = false;
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
      await _openFromPhone(read2, relay.sent.last.payload),
      isNotNull,
      reason: 'sealed under the keys of the session that is live now',
    );
    await Future.wait(fresh);
  });

  test('a relay drop report naming a channel and a byte count reopens that '
      'much of the window', () async {
    final (_, sends) = await withFullPreviewWindow();

    relay.injectError(
      ErrorMessage(
        code: 'MESSAGE_RATE_LIMITED',
        message: 'too many frames',
        retryable: true,
        channel: 'preview',
        bytes: relay.sent.first.payload.length,
      ),
    );
    await _waitUntil(
      () => relay.sent.length >= 4,
      within: const Duration(milliseconds: 300),
    );
    expect(
      relay.sent,
      hasLength(4),
      reason: 'exactly the un-charged frame worth of room came back',
    );
    await Future.wait(sends.take(4));
  });

  test('a frame that arrives across a key swap is opened with the new keys', () async {
    final k2 = fixedKeys(2);
    final read2 = _copyOf(k2);
    handshaker = FakeHandshaker.sequence([fixedKeys(1), k2]);
    final session = await establish();

    // The agent swaps to the new keys before it confirms them, so the frames it
    // writes next are sealed under a set this side does not hold yet. The
    // inbound chain captures the keys as a frame ARRIVES and decrypts it
    // several turns later, which is the gap this frame lands in — so the frame
    // is sealed up front and handed over in the same turn as the rekey
    // trigger, with nothing awaited in between. That microtask ordering is what
    // makes the case bite: an await added anywhere between the injection here
    // and the swap would let the chain capture the new keys and open the frame
    // on the first try, and the assertion below would hold for free.
    final acrossSwap = await _sealFromAgent(read2, jsonEncode({'type': 'ping'}));
    relay.inject(
      IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: acrossSwap,
      ),
    );
    for (var i = 0; i < 3; i++) {
      session.notifyRpcResult(timedOut: true);
    }

    await _waitUntil(
      () => relay.sent.isNotEmpty,
      within: const Duration(milliseconds: 500),
    );
    expect(
      (await _sessionFrames(read2, relay.sent)).map((j) => j['type']),
      contains('pong'),
      reason: 'the retry with the live keys is what saves this frame',
    );
  });
}
