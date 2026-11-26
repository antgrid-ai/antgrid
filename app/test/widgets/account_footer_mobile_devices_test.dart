import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/subscription.dart';
import 'package:antgrid/widgets/account_footer.dart';
import 'package:antgrid/services/auth_service.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  Future<void> pumpFooter(WidgetTester tester, {bool signedIn = false}) async {
    useInMemoryPrefs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith(
            (_) async => signedIn
                ? CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro')
                : null,
          ),
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

  for (final signedIn in [false, true]) {
    testWidgets('Help is directly below Settings when signedIn=$signedIn', (
      tester,
    ) async {
      await pumpFooter(tester, signedIn: signedIn);
      final settings = find.text('App settings…');
      expect(find.text('Help'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Help')).dy,
        greaterThan(tester.getTopLeft(settings).dy),
      );
      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
      expect(find.text('Chat with support'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Help'), findsOneWidget);
      expect(find.text('Chat with support'), findsNothing);
    });
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
