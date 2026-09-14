// The boot gate's local/remote routing, the one-way hand-off latch, and the
// two readiness-driven phase rows that replaced the hardcoded 'workspace'
// phase — this screen had no widget test before. Drives CheckoutReadiness
// through the providers `composeReadiness` actually reads (selectedTarget,
// supervisorStatus, terminalState) rather than overriding
// checkoutReadinessProvider itself: a plain `Provider.autoDispose` cannot be
// pushed a new value mid-test, only its own dependencies can.
import 'dart:async';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/workspace_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

/// Bounded pumps rather than `pumpAndSettle`: the running phase's glyph
/// pulses (`PulsingOpacity`) and the shell always has a connection indicator
/// animating too, so settling never terminates.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// A remote target whose registrationId equals [testAgentDeviceId] —
/// `activeProjectId` inside the shell still comes from the harness's OTHER,
/// fixed override (`selectedRegistrationIdProvider`), so a remote target with
/// a different id would point `projectSessionProvider`/`supervisorStatusProvider`
/// reads at two different keys instead of one.
const _remoteTarget = RemoteProject(
  machineUuid: 'agent-123',
  projectId: 'test-project',
);

/// Reads the leading glyph beside a phase row's label ('·' pending, '▸'
/// running, '✓' done, '×' failed) — the only way to observe a phase's status
/// from outside the shell, since `_PhaseStatus`/`_PhaseRow` are private to
/// workspace_shell.dart. The glyph is always the row's first `Text`
/// descendant, `PulsingOpacity`-wrapped or not.
String _phaseGlyph(WidgetTester tester, String label) {
  final row = find
      .ancestor(of: find.text(label), matching: find.byType(Row))
      .first;
  return tester
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .first
      .data!;
}

/// Pumps the real shell with a controllable [TerminalState] stream, and
/// optionally a specific [SessionTarget] independent of the harness's own
/// fixed `selectedRegistrationIdProvider` — which is what lets a test reach
/// the "route is mounted but no target is selected yet" window, not just "no
/// route is mounted" (`withProject: false` skips WorkspaceShell entirely;
/// AppShell routes to NewSessionScreen instead — see
/// workspace_shell_title_bar_test.dart).
Future<void> _withBootShell(
  WidgetTester tester,
  Future<void> Function(
    ProviderContainer container,
    StreamController<TerminalState> terminal,
  )
  body, {
  SessionTarget? target,
  bool overrideTarget = false,
  List<Override> extraOverrides = const [],
}) async {
  final terminal = StreamController<TerminalState>.broadcast();
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // pumpWorkspaceShell's `target` param defaults to a private "unset"
    // sentinel distinct from `null`, so it is only passed at all when this
    // helper's own caller actually wants a target other than the harness's
    // local-project default.
    final container = overrideTarget || target != null
        ? await pumpWorkspaceShell(
            tester,
            terminalStates: terminal.stream,
            target: target,
            extraOverrides: extraOverrides,
          )
        : await pumpWorkspaceShell(
            tester,
            terminalStates: terminal.stream,
            extraOverrides: extraOverrides,
          );
    await _settle(tester);
    await body(container, terminal);
  } finally {
    debugDefaultTargetPlatformOverride = null;
    await terminal.close();
  }
}

void main() {
  testWidgets('a local target renders the phase-less local boot status', (
    tester,
  ) async {
    // No terminal state ever emitted, so readiness is pinned at
    // openingSession (a holding state) for the life of the test — no race
    // against the fake transport's own session-resolve time.
    await _withBootShell(tester, (container, terminal) async {
      expect(find.text('starting agent'), findsOneWidget);
      expect(find.textContaining('cancel — back to projects'), findsOneWidget);
      expect(find.byType(AgentPanel), findsNothing);
      expect(find.text('opening session'), findsNothing);
    });
  });

  testWidgets(
    'a remote target with a resolved registration id renders the phased boot status',
    (tester) async {
      await _withBootShell(
        tester,
        (container, terminal) async {
          expect(find.text('opening session'), findsOneWidget);
          expect(find.text('loading terminal'), findsOneWidget);
          expect(find.text('starting agent'), findsNothing);
          expect(find.byType(AgentPanel), findsNothing);
        },
        target: _remoteTarget,
        extraOverrides: [
          supervisorStatusProvider(
            testAgentDeviceId,
          ).overrideWith((ref) => Stream.value(const Connected())),
        ],
      );
    },
  );

  testWidgets(
    'a route mounted with no target selected also renders the phased boot status',
    (tester) async {
      // isLocalTarget reads `selectedTargetProvider?.isLocal`, so a null
      // target routes the same as a remote one — never the phase-less local
      // screen, which is a claim about the target, not an absence of one.
      await _withBootShell(tester, (container, terminal) async {
        expect(find.text('opening session'), findsOneWidget);
        expect(find.text('loading terminal'), findsOneWidget);
        expect(find.byType(AgentPanel), findsNothing);
      }, overrideTarget: true);
    },
  );

  testWidgets(
    'the two phase rows complete in order, and the shell stays put at loadingScreen',
    (tester) async {
      await _withBootShell(
        tester,
        (container, terminal) async {
          // Nothing emitted yet: terminal == null forces openingSession
          // regardless of session resolution.
          expect(_phaseGlyph(tester, 'opening session'), '▸');
          expect(_phaseGlyph(tester, 'loading terminal'), '·');

          terminal.add(const TerminalState());
          await _settle(tester);

          // loadingScreen: opening-session has completed, loading-terminal is
          // now the running one — and loadingScreen is itself a holding
          // state, so the boot screen must still be up, not the workspace.
          expect(_phaseGlyph(tester, 'opening session'), '✓');
          expect(_phaseGlyph(tester, 'loading terminal'), '▸');
          expect(find.byType(AgentPanel), findsNothing);
        },
        target: _remoteTarget,
        extraOverrides: [
          supervisorStatusProvider(
            testAgentDeviceId,
          ).overrideWith((ref) => Stream.value(const Connected())),
        ],
      );
    },
  );

  testWidgets('hands off to the workspace at ready', (tester) async {
    await _withBootShell(
      tester,
      (container, terminal) async {
        terminal.add(const TerminalState(attach: CheckoutAttachStatus.ready));
        await _settle(tester);

        expect(find.byType(AgentPanel), findsOneWidget);
        expect(find.byType(WorkspacePanel), findsOneWidget);
        expect(find.text('opening session'), findsNothing);
      },
      target: _remoteTarget,
      extraOverrides: [
        supervisorStatusProvider(
          testAgentDeviceId,
        ).overrideWith((ref) => Stream.value(const Connected())),
      ],
    );
  });

  testWidgets(
    'a stalled checkout hands off to the workspace, not a blocking-error takeover',
    (tester) async {
      await _withBootShell(
        tester,
        (container, terminal) async {
          terminal.add(
            const TerminalState(attach: CheckoutAttachStatus.failed),
          );
          await _settle(tester);

          // The workspace itself is mounted — neither the boot screen nor
          // workspaceBlockingError's full-screen takeover, which only a
          // transport/session error or a Blocked supervisor status reaches.
          expect(find.byType(AgentPanel), findsOneWidget);
          expect(find.text('opening session'), findsNothing);
        },
        target: _remoteTarget,
        extraOverrides: [
          supervisorStatusProvider(
            testAgentDeviceId,
          ).overrideWith((ref) => Stream.value(const Connected())),
        ],
      );
    },
  );

  testWidgets(
    'a readiness regression after hand-off does not re-mount the boot overlay',
    (tester) async {
      await _withBootShell(
        tester,
        (container, terminal) async {
          terminal.add(
            const TerminalState(attach: CheckoutAttachStatus.ready),
          );
          await _settle(tester);
          expect(find.byType(AgentPanel), findsOneWidget);

          // The one-way latch: a level-triggered readiness regressing back to
          // a holding state (a fresh handshake, a mobile foreground
          // re-attach) must not re-cover the workspace — that would unmount
          // the GlobalKey-identified panels underneath.
          terminal.add(const TerminalState());
          await _settle(tester);

          expect(find.byType(AgentPanel), findsOneWidget);
          expect(find.text('opening session'), findsNothing);
          expect(find.text('starting agent'), findsNothing);
        },
        target: _remoteTarget,
        extraOverrides: [
          supervisorStatusProvider(
            testAgentDeviceId,
          ).overrideWith((ref) => Stream.value(const Connected())),
        ],
      );
    },
  );
}
