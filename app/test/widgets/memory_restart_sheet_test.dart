import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_adaptive_sheet.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/widgets/memory/memory_restart_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/toast_host.dart';

MemorySessionWithoutMemory _row(
  String id, {
  String project = 'p1',
  AgentWorkStatusArg status = AgentWorkStatusArg.done,
  bool resumable = true,
}) => MemorySessionWithoutMemory.fromJson({
  'project_id': project,
  'project_label': 'Label $project',
  'session_id': id,
  'name': 'Session $id',
  if (status.wire != null) 'work_status': status.wire,
  'agent_session_resumable': resumable,
})!;

// A local alias keeps the table below readable; null is "no status reported".
enum AgentWorkStatusArg {
  done('done'),
  unread('unread'),
  working('working'),
  attention('attention'),
  error('error'),
  none(null);

  const AgentWorkStatusArg(this.wire);
  final String? wire;
}

const _ok = {'ok': true, 'restarted': true};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  late Map<String, FakeAgentTransport> transports;
  late Set<String> unreachable;

  Future<void> open(
    WidgetTester tester,
    List<MemorySessionWithoutMemory> rows, {
    MemoryTarget target = const MemoryTarget.machine(),
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    transports = {};
    unreachable = {};
    final cache = await CachedSessionsStore.open();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectSessionProvider.overrideWith((ref, id) async {
            if (unreachable.contains(id)) throw StateError('no route to $id');
            final transport = transports.putIfAbsent(
              id,
              () => FakeAgentTransport(),
            );
            return ProjectSession(
              projectId: id,
              transport: transport,
              mode: ProjectSessionMode.local,
              cachedSessionsStore: cache,
              onClose: () async => await transport.dispose(),
            );
          }),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          builder: abToastHostBuilder,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAbAdaptiveSheet<void>(
                  context,
                  maxWidth: 560,
                  child: MemoryRestartSheet(target: target, sessions: rows),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // Not pumpAndSettle: a working or attention dot pulses forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Answers each `session:restart` frame once, by session id, until [rounds]
  /// pumps have passed.
  Future<void> answer(
    WidgetTester tester,
    Map<String, Map<String, dynamic>> replies, {
    int rounds = 6,
  }) async {
    final answered = <String>{};
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      for (final t in transports.values) {
        for (final m in t.sent.where((m) => m['type'] == 'session:restart')) {
          final requestId = m['requestId'] as String;
          final reply = replies[m['sessionId']];
          if (reply != null && answered.add(requestId)) {
            t.emit('session:result', {'requestId': requestId, ...reply});
          }
        }
      }
    }
  }

  Finder tickOf(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byWidgetPredicate(
      (w) => w is AbIcon && w.icon == AbIcons.circleCheck,
    ),
  );

  Iterable<Map<String, dynamic>> restartFrames() => [
    for (final t in transports.values)
      ...t.sent.where((m) => m['type'] == 'session:restart'),
  ];

  testWidgets('ticks idle and finished sessions, never busy or unknown ones', (
    tester,
  ) async {
    await open(tester, [
      _row('done', status: AgentWorkStatusArg.done),
      _row('unread', status: AgentWorkStatusArg.unread),
      _row('working', status: AgentWorkStatusArg.working),
      _row('attention', status: AgentWorkStatusArg.attention),
      _row('error', status: AgentWorkStatusArg.error),
      _row('none', status: AgentWorkStatusArg.none),
    ]);
    expect(tickOf('p1/done'), findsOneWidget);
    expect(tickOf('p1/unread'), findsOneWidget);
    for (final id in ['working', 'attention', 'error', 'none']) {
      expect(tickOf('p1/$id'), findsNothing, reason: id);
    }
    expect(find.text('Restart 2 sessions'), findsOneWidget);
    expect(
      find.text(
        "These sessions were already running when Memory was turned on, so they can't use it. Restarting resumes each conversation with Memory.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('subtitles carry the project and a plain status label', (
    tester,
  ) async {
    await open(tester, [
      _row('a', status: AgentWorkStatusArg.done),
      _row('b', status: AgentWorkStatusArg.unread),
      _row('c', status: AgentWorkStatusArg.working),
      _row('d', status: AgentWorkStatusArg.attention),
      _row('e', status: AgentWorkStatusArg.error),
      _row('f', status: AgentWorkStatusArg.none),
    ]);
    for (final label in [
      'Idle',
      'Finished',
      'Working',
      'Needs you',
      'Error',
      'Running',
    ]) {
      expect(find.text('Label p1 · $label'), findsOneWidget, reason: label);
    }
  });

  testWidgets('ticking a busy row adds the interrupt warning and a count', (
    tester,
  ) async {
    await open(tester, [
      _row('idle'),
      _row('busy', status: AgentWorkStatusArg.working),
    ]);
    const warning = "Restarting interrupts what it's doing now.";
    expect(find.text(warning), findsNothing);
    expect(find.text('Restart 1 session'), findsOneWidget);
    await tester.tap(find.text('Session busy'));
    await tester.pump();
    expect(find.text(warning), findsOneWidget);
    expect(find.text('Restart 2 sessions'), findsOneWidget);
    await tester.tap(find.text('Session busy'));
    await tester.pump();
    expect(find.text(warning), findsNothing);
  });

  testWidgets('a session without a resumable conversation says so', (
    tester,
  ) async {
    await open(tester, [_row('a', resumable: false), _row('b')]);
    expect(find.text('Starts a new conversation'), findsOneWidget);
  });

  testWidgets('the primary button is disabled at zero ticks', (tester) async {
    await open(tester, [_row('a')]);
    await tester.tap(find.text('Session a'));
    await tester.pump();
    final button = tester.widget<AbButton>(
      find.widgetWithText(AbButton, 'Restart 0 sessions'),
    );
    expect(button.onTap, isNull);
  });

  testWidgets('a local row goes to the bare project id', (tester) async {
    await open(tester, [_row('a')]);
    await tester.tap(find.text('Restart 1 session'));
    await answer(tester, {'a': _ok});
    expect(transports.keys, ['p1']);
    final frame = restartFrames().single;
    expect(frame['sessionId'], 'a');
    expect(frame['reason'], 'memory');
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a remote row goes to machine.project', (tester) async {
    await open(
      tester,
      [_row('a', project: 'p2')],
      target: const MemoryTarget.machine(machineId: 'm-1'),
    );
    await tester.tap(find.text('Restart 1 session'));
    await answer(tester, {'a': _ok});
    expect(transports.keys, ['m-1.p2']);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('disables the button and shows progress while restarting', (
    tester,
  ) async {
    await open(tester, [_row('a')]);
    await tester.tap(find.text('Restart 1 session'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Restarting…'), findsOneWidget);
    await answer(tester, {'a': _ok});
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('each outcome renders its own copy and failures stay open', (
    tester,
  ) async {
    await open(tester, [
      _row('restarted'),
      _row('already'),
      _row('off'),
      _row('scheduled'),
      _row('teardown'),
      _row('failed'),
      _row('other'),
    ]);
    await tester.tap(find.text('Restart 7 sessions'));
    await answer(tester, {
      'restarted': _ok,
      'already': {'ok': true, 'restarted': false},
      'off': {'ok': false, 'errorCode': 'MEMORY_OFF', 'error': 'x'},
      'scheduled': {'ok': false, 'errorCode': 'SCHEDULED_RUN', 'error': 'x'},
      'teardown': {
        'ok': false,
        'error': 'Error: timed out tearing down session: teardown',
      },
      'failed': {
        'ok': false,
        'error': 'Error: failed to restart session: failed: boom',
      },
      'other': {'ok': false, 'error': 'session not found: other'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Restarted.'), findsOneWidget);
    expect(
      find.text('Already up to date. Nothing was restarted.'),
      findsOneWidget,
    );
    expect(
      find.text('Memory was turned off. Nothing was restarted.'),
      findsOneWidget,
    );
    expect(
      find.text('A scheduled run is in progress. Its next run will use Memory.'),
      findsOneWidget,
    );
    expect(
      find.text("Didn't shut down in time. It's stopped; start it again."),
      findsOneWidget,
    );
    expect(
      find.text(
        "Shut down but didn't start again. It's stopped; start it again.",
      ),
      findsOneWidget,
    );
    expect(
      find.text("Couldn't restart. Nothing was changed."),
      findsOneWidget,
    );
    // Successes and stopped sessions are unticked and locked; the rest stay
    // ticked for a retry.
    expect(find.text('Restart 3 sessions'), findsOneWidget);
    expect(tickOf('p1/restarted'), findsNothing);
    expect(tickOf('p1/teardown'), findsNothing);
    expect(tickOf('p1/failed'), findsNothing);
    expect(tickOf('p1/off'), findsOneWidget);
  });

  testWidgets('an unreachable project fails every row in its group', (
    tester,
  ) async {
    await open(tester, [_row('a'), _row('b')]);
    unreachable.add('p1');
    await tester.tap(find.text('Restart 2 sessions'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't reach this project."), findsNWidgets(2));
    expect(find.text('Restart 2 sessions'), findsOneWidget);
  });

  testWidgets('no reply in time reads as no answer, not as a refusal', (
    tester,
  ) async {
    await open(tester, [_row('a')]);
    await tester.tap(find.text('Restart 1 session'));
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(
      find.text('No answer from the machine. Check the session before retrying.'),
      findsOneWidget,
    );
  });

  testWidgets('every row ok pops the sheet and toasts a summary', (
    tester,
  ) async {
    await open(tester, [_row('a'), _row('b')]);
    await tester.tap(find.text('Restart 2 sessions'));
    await answer(tester, {
      'a': _ok,
      'b': {'ok': true, 'restarted': false},
    });
    await tester.pumpAndSettle();
    expect(find.text('Restart to use Memory'), findsNothing);
    expect(find.text('Restarted 1 session. 1 already had Memory.'), findsOne);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a plural summary has no no-op suffix when none were no-ops', (
    tester,
  ) async {
    await open(tester, [_row('a'), _row('b')]);
    await tester.tap(find.text('Restart 2 sessions'));
    await answer(tester, {'a': _ok, 'b': _ok});
    await tester.pumpAndSettle();
    expect(find.text('Restarted 2 sessions.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('closing mid-restart throws nothing when the answer lands', (
    tester,
  ) async {
    await open(tester, [_row('a')]);
    await tester.tap(find.text('Restart 1 session'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Restart to use Memory'), findsNothing);
    await answer(tester, {'a': _ok});
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing mid-run never restarts the remaining projects', (
    tester,
  ) async {
    await open(tester, [_row('a'), _row('b', project: 'p2')]);
    await tester.tap(find.text('Restart 2 sessions'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await answer(tester, {'a': _ok, 'b': _ok});
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(transports.keys, ['p1']);
    expect(restartFrames().map((m) => m['sessionId']), ['a']);
  });

  testWidgets('a stopped session is locked and its instruction survives', (
    tester,
  ) async {
    await open(tester, [_row('a'), _row('b')]);
    await tester.tap(find.text('Restart 2 sessions'));
    await answer(tester, {
      'a': {'ok': false, 'error': 'Error: failed to restart session: a: boom'},
      'b': {'ok': false, 'errorCode': 'MEMORY_OFF', 'error': 'x'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Restart 1 session'), findsOneWidget);
    await tester.tap(find.text('Session a'));
    await tester.pump();
    expect(tickOf('p1/a'), findsNothing);
    await tester.tap(find.text('Restart 1 session'));
    await answer(tester, {
      'b': {'ok': true, 'restarted': true},
    });
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Shut down but didn't start again. It's stopped; start it again.",
      ),
      findsOneWidget,
    );
    expect(find.text('Restart to use Memory'), findsOneWidget);
  });

  testWidgets('a retried row drops its old failure while in flight', (
    tester,
  ) async {
    await open(tester, [_row('a')]);
    await tester.tap(find.text('Restart 1 session'));
    await answer(tester, {
      'a': {'ok': false, 'error': 'session not found: a'},
    });
    await tester.pumpAndSettle();
    expect(find.text("Couldn't restart. Nothing was changed."), findsOneWidget);
    await tester.tap(find.text('Restart 1 session'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text("Couldn't restart. Nothing was changed."), findsNothing);
    expect(find.byType(AbLoading), findsOneWidget);
    await answer(tester, {
      'a': {'ok': true, 'restarted': true},
    });
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
