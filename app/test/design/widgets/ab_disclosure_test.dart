import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_disclosure.dart';
import 'package:antgrid/design/widgets/ab_tap_target.dart';

import '../test_harness.dart';

// TargetPlatformVariant (not a manual debugDefaultTargetPlatformOverride)
// because the test binding asserts the override is back to null before the
// test body ends; the variant handles set/restore at the right lifecycle
// points. See test/design/ab_tap_target_test.dart.
const _mobile = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android});
const _desktop = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.windows,
});

Widget _harness({required bool expanded, required VoidCallback onToggle}) =>
    AbDisclosure(
      label: 'Why',
      expanded: expanded,
      onToggle: onToggle,
      child: const Text('the reasoning'),
    );

void main() {
  group('AbDisclosure', () {
    testWidgets('collapsed by default: label shown, child absent', (
      tester,
    ) async {
      await pumpAntgrid(tester, _harness(expanded: false, onToggle: () {}));
      expect(find.text('Why'), findsOneWidget);
      expect(find.text('the reasoning'), findsNothing);
    });

    testWidgets('expanded: child renders', (tester) async {
      await pumpAntgrid(tester, _harness(expanded: true, onToggle: () {}));
      expect(find.text('the reasoning'), findsOneWidget);
    });

    testWidgets('tapping the header calls onToggle', (tester) async {
      var toggles = 0;
      await pumpAntgrid(
        tester,
        _harness(expanded: false, onToggle: () => toggles++),
      );
      await tester.tap(find.text('Why'));
      expect(toggles, 1);
    });

    // This is the one card built to be answered from a phone; the reviewer
    // that caught the header shrink-wrapped to a 12px icon and an 11px label
    // is why this asserts the floor by measurement rather than trusting the
    // composition to hold it.
    testWidgets('mobile: the header meets the tap-target floor', (
      tester,
    ) async {
      await pumpAntgrid(tester, _harness(expanded: false, onToggle: () {}));
      final size = tester.getSize(find.byType(AbTapTarget));
      expect(size.width, greaterThanOrEqualTo(AbTokens.tapTargetMin));
      expect(size.height, greaterThanOrEqualTo(AbTokens.tapTargetMin));
    }, variant: _mobile);

    testWidgets('desktop: header stays compact, tap still fires', (
      tester,
    ) async {
      var toggles = 0;
      await pumpAntgrid(
        tester,
        _harness(expanded: false, onToggle: () => toggles++),
      );
      final size = tester.getSize(find.byType(AbTapTarget));
      expect(size.height, lessThan(AbTokens.tapTargetMin));
      await tester.tap(find.byType(AbTapTarget));
      expect(toggles, 1);
    }, variant: _desktop);

    testWidgets('announces itself as a toggle button to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAntgrid(tester, _harness(expanded: false, onToggle: () {}));

      expect(
        tester.getSemantics(find.bySemanticsLabel('Why')),
        matchesSemantics(
          label: 'Why',
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
        ),
      );

      await pumpAntgrid(tester, _harness(expanded: true, onToggle: () {}));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Why')),
        matchesSemantics(
          label: 'Why',
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );

      handle.dispose();
    });
  });
}
