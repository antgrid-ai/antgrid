// A toast about another session is only useful if it is a way to get to it.
// The half that breaks silently is the surface: revealing the handler tab by
// CALL after a session change is undone a frame later by the shell's
// per-session UI restore, so the route has to hand the tab over as pending
// state and let the drain apply it.
import 'dart:async';

import 'package:antgrid/design/widgets/ab_toast.dart';
import 'package:antgrid/models/handler_state.dart' show HandlerEscalation;
import 'package:antgrid/models/pending_nav.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

/// The compound entry the harness focuses, split the way the drawer keys it.
const _machineUuid = 'agent-123';
const _projectId = 'test-project';
const _entryId = '$_machineUuid.$_projectId';
const _target = RemoteProject(machineUuid: _machineUuid, projectId: _projectId);

const _escalation = HandlerEscalation(
  escalationId: 'esc-1',
  terminalId: 'session-9',
  question: 'Should I force-push?',
  reasoning: 'r',
  draftReply: 'd',
  urgency: 'high',
  at: 1,
);

/// Bounded pumps: the shell always has something animating, so it never
/// settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The platform override must be cleared inside the test body — the binding
/// asserts every foundation debug variable is unset before tearDown runs.
Future<void> _withShell(
  WidgetTester tester,
  Stream<({String entryId, HandlerEscalation message})> escalations,
  Future<void> Function(ProviderContainer container) body,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  try {
    final container = await pumpWorkspaceShell(
      tester,
      extraOverrides: [
        handlerEscalationsProvider.overrideWith((ref) => escalations),
      ],
    );
    // The applier compares the resolved target against this; the harness
    // leaves it unset while overriding the registration id directly.
    container.read(selectedTargetProvider.notifier).set(_target);
    await _settle(tester);
    await body(container);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets('an escalation toast opens the session it came from', (
    tester,
  ) async {
    await _withShell(tester, Stream.value((
      entryId: _entryId,
      message: _escalation,
    )), (container) async {
      // Every write of the pending view, so the assertion is about the
      // MECHANISM and not only its outcome — the drain clears it again.
      final handedOver = <PendingNav<WorkspaceView>>[];
      final sub = container.listen(pendingWorkspaceViewProvider, (_, next) {
        if (next != null) handedOver.add(next);
      });
      addTearDown(sub.close);

      final toast = tester.widget<AbToast>(find.byType(AbToast));
      expect(toast.actionLabel, 'Open');

      await tester.tap(find.text('Open'));
      await _settle(tester);

      expect(container.read(activeSessionIdProvider), _escalation.terminalId);
      expect(handedOver, [(target: _target, value: WorkspaceView.handler)]);
      // Honoured by the drain, which is what a direct reveal would have lost.
      expect(
        container.read(visibleWorkspaceViewProvider),
        WorkspaceView.handler,
      );
      // A same-project route never queues the session id: nothing would drain
      // one here, and while set it makes `reconcileActiveSession` select null.
      expect(container.read(pendingActiveSessionIdProvider), isNull);

      // Outlive the toast's own timer so nothing fires past the test.
      await tester.pump(const Duration(seconds: 12));
    });
  });

  testWidgets('a second tap on the same toast applies once', (tester) async {
    await _withShell(tester, Stream.value((
      entryId: _entryId,
      message: _escalation,
    )), (container) async {
      await tester.tap(find.text('Open'));
      await _settle(tester);
      container.read(activeSessionIdProvider.notifier).set(null);

      // Past `showAbToastOverlay`'s 4s default and well inside the 8s this
      // toast asked for: the second tap only reaches a chip that is still on
      // screen, so the two halves — the longer duration and the dedup that has
      // to absorb what it makes possible — are pinned together.
      // ~2.4s has already elapsed in the settles above, so this lands near 7s:
      // past a 6s toast, inside the 8s one, which is the window that pins the
      // duration from both sides rather than only against the 4s default.
      await tester.pump(const Duration(milliseconds: 4500));
      expect(find.text('Open'), findsOneWidget);

      // The action cannot dismiss its own toast, so it stays pressable for the
      // whole 8s — the applier's dedup is what absorbs the second press.
      await tester.tap(find.text('Open'));
      await _settle(tester);

      expect(container.read(activeSessionIdProvider), isNull);

      await tester.pump(const Duration(seconds: 12));
    });
  });

  // The complement of the case above, and what keeps that one honest: without a
  // sourceMessageId every route about one session is value-identical, so the
  // dedup that swallows a re-tap would swallow the NEXT escalation too — the
  // second and every later Open on that session, permanently.
  testWidgets('a later escalation on the same session opens it again', (
    tester,
  ) async {
    const second = HandlerEscalation(
      escalationId: 'esc-2',
      terminalId: 'session-9',
      question: 'And now?',
      reasoning: 'r',
      draftReply: 'd',
      urgency: 'high',
      at: 2,
    );
    final controller =
        StreamController<({String entryId, HandlerEscalation message})>.broadcast();
    addTearDown(controller.close);

    await _withShell(tester, controller.stream, (container) async {
      controller.add((entryId: _entryId, message: _escalation));
      await _settle(tester);
      await tester.tap(find.text('Open'));
      await _settle(tester);
      expect(container.read(activeSessionIdProvider), 'session-9');
      container.read(activeSessionIdProvider.notifier).set(null);
      await tester.pump(const Duration(seconds: 12));

      controller.add((entryId: _entryId, message: second));
      await _settle(tester);
      await tester.tap(find.text('Open'));
      await _settle(tester);

      expect(container.read(activeSessionIdProvider), 'session-9');
      await tester.pump(const Duration(seconds: 12));
    });
  });

  // The action is offered only when the route RESOLVES, not merely when an
  // entryId is present: a chip that opens nothing is worse than no chip.
  testWidgets('an unroutable notification keeps the plain toast', (
    tester,
  ) async {
    const blank = HandlerEscalation(
      escalationId: 'esc-blank',
      terminalId: 'session-9',
      question: 'Whose project is this?',
      reasoning: 'r',
      draftReply: 'd',
      urgency: 'high',
      at: 1,
    );
    await _withShell(tester, Stream.value((entryId: '  ', message: blank)), (
      container,
    ) async {
      final toast = tester.widget<AbToast>(find.byType(AbToast));
      expect(toast.actionLabel, isNull);
      expect(find.text('Open'), findsNothing);

      // The plain toast keeps `showAbToastOverlay`'s 4s default; only the
      // actionable one is held open long enough to be reached for.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(AbToast), findsNothing);
    });
  });
}
