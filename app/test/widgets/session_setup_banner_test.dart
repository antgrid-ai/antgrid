// The workspace's account of an isolated session's provisioning run. It is the
// only surface that explains why an agent has not started yet, and — on a
// failure — the only account of why the tree the agent IS working in is
// half-provisioned, so every state it can reach is pinned here.
//
// None of the running-state tests may `pumpAndSettle`: the elapsed clock ticks
// every second and never stops on its own, so a settle would hang the
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

/// Disposes the banner so its elapsed ticker is cancelled before the test ends.
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
    const headline = 'Setting up workspace · 2 of 4 · Install dependencies';

    testWidgets('names the step it is on and how far through it is', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: true));

      expect(find.text(headline), findsOneWidget);
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

    // One slim strip: a headline, a clock, a disclosure and a close over a
    // thin bar, with no notification chrome — nothing about a normal install
    // is an alert.
    testWidgets('is a slim strip with a small bar and a clock', (tester) async {
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
      expect(_button('View setup details'), findsOneWidget);
      expect(_button('Hide setup status'), findsOneWidget);
      // The headline is one line, with the clock to its right and the bar
      // beneath the row.
      final text = find.text(headline);
      expect(tester.getSize(text).height, lessThan(40));
      expect(tester.getSize(find.byType(SetupElapsed)).width, greaterThan(0));
      expect(
        tester.getTopLeft(find.byType(SetupElapsed)).dx,
        greaterThan(tester.getTopRight(text).dx - 1),
      );
      expect(
        tester.getTopLeft(bar).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(text).dy),
      );
      // Collapsed by default: neither the steps, the log nor the cancel.
      expect(find.byType(SetupStepLedger), findsNothing);
      expect(find.byKey(const ValueKey('setup-log')), findsNothing);
      expect(find.text('Cancel setup'), findsNothing);
      await unmount(tester);
    });

    // While a start is queued in terminal mode the pane below carries the one
    // release itself: a second `Start now` here would be a race, since only
    // one of them can end the wait.
    testWidgets('leaves the release to the pane in terminal mode', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: true));

      expect(find.text('Start now'), findsNothing);
      await unmount(tester);
    });

    // A chat session mounts no pane, so the strip carries a small release.
    testWidgets('carries a ghost release for a queued chat session', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        _setup('running', pendingStart: true),
        mode: 'chat',
      );

      expect(_button('Start now'), findsOneWidget);
      expect(_kindOf(tester, 'Start now'), CarbonButtonKind.ghost);
      expect(
        tester.widget<CarbonButton>(_button('Start now')).size,
        CarbonButtonSize.small,
      );
      await unmount(tester);
    });

    // Closing the strip would strand a queued chat session: nothing else on
    // screen says the agent is waiting or can release it.
    testWidgets('offers no close on a queued chat strip', (tester) async {
      await pumpBanner(
        tester,
        _setup('running', pendingStart: true),
        mode: 'chat',
      );

      expect(_button('Start now'), findsOneWidget);
      expect(_button('Hide setup status'), findsNothing);
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

      expect(find.text('Setting up workspace…'), findsOneWidget);
      expect(
        tester.widget<CarbonProgressBar>(find.byType(CarbonProgressBar)).value,
        isNull,
      );
      await unmount(tester);
    });

    // Skip releases the queued start; it does NOT stop the run. The strip has
    // to keep reporting, or a user who skipped is left with an install still
    // holding the tree and nothing on screen saying so.
    testWidgets('a skip already issued leaves the run reporting', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: false));

      expect(find.text(headline), findsOneWidget);
      expect(find.byType(CarbonProgressBar), findsOneWidget);
      expect(_button('View setup details'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the chevron opens the steps, the log and the cancel', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('running', pendingStart: true));

      await tester.tap(_button('View setup details'));
      await tester.pump();

      expect(_button('Hide setup details'), findsOneWidget);
      expect(find.byType(SetupStepLedger), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-log')), findsOneWidget);
      expect(find.text('Cancel setup'), findsOneWidget);
      expect(_kindOf(tester, 'Cancel setup'), CarbonButtonKind.dangerGhost);

      await tester.tap(_button('Hide setup details'));
      await tester.pump();
      expect(find.byType(SetupStepLedger), findsNothing);
      await unmount(tester);
    });

    // The strip is background work beside a live agent, so the user can put it
    // away; what it must never do is take the failure with it.
    group('closing the strip', () {
      testWidgets('hides it for the rest of the run', (tester) async {
        await pumpBanner(tester, _setup('running'));
        expect(find.byType(CarbonProgressBar), findsOneWidget);

        await tester.tap(_button('Hide setup status'));
        await tester.pump();

        expect(find.byType(CarbonProgressBar), findsNothing);
        expect(find.byType(SetupElapsed), findsNothing);
        await unmount(tester);
      });

      testWidgets('still lets a failure through', (tester) async {
        await pumpBanner(tester, _setup('running'));
        await tester.tap(_button('Hide setup status'));
        await tester.pump();

        await pumpBanner(
          tester,
          _setup('failed', message: 'bun install exited 1'),
        );

        expect(_notification, findsOneWidget);
        expect(_drawnKind(tester), CarbonStatusKind.error);
        expect(find.text('Setup failed — bun install exited 1'), findsOneWidget);
      });

      testWidgets('still lets an interrupted run through', (tester) async {
        await pumpBanner(tester, _setup('running'));
        await tester.tap(_button('Hide setup status'));
        await tester.pump();

        await pumpBanner(tester, _setup('interrupted'));

        expect(_notification, findsOneWidget);
        expect(_drawnKind(tester), CarbonStatusKind.warning);
      });

      testWidgets('a run closed while going announces no success', (
        tester,
      ) async {
        await pumpBanner(tester, _setup('running'));
        await tester.tap(_button('Hide setup status'));
        await tester.pump();

        await pumpBanner(tester, _setup('done', stepIndex: 3));

        expect(_notification, findsNothing);
      });

      testWidgets('takes an open panel with it', (tester) async {
        await pumpBanner(tester, _setup('running'));
        await tester.tap(_button('View setup details'));
        await tester.pump();
        await tester.tap(_button('Hide setup status'));
        await tester.pump();

        await pumpBanner(tester, _setup('failed', message: 'boom'));

        expect(_notification, findsOneWidget);
        // The failure is not born with a log unfolded under it.
        expect(find.byKey(const ValueKey('setup-log')), findsNothing);
      });
    });

    // `startAgent: immediate`, or a start the user released by hand: the agent
    // is typing into a tree this run has not finished building. That is
    // background work the user may care about, not an alert.
    group('with the agent already live', () {
      testWidgets('shows the same neutral strip, no warning', (tester) async {
        await pumpBanner(tester, _setup('running'), sessionRunning: true);

        expect(find.text(headline), findsOneWidget);
        expect(_notification, findsNothing);
        expect(find.byType(CarbonStatusIcon), findsNothing);
        expect(find.textContaining('still installing'), findsNothing);
        // The run's own measure and clock still follow it.
        expect(find.byType(CarbonProgressBar), findsOneWidget);
        expect(find.byType(SetupElapsed), findsOneWidget);
        await unmount(tester);
      });

      // Releasing an agent that is already up is meaningless; ending the
      // install holding its tree is not, and it sits in the panel.
      testWidgets('offers the cancel in the panel, never the release', (
        tester,
      ) async {
        await pumpBanner(tester, _setup('running'), sessionRunning: true);

        expect(find.text('Start now'), findsNothing);
        expect(find.text('Cancel setup'), findsNothing);

        await tester.tap(_button('View setup details'));
        await tester.pump();

        expect(find.text('Cancel setup'), findsOneWidget);
        expect(find.text('Start now'), findsNothing);
        await unmount(tester);
      });

      // A finished run reads as success whether or not the agent is live.
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
    for (final (name, setup, live, mode, toggle) in [
      ('a running strip', _setup('running'), false, 'chat', 'View setup details'),
      ('a live run', _setup('running'), true, 'terminal', 'View setup details'),
      (
        'a failure',
        _setup('failed', message: 'boom'),
        false,
        'terminal',
        'View setup log',
      ),
    ]) {
      testWidgets('$name builds no Ab widget', (tester) async {
        await pumpBanner(tester, setup, sessionRunning: live, mode: mode);
        // The disclosure opens the panel or log frame too.
        await tester.tap(_button(toggle));
        await tester.pump();

        expect(find.byType(AbCarbonScope), findsWidgets);
        for (var i = 0; i < find.byType(AbCarbonScope).evaluate().length; i++) {
          expect(
            abWidgetsInScope(tester, scope: find.byType(AbCarbonScope).at(i)),
            isEmpty,
          );
        }
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }

    // The strip floats over a live terminal: wider text than the real fonts and
    // the narrowest phone must truncate or wrap, never overflow, whether it is
    // collapsed or open. A real elapsed reading ("1m 35s"), not the fixture's
    // epoch start, which prints a clock wider than the phone on its own.
    final realStart = DateTime.now().millisecondsSinceEpoch - 95000;
    for (final (name, setup, live, mode, toggle) in [
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
        'View setup details',
      ),
      (
        'running over a live agent',
        _setup('running', startedAt: realStart),
        true,
        'terminal',
        'View setup details',
      ),
      (
        'failed with a long reason',
        _setup(
          'failed',
          message: 'bun install exited 1 while resolving a very long chain',
        ),
        false,
        'terminal',
        'View setup log',
      ),
      ('interrupted', _setup('interrupted'), false, 'terminal', 'View setup log'),
    ]) {
      testWidgets('$name does not overflow at 320x640 with 2x text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await pumpBanner(tester, setup, sessionRunning: live, mode: mode);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SessionSetupBanner)).width, 320);

        await tester.tap(_button(toggle));
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

      await tester.tap(find.text('Start now'));
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

    testWidgets('the panel cancel sends session:setup cancel once', (
      tester,
    ) async {
      final transport = await pumpWired(
        tester,
        _setup('running'),
        mode: 'chat',
      );
      await tester.tap(_button('View setup details'));
      await tester.pump();

      await tester.tap(find.text('Cancel setup'));
      await tester.pump();
      // Busy, not disabled, and a second press must not put a second verb on
      // the wire.
      await tester.tap(find.text('Cancel setup'));
      await tester.pump();
      await tester.pump();

      final sent = transport.sent
          .where((m) => m['type'] == 'session:setup')
          .toList();
      expect(sent, hasLength(1));
      expect(sent.single['action'], 'cancel');
      expect(sent.single['sessionId'], _sessionId);
      expect(tester.widget<CarbonButton>(_button('Cancel setup')).busy, isTrue);

      transport.emit('session:result', {
        'requestId': sent.single['requestId'],
        'ok': false,
        'error': 'Setup already ended',
      });
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('Setup already ended'),
        findsOneWidget,
      );
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
