// The workspace's account of an isolated session's provisioning run. It is the
// only surface that explains why an agent has not started yet, and — on a
// failure — the only account of why the tree the agent IS working in is
// half-provisioned, so every state it can reach is pinned here.
//
// None of the running-state tests may `pumpAndSettle`: a live run arms a
// periodic tail sampler that never stops on its own, so a settle would hang the
// suite rather than fail it.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/session_setup.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_setup_banner.dart';
import 'package:antgrid/widgets/session_setup_progress.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/toast_host.dart';

const _projectId = 'P';
const _sessionId = 's1';

SessionSetup _setup(
  String state, {
  int stepIndex = 1,
  int stepCount = 4,
  String? stepName = 'Install dependencies',
  String? message,
  bool pendingStart = false,
  int startedAt = 1700,
}) => SessionSetup(
  state: state,
  stepIndex: stepIndex,
  stepCount: stepCount,
  stepName: stepName,
  terminalId: 'worktree-1:setup',
  message: message,
  pendingStart: pendingStart,
  startedAt: startedAt,
);

SessionEntry _entry(
  SessionSetup? setup, {
  bool running = false,
  String mode = 'terminal',
}) => SessionEntry(
  id: _sessionId,
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: running,
  mode: mode,
  checkoutId: 'worktree-1',
  checkoutKind: 'managed-worktree',
  setup: setup,
);

final _sessionList = NotifierProvider<ValueController<SessionsState?>, SessionsState?>(
  () => ValueController<SessionsState?>(null),
);

/// Mounts the banner alone over a seeded session list; [before] is shown first
/// to watch a run settle, and `done` without it finished before the app looked.
Future<void> pumpBanner(
  WidgetTester tester,
  SessionSetup? setup, {
  SessionSetup? before,
  List<Override> extraOverrides = const [],
  bool sessionRunning = false,
  String mode = 'terminal',
}) async {
  SessionsState listWith(SessionSetup? s) => SessionsState(
    projectId: _projectId,
    sessions: [_entry(s, running: sessionRunning, mode: mode)],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeSessionIdProvider.overrideWith(
          () => ValueController<String?>(_sessionId),
        ),
        freshSessionsStateProvider.overrideWith(
          (ref) => ref.watch(_sessionList),
        ),
        ...extraOverrides,
      ],
      child: MaterialApp(
        builder: abToastHostBuilder,
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: const Scaffold(body: SessionSetupBanner()),
      ),
    ),
  );
  // Set, not overridden: re-pumping the same scope keeps the built notifier,
  // so a second call would show the first call's list.
  final list = ProviderScope.containerOf(
    tester.element(find.byType(SessionSetupBanner)),
  ).read(_sessionList.notifier);
  list.set(listWith(before ?? setup));
  await tester.pump();
  if (before == null) return;
  list.set(listWith(setup));
  await tester.pump();
}

/// Disposes the banner so its tail sampler is cancelled before the test ends.
Future<void> unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

/// A Carbon button by its visible label or, for an icon-only one, its
/// accessible name. Carbon tooltips are not Material `Tooltip`s, so
/// `find.byTooltip` cannot see them.
Finder _button(String name) => find.byWidgetPredicate(
  (w) => w is CarbonButton && (w.label ?? w.semanticLabel) == name,
  description: 'CarbonButton "$name"',
);

Finder get _notification => find.byType(CarbonNotification);

/// The kind the notification actually draws: its status glyph.
CarbonStatusKind _drawnKind(WidgetTester tester) => tester
    .widget<CarbonStatusIcon>(
      find.descendant(
        of: _notification,
        matching: find.byType(CarbonStatusIcon),
      ),
    )
    .kind;

CarbonButtonKind _kindOf(WidgetTester tester, String name) =>
    tester.widget<CarbonButton>(_button(name)).kind;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  // The common path: every shared session and every bridge that reports no
  // setup at all must cost a provider read and nothing on screen.
  testWidgets('a session with no setup renders nothing', (tester) async {
    await pumpBanner(tester, null);
    expect(_notification, findsNothing);
    expect(find.byType(CarbonProgressBar), findsNothing);
  });

  // The bridge owns this vocabulary and may widen it. Saying nothing is the
  // only honest answer for a state that could equally mean "still going".
  testWidgets('a state this build cannot name renders nothing', (tester) async {
    await pumpBanner(tester, _setup('restoring'));
    expect(_notification, findsNothing);
    expect(find.byType(CarbonProgressBar), findsNothing);
  });

  group('running', () {
    testWidgets('names the step it is on and how far through it is', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: true));

      expect(
        find.text('Preparing workspace — 2 of 4 · Install dependencies'),
        findsOneWidget,
      );
      // 0-based index: the fraction is the work already BEHIND the current
      // step, which is the only part actually done.
      expect(
        tester.widget<CarbonProgressBar>(find.byType(CarbonProgressBar)).value,
        0.25,
      );
      // A readout, not a notification: nothing has gone wrong yet.
      expect(_notification, findsNothing);
      await unmount(tester);
    });

    // The wait is a strip with a bar, a clock and no notification chrome:
    // nothing about a normal install is an alert.
    testWidgets('is a strip with a small bar and a clock, not a notification', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: true));

      expect(_notification, findsNothing);
      final bar = find.byType(CarbonProgressBar);
      expect(bar, findsOneWidget);
      expect(
        tester.widget<CarbonProgressBar>(bar).size,
        CarbonProgressBarSize.small,
      );
      // Static even when indeterminate: it sits beside live output.
      expect(tester.widget<CarbonProgressBar>(bar).animateIndeterminate, isFalse);
      expect(tester.getSize(bar).height, lessThanOrEqualTo(12));
      // The clock is drawn, inside the strip and right of the headline.
      final elapsed = find.byType(SetupElapsed);
      expect(tester.getSize(elapsed).width, greaterThan(0));
      expect(
        tester.getTopLeft(elapsed).dx,
        greaterThan(
          tester
              .getTopRight(
                find.text('Preparing workspace — 2 of 4 · Install dependencies'),
              )
              .dx -
              1,
        ),
      );
      await unmount(tester);
    });

    // While a start is queued the terminal pane below IS this transcript and
    // carries both verbs itself, so the banner stands down to a headline: a
    // second `Start agent now` 100px away is not an alternative but a race,
    // since only one of them can end the run. The dismiss is refused for the
    // whole run either way — the banner is the only account of why the agent
    // has not started.
    testWidgets('stands down to the pane while a start is queued', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: true));

      expect(find.text('Start agent now'), findsNothing);
      expect(_button('View setup log'), findsNothing);
      expect(_button('Dismiss'), findsNothing);
      await unmount(tester);
    });

    // A chat session renders AgentTranscriptView in the pane's slot and mounts
    // no provisioning pane at all, so standing down there would leave a
    // four-minute install with no output anywhere on screen.
    testWidgets('keeps the log and the release for a chat session', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        _setup('running', pendingStart: true),
        mode: 'chat',
      );

      expect(_button('View setup log'), findsOneWidget);
      expect(find.text('Start agent now'), findsOneWidget);
      // The release is a ghost button in the strip, and the disclosure an
      // icon-only one.
      expect(_kindOf(tester, 'Start agent now'), CarbonButtonKind.ghost);
      expect(_kindOf(tester, 'View setup log'), CarbonButtonKind.ghost);
      await unmount(tester);
    });

    // A project whose setup block is empty still runs, and dividing by its zero
    // step count would render a NaN-wide fill.
    testWidgets('a run with no named steps reads as indeterminate', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        _setup('running', stepIndex: 0, stepCount: 0, stepName: null),
      );

      expect(find.text('Preparing workspace…'), findsOneWidget);
      expect(
        tester.widget<CarbonProgressBar>(find.byType(CarbonProgressBar)).value,
        isNull,
      );
      await unmount(tester);
    });

    // Skip releases the queued start; it does NOT stop the run. The banner has
    // to keep reporting, or a user who skipped is left with an install still
    // holding the tree and nothing on screen saying so.
    testWidgets('a skip already issued leaves the run reporting', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: false));

      expect(
        find.text('Preparing workspace — 2 of 4 · Install dependencies'),
        findsOneWidget,
      );
      expect(find.byType(CarbonProgressBar), findsOneWidget);
      expect(_button('Dismiss'), findsNothing);
      // And the disclosure is back: the agent owns the pane now, so the strip
      // is once more the only way to reach the run still holding the tree.
      expect(_button('View setup log'), findsOneWidget);
      await unmount(tester);
    });

    // `startAgent: immediate`, or a start the user released by hand: the agent
    // is typing into a tree this run has not finished building, so commands it
    // runs can fail for a reason that is not its fault. A neutral "preparing"
    // line would be promising a wait that is already over.
    group('with the agent already live', () {
      testWidgets('warns rather than promising a wait', (tester) async {
        await pumpBanner(
          tester,
          _setup('running'),
          sessionRunning: true,
        );

        expect(
          find.text('Workspace still installing — 2 of 4 · Install dependencies'),
          findsOneWidget,
        );
        // A warning notification: the agent is typing into a tree that is not
        // finished, which is a claim about its work rather than a wait.
        expect(_notification, findsOneWidget);
        expect(_drawnKind(tester), CarbonStatusKind.warning);
        // The run's own measure and clock still follow it.
        expect(find.byType(CarbonProgressBar), findsOneWidget);
        expect(find.byType(SetupElapsed), findsOneWidget);
        await unmount(tester);
      });

      // Releasing an agent that is already up is meaningless; ending the
      // install holding its tree is not.
      testWidgets('offers the cancel instead of the release', (tester) async {
        await pumpBanner(
          tester,
          _setup('running'),
          sessionRunning: true,
        );

        expect(find.text('Start agent now'), findsNothing);
        expect(find.text('Cancel setup'), findsOneWidget);
        // The verb is the notification's own action.
        expect(
          find.descendant(
            of: _notification,
            matching: find.text('Cancel setup'),
          ),
          findsOneWidget,
        );
        // Still not dismissible, and the log still reachable: the strip is the
        // only account of the run now that the pane belongs to the agent.
        expect(_button('Dismiss'), findsNothing);
        expect(_button('View setup log'), findsOneWidget);
        await unmount(tester);
      });

      // The gate outranks it: a session cannot be both queued and running, and
      // reading the two in the wrong order would warn at a user who is waiting.
      testWidgets('a finished run is unaffected by the agent', (tester) async {
        await pumpBanner(
          tester,
          _setup('done', stepIndex: 3),
          before: _setup('running'),
          sessionRunning: true,
        );

        expect(find.text('Workspace ready'), findsOneWidget);
        expect(_drawnKind(tester), CarbonStatusKind.success);
      });
    });
  });

  group('terminal states', () {
    // Met cold, with no run watched: only a success is history, and a failure
    // is still the account of a broken tree whenever the user started looking.
    testWidgets('a failure persists, errors, and offers a rerun', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        _setup('failed', stepIndex: 2, message: 'bun install exited 1'),
      );

      expect(find.text('Setup failed — bun install exited 1'), findsOneWidget);
      expect(_notification, findsOneWidget);
      expect(_drawnKind(tester), CarbonStatusKind.error);
      // The retry is the notification's own action.
      expect(
        find.descendant(
          of: _notification,
          matching: find.text('Run setup again'),
        ),
        findsOneWidget,
      );
      // View log and dismiss both stay: the log is the record of what broke,
      // and a finished run is something the user is allowed to put away.
      expect(_button('View setup log'), findsOneWidget);
      expect(_button('Dismiss'), findsOneWidget);
      // A failure never rides the progress bar — there is no progress left.
      expect(find.byType(CarbonProgressBar), findsNothing);
      expect(find.byType(SetupElapsed), findsNothing);
    });

    // A failure the bridge could not summarise still has to name where it got
    // to, or the log is the only way to find out anything at all.
    testWidgets('a failure with no summary names the step it died on', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('failed', stepIndex: 2));
      expect(
        find.text('Setup failed at 3 of 4 · Install dependencies'),
        findsOneWidget,
      );
    });

    // Every isolated session predating this feature reports `interrupted` on
    // the first launch after it ships. It must read as an offer, not an error.
    testWidgets('an interrupted run offers to run setup', (tester) async {
      await pumpBanner(tester, _setup('interrupted'));

      expect(find.text("Setup didn't finish"), findsOneWidget);
      expect(_drawnKind(tester), CarbonStatusKind.warning);
      expect(find.text('Run setup'), findsOneWidget);
    });

    testWidgets('a skipped run offers to run setup', (tester) async {
      await pumpBanner(tester, _setup('skipped'));

      expect(find.text('Setup skipped'), findsOneWidget);
      expect(_drawnKind(tester), CarbonStatusKind.info);
      expect(find.text('Run setup'), findsOneWidget);
    });

    // The successful run's log stays reachable — it is the record of what the
    // workspace was built from, and the setup PTY is in no terminal list.
    testWidgets('a finished run says so and keeps its log', (tester) async {
      await pumpBanner(
        tester,
        _setup('done', stepIndex: 3),
        before: _setup('running'),
      );

      expect(find.text('Workspace ready'), findsOneWidget);
      expect(_drawnKind(tester), CarbonStatusKind.success);
      expect(_button('View setup log'), findsOneWidget);
      expect(find.byType(CarbonProgressBar), findsNothing);
    });

    // The bridge replays a finished run's `done` to every attaching client;
    // that is history, not a confirmation.
    testWidgets('a run that finished before this app was looking stays quiet', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('done', stepIndex: 3));

      expect(_notification, findsNothing);
    });

    testWidgets('a successful run clears after a short confirmation', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        _setup('done', stepIndex: 3),
        before: _setup('running'),
      );

      expect(find.text('Workspace ready'), findsOneWidget);
      await tester.pump(kSessionSetupSuccessHold);
      await tester.pump();

      expect(_notification, findsNothing);
    });

    testWidgets('an open successful setup log stays until it is collapsed', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        _setup('done', stepIndex: 3),
        before: _setup('running'),
      );
      await tester.tap(_button('View setup log'));
      await tester.pump();
      await tester.pump(kSessionSetupSuccessHold);

      expect(find.text('Workspace ready'), findsOneWidget);
      await tester.tap(_button('Hide setup log'));
      await tester.pump();
      await tester.pump(kSessionSetupSuccessHold);
      await tester.pump();

      expect(_notification, findsNothing);
    });

    // The notification has no slot for a second control, so the disclosure is
    // a ghost button directly beneath it, and the log box sits under that.
    testWidgets('the log toggle sits under the notification and opens the log', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('failed', message: 'boom'));

      final toggle = _button('View setup log');
      expect(_kindOf(tester, 'View setup log'), CarbonButtonKind.ghost);
      expect(find.text('Setup log not available yet'), findsNothing);
      expect(
        tester.getTopLeft(toggle).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(_notification).dy),
      );

      await tester.tap(toggle);
      await tester.pump();

      expect(_button('Hide setup log'), findsOneWidget);
      final empty = find.text('Setup log not available yet');
      expect(empty, findsOneWidget);
      expect(
        tester.getTopLeft(empty).dy,
        greaterThan(tester.getBottomLeft(_button('Hide setup log')).dy),
      );
    });
  });

  group('Carbon surface', () {
    // Under a scope of its own, with no Antgrid widget left in it: the bar the
    // banner sits in is still Antgrid-painted.
    for (final (name, setup, live, mode) in [
      ('a running strip', _setup('running'), false, 'chat'),
      ('a live warning', _setup('running'), true, 'terminal'),
      ('a failure', _setup('failed', message: 'boom'), false, 'terminal'),
    ]) {
      testWidgets('$name builds no Ab widget', (tester) async {
        await pumpBanner(
          tester,
          setup,
          sessionRunning: live,
          mode: mode,
        );
        // The disclosure opens the log frame too.
        await tester.tap(_button('View setup log'));
        await tester.pump();

        expect(find.byType(AbCarbonScope), findsOneWidget);
        expect(abWidgetsInScope(tester), isEmpty);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }

    // The strip is part of a column beside the live terminal: wider text than
    // the real fonts and the narrowest phone must wrap, never overflow. A real
    // elapsed reading ("1m 35s"), not the fixture's epoch start, which prints a
    // clock wider than the phone on its own.
    final realStart = DateTime.now().millisecondsSinceEpoch - 95000;
    for (final (name, setup, live, mode) in [
      (
        'running with a release',
        _setup(
          'running',
          pendingStart: true,
          startedAt: realStart,
          stepName: 'Install every dependency of the monorepo',
        ),
        false,
        'chat',
      ),
      ('live with a cancel', _setup('running', startedAt: realStart), true, 'terminal'),
      (
        'failed with a long reason',
        _setup(
          'failed',
          message: 'bun install exited 1 while resolving a very long chain',
        ),
        false,
        'terminal',
      ),
      ('interrupted', _setup('interrupted'), false, 'terminal'),
    ]) {
      testWidgets('$name does not overflow at 320 wide with 2x text', (
        tester,
      ) async {
        // Tall enough for the wrapped notification plus the open log: width is
        // what is under test, and a vertical overflow would mask it.
        tester.view.physicalSize = const Size(320, 3000);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await pumpBanner(tester, setup, sessionRunning: live, mode: mode);
        await tester.tap(_button('View setup log'));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SessionSetupBanner)).width, 320);
        await unmount(tester);
      });
    }
  });

  // Dismissal is keyed on the RUN, not the session: a rerun is a new answer to
  // the same question, and inheriting the old dismissal would hide it.
  testWidgets('a dismissal is spent by the next run', (tester) async {
    await pumpBanner(tester, _setup('failed', message: 'boom'));
    await tester.tap(_button('Dismiss'));
    await tester.pump();
    expect(_notification, findsNothing);

    await pumpBanner(tester, _setup('failed', message: 'boom'));
    expect(_notification, findsNothing);

    await pumpBanner(tester, _setup('running', startedAt: 9999));
    expect(find.byType(CarbonProgressBar), findsOneWidget);
    await unmount(tester);
  });

  group('actions', () {
    /// A real per-project session over a fake wire, so a tap is asserted where
    /// it actually lands: on the `session:setup` frame.
    Future<FakeAgentTransport> pumpWired(
      WidgetTester tester,
      SessionSetup setup, {
      String mode = 'terminal',
    }) async {
      final transport = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: _projectId,
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
      addTearDown(session.close);

      await pumpBanner(
        tester,
        setup,
        mode: mode,
        extraOverrides: [
          selectedRegistrationIdProvider.overrideWith((ref) => _projectId),
          projectSessionProvider(_projectId)
              .overrideWith((ref) async => session),
        ],
      );
      return transport;
    }

    // Driven in chat mode, which is where the banner still owns the release:
    // a terminal-mode session mounts the provisioning pane, and that pane's
    // copy of this button is the one under test in
    // `terminal_screen_provisioning_test.dart`.
    testWidgets('the release sends session:setup for this session', (tester) async {
      final transport = await pumpWired(
        tester,
        _setup('running', pendingStart: true),
        mode: 'chat',
      );

      await tester.tap(find.text('Start agent now'));
      await tester.pump();
      await tester.pump();

      final sent = transport.sent.firstWhere(
        (m) => m['type'] == 'session:setup',
      );
      expect(sent['sessionId'], _sessionId);
      expect(sent['action'], 'skip');

      // Answer the request so nothing is left waiting on the reply timeout.
      transport.emit('session:result', {
        'requestId': sent['requestId'],
        'ok': true,
        'session': _entry(_setup('running')).toJson(),
      });
      await tester.pump();
      await unmount(tester);
    });

    testWidgets('a rerun asks the bridge to rerun', (tester) async {
      final transport = await pumpWired(tester, _setup('failed'));

      await tester.tap(find.text('Run setup again'));
      await tester.pump();
      await tester.pump();

      final sent = transport.sent.firstWhere(
        (m) => m['type'] == 'session:setup',
      );
      expect(sent['action'], 'rerun');

      transport.emit('session:result', {
        'requestId': sent['requestId'],
        'ok': true,
        'session': _entry(_setup('running')).toJson(),
      });
      await tester.pump();
    });

    // The user pressed something and is owed an answer: nothing else on screen
    // moves when a setup verb is refused, so a refusal that only reached the
    // log would be indistinguishable from a dropped tap.
    testWidgets('a refusal is named rather than swallowed', (tester) async {
      final transport = await pumpWired(tester, _setup('interrupted'));

      await tester.tap(find.text('Run setup'));
      await tester.pump();
      await tester.pump();

      final sent = transport.sent.firstWhere(
        (m) => m['type'] == 'session:setup',
      );
      transport.emit('session:result', {
        'requestId': sent['requestId'],
        'ok': false,
        'error': 'Setup is already running',
      });
      await tester.pump();
      await tester.pump();

      expect(
        find.text("Couldn't start setup — Setup is already running"),
        findsOneWidget,
      );
    });
  });
}
