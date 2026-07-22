import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/subscription_info.dart';
import 'package:antgrid/providers/subscription.dart';
import 'package:antgrid/screens/upgrade_screen.dart';

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
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
      sessionLimit: 2,
      recurring: true,
      trial: true,
      priceDisplay: r'$49',
    ),
    PricingPlan(
      slug: 'pro_yearly',
      label: 'Pro Yearly',
      sessionLimit: 10,
      recurring: true,
      trial: false,
      priceDisplay: r'$49',
    ),
    PricingPlan(
      slug: 'pro_lifetime',
      label: 'Pro Lifetime',
      sessionLimit: 10,
      recurring: false,
      trial: false,
      priceDisplay: r'$99',
    ),
  ],
  trialDays: 7,
  yearlyPriceDisplay: r'$49',
);

void main() {
  testWidgets(
    'shows plan cards all marked Coming soon, with no current-plan or promo reveal',
    (tester) async {
      // Tall viewport so the ListView builds every card without scrolling.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(
          const UpgradeScreen(),
          overrides: [
            pricingCatalogProvider.overrideWith((ref) async => _catalog()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Plans are visible (not hidden)...
      expect(find.text('Pro Yearly'), findsOneWidget);
      expect(find.text('Pro Lifetime'), findsOneWidget);
      // ...but every CTA is a static "Coming soon", never a live checkout button.
      expect(find.text('Coming soon'), findsNWidgets(3));
      expect(find.text('Get Pro Yearly'), findsNothing);
      expect(find.text('Get Lifetime Access'), findsNothing);
      // No indication of the account's actual (promotional) entitlement.
      expect(find.text('Current plan'), findsNothing);
      expect(find.textContaining('promotion'), findsNothing);
      expect(find.textContaining('already have'), findsNothing);
    },
  );
}
