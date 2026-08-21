import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_breadcrumb.dart';
import '../test_harness.dart';

void main() {
  testWidgets('AbBreadcrumb renders segments separated by /', (tester) async {
    await pumpAntgrid(
      tester,
      const AbBreadcrumb(segments: ['antgrid', 'refactor-auth-flow']),
    );
    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('/'), findsOneWidget);
    expect(find.text('refactor-auth-flow'), findsOneWidget);
  });

  testWidgets('AbBreadcrumb single segment renders without separator', (
    tester,
  ) async {
    await pumpAntgrid(tester, const AbBreadcrumb(segments: ['antgrid']));
    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('/'), findsNothing);
  });
}
