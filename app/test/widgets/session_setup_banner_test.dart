// The workspace's account of an isolated session's provisioning run. It is the
// only surface that explains why an agent has not started yet, and — on a
// failure — the only account of why the tree the agent IS working in is
// half-provisioned, so every state it can reach is pinned here.
//
// None of the running-state tests may `pumpAndSettle`: a live run arms a
// periodic tail sampler that never stops on its own, so a settle would hang the
// suite rather than fail it.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_inline_banner.dart';
import 'package:antgrid/design/widgets/ab_progress_rule.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/session_setup.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_setup_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

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

/// Mounts the banner alone over a hand-seeded session list. The banner is a
/// pure projection of that list, so nothing here needs a live stream.
Future<void> pumpBanner(
  WidgetTester tester,
  SessionSetup? setup, {
  List<Override> extraOverrides = const [],
  bool sessionRunning = false,
  String mode = 'terminal',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeSessionIdProvider.overrideWith(
          () => ValueController<String?>(_sessionId),
        ),
        freshSessionsStateProvider.overrideWithValue(
          SessionsState(
            projectId: _projectId,
            sessions: [_entry(setup, running: sessionRunning, mode: mode)],
          ),
        ),
        ...extraOverrides,
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: const Scaffold(body: SessionSetupBanner()),
      ),
    ),
  );
  await tester.pump();
}

/// Disposes the banner so its tail sampler is cancelled before the test ends.
Future<void> unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

AbInlineBanner _banner(WidgetTester tester) =>
    tester.widget<AbInlineBanner>(find.byType(AbInlineBanner));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  // The common path: every shared session and every bridge that reports no
  // setup at all must cost a provider read and nothing on screen.
  testWidgets('a session with no setup renders nothing', (tester) async {
    await pumpBanner(tester, null);
    expect(find.byType(AbInlineBanner), findsNothing);
    expect(find.byType(AbProgressRule), findsNothing);
  });

  // The bridge owns this vocabulary and may widen it. Saying nothing is the
  // only honest answer for a state that could equally mean "still going".
  testWidgets('a state this build cannot name renders nothing', (tester) async {
    await pumpBanner(tester, _setup('restoring'));
    expect(find.byType(AbInlineBanner), findsNothing);
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
        tester.widget<AbProgressRule>(find.byType(AbProgressRule)).fraction,
        0.25,
      );
      expect(_banner(tester).color, kDefaultPalette.textSecondary);
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
      expect(find.byTooltip('View setup log'), findsNothing);
      expect(find.byTooltip('Dismiss'), findsNothing);
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

      expect(find.byTooltip('View setup log'), findsOneWidget);
      expect(find.text('Start agent now'), findsOneWidget);
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
        tester.widget<AbProgressRule>(find.byType(AbProgressRule)).fraction,
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
      expect(find.byType(AbProgressRule), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsNothing);
      // And the disclosure is back: the agent owns the pane now, so the strip
      // is once more the only way to reach the run still holding the tree.
      expect(find.byTooltip('View setup log'), findsOneWidget);
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
        expect(_banner(tester).color, kDefaultPalette.warning);
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
        // Still not dismissible, and the log still reachable: the strip is the
        // only account of the run now that the pane belongs to the agent.
        expect(find.byTooltip('Dismiss'), findsNothing);
        expect(find.byTooltip('View setup log'), findsOneWidget);
        await unmount(tester);
      });

      // The gate outranks it: a session cannot be both queued and running, and
      // reading the two in the wrong order would warn at a user who is waiting.
      testWidgets('a finished run is unaffected by the agent', (tester) async {
        await pumpBanner(
          tester,
          _setup('done', stepIndex: 3),
          sessionRunning: true,
        );

        expect(find.text('Workspace ready'), findsOneWidget);
        expect(_banner(tester).color, kDefaultPalette.textMuted);
      });
    });
  });

  group('terminal states', () {
    testWidgets('a failure persists, warns, and offers a rerun', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        _setup('failed', stepIndex: 2, message: 'bun install exited 1'),
      );

      expect(find.text('Setup failed — bun install exited 1'), findsOneWidget);
      expect(_banner(tester).color, kDefaultPalette.warning);
      expect(find.text('Run setup again'), findsOneWidget);
      // View log and dismiss both stay: the log is the record of what broke,
      // and a finished run is something the user is allowed to put away.
      expect(find.byTooltip('View setup log'), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      // A failure never rides the progress rule — there is no progress left.
      expect(find.byType(AbProgressRule), findsNothing);
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
      expect(_banner(tester).color, kDefaultPalette.warning);
      expect(find.text('Run setup'), findsOneWidget);
    });

    testWidgets('a skipped run offers to run setup', (tester) async {
      await pumpBanner(tester, _setup('skipped'));

      expect(find.text('Setup skipped'), findsOneWidget);
      expect(find.text('Run setup'), findsOneWidget);
    });

    // The successful run's log stays reachable — it is the record of what the
    // workspace was built from, and the setup PTY is in no terminal list.
    testWidgets('a finished run says so and keeps its log', (tester) async {
      await pumpBanner(tester, _setup('done', stepIndex: 3));

      expect(find.text('Workspace ready'), findsOneWidget);
      expect(find.byTooltip('View setup log'), findsOneWidget);
      expect(find.byType(AbProgressRule), findsNothing);
    });

    testWidgets('a successful run clears after a short confirmation', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('done', stepIndex: 3));

      expect(find.text('Workspace ready'), findsOneWidget);
      await tester.pump(kSessionSetupSuccessHold);
      await tester.pump();

      expect(find.byType(AbInlineBanner), findsNothing);
    });

    testWidgets('an open successful setup log stays until it is collapsed', (
      tester,
    ) async {
      await pumpBanner(tester, _setup('done', stepIndex: 3));
      await tester.tap(find.byTooltip('View setup log'));
      await tester.pump();
      await tester.pump(kSessionSetupSuccessHold);

      expect(find.text('Workspace ready'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide setup log'));
      await tester.pump();
      await tester.pump(kSessionSetupSuccessHold);
      await tester.pump();

      expect(find.byType(AbInlineBanner), findsNothing);
    });
  });

  // Dismissal is keyed on the RUN, not the session: a rerun is a new answer to
  // the same question, and inheriting the old dismissal would hide it.
  testWidgets('a dismissal is spent by the next run', (tester) async {
    await pumpBanner(tester, _setup('failed', message: 'boom'));
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.byType(AbInlineBanner), findsNothing);

    await pumpBanner(tester, _setup('failed', message: 'boom'));
    expect(find.byType(AbInlineBanner), findsNothing);

    await pumpBanner(tester, _setup('running', startedAt: 9999));
    expect(find.byType(AbInlineBanner), findsOneWidget);
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
