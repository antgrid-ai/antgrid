import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_tap_target.dart';

import 'test_harness.dart';

// TargetPlatformVariant (not a manual debugDefaultTargetPlatformOverride)
// because the test binding asserts the override is back to null before the
// test body ends; the variant handles set/restore at the right lifecycle
// points.
const _mobile = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android});
const _desktop = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.windows,
});

void main() {
  group('AbTapTarget', () {
    testWidgets(
      'mobile: inflates a 24px child to >= tapTargetMin and the '
      'margin is tappable',
      (tester) async {
        var taps = 0;
        await pumpAntgrid(
          tester,
          AbTapTarget(
            onTap: () => taps++,
            child: const SizedBox.square(dimension: 24),
          ),
        );

        final size = tester.getSize(find.byType(AbTapTarget));
        expect(size.width, greaterThanOrEqualTo(AbTokens.tapTargetMin));
        expect(size.height, greaterThanOrEqualTo(AbTokens.tapTargetMin));

        // Corner of the inflated target: inside the 44px box, outside the
        // centered 24px child (which spans 10..34 on both axes).
        final rect = tester.getRect(find.byType(AbTapTarget));
        await tester.tapAt(rect.topLeft + const Offset(3, 3));
        expect(taps, 1);
      },
      variant: _mobile,
    );

    testWidgets(
      'desktop: pixel-identical passthrough',
      (tester) async {
        var taps = 0;
        await pumpAntgrid(
          tester,
          AbTapTarget(
            onTap: () => taps++,
            child: const SizedBox.square(dimension: 24),
          ),
        );

        expect(tester.getSize(find.byType(AbTapTarget)), const Size(24, 24));

        await tester.tap(find.byType(AbTapTarget));
        expect(taps, 1);
      },
      variant: _desktop,
    );
  });

  group('AbIconButton', () {
    testWidgets(
      'mobile: hit area >= tapTargetMin, visual box stays 24px, '
      'margin tap fires onTap',
      (tester) async {
        var taps = 0;
        await pumpAntgrid(
          tester,
          AbIconButton(icon: AbIcons.close, onTap: () => taps++),
        );

        final size = tester.getSize(find.byType(AbIconButton));
        expect(size.width, greaterThanOrEqualTo(AbTokens.tapTargetMin));
        expect(size.height, greaterThanOrEqualTo(AbTokens.tapTargetMin));

        // The 24px visual box must not inflate with the hit area.
        final visual = tester.getSize(
          find.descendant(
            of: find.byType(AbIconButton),
            matching: find.byType(DecoratedBox),
          ),
        );
        expect(
          visual,
          const Size(AbTokens.iconButtonBox, AbTokens.iconButtonBox),
        );

        final rect = tester.getRect(find.byType(AbIconButton));
        await tester.tapAt(rect.topLeft + const Offset(3, 3));
        expect(taps, 1);
      },
      variant: _mobile,
    );

    testWidgets(
      'desktop: exactly the 24px visual box, still tappable',
      (tester) async {
        var taps = 0;
        await pumpAntgrid(
          tester,
          AbIconButton(icon: AbIcons.close, onTap: () => taps++),
        );

        expect(
          tester.getSize(find.byType(AbIconButton)),
          const Size(AbTokens.iconButtonBox, AbTokens.iconButtonBox),
        );

        await tester.tap(find.byType(AbIconButton));
        expect(taps, 1);
      },
      variant: _desktop,
    );

    testWidgets(
      'disabled keeps the enabled footprint on mobile',
      (tester) async {
        await pumpAntgrid(tester, const AbIconButton(icon: AbIcons.close));

        final size = tester.getSize(find.byType(AbIconButton));
        expect(size.width, greaterThanOrEqualTo(AbTokens.tapTargetMin));
        expect(size.height, greaterThanOrEqualTo(AbTokens.tapTargetMin));
      },
      variant: _mobile,
    );
  });
}
