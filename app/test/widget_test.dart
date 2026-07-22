import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/main.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/screens/sign_in_screen.dart';
import 'package:antgrid/screens/upgrade_screen.dart';
import 'package:antgrid/services/auth_service.dart';

import 'helpers/test_store_overrides.dart';
import 'helpers/prefs_test_mock.dart';

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  Widget buildApp({
    required double width,
    bool signedIn = false,
    String tier = 'pro',
  }) {
    return ProviderScope(
      overrides: [
        ...stores.overrides,
        currentUserProvider.overrideWith(
          (_) async => signedIn ? _user(tier: tier) : null,
        ),
        hasStoredSessionProvider.overrideWith((_) async => signedIn),
        nativeUpgradePlatformProvider.overrideWith((_) => true),
      ],
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: const AbApp(),
      ),
    );
  }

  testWidgets('App launches without errors', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(width: 800));
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('mobile signed-out users see SignInScreen', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(buildApp(width: 400, signedIn: false));
      await tester.pump();

      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
      expect(find.text('Continue without signing in'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('sign-in brands with the wordmark only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(buildApp(width: 400, signedIn: false));
      await tester.pump();

      bool hasAsset(Widget w, String name) =>
          w is SvgPicture &&
          w.bytesLoader is SvgAssetLoader &&
          (w.bytesLoader as SvgAssetLoader).assetName == name;

      // The wordmark is the sole brand element on sign-in; the tile mark
      // (launcher/splash identity) must not double-brand the screen.
      expect(
        find.byWidgetPredicate(
          (w) => hasAsset(w, 'assets/logo/antgrid-wordmark.svg'),
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => hasAsset(w, 'assets/logo/antgrid-mark.svg'),
        ),
        findsNothing,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop signed-out users land in AppShell', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(buildApp(width: 800, signedIn: false));
      await tester.pump();

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('narrow desktop signed-out users still land in AppShell', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(buildApp(width: 400, signedIn: false));
      await tester.pump();

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile signed-in free users land in AppShell', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        buildApp(width: 400, signedIn: true, tier: 'free'),
      );
      await tester.pump();

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(UpgradeScreen), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile signed-in pro users land in AppShell', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        buildApp(width: 400, signedIn: true, tier: 'pro'),
      );
      await tester.pump();

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(UpgradeScreen), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

CurrentUser _user({required String tier}) =>
    CurrentUser(userId: 'user-1', email: 'dev@antgrid.local', tier: tier);
