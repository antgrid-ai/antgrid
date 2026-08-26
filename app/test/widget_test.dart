import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/main.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_revocation.dart';
import 'package:antgrid/providers/value_controller.dart';
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
    bool revoked = false,
    bool settledUser = false,
  }) {
    return ProviderScope(
      overrides: [
        ...stores.overrides,
        revokedNoticeProvider.overrideWith(() => ValueController(revoked)),
        // A FutureProvider whose create returns synchronously is `AsyncData`
        // from the very first read, so a `ref.listen` on it never observes a
        // change — which is exactly the state a failed sign-out teardown
        // leaves behind. The default async form resolves a frame later and
        // does fire the listener.
        if (settledUser)
          currentUserProvider.overrideWith(
            (_) => signedIn ? _user(tier: tier) : null,
          )
        else
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
      // The reviewer's only way in — this screen is the whole app on mobile
      // until an account exists, so losing the link is a 2.1 rejection.
      expect(find.text('Explore a sample project'), findsOneWidget);
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

      // The lockup is the sole brand element on sign-in; the tile mark
      // (launcher/splash identity) must not double-brand the screen.
      expect(
        find.byWidgetPredicate(
          (w) => hasAsset(w, 'assets/logo/antgrid-lockup.svg'),
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

  // The one exception to "desktop is never gated". Same inputs as the test
  // above — which lands in AppShell — plus the revoked notice: a device the
  // account revoked has no credentials left, so leaving it in the shell would
  // show a workspace it can no longer reach.
  testWidgets('a revoked desktop device is forced to SignInScreen', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(
        buildApp(width: 800, signedIn: false, revoked: true),
      );
      await tester.pump();

      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
      // The plain sign-in screen is the whole remedy — no revocation copy.
      expect(find.textContaining('revoked'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // A `hardSignOut` that throws never reaches performHardSignOut's
  // invalidations, so currentUserProvider stays settled and non-null — while
  // handleDeviceRevoked has already raised the notice from its `finally`. The
  // sign-in screen's `ref.listen` fires only on CHANGE, so without the mount
  // check the notice pins the root here with nothing able to retire it.
  testWidgets('a revoked device with a surviving session is not stuck', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(
        buildApp(width: 800, signedIn: true, revoked: true, settledUser: true),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SignInScreen), findsNothing);
      expect(find.byType(AppShell), findsOneWidget);
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
