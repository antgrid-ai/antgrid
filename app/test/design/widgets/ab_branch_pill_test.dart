import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_branch_pill.dart';
import '../test_harness.dart';

void main() {
  testWidgets('AbBranchPill renders branch name', (tester) async {
    await pumpAntgrid(tester, const AbBranchPill(branch: 'feat/auth-flow'));
    expect(find.text('feat/auth-flow'), findsOneWidget);
  });

  testWidgets('AbBranchPill renders ahead indicator when provided',
      (tester) async {
    await pumpAntgrid(
      tester,
      const AbBranchPill(branch: 'main', ahead: 3),
    );
    expect(find.text('↑3'), findsOneWidget);
  });

  testWidgets('AbBranchPill omits ahead indicator at ahead==0',
      (tester) async {
    await pumpAntgrid(
      tester,
      const AbBranchPill(branch: 'main', ahead: 0),
    );
    expect(find.textContaining('↑'), findsNothing);
  });

  testWidgets('AbBranchPill fires onTap', (tester) async {
    var taps = 0;
    await pumpAntgrid(
      tester,
      AbBranchPill(branch: 'main', onTap: () => taps++),
    );
    await tester.tap(find.text('main'));
    expect(taps, 1);
  });
}
