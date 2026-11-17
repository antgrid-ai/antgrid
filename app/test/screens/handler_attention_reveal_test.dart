// The session kebab's attention row against the REAL shell rather than the
// menu alone: the tab it reveals belongs to WorkspaceShell, and so does the
// per-session UI restore that a focus change arms, so nothing short of the
// shell can say whether the reveal survives the switch it makes.
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/widgets/session_overflow_menu.dart';
import 'package:antgrid/widgets/workspace_panel.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

SessionEntry _entry(String id) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'terminal',
);

HandlerSessionState _session(
  String terminalId, {
  required HandlerRunState runState,
  int pendingEscalations = 0,
}) => HandlerSessionState(
  terminalId: terminalId,
  runState: runState,
  pendingEscalations: pendingEscalations,
  armedAt: 1,
  goal: 'ship it',
  backlog: const [],
  escalations: const [],
);

HandlerEscalation _escalation(String terminalId) => HandlerEscalation(
  escalationId: '$terminalId-1',
  terminalId: terminalId,
  question: 'q',
  reasoning: 'r',
  draftReply: 'd',
  urgency: 'normal',
  at: 1,
);

/// Bounded pumps rather than `pumpAndSettle`: the shell always has something
/// animating, so it never reaches a quiet frame.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The brand dot on the kebab: an 8px disc in the Carbon brand fill, painted
/// outside the trigger's layout. Found by what it draws, not by a key.
Finder _attentionDot() {
  final brand = {
    CarbonThemeData.forBrightness(Brightness.light).colors.backgroundBrand,
    CarbonThemeData.forBrightness(Brightness.dark).colors.backgroundBrand,
  };
  return find.descendant(
    of: find.byType(SessionOverflowButton),
    matching: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          brand.contains((w.decoration as BoxDecoration).color) &&
          w.child is SizedBox &&
          (w.child as SizedBox).width == CarbonSpacing.spacing03 &&
          (w.child as SizedBox).height == CarbonSpacing.spacing03,
    ),
  );
}

int _panelIndex(WidgetTester tester) => tester
    .widget<IndexedStack>(
      find.descendant(
        of: find.byType(WorkspacePanel),
        matching: find.byType(IndexedStack),
      ),
    )
    .index!;

/// The platform override is cleared inside the body, not from a tearDown: the
/// binding asserts every foundation debug variable is unset before tearDowns
/// run, and the shell's default panel mode reads the platform for the whole
/// body.
Future<void> _withShell(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body,
) async {
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await pumpWorkspaceShell(
      tester,
      extraOverrides: [
        activeSessionIdProvider.overrideWith(() => ValueController('t1')),
        sessionsStateProvider.overrideWith(
          (ref) => Stream.value(
            SessionsState(
              projectId: testAgentDeviceId,
              sessions: [_entry('t1'), _entry('t2')],
            ),
          ),
        ),
        handlerStateProvider.overrideWith(
          (ref) => Stream.value(
            const HandlerState.initial().copyWith(
              sessions: {
                't1': _session('t1', runState: HandlerRunState.watching),
                't2': _session(
                  't2',
                  runState: HandlerRunState.needsYou,
                  pendingEscalations: 1,
                ),
              },
              escalations: [_escalation('t2')],
            ),
          ),
        ),
      ],
    );
    await _settle(tester);
    await body(container);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Leaves [id] holding a saved workspace tab of its own, the way any session
/// the user has already worked in does, then hands focus back to `t1`.
Future<void> _giveSavedTab(WidgetTester tester, ProviderContainer c) async {
  c.read(activeSessionIdProvider.notifier).set('t2');
  await _settle(tester);
  await tester.tap(
    find.descendant(of: find.byType(WorkspacePanel), matching: find.text('Git')),
  );
  await _settle(tester);
  c.read(activeSessionIdProvider.notifier).set('t1');
  await _settle(tester);
}

void main() {
  // The restore is armed by the focus change the row itself makes, and it
  // re-applies the target session's own saved tab a frame later — so a reveal
  // that fires before it lands is silently undone, leaving the menu's one
  // navigation looking like a dead tap.
  testWidgets('the tab it reveals survives the focus switch it makes', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      await _giveSavedTab(tester, container);
      expect(_panelIndex(tester), isNot(WorkspaceView.handler.index));

      await tester.tap(find.byType(CarbonOverflowMenu));
      await _settle(tester);
      await tester.tap(find.text('Answer another session'));
      await _settle(tester);

      expect(container.read(activeSessionIdProvider), 't2');
      expect(_panelIndex(tester), WorkspaceView.handler.index);
    });
  });

  // The row lives behind a closed menu, so the dot on its trigger is the only
  // thing that can say a session out of focus is waiting at all.
  testWidgets('the kebab wears a dot only while a SIBLING waits', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      expect(_attentionDot(), findsOneWidget);

      container.read(activeSessionIdProvider.notifier).set('t2');
      await _settle(tester);

      // t2's own count belongs to the badge over its Handler tab now. A dot
      // still pointing away from the session in focus would send the user
      // looking for a second waiting session that does not exist.
      expect(_attentionDot(), findsNothing);
    });
  });
}
