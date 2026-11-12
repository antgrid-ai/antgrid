import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/widgets/session_delete_flow.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAbTheme(),
      home: AbCarbonScope(
        child: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  return ctx;
}

void main() {
  testWidgets('the first question is a Carbon danger modal on Cancel', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final attempts = <({bool? force, bool? deleteBranch})>[];
    final result = confirmAndDeleteSession(
      context: ctx,
      dialogs: carbonSessionDeleteDialogs,
      sessionName: 'Fix auth bug',
      checkoutKind: 'main',
      sharedBody: 'Body.',
      delete: ({force, deleteBranch}) async {
        attempts.add((force: force, deleteBranch: deleteBranch));
        return SessionDeleteAck.deleted;
      },
    );
    await tester.pumpAndSettle();
    expect(find.byType(CarbonModal), findsOneWidget);
    expect(find.text('Delete session?'), findsOneWidget);
    expect(find.text('Body. This cannot be undone.'), findsOneWidget);
    expect(
      abWidgetsInScope(tester, scope: find.byType(CarbonModal)),
      isEmpty,
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(await result, SessionDeleteResult.deleted);
    expect(attempts, [(force: null, deleteBranch: null)]);
  });

  testWidgets('cancelling asks nothing of the bridge', (tester) async {
    final ctx = await _pumpHost(tester);
    var calls = 0;
    final result = confirmAndDeleteSession(
      context: ctx,
      dialogs: carbonSessionDeleteDialogs,
      sessionName: 'x',
      checkoutKind: 'main',
      sharedBody: 'Body.',
      delete: ({force, deleteBranch}) async {
        calls++;
        return SessionDeleteAck.deleted;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, SessionDeleteResult.cancelled);
    expect(calls, 0);
  });

  testWidgets('the unpushed rung carries the unchecked branch option', (
    tester,
  ) async {
    final ctx = await _pumpHost(tester);
    final attempts = <({bool? force, bool? deleteBranch})>[];
    final result = confirmAndDeleteSession(
      context: ctx,
      dialogs: carbonSessionDeleteDialogs,
      sessionName: 'x',
      checkoutKind: 'managed-worktree',
      sharedBody: 'Body.',
      delete: ({force, deleteBranch}) async {
        attempts.add((force: force, deleteBranch: deleteBranch));
        if (force == null) {
          throw SessionOperationException('WORKTREE_UNPUSHED', 'unpushed');
        }
        return SessionDeleteAck.deleted;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      find.text('Delete isolated session with unpushed commits?'),
      findsOneWidget,
    );
    expect(find.byType(CarbonCheckbox), findsOneWidget);
    expect(
      tester.widget<CarbonCheckbox>(find.byType(CarbonCheckbox)).value,
      isFalse,
    );
    await tester.tap(find.text('Also delete the branch and its commits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Force delete'));
    await tester.pumpAndSettle();

    expect(await result, SessionDeleteResult.deleted);
    expect(attempts.last, (force: true, deleteBranch: true));
  });

  testWidgets('the uncommitted rung offers no branch option', (tester) async {
    final ctx = await _pumpHost(tester);
    final result = confirmAndDeleteSession(
      context: ctx,
      dialogs: carbonSessionDeleteDialogs,
      sessionName: 'x',
      checkoutKind: 'managed-worktree',
      sharedBody: 'Body.',
      delete: ({force, deleteBranch}) async {
        if (force == null) {
          throw SessionOperationException('WORKTREE_DIRTY', 'dirty');
        }
        return SessionDeleteAck.deleted;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.byType(CarbonCheckbox), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, SessionDeleteResult.cancelled);
  });
}
