import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/subscription_info.dart';
import 'package:antgrid/providers/subscription.dart';
import 'package:antgrid/screens/upgrade_screen.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Widget _wrap(
  Widget child, {
  List<Override> overrides = const [],
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [
      pricingCatalogProvider.overrideWith((ref) async => _catalog()),
      ...overrides,
    ],
    child: MaterialApp(
      theme: buildAbTheme(),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
      home: child,
    ),
  );
}

PricingCatalog _catalog() => PricingCatalog(
  plans: [
    PricingPlan(
      slug: 'trial',
      label: 'Trial',
      workerLimit: 2,
      recurring: true,
      trial: true,
      priceDisplay: r'$49',
    ),
    PricingPlan(
      slug: 'pro_yearly',
      label: 'Pro Yearly',
      workerLimit: 3,
      recurring: true,
      trial: false,
      priceDisplay: r'$49',
    ),
  ],
  trialDays: 7,
  yearlyPriceDisplay: r'$49',
);

/// Pumps the screen at [size] under [platform], then hands [body] control. The
/// platform override is cleared inside the body: the binding asserts every
/// foundation debug variable is unset before tearDown.
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required TargetPlatform platform,
  double textScale = 1,
  required Future<void> Function() body,
}) async {
  try {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(const UpgradeScreen(), textScale: textScale),
    );
    await tester.pumpAndSettle();
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Finder _cta() => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.label == 'Available after beta',
);

// The Pro card's price line; the trial banner's sentence also names the price.
Finder _priceText() => find.byWidgetPredicate(
  (w) => w is Text && (w.textSpan?.toPlainText().startsWith(r'$49') ?? false),
);

void main() {
  testWidgets(
    'shows plan cards all marked unbuyable, with no current-plan or promo reveal',
    (tester) async {
      // Tall viewport so the scroll view builds every card without scrolling.
      await _pump(
        tester,
        size: const Size(800, 2400),
        platform: TargetPlatform.windows,
        body: () async {
          // Plans are visible (not hidden)...
          expect(find.text('Pro Yearly'), findsOneWidget);
          // ...but every CTA is static and unbuyable, never a live checkout
          // button. The label names the beta rather than saying "Coming soon":
          // the user arrived from a site that told them the beta is free, and
          // an unexplained disabled button reads as half-built instead.
          expect(find.text('Available after beta'), findsNWidgets(2));
          expect(find.text('Coming soon'), findsNothing);
          expect(find.text('Get Pro Yearly'), findsNothing);
          // No indication of the account's actual (promotional) entitlement.
          expect(find.text('Current plan'), findsNothing);
          expect(find.textContaining('promotion'), findsNothing);
          expect(find.textContaining('already have'), findsNothing);
        },
      );
    },
  );

  testWidgets('the screen draws no Ab widget inside its Carbon scope', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      body: () async => expect(abWidgetsInScope(tester), isEmpty),
    );
  });

  testWidgets('no plan text sits under a faded container', (tester) async {
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      body: () async {
        // Carbon never fades a container: the faded price failed contrast, so
        // the card titles and the price must be at full strength.
        for (final text in ['Pro Yearly', r'$49', 'Simple, honest pricing']) {
          final finder = find.textContaining(text).first;
          final faded = find.ancestor(
            of: finder,
            matching: find.byWidgetPredicate(
              (w) => w is Opacity && w.opacity < 1,
            ),
          );
          expect(faded, findsNothing, reason: '$text is faded');
        }
        expect(find.byType(FadeTransition), findsNothing);
        // Both plan cards render, trial banner and Pro card.
        expect(find.byType(CarbonLayerSurface), findsNWidgets(2));
      },
    );
  });

  testWidgets('each CTA is a disabled, full-width Carbon button', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      body: () async {
        expect(_cta(), findsNWidgets(2));
        for (final button in tester.widgetList<CarbonButton>(_cta())) {
          expect(button.onPressed, isNull);
          expect(button.expand, isTrue);
        }
        // Full width inside its card, less the card's own padding.
        final card = tester.getSize(find.byType(CarbonLayerSurface).last);
        final cta = tester.getSize(_cta().last);
        expect(cta.width, card.width - 2 * CarbonSpacing.spacing05);
      },
    );
  });

  testWidgets('each CTA reports disabled to assistive tech', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      body: () async {
        for (var i = 0; i < 2; i++) {
          expect(
            tester.getSemantics(_cta().at(i)),
            isSemantics(hasEnabledState: true, isEnabled: false),
          );
        }
      },
    );
    handle.dispose();
  });

  testWidgets('the price is set in Plex Sans, not mono', (tester) async {
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      body: () async {
        final text = tester.widget<Text>(_priceText());
        final style = (text.textSpan! as TextSpan).children!.first.style!;
        expect(
          style.fontFamily,
          'packages/${CarbonTypography.package}/${CarbonTypography.sansFamily}',
        );
      },
    );
  });

  testWidgets('the price and its suffix share one text baseline', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      body: () async {
        // Two spans of one paragraph share a baseline; separate Text widgets
        // bottom-aligned in a Wrap do not, because their leading differs.
        final text = tester.widget<Text>(_priceText());
        expect(text.textSpan!.toPlainText(), contains('/ seat / year'));
      },
    );
  });

  testWidgets('the feature checkmark stays on the first line at 2x text', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      textScale: 2,
      body: () async {
        final icon = find
            .byWidgetPredicate(
              (w) => w is CarbonIcon && w.icon == CarbonIcons.checkmark,
            )
            .first;
        final row = find.ancestor(of: icon, matching: find.byType(Row)).first;
        final textFinder = find.descendant(
          of: row,
          matching: find.byType(RichText),
        );
        final paragraph = tester.renderObject<RenderParagraph>(textFinder.first);
        final box = paragraph
            .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
            .first;
        final lineCentre = paragraph.localToGlobal(Offset(0, box.toRect().center.dy)).dy;
        expect(tester.getCenter(icon).dy, closeTo(lineCentre, 2));
      },
    );
  });

  testWidgets('the trial plan carries a Carbon tag', (tester) async {
    await _pump(
      tester,
      size: const Size(800, 2400),
      platform: TargetPlatform.windows,
      body: () async {
        expect(
          find.byWidgetPredicate(
            (w) => w is CarbonTag && w.label == 'FREE TRIAL',
          ),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets('a phone fills its width less 16px gutters, at 2x text', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(320, 640),
      platform: TargetPlatform.iOS,
      textScale: 2,
      body: () async {
        expect(tester.takeException(), isNull);
        final card = tester.getRect(find.byType(CarbonLayerSurface).first);
        expect(card.left, 16);
        expect(card.right, 320 - 16);
        // The close button is a 44pt target, not a hand-sized one.
        final close = tester.getSize(find.byType(CarbonButton).first);
        expect(close.shortestSide, greaterThanOrEqualTo(44));
      },
    );
  });

  testWidgets('a desktop window caps the column and centres it', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(1040, 720),
      platform: TargetPlatform.windows,
      body: () async {
        expect(tester.takeException(), isNull);
        final card = tester.getRect(find.byType(CarbonLayerSurface).first);
        expect(card.width, 640);
        expect(card.center.dx, 520);
      },
    );
  });
}
