import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_brand_mark.dart';
import '../test_harness.dart';

void main() {
  testWidgets('AbEmptyState shows the brand mark when showBrand is true', (
    tester,
  ) async {
    await pumpAntgrid(
      tester,
      const AbEmptyState(title: 'Nothing here', showBrand: true),
    );
    expect(find.byType(AbBrandMark), findsOneWidget);
  });

  testWidgets('AbEmptyState hides the brand mark by default', (tester) async {
    await pumpAntgrid(tester, const AbEmptyState(title: 'Nothing here'));
    expect(find.byType(AbBrandMark), findsNothing);
  });
}
