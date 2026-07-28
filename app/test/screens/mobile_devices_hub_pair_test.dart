// The QR's `d=` carries the bare agent deviceUuid, never the compound
// `<deviceUuid>.<projectId>` slot id — RemoteConnectActions.scanAndConnect
// imports coordinates keyed by that bare id.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
import 'package:antgrid/screens/mobile_devices_hub.dart';

class _EmptyNotifier extends MobileDevicesHubNotifier {
  @override
  Future<PhonesList> build() async =>
      const PhonesList(phones: [], knownProjects: []);
}

/// Records the most recent push so the tap-CTA assertion can check it without
/// depending on ScannerScreen (which needs a camera platform view).
class _SpyObserver extends NavigatorObserver {
  Route<dynamic>? lastPushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastPushed = route;
  }
}

void main() {
  testWidgets('empty state shows same-account-first copy and pair CTA', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mobileDevicesHubProvider.overrideWith(_EmptyNotifier.new)],
        child: const MaterialApp(home: MobileDevicesHub()),
      ),
    );
    await tester.pumpAndSettle();

    // Same-account hint must appear.
    expect(
      find.textContaining(
        'same-account',
        findRichText: true,
        skipOffstage: false,
      ),
      findsAtLeast(1),
    );

    // QR path must also be mentioned.
    expect(
      find.textContaining('QR', findRichText: true, skipOffstage: false),
      findsAtLeast(1),
    );

    // Order by string index within the one subtitle string: both hints live in
    // the same Text widget, so a geometry compare is a tautology. Asserting
    // indexOf('same-account') < indexOf('QR') means reversing the copy fails.
    final subtitle = tester.widget<Text>(
      find.textContaining('same-account', skipOffstage: false),
    );
    final text = subtitle.data!;
    expect(
      text.indexOf('same-account'),
      lessThan(text.indexOf('QR')),
      reason: 'same-account hint must precede the QR mention in the subtitle',
    );

    // CTA is present and labelled correctly.
    final cta = find.byKey(const ValueKey('hub-empty-pair-cta'));
    expect(cta, findsOneWidget);
    expect(
      find.descendant(of: cta, matching: find.text('Pair a phone')),
      findsOneWidget,
    );
  });

  testWidgets('tapping pair CTA pushes a route (pairing surface opens)', (
    tester,
  ) async {
    final spy = _SpyObserver();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [mobileDevicesHubProvider.overrideWith(_EmptyNotifier.new)],
        child: MaterialApp(
          navigatorObservers: [spy],
          home: const MobileDevicesHub(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('hub-empty-pair-cta')));
    await tester.pump();

    // ScannerScreen uses a camera platform view which throws in tests; drain it.
    tester.takeException();

    expect(
      spy.lastPushed,
      isNotNull,
      reason: 'tapping the CTA must push the pairing surface',
    );
  });
}
