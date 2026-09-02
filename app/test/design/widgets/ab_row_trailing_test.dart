import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_row_trailing.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/design/widgets/ab_tap_target.dart';

import '../test_harness.dart';

const _platforms = <TargetPlatform>[
  TargetPlatform.windows,
  TargetPlatform.android,
];

/// Runs [body] with [platform] reported by `defaultTargetPlatform`.
///
/// The binding's foundation-var invariant check runs at the end of the test
/// BODY, before any tearDown, so the override has to be lifted here.
Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _pumpScaled(WidgetTester tester, double scale, Widget child) =>
    pumpAntgrid(
      tester,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child,
        ),
      ),
    );

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('AbIconButton.footprintWidth', () {
    testWidgets('equals the width the button lays out, on every platform and '
        'text scale', (tester) async {
      // The rail's premise is that a cell can be as wide as a button without
      // asking one. AbTapTarget makes that width, footprintWidth is a hand
      // copy of its rule, and nothing in the type system holds the two
      // together.
      for (final platform in _platforms) {
        await _onPlatform(platform, () async {
          for (final scale in const <double>[1.0, 1.3, 2.0]) {
            await _pumpScaled(
              tester,
              scale,
              AbCompactTapTargets(
                child: AbIconButton(icon: AbIcons.trash, onTap: () {}),
              ),
            );

            final measured = tester.getSize(find.byType(AbIconButton)).width;
            final declared = AbIconButton.footprintWidth(
              tester.element(find.byType(AbIconButton)),
            );
            final scaledBox = AbTokens.iconButtonBox * scale;
            final byTapTargetRule = platform == TargetPlatform.android
                ? math.max(AbTokens.tapTargetMin, scaledBox)
                : scaledBox;

            expect(
              measured,
              closeTo(byTapTargetRule, 0.01),
              reason:
                  'AbTapTarget moved: on $platform at text scale $scale a '
                  'compact AbIconButton lays out ${measured}px where its own '
                  'documented rule gives ${byTapTargetRule}px. Retune the rule '
                  'and AbIconButton.footprintWidth together.',
            );
            expect(
              declared,
              closeTo(measured, 0.01),
              reason:
                  'AbIconButton.footprintWidth drifted from AbTapTarget: on '
                  '$platform at text scale $scale it declares ${declared}px '
                  'while the button occupies ${measured}px. Every '
                  'AbRowTrailingCell in the panel is now '
                  '${(declared - measured).abs()}px off the rail.',
            );
          }
        });
      }
    });
  });

  group('AbRowTrailingCell', () {
    testWidgets('an empty cell reserves the footprint and no height', (
      tester,
    ) async {
      for (final platform in _platforms) {
        await _onPlatform(platform, () async {
          // Keyed per platform: an identical const widget across the two
          // iterations is short-circuited by the framework, so the cell would
          // keep the width it measured under the previous override.
          await pumpAntgrid(tester, AbRowTrailingCell(key: ValueKey(platform)));

          final width = AbIconButton.footprintWidth(
            tester.element(find.byType(AbRowTrailingCell)),
          );
          expect(
            tester.getSize(find.byType(AbRowTrailingCell)),
            Size(width, 0),
            reason:
                'A reserved-but-empty cell on $platform must hold the column '
                'open without contributing a height of its own.',
          );
        });
      }
    });

    testWidgets('a dot and a button in cells share one optical centre', (
      tester,
    ) async {
      for (final platform in _platforms) {
        await _onPlatform(platform, () async {
          await pumpAntgrid(
            tester,
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tenant in <Widget>[
                  const AbStatusDot(),
                  AbIconButton(icon: AbIcons.trash, onTap: () {}),
                ])
                  SizedBox(
                    width: 300,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [AbRowTrailingCell(child: tenant)],
                    ),
                  ),
              ],
            ),
          );

          final dot = tester.getCenter(find.byType(AbStatusDot)).dx;
          final button = tester.getCenter(find.byType(AbIconButton)).dx;
          expect(
            dot,
            closeTo(button, 0.01),
            reason:
                'On $platform a bare dot centres at ${dot}px and a padded '
                'glyph at ${button}px against the same edge — the two row '
                'classes no longer share a trailing column.',
          );
        });
      }
    });

    testWidgets('kit drops a null without charging its gap', (tester) async {
      const dense = <Widget?>[
        AbRowTrailingCell(child: AbStatusDot()),
        AbRowTrailingCell(child: AbStatusDot()),
      ];
      const sparse = <Widget?>[
        AbRowTrailingCell(child: AbStatusDot()),
        null,
        AbRowTrailingCell(child: AbStatusDot()),
      ];

      Future<Rect> spanOf(List<Widget?> cells) async {
        await pumpAntgrid(tester, AbRowTrailingCell.kit(cells)!);
        final found = find.byType(AbRowTrailingCell);
        return tester
            .getRect(found.at(0))
            .expandToInclude(tester.getRect(found.at(1)));
      }

      final sparseSpan = await spanOf(sparse);
      final denseSpan = await spanOf(dense);
      final footprint = AbIconButton.footprintWidth(
        tester.element(find.byType(AbRowTrailingCell).first),
      );

      expect(
        sparseSpan.width,
        closeTo(2 * footprint + AbTokens.space4, 0.01),
        reason:
            'A dropped cell still bought a ${AbTokens.space4}px gap — the '
            "phantom gap that put a project row's + inboard of the rail.",
      );
      expect(sparseSpan.width, closeTo(denseSpan.width, 0.01));
    });

    test('kit returns null when nothing survives', () {
      expect(AbRowTrailingCell.kit(const <Widget?>[null, null]), isNull);
      expect(AbRowTrailingCell.kit(const <Widget?>[]), isNull);
    });
  });

  group('AbRowTrailingSwap', () {
    testWidgets('desktop shares one cell, mobile keeps both tenants', (
      tester,
    ) async {
      var taps = 0;
      Future<void> pumpSwap(bool revealed) => pumpAntgrid(
        tester,
        AbRowTrailingSwap(
          revealed: revealed,
          resting: const AbStatusDot(),
          action: AbIconButton(icon: AbIcons.trash, onTap: () => taps++),
        ),
      );

      await _onPlatform(TargetPlatform.windows, () async {
        await pumpSwap(false);
        final atRest = tester.getSize(find.byType(AbRowTrailingSwap));

        await tester.tap(find.byType(AbIconButton), warnIfMissed: false);
        await tester.pump();
        expect(
          taps,
          0,
          reason:
              'The faded-out action is still laid out, so it takes hits '
              'unless IgnorePointer is wired to the same flag as the fade.',
        );

        await pumpSwap(true);
        await tester.pumpAndSettle();
        expect(find.byType(AbStatusDot), findsOneWidget);
        expect(
          tester.getSize(find.byType(AbRowTrailingSwap)),
          atRest,
          reason:
              'Revealing the action resized the cell, so a machine band dot '
              'slides on pointer-enter — the reason the two tenants share one '
              'cell at all.',
        );

        await tester.tap(find.byType(AbIconButton));
        await tester.pump();
        expect(taps, 1);
      });

      await _onPlatform(TargetPlatform.android, () async {
        // Touch has no pointer to reveal with, so a swap would retire the
        // liveness dot for good; both tenants stand side by side instead.
        for (final revealed in const <bool>[false, true]) {
          await pumpSwap(revealed);
          expect(find.byType(AbStatusDot), findsOneWidget);
          expect(find.byType(AbIconButton), findsOneWidget);

          final footprint = AbIconButton.footprintWidth(
            tester.element(find.byType(AbIconButton)),
          );
          expect(
            tester.getSize(find.byType(AbRowTrailingSwap)).width,
            closeTo(AbTokens.dotSizeSm + AbTokens.space4 + footprint, 0.01),
            reason:
                'The mobile swap at revealed=$revealed must lay out the '
                'resting slot, the gap and a full-footprint action cell.',
          );
        }
      });
    });
  });
}
