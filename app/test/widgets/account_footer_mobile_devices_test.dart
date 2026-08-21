import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/subscription.dart';
import 'package:antgrid/widgets/account_footer.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  Future<void> pumpFooter(WidgetTester tester) async {
    useInMemoryPrefs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((_) async => null),
          subscriptionProvider.overrideWith((_) async => null),
          pricingCatalogProvider.overrideWith((_) async => null),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: AccountFooter(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AccountFooter));
    await tester.pumpAndSettle();
  }

  testWidgets('account footer menu omits Mobile devices on desktop', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpFooter(tester);
    expect(find.text('Mobile devices'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('account footer menu omits Mobile devices on mobile', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpFooter(tester);
    expect(find.text('Mobile devices'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
