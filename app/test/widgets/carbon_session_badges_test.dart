import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/open_checkout.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/carbon_session_badges.dart';
import 'package:antgrid/widgets/session_deleting_badge.dart';
import 'package:antgrid/widgets/session_isolation_badge.dart';
import 'package:antgrid/widgets/session_shared_workspace_badge.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

SessionEntry _s({
  String checkoutKind = 'main',
  String checkoutState = 'ready',
  bool shared = false,
  int members = 1,
  String approvalPolicy = 'default',
}) => SessionEntry(
  id: 's',
  name: 'n',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  checkoutKind: checkoutKind,
  checkoutState: checkoutState,
  sharedWorkspace: shared,
  workspaceMemberCount: members,
  approvalPolicy: approvalPolicy,
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildAbTheme(),
    home: AbCarbonScope(
      child: Scaffold(body: Row(children: [child])),
    ),
  ),
);

void main() {
  testWidgets('every badge renders nothing when it does not apply', (
    tester,
  ) async {
    await _pump(
      tester,
      Row(
        children: [
          CarbonSessionIsolationBadge(session: _s()),
          CarbonSessionApprovalBadge(session: _s()),
          CarbonSessionSharedWorkspaceBadge(session: _s()),
          const CarbonSessionDeletingBadge(deleting: false),
        ],
      ),
    );
    expect(find.byType(CarbonIcon), findsNothing);
    expect(find.byType(CarbonTag), findsNothing);
    expect(find.byType(CarbonTooltip), findsNothing);
  });

  testWidgets('isolation: fork when ready, warning when unavailable', (
    tester,
  ) async {
    await _pump(
      tester,
      CarbonSessionIsolationBadge(
        session: _s(checkoutKind: 'managed-worktree'),
      ),
    );
    expect(
      tester.widget<CarbonIcon>(find.byType(CarbonIcon)).icon,
      CarbonIcons.fork,
    );
    expect(
      tester.widget<CarbonTooltip>(find.byType(CarbonTooltip)).message,
      sessionIsolationTip(SessionCheckoutHealth.ready, false),
    );

    await _pump(
      tester,
      CarbonSessionIsolationBadge(
        session: _s(checkoutKind: 'managed-worktree', checkoutState: 'missing'),
      ),
    );
    expect(find.byType(CarbonStatusIcon), findsOneWidget);
    expect(
      tester.widget<CarbonTooltip>(find.byType(CarbonTooltip)).message,
      sessionIsolationTip(SessionCheckoutHealth.unavailable, false),
    );
  });

  testWidgets('approval keeps the YOLO key and label', (tester) async {
    await _pump(
      tester,
      CarbonSessionApprovalBadge(session: _s(approvalPolicy: 'bypass')),
    );
    expect(find.byKey(const Key('session-yolo-badge')), findsOneWidget);
    expect(find.text('YOLO'), findsOneWidget);
  });

  testWidgets('shared workspace and deleting share the Ab copy', (
    tester,
  ) async {
    await _pump(
      tester,
      Row(
        children: [
          CarbonSessionSharedWorkspaceBadge(
            session: _s(shared: true, members: 3),
          ),
          const CarbonSessionDeletingBadge(deleting: true),
        ],
      ),
    );
    // A tag carries its own tooltip for a truncated label, so look for the
    // badge copy among them rather than at an exact list.
    final messages = tester
        .widgetList<CarbonTooltip>(find.byType(CarbonTooltip))
        .map((w) => w.message)
        .toList();
    expect(messages, containsAllInOrder([sharedWorkspaceTip(2), kSessionDeletingTip]));
    expect(find.text('Deleting'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  _handlerAndMemoryBadges();
}

List<String> _tooltipMessages(WidgetTester tester) => tester
    .widgetList<CarbonTooltip>(find.byType(CarbonTooltip))
    .map((w) => w.message)
    .toList();

HandlerSessionState _handlerSession(String terminalId, {required int pending}) =>
    HandlerSessionState(
      terminalId: terminalId,
      runState: pending > 0
          ? HandlerRunState.needsYou
          : HandlerRunState.watching,
      pendingEscalations: pending,
      armedAt: 1,
      goal: 'ship it',
      backlog: const [],
      escalations: const [],
    );

Future<void> _pumpHandler(
  WidgetTester tester, {
  required String entryId,
  required String sessionId,
  String? focusedProject = 'p',
  Map<String, HandlerSessionState> sessions = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue(focusedProject),
        handlerStateProvider.overrideWith(
          (ref) =>
              Stream.value(HandlerState.initial().copyWith(sessions: sessions)),
        ),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: AbCarbonScope(
          child: Scaffold(
            body: CarbonSessionHandlerBadge(
              entryId: entryId,
              sessionId: sessionId,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

SessionEntry _memorySession({bool flagged = true, bool running = true}) =>
    SessionEntry(
      id: 's1',
      name: 'Session',
      createdAt: 0,
      lastUsedAt: 0,
      archived: false,
      running: running,
      startedWithoutMemory: flagged,
    );

Future<void> _pumpMemory(
  WidgetTester tester, {
  required SessionEntry session,
  bool local = true,
  bool memoryOn = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        entryIsLocalCheckoutProvider.overrideWith((ref, id) async => local),
        memoryDrawerEnabledProvider.overrideWith((ref) async => memoryOn),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: AbCarbonScope(
          child: Scaffold(
            body: CarbonSessionMemoryRestartBadge(
              entryId: 'proj',
              session: session,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// The Handler badge is the one surface a session that is NOT in focus has: the
// Handler tab, its tab badge and the agent header's pill all answer for the
// focused session, so a sibling's unanswered question is only ever visible on
// its drawer row.
void _handlerAndMemoryBadges() {
  testWidgets('handler: counts the answers Handler is waiting on', (
    tester,
  ) async {
    await _pumpHandler(
      tester,
      entryId: 'p',
      sessionId: 't2',
      sessions: {
        't1': _handlerSession('t1', pending: 1),
        't2': _handlerSession('t2', pending: 2),
      },
    );
    expect(find.text('2'), findsOneWidget);
    // The tag carries a tooltip of its own, so look for the badge's among them.
    expect(_tooltipMessages(tester), contains(handlerPendingTip(2)));
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('handler: says nothing for a session with nothing pending', (
    tester,
  ) async {
    await _pumpHandler(
      tester,
      entryId: 'p',
      sessionId: 't1',
      sessions: {'t1': _handlerSession('t1', pending: 0)},
    );
    expect(find.byType(CarbonTag), findsNothing);
  });

  testWidgets('handler: says nothing for a session that is not armed', (
    tester,
  ) async {
    await _pumpHandler(tester, entryId: 'p', sessionId: 'unarmed');
    expect(find.byType(CarbonTag), findsNothing);
  });

  testWidgets('handler: refuses a row belonging to another project', (
    tester,
  ) async {
    // handlerStateProvider follows project focus, so answering this row would
    // attach the FOCUSED project's count to another project's session name,
    // which is worse than no count.
    await _pumpHandler(
      tester,
      entryId: 'other',
      sessionId: 't2',
      sessions: {'t2': _handlerSession('t2', pending: 2)},
    );
    expect(find.text('2'), findsNothing);
  });

  testWidgets('memory: renders for a flagged local session with Memory on', (
    tester,
  ) async {
    await _pumpMemory(tester, session: _memorySession());
    expect(find.text('No Memory'), findsOneWidget);
    expect(_tooltipMessages(tester), contains(kSessionMemoryRestartTip));
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('memory: absent for an entry that is not a local checkout', (
    tester,
  ) async {
    await _pumpMemory(tester, session: _memorySession(), local: false);
    expect(find.byType(CarbonTag), findsNothing);
  });

  testWidgets('memory: absent when the session is not flagged', (
    tester,
  ) async {
    await _pumpMemory(tester, session: _memorySession(flagged: false));
    expect(find.byType(CarbonTag), findsNothing);
  });

  testWidgets('memory: absent for a stopped session that is still flagged', (
    tester,
  ) async {
    await _pumpMemory(tester, session: _memorySession(running: false));
    expect(find.byType(CarbonTag), findsNothing);
  });

  testWidgets('memory: absent while Memory is off', (tester) async {
    await _pumpMemory(tester, session: _memorySession(), memoryOn: false);
    expect(find.byType(CarbonTag), findsNothing);
  });
}
