// app/test/navigation/platform_route_guard_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/platform_route_guard.dart';

/// The OAuth return leg, as Android hands it to the navigation channel.
const _authCallback = 'antgrid://auth/callback?token=one-time-token';

void main() {
  // The shell under test is the framework configuration, not our widget tree:
  // `home` only, no routes table, no onGenerateRoute, no onUnknownRoute — what
  // AbApp builds.
  Future<void> pumpShell(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: SizedBox()));

  // `handlePushRoute` is the binding's own test seam onto the observer walk the
  // navigation channel drives — same list, same first-true-wins semantics.
  Future<bool> pushRoute(WidgetTester tester, String location) =>
      // ignore: invalid_use_of_protected_member
      tester.binding.handlePushRoute(location);

  testWidgets('guard swallows a deep-link route push', (tester) async {
    final guard = PlatformRouteGuard();
    // Added before pumpWidget, exactly as main() adds it before runApp: the
    // binding stops at the first observer returning true, so being registered
    // ahead of WidgetsApp is the whole mechanism.
    WidgetsBinding.instance.addObserver(guard);
    addTearDown(() => WidgetsBinding.instance.removeObserver(guard));

    await pumpShell(tester);

    expect(await pushRoute(tester, _authCallback), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without the guard the same push blows up', (tester) async {
    await pumpShell(tester);
    await pushRoute(tester, _authCallback);

    // WidgetsApp pushes the unmatched path and reaches its null onUnknownRoute.
    // Asserts are live under `flutter test`, so the failure surfaces as the
    // FlutterError the assert throws; a release build strips that assert and
    // dies one line later on `widget.onUnknownRoute!` — the null-check
    // TypeError that shipped as a fatal in 1.20677.173.
    expect(
      tester.takeException(),
      isA<FlutterError>().having(
        (e) => e.message,
        'message',
        contains('onUnknownRoute'),
      ),
    );
  });
}
