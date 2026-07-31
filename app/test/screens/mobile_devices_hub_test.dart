import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_mobile_cta.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
import 'package:antgrid/screens/mobile_devices_hub.dart';

class _FakeNotifier extends MobileDevicesHubNotifier {
  final List<String> unpaired = [];
  @override
  Future<PhonesList> build() async => const PhonesList(
        phones: [PairedPhoneSummary(
          phonePubkey: 'pk-1', phoneDeviceId: 'ph-1', label: 'iPhone',
          pairedAt: 'x', lastSeenAt: 'y')],
        knownProjects: [
          KnownProject(projectId: 'p1', label: 'Proj One', path: '/p1', running: true),
        ],
      );
  @override
  Future<void> unpair({required String phonePubkey}) async {
    unpaired.add(phonePubkey);
  }
}

class _EmptyNotifier extends MobileDevicesHubNotifier {
  @override
  Future<PhonesList> build() async =>
      const PhonesList(phones: [], knownProjects: []);
}

class _FakePolicyNotifier extends MobileAccessPolicyNotifier {
  _FakePolicyNotifier(this._enabled);
  final bool _enabled;
  final List<bool> writes = [];
  @override
  Future<MobileAccessPolicy> build() async => MobileAccessPolicy(enabled: _enabled);
  @override
  Future<void> setEnabled(bool enabled) async => writes.add(enabled);
}

/// Pumps the hub with both providers faked. The real
/// [mobileAccessPolicyProvider] would reach for the loopback host through
/// `ensureHost()`, so it must be overridden even in tests that only care about
/// the phone list.
Future<void> _pumpHub(
  WidgetTester tester, {
  required MobileDevicesHubNotifier Function() hub,
  MobileAccessPolicyNotifier Function()? policy,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mobileDevicesHubProvider.overrideWith(hub),
      mobileAccessPolicyProvider.overrideWith(
        policy ?? () => _FakePolicyNotifier(false),
      ),
    ],
    child: const MaterialApp(home: MobileDevicesHub()),
  ));
  // Not pumpAndSettle: an enabled AbMobileCta pulses forever and would time out.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('lists a connected phone as identity only; Unpair is its one action',
      (tester) async {
    final fake = _FakeNotifier();
    await _pumpHub(tester, hub: () => fake);

    expect(find.text('iPhone'), findsOneWidget);
    // Access is machine-wide now, so no project ever appears against a phone.
    expect(find.text('Proj One'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('unpair-pk-1')));
    await tester.pump();
    expect(fake.unpaired, ['pk-1']);
  });

  testWidgets('the machine switch renders above the roster and reflects the policy',
      (tester) async {
    final policy = _FakePolicyNotifier(true);
    await _pumpHub(tester, hub: _FakeNotifier.new, policy: () => policy);

    expect(find.text('Mobile access'), findsOneWidget);
    expect(find.byType(AbMobileCta), findsOneWidget);
    expect(find.text('Disable mobile access'), findsOneWidget);

    await tester.tap(find.byType(AbMobileCta));
    await tester.pump();
    expect(policy.writes, [false]);
  });

  testWidgets('the switch stays reachable when no phone has ever connected',
      (tester) async {
    // The switch is what grants access, so it must not be gated on the roster
    // being non-empty — otherwise a fresh machine has no way to turn mobile on.
    await _pumpHub(tester, hub: _EmptyNotifier.new);

    final cta = find.byKey(const ValueKey('hub-empty-pair-cta'));
    expect(cta, findsOneWidget);
    // The CTA must be wired (not a disabled stub) so it can route to the
    // existing QR pairing surface.
    expect(tester.widget<AbButton>(cta).onTap, isNotNull);
    expect(find.text('Enable mobile access'), findsOneWidget);
  });
}
