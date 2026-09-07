// The attach state TerminalService derives for each terminal, and for the
// checkout as a whole.
//
// Three orthogonal facts are folded into one stage: whether the engine holds
// bytes, whether a screen pull is outstanding, and whether that pull went
// unanswered past its bound. The paint is what decides how an outstanding pull
// reads — a re-pull over an engine that already holds current bytes fires on
// every re-establishment and every mobile focus resume, so presenting it as a
// wait would dim and mislabel a live terminal several times an hour.
//
// The bounds are constructor parameters so these cases drive a short window
// instead of the production one.
//
// Engine-free by construction: nothing here reads `ghostty.plainText`, so a
// host without the prebuilt libghostty-vt runs the whole suite. The seq-cutoff
// invariant is observed through the stage a low-seq output frame produces —
// a frame filtered by a cutoff never reaches the paint.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

/// Short enough that a case can wait it out, long enough to survive a loaded
/// host between the frame that arms it and the assertion that follows.
const _attachBound = Duration(milliseconds: 30);
const _checkoutBound = Duration(milliseconds: 30);
const _pastBound = Duration(milliseconds: 120);

/// A bound no case reaches, for the cases that are not about the bound.
const _unreachedBound = Duration(seconds: 30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  /// A transport whose `terminal.snapshot` RPC is never answered.
  ///
  /// The discovery pull rides a correlated RPC, so a fake with no handler
  /// reports the method as unimplemented and every pull below would resolve
  /// — as a failure — before the case that is about the wait even begins.
  /// Held open instead, the pull is outstanding exactly as it is against a
  /// real bridge, and the cases that want a bound reach it through
  /// `request`'s own timeout, which is what bounds the RPC arm in production.
  FakeAgentTransport newTransport() => FakeAgentTransport()
    ..requestHandler = (_, _) => Completer<Map<String, dynamic>>().future;

  Future<ProjectSession> newSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  /// The service under test, with its own bounds.
  ///
  /// The session builds a main-checkout TerminalService of its own, so the
  /// outbound log carries both. Every count below is taken after a
  /// [FakeAgentTransport.clearSent] over an action only this instance can take.
  TerminalService newService(
    ProjectSession session, {
    Duration snapshotAttachTimeout = _unreachedBound,
    Duration checkoutAttachTimeout = _unreachedBound,
  }) => TerminalService.fromSession(
    session,
    snapshotAttachTimeout: snapshotAttachTimeout,
    checkoutAttachTimeout: checkoutAttachTimeout,
  );

  Map<String, dynamic> terminalInfo(String id, {bool running = true}) => {
    'id': id,
    'terminalId': id,
    'name': id,
    'running': running,
  };

  void emitStatus(FakeAgentTransport t, List<Map<String, dynamic>> terminals) {
    t.emit('agent:status', {'projectId': 'p', 'terminals': terminals});
  }

  /// A composed blob, which carries its own preamble and takes no erase.
  void emitSnapshot(
    FakeAgentTransport t,
    String id, {
    required int seq,
    bool history = false,
  }) {
    t.emit('terminal:snapshot', {
      'terminalId': id,
      'scrollback': 'SCREEN',
      'seq': seq,
      'composed': true,
      'history': history,
    });
  }

  /// Drains the delivery chain and the microtask the hydration re-emit is
  /// coalesced onto.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// The paused -> resumed edge, which re-pulls every live tab. Raised on the
  /// union the agent gates on, so it needs the heavy subscriber the services
  /// already hold.
  Future<void> resumeFocus(ProjectSession session) async {
    session.setLifecyclePaused(true);
    await settle();
    session.setLifecyclePaused(false);
    await settle();
    await settle();
  }

  TerminalAttachStage stageOf(TerminalService svc, String id) =>
      svc.currentState.hydration[id]!.stage;

  test('a discovered terminal reads awaitingScreen with a stamp until its '
      'snapshot lands', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session);

    emitStatus(t, [terminalInfo('a')]);
    await settle();

    expect(stageOf(svc, 'a'), TerminalAttachStage.awaitingScreen);
    expect(
      svc.currentState.hydration['a']!.requestedAtMs,
      isNotNull,
      reason: 'the elapsed readout has nothing to count from without a stamp',
    );
    expect(svc.currentState.attach, CheckoutAttachStatus.attaching);

    emitSnapshot(t, 'a', seq: 1, history: true);
    await settle();

    expect(stageOf(svc, 'a'), TerminalAttachStage.painted);
    expect(svc.currentState.attach, CheckoutAttachStatus.ready);

    await svc.dispose();
    await session.close();
  });

  // Every re-establishment and every mobile foreground re-pulls every live tab.
  // Reading that as a wait would dim the pane and label it "attaching" over a
  // screen that is real and current.
  test('a re-pull over a painted engine reads refreshing, not awaitingScreen',
      () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session);

    emitStatus(t, [terminalInfo('a')]);
    await settle();
    t.emit('terminal:output', {'terminalId': 'a', 'data': 'live'});
    await settle();
    expect(stageOf(svc, 'a'), TerminalAttachStage.painted);

    await resumeFocus(session);

    expect(stageOf(svc, 'a'), TerminalAttachStage.refreshing);
    expect(svc.currentState.attach, CheckoutAttachStatus.ready);

    await svc.dispose();
    await session.close();
  });

  test('an unanswered pull over an empty engine reads failed, and later output '
      'revives it', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, snapshotAttachTimeout: _attachBound);
    // Never answered: the RPC arm's bound IS `request(timeout: …)`, so the
    // fake has to actually hold the call open for the fake's own timer to
    // fire — a null `requestHandler` fails instantly with a non-RPC error
    // instead, which would reach `failed` for the wrong reason.
    t.requestHandler = (_, _) => Completer<Map<String, dynamic>>().future;

    emitStatus(t, [terminalInfo('a')]);
    await settle();
    await Future<void>.delayed(_pastBound);

    expect(stageOf(svc, 'a'), TerminalAttachStage.failed);

    // The deadline bounds how long the pane may claim to be attaching; it is
    // not a verdict on the PTY. A merely slow reply and a respawn both surface
    // here as output arriving after the failure, and neither is a reason to go
    // on showing one. (That a cutoff is armed on the reply and never on the
    // request is pinned from the other side, in terminal_reattach_test.dart —
    // no seq filter runs on this path, so nothing here could observe it.)
    t.emit('terminal:output', {'terminalId': 'a', 'data': 'reborn', 'seq': 1});
    await settle();

    expect(stageOf(svc, 'a'), TerminalAttachStage.painted);

    await svc.dispose();
    await session.close();
  });

  // Checkout-wide failure means only "no agent:status ever arrived". One
  // terminal the agent cannot snapshot is that terminal's problem; the rest of
  // the checkout is usable and must not be presented as broken.
  test('one failed terminal does not condemn the checkout', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, snapshotAttachTimeout: _attachBound);
    // Held open the same way as above, so 'b' actually reaches its bound
    // instead of failing instantly on an unset handler.
    t.requestHandler = (_, _) => Completer<Map<String, dynamic>>().future;

    emitStatus(t, [terminalInfo('a'), terminalInfo('b')]);
    await settle();
    t.emit('terminal:output', {'terminalId': 'a', 'data': 'live'});
    await settle();
    await Future<void>.delayed(_pastBound);

    expect(stageOf(svc, 'a'), TerminalAttachStage.painted);
    expect(stageOf(svc, 'b'), TerminalAttachStage.failed);
    expect(svc.currentState.attach, CheckoutAttachStatus.ready);

    await svc.dispose();
    await session.close();
  });

  // A terminal whose process has exited has no screen left to serialize: the
  // bridge answers the RPC `ok: true` with `snapshot: null` rather than a log
  // line and no frame. It is snapshotted on purpose — a retained transcript is
  // always already stopped — so that pull must read as neither a wait nor a
  // fault.
  test(
    "an exited terminal's pull is answered snapshot: null and reads neither "
    'failed nor awaitingScreen',
    () async {
      final t = newTransport();
      final session = await newSession(t);
      final svc = newService(session, snapshotAttachTimeout: _attachBound);
      t.requestHandler = (_, _) => <String, dynamic>{'snapshot': null};

      emitStatus(t, [terminalInfo('setup', running: false)]);
      await settle();
      await Future<void>.delayed(_pastBound);

      expect(stageOf(svc, 'setup'), isNot(TerminalAttachStage.failed));
      expect(stageOf(svc, 'setup'), isNot(TerminalAttachStage.awaitingScreen));
      expect(
        svc.currentState.attach,
        CheckoutAttachStatus.ready,
        reason: 'a wait nothing will ever end must not hold the checkout back',
      );

      await svc.dispose();
      await session.close();
    },
  );

  // The common case for a busy TUI, and for a pull the agent answers with
  // nothing: without this the pane waits out the whole bound and then reports a
  // failure over output the user can see arriving.
  test('live output retires an outstanding pull', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, snapshotAttachTimeout: _attachBound);

    emitStatus(t, [terminalInfo('a')]);
    await settle();
    expect(stageOf(svc, 'a'), TerminalAttachStage.awaitingScreen);

    t.emit('terminal:output', {'terminalId': 'a', 'data': 'live'});
    await settle();
    await Future<void>.delayed(_pastBound);

    expect(stageOf(svc, 'a'), TerminalAttachStage.painted);

    await svc.dispose();
    await session.close();
  });

  test('retryAttach re-sends exactly one snapshot request and clears the '
      'failure', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, snapshotAttachTimeout: _attachBound);
    t.requestHandler = (_, _) => Completer<Map<String, dynamic>>().future;

    emitStatus(t, [terminalInfo('a')]);
    await settle();
    await Future<void>.delayed(_pastBound);
    expect(stageOf(svc, 'a'), TerminalAttachStage.failed);

    // `requests`, not `sent`: the pull is an RPC now, and this transport has
    // no `clearRequests` — the retry's own call is everything past this mark.
    final before = t.requests.length;
    svc.retryAttach('a');
    await settle();

    final pulls = t.requests
        .skip(before)
        .where((r) => r.method == 'terminal.snapshot')
        .toList();
    expect(pulls, hasLength(1));
    expect(pulls.first.params?['terminalId'], 'a');
    // A full hydrator re-drive would re-pull every checkout's tree as well,
    // turning one tap into a multi-megabyte fan-out.
    expect(t.requests.where((r) => r.method == 'state.snapshot'), isEmpty);
    expect(stageOf(svc, 'a'), TerminalAttachStage.awaitingScreen);

    await svc.dispose();
    await session.close();
  });

  test('a checkout that never sees agent:status reads failed', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, checkoutAttachTimeout: _checkoutBound);
    // The bound belongs to a surface that is watching: it arms on the first
    // subscription, which is what `terminalStateProvider` supplies in the app.
    final sub = svc.stateStream.listen((_) {});
    addTearDown(sub.cancel);

    expect(svc.currentState.attach, CheckoutAttachStatus.unknown);

    await Future<void>.delayed(_pastBound);

    expect(svc.currentState.attach, CheckoutAttachStatus.failed);

    await svc.dispose();
    await session.close();
  });

  // The slow-cellular case. A checkout that was merely slow is not a broken
  // one: the deadline fired before the frame arrived, and the frame arriving is
  // the answer.
  test('a checkout that times out and THEN receives agent:status reads ready',
      () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, checkoutAttachTimeout: _checkoutBound);
    // The bound belongs to a surface that is watching: it arms on the first
    // subscription, which is what `terminalStateProvider` supplies in the app.
    final sub = svc.stateStream.listen((_) {});
    addTearDown(sub.cancel);

    await Future<void>.delayed(_pastBound);
    expect(svc.currentState.attach, CheckoutAttachStatus.failed);

    emitStatus(t, [terminalInfo('a')]);
    await settle();
    expect(
      svc.currentState.attach,
      CheckoutAttachStatus.attaching,
      reason: 'the verdict must clear the moment the frame lands',
    );

    emitSnapshot(t, 'a', seq: 1, history: true);
    await settle();

    expect(svc.currentState.attach, CheckoutAttachStatus.ready);

    await svc.dispose();
    await session.close();
  });

  test('an agent:status cancels the checkout deadline', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, checkoutAttachTimeout: _checkoutBound);

    // No terminals, so nothing but the deadline could move the checkout off
    // ready once the frame has landed.
    emitStatus(t, const []);
    await settle();
    expect(svc.currentState.attach, CheckoutAttachStatus.ready);

    await Future<void>.delayed(_pastBound);

    expect(svc.currentState.attach, CheckoutAttachStatus.ready);

    await svc.dispose();
    await session.close();
  });

  // A tab can leave the status without ever exiting — a service dropped from
  // antgrid.yaml, a slot renamed — and its bookkeeping would otherwise outlive
  // it and fire against an id nothing holds.
  test('a tab that leaves agent:status takes its hydration record with it',
      () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session, snapshotAttachTimeout: _attachBound);

    emitStatus(t, [terminalInfo('a'), terminalInfo('b')]);
    await settle();
    expect(svc.currentState.hydration.keys, unorderedEquals(['a', 'b']));

    emitStatus(t, [terminalInfo('a')]);
    await settle();
    expect(svc.currentState.hydration.keys, ['a']);

    // Past the bound the dropped tab's deadline would have fired had the prune
    // not cancelled it.
    await Future<void>.delayed(_pastBound);
    expect(svc.currentState.hydration.keys, ['a']);

    await svc.dispose();
    await session.close();
  });

  // A snapshot reply is published on the project bus, so a history blob can be
  // the answer to ANOTHER device's cold attach. This client refuses it — the
  // erase would take its own scrollback — and a refusal paints nothing, so it
  // cannot stand in for the answer to this client's own outstanding pull.
  test("another device's cold history blob does not clear this client's "
      'outstanding pull', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session);

    emitStatus(t, [terminalInfo('a')]);
    await settle();
    // This client's own cold pull is answered first, which is what spends its
    // history claim: a later history blob can then only be someone else's.
    emitSnapshot(t, 'a', seq: 1, history: true);
    await settle();
    expect(stageOf(svc, 'a'), TerminalAttachStage.painted);

    await resumeFocus(session);
    final outstanding = svc.currentState.hydration['a']!.requestedAtMs;
    expect(outstanding, isNotNull);

    emitSnapshot(t, 'a', seq: 2, history: true);
    await settle();

    expect(
      svc.currentState.hydration['a']!.requestedAtMs,
      outstanding,
      reason: 'a refused blob answered nothing, so the deadline still owns it',
    );
    expect(stageOf(svc, 'a'), TerminalAttachStage.refreshing);

    await svc.dispose();
    await session.close();
  });

  test(
    'a failed checkout clears its verdict and re-arms its bound on '
    'retryCheckoutAttach',
    () async {
      final t = newTransport();
      final session = await newSession(t);
      final svc = newService(session, checkoutAttachTimeout: _checkoutBound);
      // The bound belongs to a surface that is watching: it arms on the first
      // subscription, which is what `terminalStateProvider` supplies in the
      // app.
      final sub = svc.stateStream.listen((_) {});
      addTearDown(sub.cancel);

      await Future<void>.delayed(_pastBound);
      expect(svc.currentState.attach, CheckoutAttachStatus.failed);

      await svc.retryCheckoutAttach();
      await settle();

      expect(
        svc.currentState.attach,
        CheckoutAttachStatus.attaching,
        reason: 'the failure must clear, and no agent:status has landed yet',
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'the re-armed bound fails the checkout again if the retry is never '
    'answered',
    () async {
      final t = newTransport();
      final session = await newSession(t);
      final svc = newService(session, checkoutAttachTimeout: _checkoutBound);
      final sub = svc.stateStream.listen((_) {});
      addTearDown(sub.cancel);

      await Future<void>.delayed(_pastBound);
      expect(svc.currentState.attach, CheckoutAttachStatus.failed);

      await svc.retryCheckoutAttach();
      await settle();
      expect(svc.currentState.attach, CheckoutAttachStatus.attaching);

      await Future<void>.delayed(_pastBound);

      expect(
        svc.currentState.attach,
        CheckoutAttachStatus.failed,
        reason: 'a re-armed bound with nothing answering it must still end',
      );

      await svc.dispose();
      await session.close();
    },
  );

  // FakeAgentTransport is not a StreamTransport, so this exercises the
  // hydrator-rerun arm rather than `refreshDurableState` — the same arm a
  // local project's TerminalService always takes.
  test('a retry over a non-relay transport re-runs the checkout hydrator',
      () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session);

    emitStatus(t, [terminalInfo('a')]);
    await settle();

    final before = t.requests.length;
    await svc.retryCheckoutAttach();
    await settle();

    final pulls = t.requests
        .skip(before)
        .where((r) => r.method == 'terminal.snapshot')
        .toList();
    expect(pulls, isNotEmpty);
    expect(pulls.first.params?['terminalId'], 'a');

    await svc.dispose();
    await session.close();
  });

  // Neither TerminalState nor TerminalTab defines `==` and the state rides a
  // StreamProvider, so every emission notifies every listener in the workspace.
  test('a burst of discovered terminals publishes once', () async {
    final t = newTransport();
    final session = await newSession(t);
    final svc = newService(session);

    final emissions = <TerminalState>[];
    final sub = svc.stateStream.listen(emissions.add);
    await settle();

    emitStatus(t, [
      for (var i = 0; i < 6; i++) terminalInfo('t$i'),
    ]);
    await settle();

    expect(svc.currentState.tabs, hasLength(6));
    expect(
      emissions,
      hasLength(2),
      reason: 'the rebuild, then one coalesced hydration re-emit for all six',
    );
    expect(emissions.last.hydration.keys, hasLength(6));

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });
}
