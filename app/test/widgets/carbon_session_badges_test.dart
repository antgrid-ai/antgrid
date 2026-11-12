import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/widgets/carbon_session_badges.dart';
import 'package:antgrid/widgets/session_deleting_badge.dart';
import 'package:antgrid/widgets/session_isolation_badge.dart';
import 'package:antgrid/widgets/session_shared_workspace_badge.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
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
}
