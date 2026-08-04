import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_confirm_dialog.dart';
import 'package:antgrid/design/widgets/ab_switch.dart';

import '../test_harness.dart';

/// Pumps a button that opens the dialog and records what it returned.
Future<({bool confirmed, bool optionSelected})? Function()> _opener(
  WidgetTester tester, {
  String? optionLabel,
}) async {
  ({bool confirmed, bool optionSelected})? result;
  await pumpAntgrid(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await AbConfirmDialog.showWithOption(
            context: context,
            title: 'Delete worktree with unpushed commits?',
            body: 'body',
            confirmLabel: 'Force delete',
            destructive: true,
            optionLabel: optionLabel,
          );
        },
        child: const Text('open'),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

void main() {
  testWidgets('no option toggle is rendered when none is offered', (
    tester,
  ) async {
    final read = await _opener(tester);
    expect(find.byType(AbSwitch), findsNothing);

    await tester.tap(find.text('Force delete'));
    await tester.pumpAndSettle();
    expect(read(), (confirmed: true, optionSelected: false));
  });

  testWidgets('the option starts off and is not implied by confirming', (
    tester,
  ) async {
    // Branch deletion must be a deliberate second choice — confirming the
    // primary destructive action alone must never take the branch with it.
    final read = await _opener(tester, optionLabel: 'Also delete the branch');
    expect(find.byType(AbSwitch), findsOneWidget);
    expect(tester.widget<AbSwitch>(find.byType(AbSwitch)).value, isFalse);

    await tester.tap(find.text('Force delete'));
    await tester.pumpAndSettle();
    expect(read(), (confirmed: true, optionSelected: false));
  });

  testWidgets('an enabled option is reported back to the caller', (
    tester,
  ) async {
    final read = await _opener(tester, optionLabel: 'Also delete the branch');
    await tester.tap(find.byType(AbSwitch));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Force delete'));
    await tester.pumpAndSettle();
    expect(read(), (confirmed: true, optionSelected: true));
  });

  testWidgets('cancelling reports the option off even when it was on', (
    tester,
  ) async {
    final read = await _opener(tester, optionLabel: 'Also delete the branch');
    await tester.tap(find.byType(AbSwitch));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(read(), (confirmed: false, optionSelected: false));
  });

  testWidgets('show() still returns a plain bool for existing callers', (
    tester,
  ) async {
    bool? confirmed;
    await pumpAntgrid(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            confirmed = await AbConfirmDialog.show(
              context: context,
              title: 'Delete session?',
              body: 'body',
              confirmLabel: 'Delete',
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
}
