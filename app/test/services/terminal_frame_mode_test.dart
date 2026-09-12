import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/models/terminal_history_model.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

/// A transport whose sends stop leaving, without the socket reporting anything
/// -- a relay stream that is connected but not yet established, where a frame
/// is sealed against nothing and vanishes. The one failure mode a
/// fire-and-forget verb cannot observe at its own call site.
class _UndeliverableTransport extends FakeAgentTransport {
  bool deliver = true;

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    if (!deliver) return;
    await super.send(message, channel: channel);
  }
}

/// A transport that fails AT THE CALL: `send` is deliberately not `async`
/// here, so the error escapes the verb that called it instead of becoming a
/// rejected future. The shape a transport torn down under a live call takes.
class _ThrowingTransport extends FakeAgentTransport {
  bool throwOnSend = false;

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) {
    if (throwOnSend) throw StateError('transport is gone');
    return super.send(message, channel: channel);
  }
}

/// One timer the service armed, captured at the zone's own factory.
///
/// A history request's bound is real wall-clock, so a test that sleeps past it
/// is racing every other timer on the shared event loop. Firing the captured
/// callback runs the same code the bound would have, at an instant the test
/// picked, and no case in this group waits on a duration to reach it.
class _ArmedBound {
  _ArmedBound(this._timer, this.duration, this._callback);

  final Timer _timer;

  /// The duration the service ASKED for. Recorded because [fire] runs the
  /// callback whatever duration was requested, so nothing else in this group
  /// can tell one bound's length from another's.
  final Duration duration;

  final void Function() _callback;

  bool get isActive => _timer.isActive;

  /// Runs what the bound would have run, once: the real timer is retired
  /// first, so nothing can run it again later in the test.
  void fire() {
    expect(_timer.isActive, isTrue);
    _timer.cancel();
    _callback();
  }
}

/// Runs [body] with the zone's timer factory intercepted, appending every
/// timer armed inside it to [into].
///
/// [into] is an argument rather than a return value so a body that THROWS --
/// a transport that fails at the call -- still leaves the caller holding the
/// bounds armed before the throw.
void _captureBounds(List<_ArmedBound> into, void Function() body) {
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, f) {
        final timer = parent.createTimer(zone, duration, f);
        into.add(_ArmedBound(timer, duration, f));
        return timer;
      },
    ),
  );
}

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

Map<String, dynamic> _historyBoundary({
  int epoch = 1,
  int firstRowId = 0,
  int nextRowId = 0,
  String status = 'recording',
}) => {
  'epoch': epoch,
  'firstRowId': firstRowId,
  'nextRowId': nextRowId,
  'status': status,
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
  Map<String, dynamic>? history,
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
  'history': history ?? _historyBoundary(),
};

Map<String, dynamic> _historyRow(int rowId, {int cols = 80}) => {
  'rowId': rowId,
  'cols': cols,
  'wrapped': false,
  'spans': [
    {'text': 'row$rowId', 'cells': 6, 'sgr': ''},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
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

  /// Reads the `requestId` off the most recently sent
  /// `terminal:history:request` for [terminalId].
  String lastHistoryRequestId(FakeAgentTransport t, String terminalId) {
    final sent = t.sent.lastWhere(
      (m) =>
          m['type'] == 'terminal:history:request' &&
          m['terminalId'] == terminalId,
    );
    return sent['requestId'] as String;
  }

  Future<void> applyHistoryBoundary(
    FakeAgentTransport t,
    String terminalId, {
    required Map<String, dynamic> history,
    String runId = 'run-1',
    String attachmentId = 'att-1',
    int sequence = 1,
  }) async {
    t.emit(
      'terminal:frame',
      _frameExtra(
        terminalId: terminalId,
        runId: runId,
        attachmentId: attachmentId,
        sequence: sequence,
        ansi: 'HISTORY-SCREEN',
        cols: 100,
        history: history,
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  /// Emits a `terminal:history:page` answering [requestId].
  void emitHistoryPage(
    FakeAgentTransport t, {
    required String terminalId,
    required String requestId,
    String runId = 'run-1',
    String attachmentId = 'att-1',
    Map<String, dynamic>? history,
    bool expired = false,
    required int beforeRowId,
    List<Map<String, dynamic>> rows = const [],
  }) {
    t.emit('terminal:history:page', {
      'terminalId': terminalId,
      'runId': runId,
      'attachmentId': attachmentId,
      'requestId': requestId,
      'history': history ?? _historyBoundary(),
      'expired': expired,
      'beforeRowId': beforeRowId,
      'rows': rows,
    });
  }

  test('missing terminal removes an empty tab without stopping it', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = session.terminalService;
    svc.setDisplayInterest('frame-test-pane', 'a');
    svc.activate();
    await seedRunningTab(t, 'a');
    t.emit('terminal:display:status', {
      'terminalId': 'a',
      'requestId': lastSubscribeRequestId(t, 'a'),
      'code': 'UNKNOWN_TERMINAL',
      'message': 'Terminal no longer available',
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.tabs, isEmpty);
    expect(svc.currentState.activeTerminalId, isNull);
    expect(t.sent.where((m) => m['type'] == 'terminal:stop'), isEmpty);
    t.clearSent();
    await seedRunningTab(t, 'a');
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.tabs, isEmpty);
    expect(t.sent.where((m) => m['type'] == 'terminal:subscribe'), isEmpty);
    t.emit('terminal:started', {
      'terminalId': 'a',
      'shell': 'sh',
      'cols': 80,
      'rows': 24,
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.tabs.containsKey('a'), isTrue);
    expect(
      t.sent.where((m) => m['type'] == 'terminal:subscribe'),
      hasLength(1),
    );
    await svc.dispose();
    await session.close();
  });

  test(
    'bell events ring only the focused current run and never repaint',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = session.terminalService;
      svc.setDisplayInterest('frame-test-pane', 'a');
      addTearDown(session.close);
      svc.activate();
      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;
      tab.ghostty.setFocused(false);
      t.emit('terminal:bell', {'terminalId': 'a', 'runId': 'run-1'});
      await Future<void>.delayed(Duration.zero);
      tab.ghostty.setFocused(true);
      t.emit('terminal:bell', {'terminalId': 'a', 'runId': 'retired-run'});
      t.emit('terminal:bell', {
        'terminalId': 'a',
        'runId': 'run-1',
        'checkoutId': 'other',
      });
      t.emit('terminal:bell', {'terminalId': 'missing', 'runId': 'run-1'});
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'SystemSound.play'), isEmpty);
      t.emit('terminal:bell', {'terminalId': 'a', 'runId': 'run-1'});
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((call) => call.method == 'SystemSound.play'),
        hasLength(1),
      );
      expect(
        t.sent.where((message) => message['type'] == 'terminal:ack'),
        isEmpty,
      );
    },
  );

  test(
    'missing terminal retains its screen and history through a start timeout',
    () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = session.terminalService;
      svc.setDisplayInterest('frame-test-pane', 'a');
      svc.activate();
      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(nextRowId: 2),
      );
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: lastHistoryRequestId(t, 'a'),
        history: _historyBoundary(nextRowId: 2),
        beforeRowId: 2,
        rows: [_historyRow(0), _historyRow(1)],
      );
      await Future<void>.delayed(Duration.zero);
      final tab = svc.currentState.tabs['a']!;
      svc.retryAttach('a');
      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'requestId': lastSubscribeRequestId(t, 'a'),
        'code': 'UNKNOWN_TERMINAL',
        'message': 'Terminal no longer available',
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.unavailable,
      );
      expect(tab.ghostty.plainText, contains('HISTORY-SCREEN'));
      expect(tab.history.rows, hasLength(2));
      expect(svc.sendInput('a', 'ignored'), isFalse);
      t.clearSent();
      svc.retryAttach('a');
      t.redriveHydrators();
      t.emit('agent:status', {'projectId': 'p', 'terminals': []});
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.tabs['a']!.history.rows, hasLength(2));
      await seedRunningTab(t, 'a');
      expect(
        svc.currentState.tabs['a']!.sessionState,
        TerminalSessionState.exited,
      );
      expect(t.sent.where((m) => m['type'] == 'terminal:subscribe'), isEmpty);
      final startBounds = <_ArmedBound>[];
      _captureBounds(startBounds, () => svc.requestStart('a'));
      expect(
        svc.currentState.tabs['a']!.sessionState,
        TerminalSessionState.starting,
      );
      expect(tab.ghostty.isRunning, isFalse);
      startBounds
          .singleWhere((bound) => bound.duration == svc.terminalStartTimeout)
          .fire();
      expect(
        svc.currentState.tabs['a']!.sessionState,
        TerminalSessionState.exited,
      );
      expect(svc.currentState.tabs['a']!.ghostty, same(tab.ghostty));
      expect(tab.ghostty.plainText, contains('HISTORY-SCREEN'));
      expect(tab.history.rows, hasLength(2));
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.unavailable,
      );
      expect(tab.ghostty.isRunning, isFalse);
      expect(svc.sendInput('a', 'ignored-after-timeout'), isFalse);
      t.emit('terminal:started', {
        'terminalId': 'a',
        'shell': 'sh',
        'cols': 80,
        'rows': 24,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.currentState.tabs['a']!.sessionState,
        TerminalSessionState.running,
      );
      expect(tab.ghostty.isRunning, isTrue);
      expect(
        svc.currentState.hydration['a']!.stage,
        isNot(TerminalAttachStage.unavailable),
      );
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe'),
        hasLength(1),
      );
      await svc.dispose();
      await session.close();
    },
  );

  test(
    'missing refusal from a superseded request cannot retire a live attachment',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = session.terminalService;
      svc.setDisplayInterest('frame-test-pane', 'a');
      await seedRunningTab(t, 'a');
      final staleRequest = lastSubscribeRequestId(t, 'a');
      svc.retryAttach('a');
      await acceptSubscribe(t, 'a');
      for (final requestId in [
        staleRequest,
        lastSubscribeRequestId(t, 'a'),
        null,
      ]) {
        t.emit('terminal:display:status', {
          'terminalId': 'a',
          'requestId': ?requestId,
          'code': 'UNKNOWN_TERMINAL',
          'message': 'Terminal no longer available',
        });
      }
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.tabs.containsKey('a'), isTrue);
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.awaitingScreen,
      );
      await svc.dispose();
      await session.close();
    },
  );

  test('starting a terminal supersedes a pending missing refusal', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = session.terminalService;
    svc.setDisplayInterest('frame-test-pane', 'a');
    svc.activate();
    await seedRunningTab(t, 'a');
    final staleRequest = lastSubscribeRequestId(t, 'a');
    svc.requestStart('a');
    t.emit('terminal:display:status', {
      'terminalId': 'a',
      'requestId': staleRequest,
      'code': 'UNKNOWN_TERMINAL',
      'message': 'Terminal no longer available',
    });
    t.clearSent();
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);
    expect(
      svc.currentState.tabs['a']!.sessionState,
      TerminalSessionState.starting,
    );
    expect(t.sent.where((m) => m['type'] == 'terminal:subscribe'), isEmpty);
    t.emit('terminal:started', {
      'terminalId': 'a',
      'shell': 'sh',
      'cols': 80,
      'rows': 24,
    });
    await Future<void>.delayed(Duration.zero);
    expect(
      t.sent.where((m) => m['type'] == 'terminal:subscribe'),
      hasLength(1),
    );
    await svc.dispose();
    await session.close();
  });

  test('discovering a running terminal sends terminal:subscribe', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

    await seedRunningTab(t, 'a');

    final subscribe = t.sent.firstWhere(
      (m) => m['type'] == 'terminal:subscribe',
    );
    expect(subscribe['terminalId'], 'a');
    expect(subscribe['version'], kTerminalFrameProtocolVersion);
    expect(subscribe['requestId'], isA<String>());
    expect((subscribe['requestId'] as String).isNotEmpty, isTrue);
    expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);

    await svc.dispose();
    await session.close();
  });

  test(
    'a re-attach while subscribing sends only a fresh frame subscription',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      // `_rehydrateTerminals` reaches the transport only as a registered
      // hydrator, and `activate()` is what registers it.
      svc.activate();

      await seedRunningTab(t, 'a');
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe'),
        isNotEmpty,
      );
      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isEmpty);
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);

      final beforeRequests = t.requests.length;
      final beforeSent = t.sent.length;
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);

      expect(
        t.requests
            .skip(beforeRequests)
            .where((r) => r.method == 'terminal.snapshot'),
        isEmpty,
      );
      expect(
        t.sent.skip(beforeSent).where((m) => m['type'] == 'terminal:subscribe'),
        hasLength(1),
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a re-attach over a COMMITTED frame tab re-subscribes and does not pull',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      // `_rehydrateTerminals` reaches the transport only as a registered
      // hydrator, and `activate()` is what registers it.
      svc.activate();

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);

      final beforeRequests = t.requests.length;
      final beforeSent = t.sent.length;
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);

      expect(
        t.requests
            .skip(beforeRequests)
            .where((r) => r.method == 'terminal.snapshot'),
        isEmpty,
      );
      expect(
        t.sent.skip(beforeSent).where((m) => m['type'] == 'terminal:subscribe'),
        hasLength(1),
      );

      await svc.dispose();
      await session.close();
    },
  );

  test('a stopped terminal subscribes for its retained final screen', () async {
    // The control case proving the remaining gate actually gates: frame
    // mode is scoped to a live PTY generation, so every other case in this
    // file would look identical if `_hasLivePty` did nothing.
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {'id': 'a', 'terminalId': 'a', 'name': 'a', 'running': false},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(t.sent.where((m) => m['type'] == 'terminal:subscribe'), isNotEmpty);
    expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);

    await svc.dispose();
    await session.close();
  });

  test(
    'terminal:subscribed commits the tab to frame mode at TerminalAttachStage.awaitingScreen',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isEmpty);

      await acceptSubscribe(t, 'a');

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.awaitingScreen,
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a stale-requestId terminal:subscribed cannot resurrect a superseded attempt',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'once frame mode commits, a fresh attach cycle no longer touches the legacy pull',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      t.requests.clear();
      t.clearSent();

      svc.retryAttach('a');
      await Future<void>.delayed(Duration.zero);

      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isEmpty);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:snapshot:request'),
        isEmpty,
      );
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe'),
        isNotEmpty,
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'an applied frame is one appendOutputBytes call, bumps replaceEpoch, and ack'
    's the sequence',
    () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.painted,
      );

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
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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

  test('a frame applies its own geometry before acknowledgment', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

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

    expect(tab.ghostty.plainText, contains('STALE-GEOMETRY'));
    expect(svc.currentState.tabs['a']!.cols, 100);
    // Ack is delivery, not proof of rendering (D5) — still sent.
    final ack = t.sent.lastWhere((m) => m['type'] == 'terminal:ack');
    expect(ack['sequence'], 1);
    // Never painted, so hydration must not read painted either.
    expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.painted);

    await svc.dispose();
    await session.close();
  });

  test('terminal:output is dropped once a terminal is in frame mode', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

    await seedRunningTab(t, 'a');
    await acceptSubscribe(t, 'a');
    final tab = svc.currentState.tabs['a']!;

    t.emit('terminal:output', {'terminalId': 'a', 'data': 'LEGACY-BYTES'});
    await Future<void>.delayed(Duration.zero);

    expect(tab.ghostty.plainText, isNot(contains('LEGACY-BYTES')));

    await svc.dispose();
    await session.close();
  });

  test(
    'terminal:snapshot is dropped once a terminal is in frame mode',
    () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;

      t.emit('terminal:snapshot', {
        'terminalId': 'a',
        'scrollback': 'ANOTHER-DEVICES-SCREEN',
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);

      expect(tab.ghostty.plainText, isNot(contains('ANOTHER-DEVICES-SCREEN')));

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'exit waits for the final consumed frame and keeps history paging after ENDED',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');
      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      t.emit('terminal:exited', {'terminalId': 'a', 'exitCode': 7});
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.currentState.tabs['a']!.sessionState,
        TerminalSessionState.running,
      );
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
      );
      expect(
        t.sent.lastWhere((m) => m['type'] == 'terminal:ack')['sequence'],
        1,
      );
      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'ENDED',
        'message': 'Terminal completed.',
        'finalSequence': 1,
        'exitCode': 7,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.currentState.tabs['a']!.sessionState,
        TerminalSessionState.exited,
      );
      expect(svc.currentState.tabs['a']!.exitCode, 7);
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: lastHistoryRequestId(t, 'a'),
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
        beforeRowId: 49,
        rows: [_historyRow(49)],
      );
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.tabs['a']!.history.rows.single.rowId, 49);
      await svc.dispose();
      await session.close();
    },
  );

  test(
    'display:status ENDED is a lifecycle stage, never rendered as a failure',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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

      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.failed,
      );
      expect(svc.currentState.hydration['a']!.message, 'could not render');

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'an unrecognized display:status code is a generic failure, never ignored',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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

      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.failed,
      );

      await svc.dispose();
      await session.close();
    },
  );

  test('a respawn requests a fresh frame attachment', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

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

    expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
    final secondRequestId = lastSubscribeRequestId(t, 'a');
    expect(secondRequestId, isNot(firstRequestId));

    await svc.dispose();
    await session.close();
  });

  test(
    'a stream re-attach re-subscribes a frame-mode terminal and reads as refreshing',
    () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');
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
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe'),
        isNotEmpty,
      );
      // ...but the engine's last frame is still current-looking on screen, so
      // this reads as a routine refresh, never a cold wait.
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.refreshing,
      );
      expect(svc.currentState.hydration['a']!.requestedAtMs, isNotNull);
      // And the screen itself is untouched until a fresh frame actually lands.
      expect(tab.ghostty.plainText, contains('BEFORE-RECONNECT'));

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'an unanswered subscribe exposes failure without accepting raw output',
    () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(
        session,
        snapshotAttachTimeout: const Duration(milliseconds: 20),
      );
      svc.setDisplayInterest('frame-test-pane', 'a');

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

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isEmpty);
      // And the drop guards let go with the latch, so the pane is reachable
      // by the protocol that is actually answering.
      t.emit('terminal:output', {'terminalId': 'a', 'data': 'AFTER-FALLBACK'});
      await Future<void>.delayed(Duration.zero);
      expect(tab.ghostty.plainText, isNot(contains('AFTER-FALLBACK')));
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.failed,
      );

      await svc.dispose();
      await session.close();
    },
  );

  test('a non-latching oversize DISPLAY_FAILED keeps the attachment: the next '
      'screen that fits still paints and is still acked', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

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
      'message': 'This screen is too large to send. Waiting for it to change.',
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
    expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.painted);
    expect(svc.currentState.hydration['a']!.message, isNull);

    await svc.dispose();
    await session.close();
  });

  test('a frame paints before a delayed terminal:size arrives', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

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
    expect(tab.ghostty.plainText, contains('POST-RESIZE'));
    expect(svc.currentState.tabs['a']!.cols, 100);

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
  });

  test(
    'UPGRADE_REQUIRED refusing a re-subscribe reaches a tab already in frame '
    'mode and exposes the upgrade requirement',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test('after ENDED the next attach renegotiates instead of blackholing the '
      'run that replaced it', () async {
    if (_skipWithoutNative()) return;
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

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

    expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
    t.emit('terminal:output', {'terminalId': 'a', 'data': 'NEW-RUN-BYTES'});
    await Future<void>.delayed(Duration.zero);
    expect(tab.ghostty.plainText, isNot(contains('NEW-RUN-BYTES')));
    expect(
      svc.currentState.hydration['a']!.stage,
      TerminalAttachStage.awaitingScreen,
    );

    await svc.dispose();
    await session.close();
  });

  test(
    'retryAttach on a stopped tab subscribes for its retained screen',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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

      expect(t.requests.where((r) => r.method == 'terminal.snapshot'), isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'a respawn retains the previous screen until a new frame arrives',
    () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

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

      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);
      expect(tab.ghostty.terminal.isAlternateScreen, isTrue);

      await svc.dispose();
      await session.close();
    },
  );

  test('deleteTerminal leaves replaceEpoch usable: a tab object outliving its '
      'deletion must not throw on a fresh listener', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setDisplayInterest('frame-test-pane', 'a');

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
  });

  test(
    'deleteTerminal sends terminal:unsubscribe for the live attachment',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-7', attachmentId: 'att-7');
      t.clearSent();

      svc.deleteTerminal('a');
      await Future<void>.delayed(Duration.zero);

      final unsub = t.sent.lastWhere(
        (m) => m['type'] == 'terminal:unsubscribe',
      );
      expect(unsub['terminalId'], 'a');
      expect(unsub['runId'], 'run-7');
      expect(unsub['attachmentId'], 'att-7');

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'dispose sends terminal:unsubscribe for every live frame attachment',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-9', attachmentId: 'att-9');
      t.clearSent();

      await svc.dispose();
      await Future<void>.delayed(Duration.zero);

      final unsub = t.sent.lastWhere(
        (m) => m['type'] == 'terminal:unsubscribe',
      );
      expect(unsub['terminalId'], 'a');
      expect(unsub['runId'], 'run-9');
      expect(unsub['attachmentId'], 'att-9');

      await session.close();
    },
  );

  group('history paging', () {
    test(
      'requestTerminalHistoryPage sends a well-formed terminal:history:request',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-42', attachmentId: 'att-42');
        await applyHistoryBoundary(
          t,
          'a',
          runId: 'run-42',
          attachmentId: 'att-42',
          history: _historyBoundary(epoch: 7, firstRowId: 0, nextRowId: 120),
        );

        expect(svc.requestTerminalHistoryPage('a'), isTrue);

        final sent = t.sent.lastWhere(
          (m) => m['type'] == 'terminal:history:request',
        );
        expect(sent['terminalId'], 'a');
        expect(sent['runId'], 'run-42');
        expect(sent['attachmentId'], 'att-42');
        expect(sent['epoch'], 7);
        expect(sent['beforeRowId'], 120);
        expect(sent['requestId'], isA<String>());
        expect((sent['requestId'] as String).isNotEmpty, isTrue);

        await svc.dispose();
        await session.close();
      },
    );

    test('refuses to page before a subscription is accepted', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');

      expect(svc.requestTerminalHistoryPage('a'), isFalse);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:history:request'),
        isEmpty,
      );

      await svc.dispose();
      await session.close();
    });

    test('pages retained history through the completed attachment', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 10),
      );

      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'ENDED',
        'message': 'Terminal completed.',
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);

      t.clearSent();
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      final request = t.sent.singleWhere(
        (m) => m['type'] == 'terminal:history:request',
      );
      expect(request['runId'], 'run-1');
      expect(request['attachmentId'], 'att-1');
      expect(request['beforeRowId'], 10);
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: request['requestId'] as String,
        history: _historyBoundary(nextRowId: 10),
        beforeRowId: 10,
        rows: List.generate(10, _historyRow),
      );
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.tabs['a']!.history.rows, hasLength(10));
      expect(svc.currentState.tabs['a']!.history.loading, isFalse);
      expect(svc.currentState.hydration['a']!.stage, TerminalAttachStage.ended);

      await svc.dispose();
      await session.close();
    });

    test('refuses to send when nothing is archived for this run', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      // Default boundary: firstRowId == nextRowId, so hasHistory is false.
      await applyHistoryBoundary(t, 'a', history: _historyBoundary());

      expect(svc.requestTerminalHistoryPage('a'), isFalse);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:history:request'),
        isEmpty,
      );

      await svc.dispose();
      await session.close();
    });

    test(
      'reads committed rows after further history recording is disabled',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(
            firstRowId: 0,
            nextRowId: 50,
            status: 'disabled',
          ),
        );

        expect(svc.requestTerminalHistoryPage('a'), isTrue);
        final request = t.sent.singleWhere(
          (m) => m['type'] == 'terminal:history:request',
        );
        expect(request['beforeRowId'], 50);
        emitHistoryPage(
          t,
          terminalId: 'a',
          requestId: request['requestId'] as String,
          history: _historyBoundary(nextRowId: 50, status: 'disabled'),
          beforeRowId: 50,
          rows: List.generate(50, _historyRow),
        );
        await Future<void>.delayed(Duration.zero);
        final model = svc.currentState.tabs['a']!.history;
        expect(model.rows, hasLength(50));
        expect(model.recording, isFalse);
        expect(model.loading, isFalse);
        expect(svc.requestTerminalHistoryPage('a'), isFalse);

        await svc.dispose();
        await session.close();
      },
    );

    test(
      'refuses to send once the oldest archived row is already loaded',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 5),
        );

        final model = svc.currentState.tabs['a']!.history;
        expect(model.cursor, 5);
        expect(svc.requestTerminalHistoryPage('a'), isTrue);
        emitHistoryPage(
          t,
          terminalId: 'a',
          requestId: lastHistoryRequestId(t, 'a'),
          history: _historyBoundary(firstRowId: 0, nextRowId: 5),
          beforeRowId: 5,
          rows: [for (var i = 0; i < 5; i++) _historyRow(i)],
        );
        await Future<void>.delayed(Duration.zero);
        expect(model.atOldest, isTrue);

        t.clearSent();
        expect(svc.requestTerminalHistoryPage('a'), isFalse);
        expect(
          t.sent.where((m) => m['type'] == 'terminal:history:request'),
          isEmpty,
        );

        await svc.dispose();
        await session.close();
      },
    );

    test(
      'refuses to send a second request while one is already outstanding',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 50),
        );

        expect(svc.requestTerminalHistoryPage('a'), isTrue);
        expect(svc.requestTerminalHistoryPage('a'), isFalse);
        expect(
          t.sent.where((m) => m['type'] == 'terminal:history:request'),
          hasLength(1),
        );

        await svc.dispose();
        await session.close();
      },
    );

    test('pages older rows within the model\'s strict cap', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      // Archive bottoms out at row 0, well below anything this page
      // returns, so hitting the cap here can never be confused with
      // reaching the top of the archive.
      const archiveNextRowId = kTerminalHistoryMaxRows + 1001;
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: archiveNextRowId),
      );

      final model = svc.currentState.tabs['a']!.history;
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      // One oversize page (the wire caps a real page at 200 rows; nothing
      // client-side enforces that) pushes the loaded count past the cap in
      // one reply, proving the ceiling is on ROWS LOADED, not requests made.
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: lastHistoryRequestId(t, 'a'),
        history: _historyBoundary(firstRowId: 0, nextRowId: archiveNextRowId),
        beforeRowId: archiveNextRowId,
        rows: List<Map<String, dynamic>>.generate(
          kTerminalHistoryMaxRows + 1,
          (i) => _historyRow(1000 + i),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(model.rows.length, kTerminalHistoryMaxRows);
      expect(model.atOldest, isFalse); // the cap tripped first, not the top

      t.clearSent();
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:history:request'),
        hasLength(1),
      );

      await svc.dispose();
      await session.close();
    });

    test(
      'a page naming the live runId and attachmentId is applied to the tab\'s '
      'model',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 3),
        );

        final model = svc.currentState.tabs['a']!.history;
        expect(svc.requestTerminalHistoryPage('a'), isTrue);
        emitHistoryPage(
          t,
          terminalId: 'a',
          requestId: lastHistoryRequestId(t, 'a'),
          runId: 'run-1',
          attachmentId: 'att-1',
          history: _historyBoundary(firstRowId: 0, nextRowId: 3),
          beforeRowId: 3,
          rows: [for (var i = 0; i < 3; i++) _historyRow(i)],
        );
        await Future<void>.delayed(Duration.zero);

        expect(model.rows.map((r) => r.rowId), [0, 1, 2]);
        expect(model.loading, isFalse);

        await svc.dispose();
        await session.close();
      },
    );

    test('a page naming a stale runId or a stale attachmentId is dropped and '
        'leaves the model untouched', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 3),
      );

      final model = svc.currentState.tabs['a']!.history;
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      final requestId = lastHistoryRequestId(t, 'a');

      // Half 1: correct attachmentId, stale runId.
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: requestId,
        runId: 'run-STALE',
        attachmentId: 'att-1',
        history: _historyBoundary(firstRowId: 0, nextRowId: 99),
        beforeRowId: 3,
        rows: [_historyRow(0)],
      );
      await Future<void>.delayed(Duration.zero);
      expect(model.rows, isEmpty);
      expect(model.boundary!.nextRowId, 3);
      expect(model.loading, isTrue);

      // Half 2: correct runId, stale attachmentId.
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: requestId,
        runId: 'run-1',
        attachmentId: 'att-STALE',
        history: _historyBoundary(firstRowId: 0, nextRowId: 99),
        beforeRowId: 3,
        rows: [_historyRow(0)],
      );
      await Future<void>.delayed(Duration.zero);
      expect(model.rows, isEmpty);
      expect(model.boundary!.nextRowId, 3);
      expect(model.loading, isTrue);

      await svc.dispose();
      await session.close();
    });

    test(
      'a page whose requestId is not the outstanding one is dropped',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 3),
        );

        final model = svc.currentState.tabs['a']!.history;
        expect(svc.requestTerminalHistoryPage('a'), isTrue);

        // Names the live attachment correctly, but a requestId this client
        // never issued -- a late reply to an already-superseded request.
        emitHistoryPage(
          t,
          terminalId: 'a',
          requestId: 'not-the-outstanding-request',
          runId: 'run-1',
          attachmentId: 'att-1',
          history: _historyBoundary(firstRowId: 0, nextRowId: 99),
          beforeRowId: 3,
          rows: [_historyRow(0)],
        );
        await Future<void>.delayed(Duration.zero);

        expect(model.rows, isEmpty);
        expect(model.boundary!.nextRowId, 3);
        expect(model.loading, isTrue);

        await svc.dispose();
        await session.close();
      },
    );

    test('the per-request deadline reports failure onto the model without '
        'demoting the pane or touching the frame attachment', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-9', attachmentId: 'att-9');
      await applyHistoryBoundary(
        t,
        'a',
        runId: 'run-9',
        attachmentId: 'att-9',
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
      );

      final model = svc.currentState.tabs['a']!.history;
      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
      );
      expect(armed, hasLength(1));
      armed.single.fire();

      expect(model.loading, isFalse);
      expect(model.failure, isNotNull);
      expect(svc.currentState.tabs['a']!.mode, TerminalDisplayMode.frame);

      // The frame attachment itself must be untouched by a stalled
      // scrollback page -- proven by the attachment `dispose` still
      // unsubscribes surviving with the SAME runId/attachmentId.
      t.clearSent();
      await svc.dispose();
      final unsub = t.sent.lastWhere(
        (m) => m['type'] == 'terminal:unsubscribe',
      );
      expect(unsub['runId'], 'run-9');
      expect(unsub['attachmentId'], 'att-9');

      await session.close();
    });

    test('a page that arrives before the deadline cancels it, and nothing else '
        'changes once the original bound passes', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 3),
      );

      final model = svc.currentState.tabs['a']!.history;
      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
      );
      expect(armed, hasLength(1));
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: lastHistoryRequestId(t, 'a'),
        history: _historyBoundary(firstRowId: 0, nextRowId: 3),
        beforeRowId: 3,
        rows: [for (var i = 0; i < 3; i++) _historyRow(i)],
      );
      await Future<void>.delayed(Duration.zero);
      expect(model.loading, isFalse);
      expect(model.failure, isNull);

      // The bound itself, rather than a sleep past it: a retired timer
      // cannot fire over the page it just answered.
      expect(armed.single.isActive, isFalse);
      expect(model.rows.map((r) => r.rowId), [0, 1, 2]);

      await svc.dispose();
      await session.close();
    });

    test('every terminal:frame restates the boundary onto the model, including '
        'one changing the authoritative geometry', () async {
      if (_skipWithoutNative()) return;
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      final tab = svc.currentState.tabs['a']!;
      expect(tab.cols, 80);

      // Matching geometry: painted, and still restates the boundary.
      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 1,
          ansi: 'PAINTED',
          history: _historyBoundary(firstRowId: 0, nextRowId: 10),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(tab.history.boundary!.nextRowId, 10);

      // Mismatched geometry: deferred, never painted (D4) -- the boundary
      // must still move, because the archive scrolled off regardless of
      // whether this screen fit.
      t.emit(
        'terminal:frame',
        _frameExtra(
          terminalId: 'a',
          runId: 'run-1',
          attachmentId: 'att-1',
          sequence: 2,
          ansi: 'HISTORY-SCREEN',
          cols: 100,
          history: _historyBoundary(firstRowId: 0, nextRowId: 20),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(tab.history.boundary!.nextRowId, 20);
      expect(tab.ghostty.plainText, contains('HISTORY-SCREEN'));

      await svc.dispose();
      await session.close();
    });

    test(
      'a respawn resets the tab\'s history model and cancels the outstanding '
      'deadline',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 10),
        );
        final model = svc.currentState.tabs['a']!.history;
        final armed = <_ArmedBound>[];
        _captureBounds(
          armed,
          () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
        );
        expect(armed, hasLength(1));
        expect(model.loading, isTrue);

        t.emit('terminal:exited', {'terminalId': 'a', 'exitCode': 0});
        await Future<void>.delayed(Duration.zero);
        t.emit('terminal:started', {
          'terminalId': 'a',
          'shell': 'pwsh',
          'cols': 80,
          'rows': 24,
        });
        await Future<void>.delayed(Duration.zero);

        // The SAME TerminalHistoryModel instance survives a respawn's
        // copyWith (see TerminalTab.history's doc comment), so this checks
        // the model reset, not a fresh empty one.
        expect(model.rows, isEmpty);
        expect(model.boundary, isNull);
        expect(model.failure, isNull);
        expect(model.loading, isFalse);

        // The ORIGINAL request's bound goes with the archive it belonged to.
        // Nothing downstream can tell a leaked one from a retired one -- the
        // model's own requestId correlation drops the write either way -- so
        // the timer is the only thing that can report the leak.
        expect(armed.single.isActive, isFalse);

        await svc.dispose();
        await session.close();
      },
    );

    test('HISTORY_DISABLED lands on the model\'s failure without marking the '
        'frame attachment failed, and stops the pane asking again', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
      );
      final model = svc.currentState.tabs['a']!.history;
      // A pageable archive, so what closes paging below is the refusal and
      // not an archive that was never pageable.
      expect(model.canLoadMore, isTrue);
      expect(model.refused, isFalse);

      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'HISTORY_DISABLED',
        'message': 'Scrollback archiving is off for this run.',
      });
      await Future<void>.delayed(Duration.zero);

      final tab = svc.currentState.tabs['a']!;
      expect(tab.history.failure, 'Scrollback archiving is off for this run.');
      expect(tab.mode, TerminalDisplayMode.frame);
      expect(
        svc.currentState.hydration['a']!.stage,
        TerminalAttachStage.painted,
      );
      expect(tab.ghostty.plainText, contains('HISTORY-SCREEN'));

      // The refusal is addressed at the RUN, and the reader's every scroll
      // step at the top asks again: a request that goes out here earns the
      // same refusal, and the bound it arms then replaces the sentence
      // explaining the problem with a generic timeout.
      expect(model.refused, isTrue);
      expect(model.canLoadMore, isFalse);
      t.clearSent();
      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isFalse),
      );
      expect(
        t.sent.where((m) => m['type'] == 'terminal:history:request'),
        isEmpty,
      );
      // Nothing armed: the refusal has to outlive every scroll tick that
      // follows it, and the bound a request would arm is what replaces its
      // sentence with a generic timeout.
      expect(armed, isEmpty);
      expect(model.failure, 'Scrollback archiving is off for this run.');

      await svc.dispose();
      await session.close();
    });

    test('HISTORY_DISABLED arriving with a request in flight ends the wait it '
        'interrupts', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
      );

      final model = svc.currentState.tabs['a']!.history;
      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
      );
      expect(model.loading, isTrue);

      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'HISTORY_DISABLED',
        'message': 'Scrollback archiving is off for this run.',
      });
      await Future<void>.delayed(Duration.zero);

      // The refusal answers the request in flight as well as the run: the
      // bound that would otherwise have ended the wait is retired with it,
      // so the refusal is the only thing left that can clear `loading`.
      expect(armed.single.isActive, isFalse);
      expect(model.loading, isFalse);
      expect(model.refused, isTrue);
      expect(model.failure, 'Scrollback archiving is off for this run.');

      await svc.dispose();
      await session.close();
    });

    test('a respawn after a refusal lets the new run page again', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
      );

      final model = svc.currentState.tabs['a']!.history;
      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'runId': 'run-1',
        'attachmentId': 'att-1',
        'code': 'HISTORY_DISABLED',
        'message': 'Scrollback archiving is off for this run.',
      });
      await Future<void>.delayed(Duration.zero);
      expect(model.refused, isTrue);

      // A fresh PTY archives afresh, so the refusal must not outlive the run
      // it was addressed at. The same model instance survives the respawn
      // (see TerminalTab.history), so nothing but `reset` drops it.
      t.emit('terminal:exited', {'terminalId': 'a', 'exitCode': 0});
      await Future<void>.delayed(Duration.zero);
      t.emit('terminal:started', {
        'terminalId': 'a',
        'shell': 'pwsh',
        'cols': 80,
        'rows': 24,
      });
      await Future<void>.delayed(Duration.zero);
      expect(model.refused, isFalse);

      await acceptSubscribe(t, 'a', runId: 'run-2', attachmentId: 'att-2');
      await applyHistoryBoundary(
        t,
        'a',
        runId: 'run-2',
        attachmentId: 'att-2',
        history: _historyBoundary(firstRowId: 0, nextRowId: 30),
      );

      expect(model.canLoadMore, isTrue);
      t.clearSent();
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      final sent = t.sent.lastWhere(
        (m) => m['type'] == 'terminal:history:request',
      );
      expect(sent['runId'], 'run-2');
      expect(sent['beforeRowId'], 30);

      await svc.dispose();
      await session.close();
    });

    test(
      'a late page for a superseded request leaves the live request bounded',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 50),
        );

        final model = svc.currentState.tabs['a']!.history;
        final boundA = <_ArmedBound>[];
        _captureBounds(
          boundA,
          () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
        );
        final abandoned = lastHistoryRequestId(t, 'a');

        // Request A gives up. The pane is free to ask again, and does.
        boundA.single.fire();
        expect(model.loading, isFalse);
        final boundB = <_ArmedBound>[];
        _captureBounds(
          boundB,
          () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
        );
        final live = lastHistoryRequestId(t, 'a');
        expect(live, isNot(abandoned));

        // A's answer finally lands, naming the attachment that is still live.
        // The model refuses it -- and the bound it must NOT take down with it
        // belongs to B, because the map holding bounds is keyed by terminal.
        emitHistoryPage(
          t,
          terminalId: 'a',
          requestId: abandoned,
          history: _historyBoundary(firstRowId: 0, nextRowId: 50),
          beforeRowId: 50,
          rows: [for (var i = 0; i < 3; i++) _historyRow(i)],
        );
        await Future<void>.delayed(Duration.zero);
        expect(model.rows, isEmpty);
        expect(model.loading, isTrue);

        // B's own bound still expires, so the pane recovers instead of
        // loading for good with nothing left that could clear it.
        boundB.single.fire();
        expect(model.loading, isFalse);
        expect(model.failure, isNotNull);
        expect(model.canLoadMore, isTrue);
        expect(svc.requestTerminalHistoryPage('a'), isTrue);

        await svc.dispose();
        await session.close();
      },
    );

    test('an epoch turnover abandons the request in flight without reporting a '
        'failure for it', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(epoch: 1, firstRowId: 0, nextRowId: 50),
      );

      final model = svc.currentState.tabs['a']!.history;
      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
      );
      expect(model.loading, isTrue);

      // An explicit history clear, restated by the next frame: the archive
      // is emptied and counted again from zero, so the answer in flight is
      // addressed by row ids that no longer exist. The client withdraws it.
      await applyHistoryBoundary(
        t,
        'a',
        sequence: 2,
        history: _historyBoundary(epoch: 2, firstRowId: 0, nextRowId: 4),
      );
      expect(model.loading, isFalse);
      expect(model.failure, isNull);

      // The withdrawn request's bound is still armed -- the client gave up
      // in the model, not at the timer -- so what has to hold is that it
      // writes nothing when it expires. Blaming the agent for a request the
      // client itself abandoned puts a scrollback error over what the user
      // experienced as an ordinary history clear.
      armed.single.fire();
      expect(model.failure, isNull);
      expect(model.loading, isFalse);
      expect(model.cursor, 4);
      expect(svc.requestTerminalHistoryPage('a'), isTrue);

      await svc.dispose();
      await session.close();
    });

    test(
      'a page counted in a new epoch restarts paging even when the agent did '
      'not call it expired',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(epoch: 1, firstRowId: 0, nextRowId: 50),
        );

        final model = svc.currentState.tabs['a']!.history;
        expect(svc.requestTerminalHistoryPage('a'), isTrue);
        emitHistoryPage(
          t,
          terminalId: 'a',
          requestId: lastHistoryRequestId(t, 'a'),
          history: _historyBoundary(epoch: 1, firstRowId: 0, nextRowId: 50),
          beforeRowId: 40,
          rows: [for (var i = 40; i < 50; i++) _historyRow(i)],
        );
        await Future<void>.delayed(Duration.zero);
        expect(model.rows, hasLength(10));
        expect(model.cursor, 40);

        // The archive was emptied and counted again from zero while this
        // second request was in flight, and the agent answered without
        // setting `expired`. Row 6 of epoch 2 is not row 6 of epoch 1, so the
        // flag is a courtesy and the epoch is the fact: splicing the two runs
        // together would put the reader's next cursor in neither of them.
        expect(svc.requestTerminalHistoryPage('a'), isTrue);
        emitHistoryPage(
          t,
          terminalId: 'a',
          requestId: lastHistoryRequestId(t, 'a'),
          history: _historyBoundary(epoch: 2, firstRowId: 0, nextRowId: 8),
          beforeRowId: 6,
          rows: [for (var i = 6; i < 8; i++) _historyRow(i)],
        );
        await Future<void>.delayed(Duration.zero);

        expect(model.boundary!.epoch, 2);
        expect(model.rows, isEmpty);
        expect(model.atOldest, isFalse);
        expect(model.cursor, 8);

        await svc.dispose();
        await session.close();
      },
    );

    test('an expired page restarts paging from the boundary it carries and '
        'retires the bound with it', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
      );

      final model = svc.currentState.tabs['a']!.history;
      // The bound itself, not what it would have written: by the time it
      // could fire the model has already forgotten the request it belongs
      // to, so `noteRequestFailed`'s own correlation drops the write and a
      // leaked bound leaves the model in exactly the state a retired one
      // does. Intercepting the zone's timer factory is what makes the
      // retirement observable at all.
      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
      );
      expect(armed, hasLength(1));
      expect(t.sent.last['beforeRowId'], 50);

      // Retention walked past the cursor while the request was in flight.
      emitHistoryPage(
        t,
        terminalId: 'a',
        requestId: lastHistoryRequestId(t, 'a'),
        history: _historyBoundary(firstRowId: 400, nextRowId: 600),
        expired: true,
        beforeRowId: 50,
      );
      await Future<void>.delayed(Duration.zero);

      // Not a failure: the agent answered, and said where to start again.
      expect(model.rows, isEmpty);
      expect(model.loading, isFalse);
      expect(model.failure, isNull);
      expect(model.atOldest, isFalse);
      expect(model.cursor, 600);

      // That answer retired the bound, so no timeout can land over the
      // recovery it just described.
      expect(armed.single.isActive, isFalse);

      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      expect(t.sent.last['beforeRowId'], 600);

      await svc.dispose();
      await session.close();
    });

    test(
      'a request the transport silently drops is bounded, and retryable once '
      'sends leave again',
      () async {
        final t = _UndeliverableTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 50),
        );

        final model = svc.currentState.tabs['a']!.history;
        t.deliver = false;
        // The verb is fire-and-forget, so it cannot report the drop at the
        // call site: what has to hold is that the bound it armed still ends
        // the wait.
        final armed = <_ArmedBound>[];
        _captureBounds(
          armed,
          () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
        );
        expect(
          t.sent.where((m) => m['type'] == 'terminal:history:request'),
          isEmpty,
        );
        expect(model.loading, isTrue);

        armed.single.fire();
        expect(model.loading, isFalse);
        expect(model.failure, isNotNull);
        expect(model.canLoadMore, isTrue);

        t.deliver = true;
        expect(svc.requestTerminalHistoryPage('a'), isTrue);
        final retry = t.sent.lastWhere(
          (m) => m['type'] == 'terminal:history:request',
        );
        expect(retry['beforeRowId'], 50);

        await svc.dispose();
        await session.close();
      },
    );

    test(
      'a send that throws at the call still leaves the request bounded',
      () async {
        final t = _ThrowingTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 50),
        );

        final model = svc.currentState.tabs['a']!.history;
        t.throwOnSend = true;
        // The verb does not swallow this -- the caller asked for a page and
        // the transport refused at the call -- but the model was marked
        // outstanding before the send, so the pane must not be left loading
        // on a bound the throw jumped over.
        final armed = <_ArmedBound>[];
        expect(
          () =>
              _captureBounds(armed, () => svc.requestTerminalHistoryPage('a')),
          throwsStateError,
        );
        expect(model.loading, isTrue);
        // Armed on the way out, despite the throw: without it nothing is left
        // that could end the wait.
        expect(armed, hasLength(1));

        armed.single.fire();
        expect(model.loading, isFalse);
        expect(model.failure, isNotNull);
        expect(model.canLoadMore, isTrue);

        t.throwOnSend = false;
        await svc.dispose();
        await session.close();
      },
    );

    test(
      'requestTerminalHistoryPage is inert from the first instant of dispose',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 50),
        );
        final model = svc.currentState.tabs['a']!.history;
        expect(model.canLoadMore, isTrue);
        t.clearSent();

        // Deliberately NOT awaited. `dispose()` disowns the frame attachments
        // only after several awaits, so this is the window the `_disposed`
        // guard exists for: every other guard in the verb still reads as
        // live, and a request that leaves here arms a bound the teardown has
        // already walked past. Awaiting first would be answered by the
        // attachment guard, and prove nothing about this line.
        final teardown = svc.dispose();
        expect(svc.requestTerminalHistoryPage('a'), isFalse);
        expect(
          t.sent.where((m) => m['type'] == 'terminal:history:request'),
          isEmpty,
        );
        // Refused outright, never marked outstanding against a bound that no
        // longer exists to end it.
        expect(model.loading, isFalse);
        await teardown;

        expect(svc.requestTerminalHistoryPage('a'), isFalse);

        await session.close();
      },
    );

    test(
      'deleting a terminal drops its archive and leaves the model usable',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = TerminalService.fromSession(session);
        svc.setDisplayInterest('frame-test-pane', 'a');

        await seedRunningTab(t, 'a');
        await acceptSubscribe(t, 'a', runId: 'run-1', attachmentId: 'att-1');
        await applyHistoryBoundary(
          t,
          'a',
          history: _historyBoundary(firstRowId: 0, nextRowId: 50),
        );
        final model = svc.currentState.tabs['a']!.history;
        expect(model.hasHistory, isTrue);

        svc.deleteTerminal('a');
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.tabs.containsKey('a'), isFalse);
        expect(model.boundary, isNull);

        // The model is deliberately NOT disposed here, for the reason
        // `TerminalTab.replaceEpoch` is not: `addListener` on a disposed
        // notifier throws where `removeListener` is allowed, so disposing it
        // beside the engine would turn a widget still holding the removed tab
        // from a no-op into a fault -- and buy nothing back, because the model
        // holds no native resource and is garbage with the tab either way.
        void listener() {}
        model.addListener(listener);
        model.removeListener(listener);

        await svc.dispose();
        await session.close();
      },
    );

    test('dispose cancels the outstanding history deadline', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 10),
      );
      final model = svc.currentState.tabs['a']!.history;

      // The Timer itself, not what it would have written: the deadline body
      // returns early on a disposed service, so a leaked timer leaves the
      // model in exactly the state a cancelled one does and nothing
      // downstream can tell the two apart. Intercepting the zone's timer
      // factory around the one call that arms one is what makes a leak
      // visible at all.
      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
      );
      expect(armed, hasLength(1));
      expect(armed.single.isActive, isTrue);

      await svc.dispose();
      expect(armed.single.isActive, isFalse);
      expect(model.loading, isTrue);
      expect(model.failure, isNull);

      await session.close();
    });

    test('the history request arms its bound at the configured '
        'snapshotAttachTimeout, never at a duration of its own', () async {
      // Nothing observes this bound's LENGTH except this assertion: every
      // other case in this group reaches the timeout by firing the captured
      // callback, which runs whatever duration was armed. Deliberately not
      // the 15s default, so a bound hardcoded to the default fails too.
      const configured = Duration(minutes: 7);
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(
        session,
        snapshotAttachTimeout: configured,
      );
      svc.setDisplayInterest('frame-test-pane', 'a');

      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(firstRowId: 0, nextRowId: 50),
      );

      final armed = <_ArmedBound>[];
      _captureBounds(
        armed,
        () => expect(svc.requestTerminalHistoryPage('a'), isTrue),
      );
      expect(armed, hasLength(1));
      expect(armed.single.duration, configured);

      await svc.dispose();
      await session.close();
    });

    test('stopped recording still permits reading committed history', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setDisplayInterest('frame-test-pane', 'a');
      await seedRunningTab(t, 'a');
      await acceptSubscribe(t, 'a');
      await applyHistoryBoundary(
        t,
        'a',
        history: _historyBoundary(
          firstRowId: 0,
          nextRowId: 50,
          status: 'disabled',
        ),
      );
      expect(svc.currentState.tabs['a']!.history.recording, isFalse);
      expect(svc.requestTerminalHistoryPage('a'), isTrue);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:history:request'),
        hasLength(1),
      );
      await svc.dispose();
      await session.close();
    });
  });
}
