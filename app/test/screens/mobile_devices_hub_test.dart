import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
import 'package:antgrid/screens/mobile_devices_hub.dart';

class _FakeNotifier extends MobileDevicesHubNotifier {
  final List<(String, String)> denied = [];
  @override
  Future<PhonesList> build() async => const PhonesList(
        phones: [PairedPhoneSummary(
          phonePubkey: 'pk-1', phoneDeviceId: 'ph-1', label: 'iPhone',
          pairedAt: 'x', lastSeenAt: 'y',
          allowedProjects: ['p1'])],
        knownProjects: [
          KnownProject(projectId: 'p1', label: 'Proj One', path: '/p1', running: true),
          KnownProject(projectId: 'p2', label: 'Proj Two', path: '/p2', running: false),
        ],
      );
  @override
  Future<void> deny({required String phonePubkey, required String projectId}) async {
    denied.add((phonePubkey, projectId));
  }
}

void main() {
  testWidgets('renders a checked box for an allowed project; unchecking denies', (tester) async {
    final fake = _FakeNotifier();
    await tester.pumpWidget(ProviderScope(
      overrides: [mobileDevicesHubProvider.overrideWith(() => fake)],
      child: const MaterialApp(home: MobileDevicesHub()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('iPhone'), findsOneWidget);
    expect(find.text('Proj One'), findsOneWidget);
    expect(find.text('Proj Two'), findsOneWidget);

    // Tap the row/checkbox for the allowed project "p1" → deny.
    await tester.tap(find.byKey(const ValueKey('toggle-pk-1-p1')));
    await tester.pumpAndSettle();
    expect(fake.denied, [('pk-1', 'p1')]);
  });

  testWidgets('empty state shows the pair CTA when no phones are paired', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [mobileDevicesHubProvider.overrideWith(_EmptyNotifier.new)],
      child: const MaterialApp(home: MobileDevicesHub()),
    ));
    await tester.pumpAndSettle();
    final cta = find.byKey(const ValueKey('hub-empty-pair-cta'));
    expect(cta, findsOneWidget);
    // The CTA must be wired (not a disabled stub) so it can route to the
    // existing QR pairing surface.
    expect(tester.widget<AbButton>(cta).onTap, isNotNull);
  });
}

class _EmptyNotifier extends MobileDevicesHubNotifier {
  @override
  Future<PhonesList> build() async =>
      const PhonesList(phones: [], knownProjects: []);
}
