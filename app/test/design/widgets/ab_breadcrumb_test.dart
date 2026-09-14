import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:antgrid/design/widgets/ab_breadcrumb.dart';
import '../test_harness.dart';

void main() {
  for (final width in [0.0, 80.0, 146.6, 280.0]) {
    testWidgets(
      'a breadcrumb fits a $width pixel slot and keeps its leaf action',
      (tester) async {
        var tapped = false;
        await pumpAntgrid(
          tester,
          Center(
            child: SizedBox(
              width: width,
              child: AbBreadcrumb(
                segments: const ['a very long project name', 'active session'],
                leafOverride: GestureDetector(
                  onTap: () => tapped = true,
                  child: const Text(
                    'active session',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('active session'), findsOneWidget);
        if (width > 0) {
          await tester.tap(find.text('active session'));
          expect(tapped, isTrue);
        }
      },
    );
  }

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
