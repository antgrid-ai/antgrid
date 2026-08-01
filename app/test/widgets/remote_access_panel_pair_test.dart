// The QR's `d=` carries the bare agent deviceUuid, never the compound
// `<deviceUuid>.<projectId>` slot id — RemoteConnectActions.scanAndConnect
// imports coordinates keyed by that bare id.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/widgets/remote_access_panel.dart';

class _EmptyNotifier extends RemoteDevicesNotifier {
  @override
  Future<PhonesList> build() async =>
      const PhonesList(phones: [], knownProjects: []);
}

class _PolicyNotifier extends RemoteAccessPolicyNotifier {
  @override
  Future<RemoteAccessPolicy> build() async =>
      const RemoteAccessPolicy(enabled: false);
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

final _overrides = [
  remoteDevicesProvider.overrideWith(_EmptyNotifier.new),
  // The real policy provider would reach for the loopback host through
  // `ensureHost()`, so it must be faked even here.
  remoteAccessPolicyProvider.overrideWith(_PolicyNotifier.new),
];

void main() {
  testWidgets('empty roster leads with the automatic same-account path', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides,
        child: const MaterialApp(
          home: Scaffold(body: RemoteAccessPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Order by string index within the one note: both hints live in the same
    // Text widget, so a geometry compare is a tautology. Asserting the
    // automatic path is described before the scan path means reversing the
    // copy fails — scanning is the exception, not the instruction.
    final note = tester.widget<Text>(
      find.textContaining('signed in as you', skipOffstage: false),
    );
    final text = note.data!;
    expect(
      text.indexOf('signed in as you'),
      lessThan(text.indexOf('scan')),
      reason: 'the automatic path must precede the scan path',
    );

    final cta = find.byKey(const ValueKey('remote-panel-pair-cta'));
    expect(cta, findsOneWidget);
    expect(
      find.descendant(of: cta, matching: find.text('Scan a device')),
      findsOneWidget,
    );
  });

  testWidgets('tapping the scan CTA pushes a route (pairing surface opens)', (
    tester,
  ) async {
    final spy = _SpyObserver();

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides,
        child: MaterialApp(
          navigatorObservers: [spy],
          home: const Scaffold(body: RemoteAccessPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-panel-pair-cta')));
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
