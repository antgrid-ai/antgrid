// Opt-in coverage for the live frame-replace terminal protocol
// (`terminal:subscribe`/`subscribed`/`frame`/`ack`/`unsubscribe`/
// `display:status`), gated behind `kTerminalFrameModeEnabled`.
//
// Every legacy terminal test in this directory asserts the snapshot-plus-diff
// path with the latch at its OFF default and must keep passing unedited —
// that is the whole point of D1. These cases flip the latch on for their own
// duration and pin the state machine the spec's D1-D10 decisions describe:
// what commits a terminal to frame mode, what an applied frame does to the
// engine, what a superseded or stale-geometry frame does NOT do, and every
// path that can retire an attachment (ended, failed, respawn, reconnect,
// retry, delete, dispose).
//
// The engine cases are gated on native availability, exactly like
// terminal_reattach_test.dart: a host without the prebuilt libghostty-vt
// reports them SKIPPED rather than failing.


import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

bool _hasNative() {
  try {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    return true;
  } catch (_) {
    return false;
  }
}

/// True when the native VT is missing, having marked the current test skipped.
bool _skipWithoutNative() {
  if (_hasNative()) return false;
  markTestSkipped('native VT unavailable');
  return true;
}

Map<String, dynamic> _historyBoundary() => {
  'epoch': 1,
  'firstRowId': 0,
  'nextRowId': 0,
  'status': 'recording',
};

Map<String, dynamic> _frameExtra({
  required String terminalId,
  required String runId,
  required String attachmentId,
  required int sequence,
  required String ansi,
  int cols = 80,
  int rows = 24,
  int revision = 1,
  bool syncTimedOut = false,
}) => {
  'terminalId': terminalId,
  'runId': runId,
  'attachmentId': attachmentId,
  'sequence': sequence,
  'version': kTerminalFrameProtocolVersion,
  'revision': revision,
  'cols': cols,
  'rows': rows,
  'ansi': ansi,
  'syncTimedOut': syncTimedOut,
  'history': _historyBoundary(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
    kTerminalFrameModeEnabled = false;
  });

  // The latch is a process-global mutable, so every test that flips it on
  // must flip it back regardless of how the test ends, or it leaks into
  // whatever legacy-mode test runs next in the same process.
  tearDown(() {
    kTerminalFrameModeEnabled = false;
  });

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

  /// Seeds one running tab named [id] via `agent:status` (status tier) and
  /// settles the discovery attach — the same seam legacy discovery uses, so
  /// frame mode's dual-protocol transition window (a subscribe alongside the
  /// legacy pull) is exercised exactly as it would be live.
  Future<void> seedRunningTab(FakeAgentTransport t, String id) async {
    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {'id': id, 'terminalId': id, 'name': id, 'running': true},
      ],
    });
    await Future<void>.delayed(Duration.zero);
  }

  /// Reads the `requestId` off the most recently sent `terminal:subscribe`
  /// for [terminalId].
  String lastSubscribeRequestId(FakeAgentTransport t, String terminalId) {
    final sent = t.sent.lastWhere(
      (m) => m['type'] == 'terminal:subscribe' && m['terminalId'] == terminalId,
    );
    return sent['requestId'] as String;
  }

  /// Answers the most recent outstanding subscribe for [terminalId] with a
  /// `terminal:subscribed`, committing it to frame mode.
  Future<void> acceptSubscribe(
    FakeAgentTransport t,
    String terminalId, {
    String runId = 'run-1',
    String attachmentId = 'att-1',
  }) async {
    t.emit('terminal:subscribed', {
      'terminalId': terminalId,
      'runId': runId,
      'attachmentId': attachmentId,
      'version': kTerminalFrameProtocolVersion,
      'requestId': lastSubscribeRequestId(t, terminalId),
    });
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'discovering a running terminal sends terminal:subscribe when the latch is on',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');

      final subscribe = t.sent.firstWhere((m) => m['type'] == 'terminal:subscribe');
      expect(subscribe['terminalId'], 'a');
      expect(subscribe['version'], kTerminalFrameProtocolVersion);
      expect(subscribe['requestId'], isA<String>());
      expect((subscribe['requestId'] as String).isNotEmpty, isTrue);
      // D1: still legacy until a `terminal:subscribed` actually lands.
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'the latch off by default sends no subscribe and never leaves legacy mode',
    () async {
      // Deliberately NOT flipping the latch — this is the control case
      // proving the gate actually gates, since every other case in this file
      // would look identical if kTerminalFrameModeEnabled did nothing.
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');

      expect(t.sent.where((m) => m['type'] == 'terminal:subscribe'), isEmpty);
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'terminal:subscribed commits the tab to frame mode at TerminalAttachStage.cold',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      // Dual-protocol window: the legacy RPC pull is still in flight here too.
      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isNotEmpty);

      await acceptSubscribe(t, 'a');

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
      expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.cold);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a stale-requestId terminal:subscribed cannot resurrect a superseded attempt',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      // Answer with a requestId this client never sent.
      t.emit('terminal:subscribed', {
        'terminalId': 'a',
        'runId': 'run-x',
        'attachmentId': 'att-x',
        'version': kTerminalFrameProtocolVersion,
        'requestId': 'not-the-real-one',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'once frame mode commits, a fresh attach cycle no longer touches the legacy pull',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      t.requests.clear();
      t.clearSent();

      svc.retryAttach('a');
      await Future<void>.delayed(Duration.zero);

      // D6/D8: legacy is fully disowned once frame mode is confirmed — a
      // retry re-subscribes and nothing else.
      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isEmpty);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:snapshot:request'),
        isEmpty,
      );
      expect(t.sent.where((m) => m['type'] == 'terminal:subscribe'), isNotEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'an applied frame is one appendOutputBytes call, bumps replaceEpoch, and ack'
    's the sequence',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;
      final epochBefore = tab.replaceEpoch.value;

      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 1,
          ansi: 'FRAME-ONE',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(tab.ghostty.plainText, contains('FRAME-ONE'));
      expect(tab.replaceEpoch.value, epochBefore + 1);
      expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.painted);

      final ack = t.sent.lastWhere((m) => m['type'] == 'terminal:ack');
      expect(ack['terminalId'], 'a');
      expect(ack['runId'], 'run-1');
      expect(ack['attachmentId'], 'att-1');
      expect(ack['sequence'], 1);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a superseded (already-processed) sequence is dropped unparsed and never re-acked',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;

      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 5,
          ansi: 'HIGH-SEQ',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      t.clearSent();

      // Arrives late, addressing a sequence already retired.
      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 3,
          ansi: 'SUPERSEDED',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(tab.ghostty.plainText, isNot(contains('SUPERSEDED')));
      expect(t.sent.where((m) => m['type'] == 'terminal:ack'), isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a frame whose geometry predates the tab\'s own resize is dropped but still acked',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;
      // Tab defaults to 80x24; a frame claiming a different size predates a
      // resize the driver already believes it sent (D4).
      expect(tab.cols, 80);
      expect(tab.rows, 24);

      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 1,
          ansi: 'STALE-GEOMETRY',
          cols: 100,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(tab.ghostty.plainText, isNot(contains('STALE-GEOMETRY')));
      // Ack is delivery, not proof of rendering (D5) — still sent.
      final ack = t.sent.lastWhere((m) => m['type'] == 'terminal:ack');
      expect(ack['sequence'], 1);
      // Never painted, so hydration must not read painted either.
      expect(svc.currentState.hydration['a']!.stage, isNot(TerminalAttachStage.painted));

      await svc.dispose();
      await session.close();
    },
  );

  test('terminal:output is dropped once a terminal is in frame mode', () async {
    if (_skipWithoutNative()) return;
    kTerminalFrameModeEnabled = true;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);

    await seedRunningTab(t, 'a');
    await acceptSubscribe(t, 'a');
    final tab = svc.currentState.tabs['a']!;

    t.emit('terminal:output', {'terminalId': 'a', 'data': 'LEGACY-BYTES'});
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, isNot(contains('LEGACY-BYTES')));

    await svc.dispose();
    await session.close();
  });

  test('terminal:snapshot is dropped once a terminal is in frame mode', () async {
    if (_skipWithoutNative()) return;
    kTerminalFrameModeEnabled = true;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);

    await seedRunningTab(t, 'a');
    await acceptSubscribe(t, 'a');
    final tab = svc.currentState.tabs['a']!;

    // The fan-out of another client's still-legacy request, or this client's
    // own now-superseded dual-protocol-window pull.
    t.emit('terminal:snapshot', {
      'terminalId': 'a',
      'scrollback': 'ANOTHER-DEVICES-SCREEN',
      'seq': 1,
    });
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, isNot(contains('ANOTHER-DEVICES-SCREEN')));

    await svc.dispose();
    await session.close();
  });

  test(
    'display:status ENDED is a lifecycle stage, never rendered as a failure',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');

      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'ENDED',
        'message': 'the run completed',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.ended);
      expect(svc.currentState.hydration['a']!.message, 'the run completed');

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'display:status DISPLAY_FAILED surfaces as a failure carrying the message',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');

      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'DISPLAY_FAILED',
        'message': 'could not render',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.failed);
      expect(svc.currentState.hydration['a']!.message, 'could not render');

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'an unrecognized display:status code is a generic failure, never ignored',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');

      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'SOME_FUTURE_CODE_THIS_CLIENT_HAS_NEVER_SEEN',
        'message': 'from a newer agent',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.failed);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a respawn resets the mode to legacy and renegotiates from scratch',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
      final firstRequestId = lastSubscribeRequestId(t, 'a');

      t.emit('terminal:exited', {'terminalId': 'a', 'exitCode': 0});
      await Future<void>.delayed(Duration.zero);
      t.emit('terminal:started', {
        'terminalId': 'a',
        'shell': 'pwsh',
        'cols': 80,
        'rows': 24,
      });
      await Future<void>.delayed(Duration.zero);

      // D1: a fresh PTY generation starts the legacy-or-frame choice over.
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);
      final secondRequestId = lastSubscribeRequestId(t, 'a');
      expect(secondRequestId, isNot(firstRequestId));

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a stream re-attach re-subscribes a frame-mode terminal and reads as refreshing',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      // `_rehydrateTerminals` reaches the transport only as a registered
      // hydrator, and `activate()` is what registers it — without this a
      // re-drive iterates an empty map and re-attaches nothing at all, so
      // the assertions below would pass or fail for the wrong reason.
      svc.activate();

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 1,
          ansi: 'BEFORE-RECONNECT',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final tab = svc.currentState.tabs['a']!;
      expect(tab.ghostty.plainText, contains('BEFORE-RECONNECT'));

      t.clearSent();
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);

      // The attachment does not survive a re-establishment (spec scope: "the
      // subscription does not survive a re-establishment"), so a fresh
      // subscribe goes out...
      expect(t.sent.where((m) => m['type'] == 'terminal:subscribe'), isNotEmpty);
      // ...but the engine's last frame is still current-looking on screen, so
      // this reads as a routine refresh, never a cold wait.
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.refreshing,
      );
      // The elapsed readout the legacy pull gives: a subscribe the user is
      // waiting on has to be as legible as a snapshot pull.
      expect(svc.currentState.hydration['a']!.requestedAtMs, isNotNull);
      // And the screen itself is untouched until a fresh frame actually lands.
      expect(tab.ghostty.plainText, contains('BEFORE-RECONNECT'));

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'an unanswered subscribe is bounded: the tab falls back to the legacy '
    'pull instead of wedging on a stale screen',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(
        session,
        snapshotAttachTimeout: const Duration(milliseconds: 20),
      );

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;
      expect(tab.mode, TerminalDisplayMode.frame);
      t.requests.clear();
      t.clearSent();

      // An unanswered subscribe is a routine bridge outcome, not a race:
      // agent-core breaks with no reply on a deleting checkout, a disposed
      // owner or a stale client generation, and the frame delivery path
      // returns silently while the connection is suppressed -- which is
      // exactly the state a reconnect passes through.
      svc.retryAttach('a');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);
      expect(
        t.requests.where((r) => r.method == 'terminal.snapshot'),
        isNotEmpty,
      );
      // And the drop guards let go with the latch, so the pane is reachable
      // by the protocol that is actually answering.
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'AFTER-FALLBACK'});
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.plainText, contains('AFTER-FALLBACK'));

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a non-latching oversize DISPLAY_FAILED keeps the attachment: the next '
    'screen that fits still paints and is still acked',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;
      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 1,
          ansi: 'FITS-ONE',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // `TerminalFrameDelivery.reportOversize` says the screen was skipped
      // WITHOUT retiring the attachment -- the viewer stays subscribed and
      // the next screen that fits resumes it. Treating it as a retirement
      // stops the acks, and the bridge then kills the still-live attachment
      // with ACK_TIMEOUT ten seconds later.
      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'DISPLAY_FAILED',
        'message':
            'This screen is too large to send. Waiting for it to change.',
      });
      await Future<void>.delayed(Duration.zero);
      t.clearSent();

      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 2,
          revision: 2,
          ansi: 'FITS-TWO',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(tab.ghostty.plainText, contains('FITS-TWO'));
      final ack = t.sent.lastWhere((m) => m['type'] == 'terminal:ack');
      expect(ack['sequence'], 2);
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.painted,
      );
      expect(svc.currentState.hydration['a']!.message, isNull);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a frame that overtakes its own terminal:size is held, not lost: it '
    'paints once the geometry catches up',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;

      // `terminal:frame` rides the preview channel and `terminal:size` the
      // status channel, each with its own credit window, so the post-resize
      // frame can land first. The bridge never resends a revision it has
      // already sent, so dropping this frame outright freezes the pane until
      // the guest happens to redraw.
      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 1,
          revision: 2,
          cols: 100,
          ansi: 'POST-RESIZE',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.plainText, isNot(contains('POST-RESIZE')));

      t.emit('terminal:size', {
        'terminalId': 'a',
        'cols': 100,
        'rows': 24,
        'driverClientId': 'the-driver',
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        svc.currentState.tabs['a']!.ghostty.plainText,
        contains('POST-RESIZE'),
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'UPGRADE_REQUIRED refusing a re-subscribe reaches a tab already in frame '
    'mode and demotes it',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
      svc.retryAttach('a');
      await Future<void>.delayed(Duration.zero);
      t.requests.clear();

      // The bridge sends this with a requestId and deliberately NO
      // runId/attachmentId -- a refused subscribe has only the terminal to
      // name -- so an attachment-keyed guard drops the only notice there is.
      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'requestId': lastSubscribeRequestId(t, 'a'),
        'code': 'UPGRADE_REQUIRED',
        'message': 'Upgrade the app and bridge to use terminal screens.',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);
      expect(
        t.requests.where((r) => r.method == 'terminal.snapshot'),
        isNotEmpty,
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'after ENDED the next attach renegotiates instead of blackholing the '
    'run that replaced it',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;

      // `retireRun` sends ENDED for every attachment on a run being torn
      // down, so it can arrive for a terminal that already has a live
      // successor PTY.
      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'ENDED',
        'message': 'Terminal completed.',
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.ended);

      svc.retryAttach('a');
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'NEW-RUN-BYTES'});
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.plainText, contains('NEW-RUN-BYTES'));

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'retryAttach on a frame-mode tab with no live PTY still issues a pull',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      t.emit('terminal:exited', {'terminalId': 'a', 'exitCode': 0});
      await Future<void>.delayed(Duration.zero);
      t.requests.clear();
      t.clearSent();

      // Frame mode cannot serve a terminal with no PTY behind it, so a Retry
      // that only re-subscribes sends nothing at all on either channel.
      svc.retryAttach('a');
      await Future<void>.delayed(Duration.zero);

      expect(
        t.requests.where((r) => r.method == 'terminal.snapshot'),
        isNotEmpty,
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a tab leaving frame mode leaves the alternate screen the frame put the '
    'engine on',
    () async {
      if (_skipWithoutNative()) return;
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;

      // A frame serialized from a guest running a full-screen TUI carries
      // `?1049h` in its own body, so applying it leaves the app's engine on
      // the alternate screen with no counterpart sequence guaranteed to
      // follow.
      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 1,
          ansi: '\x1b[?1049hTUI-SCREEN',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.terminal.isAlternateScreen, isTrue);

      t.emit('terminal:exited', {'terminalId': 'a', 'exitCode': 0});
      await Future<void>.delayed(Duration.zero);
      t.emit('terminal:started', {
        'terminalId': 'a',
        'shell': 'pwsh',
        'cols': 80,
        'rows': 24,
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.legacy);
      expect(tab.ghostty.terminal.isAlternateScreen, isFalse);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'deleteTerminal leaves replaceEpoch usable: a tab object outliving its '
    'deletion must not throw on a fresh listener',
    () async {
      kTerminalFrameModeEnabled = true;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      await seedRunningTab(t, 'a');
      final tab = svc.currentState.tabs['a']!;

      svc.deleteTerminal('a');
      await Future<void>.delayed(Duration.zero);

      // `TerminalService.dispose` and a same-id respawn both leave a tab's
      // notifier undisposed, so a half-measure here is the only shape that
      // can make a remount throw where the two other paths do not.
      void listener() {}
      expect(() => tab.replaceEpoch.addListener(listener), returnsNormally);
      tab.replaceEpoch.removeListener(listener);

      await svc.dispose();
      await session.close();
    },
  );

  test('deleteTerminal sends terminal:unsubscribe for the live attachment', () async {
    kTerminalFrameModeEnabled = true;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);

    await seedRunningTab(t, 'a');
    await acceptSubscribe(t, 'a', runId: 'run-7', attachmentId: 'att-7');
    t.clearSent();

    svc.deleteTerminal('a');
    await Future<void>.delayed(Duration.zero);

    final unsub = t.sent.lastWhere((m) => m['type'] == 'terminal:unsubscribe');
    expect(unsub['terminalId'], 'a');
    expect(unsub['runId'], 'run-7');
    expect(unsub['attachmentId'], 'att-7');

    await svc.dispose();
    await session.close();
  });

  test('dispose sends terminal:unsubscribe for every live frame attachment', () async {
    kTerminalFrameModeEnabled = true;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);

    await seedRunningTab(t, 'a');
    await acceptSubscribe(t, 'a', runId: 'run-9', attachmentId: 'att-9');
    t.clearSent();

    await svc.dispose();
    await Future<void>.delayed(Duration.zero);

    final unsub = t.sent.lastWhere((m) => m['type'] == 'terminal:unsubscribe');
    expect(unsub['terminalId'], 'a');
    expect(unsub['runId'], 'run-9');
    expect(unsub['attachmentId'], 'att-9');

    await session.close();
  });
}
