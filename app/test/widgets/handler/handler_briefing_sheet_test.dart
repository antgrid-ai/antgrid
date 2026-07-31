import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/handler_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/handler/handler_briefing_sheet.dart';

import '../../helpers/prefs_test_mock.dart';

/// Builds a real (local) [ProjectSession] + [HandlerService] over a
/// [FakeAgentTransport], with teardown registered via [addTearDown] —
/// disposing inline (a bare trailing `await`) deadlocks under the widget
/// tester's fake clock (see terminal_letterbox_test.dart's `_makeService`
/// for the same pattern).
Future<(FakeAgentTransport, HandlerService)> _newService() async {
  final t = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: 'p',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await t.dispose(),
  );
  final svc = HandlerService.fromSession(session);
  addTearDown(() async {
    await svc.dispose();
    await session.close();
  });
  return (t, svc);
}

Map<String, dynamic> _briefJson({String taskSummary = 'summary'}) => {
  'taskSummary': taskSummary,
  'willHandle': ['fix lint'],
  'wakeFor': ['destructive ops'],
  'thenItems': ['run tests'],
};

Map<String, dynamic> _sessionJson({
  required String terminalId,
  String? judgeTool,
  String? judgeModel,
}) => {
  'terminalId': terminalId,
  'notifyOnly': false,
  'state': 'watching',
  'pendingEscalations': 0,
  'armedAt': 0,
  'doneWhenMet': false,
  'brief': _briefJson(),
  'ledger': [],
  'escalations': [],
  'judgeTool': ?judgeTool,
  'judgeModel': ?judgeModel,
};

/// Pumps a host app with a single button that, when tapped, opens the
/// briefing sheet for [terminalId] and hands the result to [onResult].
Future<void> _pumpHostApp(
  WidgetTester tester, {
  required HandlerService service,
  required String terminalId,
  required ValueSetter<HandlerArmChoice?> onResult,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async => onResult(
                await showHandlerBriefingSheet(
                  context,
                  terminalId: terminalId,
                  service: service,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

// A single pump, not pumpAndSettle: the loading phase's [AbLoading] cursor
// animates indefinitely (`repeat(reverse: true)`), so pumpAndSettle never
// observes a settled frame and hangs. One pump is enough to render whichever
// phase the sheet opens into; callers that need the dialog's entrance
// transition to finish too can follow up with their own pumpAndSettle once
// they're past a phase with an unbounded animation.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  testWidgets('seeds the judge picker from lastKnownJudge', (tester) async {
    final (t, svc) = await _newService();

    await _pumpHostApp(
      tester,
      service: svc,
      terminalId: 't1',
      onResult: (_) {},
    );

    // Armed session with a stored judge — lastKnownBrief is also non-null, so
    // the sheet starts directly in the editing phase (no plan call).
    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(terminalId: 't1', judgeTool: 'codex', judgeModel: 'm1'),
      ],
    });
    await tester.pump();

    await _openSheet(tester);

    expect(find.text('codex'), findsOneWidget);
    expect(find.text('m1'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'planResult echo populates the picker when the user has not touched it',
    (tester) async {
      final (t, svc) = await _newService();
      addTearDown(svc.session.heavyStream.listen((_) {}).cancel);

      // t2 has no cached brief/judge — the sheet must go through the loading
      // phase and fire the initial (judge-omitting) plan request.
      await _pumpHostApp(
        tester,
        service: svc,
        terminalId: 't2',
        onResult: (_) {},
      );
      await _openSheet(tester);
      expect(find.text('Reading session…'), findsOneWidget);

      final planRequest = t.sent.lastWhere(
        (m) => m['type'] == 'handler:planRequest',
      );
      expect(planRequest.containsKey('judgeTool'), isFalse);
      expect(planRequest.containsKey('judgeModel'), isFalse);

      t.emit('handler:planResult', {
        'projectId': 'p',
        'terminalId': 't2',
        'fallback': false,
        'brief': _briefJson(),
        'judgeTool': 'opencode',
        'judgeModel': 'sm',
      });
      await tester.pumpAndSettle();

      expect(find.text('opencode'), findsOneWidget);
      expect(find.text('sm'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('planResult echo does not override a user-changed picker', (
    tester,
  ) async {
    final (t, svc) = await _newService();
    addTearDown(svc.session.heavyStream.listen((_) {}).cancel);

    await _pumpHostApp(
      tester,
      service: svc,
      terminalId: 't3',
      onResult: (_) {},
    );
    await _openSheet(tester);

    t.emit('handler:planResult', {
      'projectId': 'p',
      'terminalId': 't3',
      'fallback': false,
      'brief': _briefJson(),
      'judgeTool': 'claude-code',
    });
    await tester.pumpAndSettle();
    expect(find.text('claude-code'), findsOneWidget);

    // User picks a different judge tool from the menu. The judge section sits
    // near the bottom of the sheet's SingleChildScrollView, below the fold at
    // the test viewport's default size — scroll it into view before tapping.
    await tester.ensureVisible(find.text('claude-code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('claude-code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('opencode').last);
    await tester.pumpAndSettle();
    expect(find.text('opencode'), findsOneWidget);

    // Regenerate re-enters loading and fires a second plan call; its echo
    // must not clobber the user's pick once the result lands.
    await tester.tap(find.byTooltip('Regenerate from the live session'));
    await tester.pump();
    t.emit('handler:planResult', {
      'projectId': 'p',
      'terminalId': 't3',
      'fallback': false,
      'brief': _briefJson(),
      'judgeTool': 'codex',
    });
    await tester.pumpAndSettle();

    expect(find.text('opencode'), findsOneWidget);
    expect(find.text('codex'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Arm omits the judge when the picker was never touched', (
    tester,
  ) async {
    final (t, svc) = await _newService();

    HandlerArmChoice? result;
    await _pumpHostApp(
      tester,
      service: svc,
      terminalId: 't4',
      onResult: (r) => result = r,
    );

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(terminalId: 't4', judgeTool: 'codex', judgeModel: 'm1'),
      ],
    });
    await tester.pump();

    await _openSheet(tester);

    await tester.tap(find.text('Arm'));
    await tester.pumpAndSettle();

    // Null, not the seeded values: untouched → keys omitted on the wire →
    // the bridge keeps its stored record (which the seed came from anyway).
    expect(result, isNotNull);
    expect(result!.judgeTool, isNull);
    expect(result!.judgeModel, isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Arm sends explicit values once the picker was touched', (
    tester,
  ) async {
    final (t, svc) = await _newService();

    HandlerArmChoice? result;
    await _pumpHostApp(
      tester,
      service: svc,
      terminalId: 't5',
      onResult: (r) => result = r,
    );

    t.emit('handler:status', {
      'projectId': 'p',
      'sessions': [
        _sessionJson(terminalId: 't5', judgeTool: 'codex', judgeModel: 'm1'),
      ],
    });
    await tester.pump();

    await _openSheet(tester);

    await tester.ensureVisible(find.text('codex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('codex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('opencode').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Arm'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.judgeTool, 'opencode');
    // The tool change clears the tool-specific model — explicit '' clears the
    // stored model too.
    expect(result!.judgeModel, '');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Arm after a plan timeout leaves the stored judge intact', (
    tester,
  ) async {
    final (t, svc) = await _newService();

    HandlerArmChoice? result;
    // t6 has no cached brief/judge — the sheet goes through the loading phase.
    await _pumpHostApp(
      tester,
      service: svc,
      terminalId: 't6',
      onResult: (r) => result = r,
    );
    await _openSheet(tester);
    expect(find.text('Reading session…'), findsOneWidget);

    // No planResult ever arrives; the sheet's backstop fires and lands on the
    // skeletal editor with a blank Default picker. Must stay past _kPlanTimeout,
    // which tracks the bridge's PLAN_TIMEOUT_MS.
    await tester.pump(const Duration(seconds: 51));
    expect(
      find.text("Couldn't read the session — write your own brief."),
      findsOneWidget,
    );

    await tester.tap(find.text('Arm'));
    await tester.pumpAndSettle();

    // The blank picker is a failure artifact, not a choice: arming must omit
    // the judge keys so a pick stored on disk isn't silently cleared.
    expect(result, isNotNull);
    expect(result!.judgeTool, isNull);
    expect(result!.judgeModel, isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
