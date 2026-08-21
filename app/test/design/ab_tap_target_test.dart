import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/design/widgets/ab_tap_target.dart';
import 'package:antgrid/design/widgets/ab_toolbar.dart';

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
    testWidgets('mobile: inflates a 24px child to >= tapTargetMin and the '
        'margin is tappable', (tester) async {
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
    }, variant: _mobile);

    testWidgets('desktop: pixel-identical passthrough', (tester) async {
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
    }, variant: _desktop);
  });

  group('AbIconButton', () {
    testWidgets('mobile: hit area >= tapTargetMin, visual box stays 24px, '
        'margin tap fires onTap', (tester) async {
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
    }, variant: _mobile);

    testWidgets('desktop: exactly the 24px visual box, still tappable', (
      tester,
    ) async {
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
    }, variant: _desktop);

    testWidgets('disabled keeps the enabled footprint on mobile', (
      tester,
    ) async {
      await pumpAntgrid(tester, const AbIconButton(icon: AbIcons.close));

      final size = tester.getSize(find.byType(AbIconButton));
      expect(size.width, greaterThanOrEqualTo(AbTokens.tapTargetMin));
      expect(size.height, greaterThanOrEqualTo(AbTokens.tapTargetMin));
    }, variant: _mobile);
  });

  group('AbCompactTapTargets', () {
    // A `sm` list row carrying trailing icon buttons — the drawer/session-row
    // shape. Its height must come from its density, not from the buttons.
    Future<void> pumpRow(WidgetTester tester) => pumpAntgrid(
      tester,
      SizedBox(
        width: 300,
        child: AbListRow(
          title: const Text('project-name'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbIconButton(icon: AbIcons.add, onTap: () {}),
              AbIconButton(icon: AbIcons.trash, onTap: () {}),
            ],
          ),
          density: AbRowDensity.sm,
          horizontalPadding: 0,
          onTap: () {},
        ),
      ),
    );

    testWidgets(
      'mobile: trailing buttons keep the 44px width but do not raise the row',
      (tester) async {
        await pumpRow(tester);

        final button = tester.getSize(find.byType(AbIconButton).first);
        expect(button.width, greaterThanOrEqualTo(AbTokens.tapTargetMin));
        expect(button.height, AbTokens.iconButtonBox);

        // 24px content + 2 * space6 — the density's own height.
        expect(tester.getSize(find.byType(AbListRow)).height, 36);
      },
      variant: _mobile,
    );

    testWidgets('desktop: row height unchanged by the scope', (tester) async {
      await pumpRow(tester);
      expect(tester.getSize(find.byType(AbListRow)).height, 36);
    }, variant: _desktop);
  });

  group('AbIconButton text scaling', () {
    Future<void> pumpScaled(WidgetTester tester, double scale, Widget child) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Center(child: SizedBox(width: 300, child: child)),
              ),
            ),
          ),
        );

    testWidgets('inside a compact row the target grows with the text scale', (
      tester,
    ) async {
      Future<Size> targetAt(double scale) async {
        await pumpScaled(
          tester,
          scale,
          AbListRow(
            title: const Text('project-name'),
            trailing: AbIconButton(icon: AbIcons.trash, onTap: () {}),
            density: AbRowDensity.sm,
            horizontalPadding: 0,
            onTap: () {},
          ),
        );
        await tester.pumpAndSettle();
        return tester.getSize(find.byType(AbIconButton));
      }

      // The compact scope drops the flat 44px height floor, so the box IS
      // the target height here — it must track the type beside it or a
      // large-text user gets a target that never grows.
      expect((await targetAt(1.0)).height, AbTokens.iconButtonBox);
      expect((await targetAt(1.3)).height, closeTo(31.2, 0.01));
      expect((await targetAt(2.0)).height, AbTokens.iconButtonBox * 2);
    }, variant: _mobile);

    testWidgets(
      'standalone keeps the 44px floor until the scaled box exceeds it',
      (tester) async {
        Future<double> heightAt(double scale) async {
          await pumpScaled(
            tester,
            scale,
            Align(
              child: AbIconButton(icon: AbIcons.close, onTap: () {}),
            ),
          );
          await tester.pumpAndSettle();
          return tester.getSize(find.byType(AbIconButton)).height;
        }

        expect(await heightAt(1.0), AbTokens.tapTargetMin);
        expect(await heightAt(1.3), AbTokens.tapTargetMin);
        expect(await heightAt(2.0), AbTokens.iconButtonBox * 2);
      },
      variant: _mobile,
    );

    testWidgets(
      'a narrow panel toolbar ellipsizes rather than overflowing at 2.0',
      (tester) async {
        await pumpScaled(
          tester,
          2.0,
          AbToolbar.panel(
            title: 'EXPLORER',
            actions: [
              for (final i in [
                AbIcons.refresh,
                AbIcons.search,
                AbIcons.add,
                AbIcons.close,
              ])
                AbIconButton(icon: i, onTap: () {}),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      variant: _mobile,
    );
  });
}
