import 'dart:async';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake for every mechanism the supervisor drives. Each verb records its calls
/// and the getters are settable, so a test can script "dial succeeds but the
/// socket never authenticates" — the shapes real relay code produces — without
/// a relay, a socket, or a wall-clock wait.
class ScriptedMechanisms implements ConnMechanisms {
  ConnCoords? coords = const ConnCoords(
    relayUrl: 'wss://relay.test',
    agentEd25519PubB64: 'AGENT_PUB',
  );

  bool socketAuthenticatedValue = false;
  bool agentOnlineValue = false;
  bool sessionEstablishedValue = false;

  int resolveCalls = 0;
  int mintCalls = 0;
  int dialCalls = 0;
  int establishCalls = 0;
  int releaseCalls = 0;

  final List<String> dialedTokens = <String>[];

  /// Number of upcoming calls that fail before the scripted success.
  int coordsNulls = 0;
  int dialFailures = 0;
  int establishFailures = 0;

  /// When set, [dial] parks on this until the test completes it.
  Completer<void>? dialGate;

  /// When set, [mintToken] parks on this until the test completes it — the
  /// window in which a coords change can invalidate the pending dial.
  Completer<void>? mintGate;

  @override
  Future<ConnCoords?> resolveCoords() async {
    resolveCalls++;
    if (coordsNulls > 0) {
      coordsNulls--;
      return null;
    }
    return coords;
  }

  @override
  Future<String> mintToken() async {
    mintCalls++;
    final gate = mintGate;
    if (gate != null) {
      await gate.future;
    }
    return 'token-$mintCalls';
  }

  @override
  Future<void> dial(ConnCoords coords, String token) async {
    dialCalls++;
    dialedTokens.add(token);
    final gate = dialGate;
    if (gate != null) {
      await gate.future;
    }
    if (dialFailures > 0) {
      dialFailures--;
      throw StateError('dial rejected');
    }
    socketAuthenticatedValue = true;
  }

  @override
  bool get socketAuthenticated => socketAuthenticatedValue;

  @override
  bool get agentOnline => agentOnlineValue;

  @override
  Future<void> establishSession() async {
    establishCalls++;
    if (establishFailures > 0) {
      establishFailures--;
      throw StateError('handshake failed');
    }
    sessionEstablishedValue = true;
  }

  @override
  bool get sessionEstablished => sessionEstablishedValue;

  @override
  Future<void> release() async {
    releaseCalls++;
    socketAuthenticatedValue = false;
    agentOnlineValue = false;
    sessionEstablishedValue = false;
  }
}

/// Lets microtasks and zero-duration timers drain. Backoffs in these tests are
/// either 0ms or a few ms, so nothing here waits on real network-scale delays.
Future<void> settle([int rounds = 16]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within 5s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late ScriptedMechanisms mech;

  setUp(() {
    mech = ScriptedMechanisms();
  });

  ConnectionSupervisor build({
    int backoffBaseMs = 1000,
    int backoffCapMs = 30000,
    int routableStallMs = 2000,
    int Function(int)? jitter,
  }) {
    final sup = ConnectionSupervisor(
      mech,
      backoffBaseMs: backoffBaseMs,
      backoffCapMs: backoffCapMs,
      routableStallMs: routableStallMs,
      jitter: jitter ?? (_) => 0,
    );
    addTearDown(sup.dispose);
    return sup;
  }

  test(
    'an agent that is simply not running reaches Blocked(agentOffline) on its '
    'own — no external evaluate() ever fires',
    () async {
      // The production scenario the routable rung used to lose: coords resolve,
      // the dial succeeds, and then nothing else happens because presence is
      // pushed by a peer that is not there. Nothing in the app calls evaluate()
      // in that state, so without a stall timer the UI sits on Climbing forever
      // and never tells the user the agent is offline.
      final sup = build(routableStallMs: 5);

      sup.setWanted(true);
      await waitUntil(() => sup.status is Blocked);

      expect(sup.status, const Blocked(BlockReason.agentOffline));
      expect(mech.dialCalls, 1, reason: 'the socket rung was satisfied');
      expect(mech.establishCalls, 0);
    },
  );

  test('evaluate is idempotent — concurrent calls produce one dial', () async {
    mech.agentOnlineValue = true;
    mech.dialGate = Completer<void>();
    final sup = build();

    sup.setWanted(true);
    await settle(4);
    expect(mech.dialCalls, 1, reason: 'first evaluate reached the dial');

    final a = sup.evaluate();
    final b = sup.evaluate();
    mech.dialGate!.complete();
    await Future.wait<void>(<Future<void>>[a, b]);
    await settle();

    expect(mech.dialCalls, 1);
    expect(mech.mintCalls, 1);
    expect(mech.resolveCalls, 1);
    expect(sup.status, const Connected());
  });

  test(
    'climbs rung by rung: coords → dial(fresh token) → waits presence → establishes',
    () async {
      final sup = build();
      final seen = <SupervisorStatus>[];
      final sub = sup.statusStream.listen(seen.add);
      addTearDown(sub.cancel);

      sup.setWanted(true);
      await settle();

      expect(mech.resolveCalls, 1);
      expect(mech.dialCalls, 1);
      expect(mech.dialedTokens.single, 'token-1');
      expect(
        mech.establishCalls,
        0,
        reason: 'the routable rung must wait for presence',
      );
      expect(sup.status, const Climbing(ConnRung.socket));

      mech.agentOnlineValue = true;
      sup.notePresence(true);
      await settle();

      expect(mech.establishCalls, 1);
      expect(sup.status, const Connected());
      expect(
        seen,
        containsAllInOrder(<SupervisorStatus>[
          const Climbing(ConnRung.socket),
          const Connected(),
        ]),
      );
    },
  );

  test('a fresh token is minted for EVERY dial attempt', () async {
    mech.agentOnlineValue = true;
    mech.dialFailures = 2;
    final sup = build(backoffBaseMs: 0);

    sup.setWanted(true);
    await waitUntil(() => mech.dialCalls >= 3);
    await settle();

    expect(mech.mintCalls, 3);
    expect(mech.dialedTokens.length, 3);
    expect(mech.dialedTokens.toSet().length, 3, reason: 'no token reuse');
    expect(sup.status, const Connected());
  });

  test(
    'highest satisfied rung only — established session + dead socket reruns dial, not handshake',
    () async {
      mech.agentOnlineValue = true;
      final sup = build();
      sup.setWanted(true);
      await settle();
      expect(sup.status, const Connected());
      expect(mech.dialCalls, 1);
      expect(mech.establishCalls, 1);

      // Session object still believes it is established; the socket under it died.
      mech.socketAuthenticatedValue = false;
      sup.noteSocketState(authenticated: false);
      await settle();

      expect(mech.dialCalls, 2, reason: 'the lowest broken rung is the socket');
      expect(mech.mintCalls, 2);
      expect(
        mech.establishCalls,
        1,
        reason: 'the established rung was already satisfied',
      );
      expect(sup.status, const Connected());
    },
  );

  test('per-rung backoff doubles with jitter and resets on success', () async {
    final windows = <int>[];
    mech.agentOnlineValue = true;
    mech.dialFailures = 3;
    final sup = build(
      backoffBaseMs: 4,
      jitter: (int maxExclusive) {
        windows.add(maxExclusive);
        return 0;
      },
    );

    sup.setWanted(true);
    await waitUntil(() => mech.dialCalls >= 4);
    await settle();

    expect(windows, <int>[4, 8, 16]);
    expect(sup.status, const Connected());

    // A later failure starts from the base again — success reset the rung.
    windows.clear();
    mech.dialFailures = 1;
    mech.socketAuthenticatedValue = false;
    sup.noteSocketState(authenticated: false);
    await waitUntil(() => windows.isNotEmpty);

    expect(windows.first, 4);
  });

  test(
    'the backoff window saturates at the cap and never falls below the base',
    () async {
      // The regression this guards is a shift overflow: `base << attempt` with
      // no clamp goes negative (and then below the base, i.e. a retry storm)
      // once attempt passes 63. Only a long run of consecutive failures can
      // see it, so the doubling test above cannot.
      final windows = <int>[];
      mech.agentOnlineValue = true;
      mech.dialFailures = 99;
      final sup = build(
        backoffBaseMs: 1,
        backoffCapMs: 8,
        jitter: (int maxExclusive) {
          windows.add(maxExclusive);
          return 0;
        },
      );

      sup.setWanted(true);
      await waitUntil(() => windows.length >= 10);

      expect(windows.take(4), <int>[1, 2, 4, 8]);
      expect(
        windows.skip(4),
        everyElement(8),
        reason: 'the window must saturate at the cap, never keep doubling',
      );
      expect(windows, everyElement(inInclusiveRange(1, 8)));
    },
  );

  test(
    'a coords change during mintToken() is not charged to the socket backoff',
    () async {
      final windows = <int>[];
      mech.agentOnlineValue = true;
      final sup = build(
        backoffBaseMs: 4,
        jitter: (int maxExclusive) {
          windows.add(maxExclusive);
          return 0;
        },
      );

      mech.mintGate = Completer<void>();
      sup.setWanted(true);
      await waitUntil(() => mech.mintCalls >= 1);

      // The machine moved while the token was in flight: the coords the dial
      // was about to use are gone. That is a coords event, not a socket
      // failure, and must not delay the next dial.
      sup.noteCoordsChanged();
      mech.mintGate!.complete();
      mech.mintGate = null;
      await waitUntil(() => sup.status == const Connected());

      expect(
        windows,
        isEmpty,
        reason: 'no rung failed, so no backoff window was computed',
      );
      expect(mech.dialCalls, 1);
    },
  );

  test(
    'agentOffline blocks after repeated routable stalls and unblocks on notePresence(true)',
    () async {
      final sup = build();
      sup.setWanted(true);
      await settle();
      expect(sup.status, const Climbing(ConnRung.socket));

      await sup.evaluate();
      expect(sup.status, const Climbing(ConnRung.socket));

      await sup.evaluate();
      expect(sup.status, const Blocked(BlockReason.agentOffline));
      expect(mech.establishCalls, 0);

      mech.agentOnlineValue = true;
      sup.notePresence(true);
      await settle();

      expect(sup.status, const Connected());
      expect(mech.establishCalls, 1);
    },
  );

  test(
    'sessionTakenOver blocks and ONLY retry() unblocks (presence does not)',
    () async {
      mech.agentOnlineValue = true;
      final sup = build();
      sup.setWanted(true);
      await settle();
      expect(sup.status, const Connected());

      mech.sessionEstablishedValue = false;
      sup.noteSessionTakenOver();
      await settle();
      expect(sup.status, const Blocked(BlockReason.sessionTakenOver));
      expect(mech.establishCalls, 1);

      sup.notePresence(true);
      sup.noteFreshToken();
      sup.noteCoordsChanged();
      sup.noteResume();
      sup.noteSessionDown();
      await settle();

      expect(
        sup.status,
        const Blocked(BlockReason.sessionTakenOver),
        reason: 'presence must never auto-resume a session another device took',
      );
      expect(mech.establishCalls, 1);

      sup.retry();
      await settle();

      expect(sup.status, const Connected());
      expect(mech.establishCalls, 2);
    },
  );

  test(
    'LICENSE_EXPIRED blocks and noteFreshToken() unblocks into a dial',
    () async {
      mech.agentOnlineValue = true;
      mech.dialFailures = 1;
      final sup = build();

      sup.setWanted(true);
      await settle();
      expect(mech.dialCalls, 1);

      sup.noteRelayError('LICENSE_EXPIRED', retryable: false);
      await settle();
      expect(sup.status, const Blocked(BlockReason.licenseExpired));

      sup.noteResume();
      await sup.evaluate();
      await settle();
      expect(mech.dialCalls, 1, reason: 'a block does not clear on evaluation');

      sup.noteFreshToken();
      await settle();

      expect(mech.dialCalls, 2);
      expect(mech.mintCalls, 2);
      expect(mech.dialedTokens, <String>['token-1', 'token-2']);
      expect(sup.status, const Connected());
    },
  );

  test(
    'SUPERSEDED against our OWN stale relay entry recovers on the next dial',
    () async {
      // Network blip: the client socket died instantly, the relay still holds
      // the old entry, and the redial carries the same per-launch epoch — which
      // the relay rejects as "a newer or equal connection already holds this
      // deviceId". Once its liveness sweep drops the stale entry the very same
      // epoch is admitted, so this must not be a dead end.
      mech.agentOnlineValue = true;
      final sup = build(backoffBaseMs: 0);
      sup.setWanted(true);
      await settle();
      expect(sup.status, const Connected());

      mech.socketAuthenticatedValue = false;
      mech.sessionEstablishedValue = false;
      mech.dialFailures = 1;
      sup.noteRelayError('SUPERSEDED', retryable: false);
      // Inputs evaluate on a microtask (see _kick), so the stale Connected
      // status survives until the deferred evaluation runs — drain first or
      // the waitUntil below matches it before the ladder even starts.
      await settle();
      await waitUntil(() => sup.status == const Connected());

      expect(mech.dialCalls, 3);
    },
  );

  test('SUPERSEDED blocks only after the relay has had time to sweep, and '
      'retry() clears it', () async {
    mech.agentOnlineValue = true;
    final sup = build(backoffBaseMs: 0);
    sup.setWanted(true);
    await settle();
    expect(sup.status, const Connected());

    mech.socketAuthenticatedValue = false;
    mech.sessionEstablishedValue = false;
    mech.dialFailures = 999;
    for (var i = 0; i < kMaxSupersededRetries - 1; i++) {
      sup.noteRelayError('SUPERSEDED', retryable: false);
      await settle();
      expect(
        sup.status,
        isNot(isA<Blocked>()),
        reason: 'a genuinely newer holder is only provable by persistence',
      );
    }

    sup.noteRelayError('SUPERSEDED', retryable: false);
    await settle();
    expect(sup.status, const Blocked(BlockReason.superseded));

    sup.noteFreshToken();
    sup.notePresence(true);
    await settle();
    expect(sup.status, const Blocked(BlockReason.superseded));

    mech.dialFailures = 0;
    sup.retry();
    await waitUntil(() => sup.status == const Connected());
  });

  test(
    'repeated socket failures re-resolve the coords instead of dialling a '
    'dead endpoint forever',
    () async {
      // A host that moved relay (or re-provisioned its identity) while this
      // machine was held warm: the cached coords can never succeed, and with
      // no producer for noteCoordsChanged() the ladder used to sit on the 30s
      // socket cap with no Blocked reason and an inert Retry.
      mech.agentOnlineValue = true;
      mech.dialFailures = 999;
      final sup = build(backoffBaseMs: 0);

      sup.setWanted(true);
      await waitUntil(() => mech.resolveCalls >= 2);

      expect(mech.dialCalls, greaterThanOrEqualTo(kMaxSocketFailuresPerCoords));
    },
  );

  test('retry() re-resolves the coords, not just the backoff', () async {
    mech.agentOnlineValue = true;
    final sup = build();
    sup.setWanted(true);
    await settle();
    expect(sup.status, const Connected());
    expect(mech.resolveCalls, 1);

    // The user's Retry is the manual "something out there changed" input, so
    // it must re-ask where the machine lives — otherwise a stale endpoint
    // survives every retry the user can make.
    mech.socketAuthenticatedValue = false;
    mech.sessionEstablishedValue = false;
    sup.retry();
    await settle();

    expect(mech.resolveCalls, 2);
    expect(sup.status, const Connected());
  });

  test(
    'LICENSE_REVOKED and LICENSE_INVALID block on deviceRevoked; only retry() clears it',
    () async {
      mech.agentOnlineValue = true;
      final sup = build();
      sup.setWanted(true);
      await settle();
      expect(sup.status, const Connected());

      mech.socketAuthenticatedValue = false;
      mech.sessionEstablishedValue = false;
      sup.noteRelayError('LICENSE_REVOKED', retryable: false);
      await settle();
      expect(sup.status, const Blocked(BlockReason.deviceRevoked));
      expect(mech.dialCalls, 1);

      // A revoked device needs re-provisioning outside this supervisor, so no
      // amount of new tokens, presence or coords may resume it on its own.
      sup.noteFreshToken();
      sup.notePresence(true);
      sup.noteCoordsChanged();
      sup.noteResume();
      await settle();
      expect(sup.status, const Blocked(BlockReason.deviceRevoked));
      expect(mech.dialCalls, 1);

      sup.retry();
      await settle();
      expect(mech.dialCalls, 2);
      expect(sup.status, const Connected());

      // LICENSE_INVALID lands on the same block.
      mech.socketAuthenticatedValue = false;
      sup.noteRelayError('LICENSE_INVALID', retryable: false);
      await settle();
      expect(sup.status, const Blocked(BlockReason.deviceRevoked));
      expect(mech.dialCalls, 2);
    },
  );

  test('noteCoordsChanged() unblocks agentOffline and re-resolves', () async {
    final sup = build();
    sup.setWanted(true);
    await settle();
    await sup.evaluate();
    await sup.evaluate();
    expect(sup.status, const Blocked(BlockReason.agentOffline));
    expect(mech.resolveCalls, 1);

    // New coords are new information about where the agent lives, so the
    // "offline" verdict earned at the old endpoint no longer holds.
    mech.coords = const ConnCoords(
      relayUrl: 'wss://relay2.test',
      agentEd25519PubB64: 'AGENT_PUB',
    );
    mech.agentOnlineValue = true;
    sup.noteCoordsChanged();
    await settle();

    expect(mech.resolveCalls, 2);
    expect(sup.status, const Connected());
  });

  test(
    'noteCoordsChanged() unblock is not instantly undone by a stale stall count',
    () async {
      final sup = build();
      sup.setWanted(true);
      await settle();
      await sup.evaluate();
      await sup.evaluate();
      expect(sup.status, const Blocked(BlockReason.agentOffline));

      // The agent is STILL offline at the new endpoint — unlike the sibling
      // test above, this must not climb straight to Connected. It exercises
      // whether the unblock actually buys a fresh run of stalls rather than
      // inheriting the count that just tripped the block.
      mech.coords = const ConnCoords(
        relayUrl: 'wss://relay2.test',
        agentEd25519PubB64: 'AGENT_PUB',
      );
      sup.noteCoordsChanged();
      await settle();

      expect(sup.status, isNot(const Blocked(BlockReason.agentOffline)));
    },
  );

  test('retryable relay errors do not block — they just re-evaluate', () async {
    mech.agentOnlineValue = true;
    final sup = build();
    sup.setWanted(true);
    await settle();

    mech.socketAuthenticatedValue = false;
    sup.noteRelayError('PEER_OFFLINE', retryable: true);
    await settle();

    expect(sup.status, const Connected());
    expect(mech.dialCalls, 2);
  });

  test('handshake failures block after 6 consecutive attempts', () async {
    mech.agentOnlineValue = true;
    mech.establishFailures = 99;
    final sup = build(backoffBaseMs: 0);

    sup.setWanted(true);
    await waitUntil(() => sup.status is Blocked);
    await settle();

    expect(sup.status, const Blocked(BlockReason.handshakeFailing));
    expect(mech.establishCalls, 6);

    mech.establishFailures = 0;
    sup.notePresence(true);
    await settle();

    expect(sup.status, const Connected());
    expect(mech.establishCalls, 7);
  });

  test(
    'noteResume() while healthy is a no-op; while broken it re-runs the broken rung',
    () async {
      mech.agentOnlineValue = true;
      final sup = build();
      sup.setWanted(true);
      await settle();
      expect(sup.status, const Connected());

      sup.noteResume();
      await settle();
      expect(mech.dialCalls, 1);
      expect(mech.establishCalls, 1);
      expect(mech.resolveCalls, 1);
      expect(sup.status, const Connected());

      // Socket died with no edge event to announce it — resume must notice.
      mech.socketAuthenticatedValue = false;
      sup.noteResume();
      await settle();

      expect(mech.dialCalls, 2);
      expect(mech.establishCalls, 1);
      expect(sup.status, const Connected());
    },
  );

  test('setWanted(false) releases and stops all timers', () async {
    mech.agentOnlineValue = true;
    mech.dialFailures = 99;
    final sup = build(backoffBaseMs: 4);

    sup.setWanted(true);
    await waitUntil(() => mech.dialCalls >= 2);

    sup.setWanted(false);
    await settle();
    final dialsAtRelease = mech.dialCalls;

    expect(mech.releaseCalls, 1);
    expect(sup.status, const Released());

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      mech.dialCalls,
      dialsAtRelease,
      reason: 'no work runs while released',
    );
    // dialCalls alone cannot see a leaked timer — the !wanted branch returns
    // before any dial. release() is the observable: a surviving backoff timer
    // fires _kick(), which re-runs that branch and releases a second time.
    expect(
      mech.releaseCalls,
      1,
      reason: 'the armed backoff timer must be cancelled, not merely ignored',
    );
  });

  test(
    'statusStream is broadcast and replays the current status on listen',
    () async {
      mech.agentOnlineValue = true;
      final sup = build();
      sup.setWanted(true);
      await settle();
      expect(sup.status, const Connected());

      final stream = sup.statusStream;
      expect(stream.isBroadcast, isTrue);

      final first = await stream.first;
      expect(first, const Connected());

      final second = await sup.statusStream.first;
      expect(second, const Connected());
    },
  );

  // Named for what it can actually observe: after dispose every path out of a
  // surviving timer is already guarded, so "no work happens" is the testable
  // requirement, not "the Timer object was cancelled".
  test(
    'dispose closes the stream and no input does work afterwards',
    () async {
      mech.agentOnlineValue = true;
      mech.dialFailures = 99;
      final sup = ConnectionSupervisor(
        mech,
        backoffBaseMs: 4,
        jitter: (_) => 0,
      );
      var done = false;
      sup.statusStream.listen(null, onDone: () => done = true);

      sup.setWanted(true);
      await waitUntil(() => mech.dialCalls >= 2);

      await sup.dispose();
      final dialsAtDispose = mech.dialCalls;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(done, isTrue);
      expect(mech.dialCalls, dialsAtDispose);

      sup.retry();
      sup.noteResume();
      await settle();
      expect(mech.dialCalls, dialsAtDispose);
    },
  );
}
