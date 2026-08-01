import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/design/widgets/ab_segmented.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/widgets/remote_access_panel.dart';

class _FakeNotifier extends RemoteDevicesNotifier {
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

class _EmptyNotifier extends RemoteDevicesNotifier {
  @override
  Future<PhonesList> build() async =>
      const PhonesList(phones: [], knownProjects: []);
}

class _FakePolicyNotifier extends RemoteAccessPolicyNotifier {
  _FakePolicyNotifier(this._enabled);
  final bool _enabled;
  final List<bool> writes = [];
  @override
  Future<RemoteAccessPolicy> build() async => RemoteAccessPolicy(enabled: _enabled);
  @override
  Future<void> setEnabled(bool enabled) async => writes.add(enabled);
}

/// Pumps the panel with both providers faked. The real
/// [remoteAccessPolicyProvider] would reach for the loopback host through
/// `ensureHost()`, so it must be overridden even in tests that only care about
/// the device roster.
Future<void> _pumpPanel(
  WidgetTester tester, {
  required RemoteDevicesNotifier Function() devices,
  RemoteAccessPolicyNotifier Function()? policy,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      remoteDevicesProvider.overrideWith(devices),
      remoteAccessPolicyProvider.overrideWith(
        policy ?? () => _FakePolicyNotifier(false),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: RemoteAccessPanel())),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('lists a connected device as identity only; Forget is its one action',
      (tester) async {
    final fake = _FakeNotifier();
    await _pumpPanel(tester, devices: () => fake);

    expect(find.text('iPhone'), findsOneWidget);
    // Access is machine-wide, so no project ever appears against a device.
    expect(find.text('Proj One'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('forget-pk-1')));
    await tester.pump();
    expect(fake.unpaired, ['pk-1']);
  });

  testWidgets('the switch shows both options and turning OFF needs no confirm',
      (tester) async {
    final policy = _FakePolicyNotifier(true);
    await _pumpPanel(tester, devices: _FakeNotifier.new, policy: () => policy);

    expect(find.text('REMOTE ACCESS'), findsOneWidget);
    expect(find.byType(AbSegmented<bool>), findsOneWidget);
    // Both states visible: the switch is a decision, not a status.
    expect(find.text('OFF'), findsOneWidget);
    expect(find.text('ON'), findsOneWidget);

    await tester.tap(find.text('OFF'));
    await tester.pump();
    // Withdrawing access must never be slower than the fear that prompted it.
    expect(policy.writes, [false]);
  });

  testWidgets('turning ON is confirmed before anything is written',
      (tester) async {
    final policy = _FakePolicyNotifier(false);
    await _pumpPanel(tester, devices: _FakeNotifier.new, policy: () => policy);

    await tester.tap(find.text('ON'));
    await tester.pumpAndSettle();
    expect(policy.writes, isEmpty, reason: 'the dialog must gate the write');

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(policy.writes, [true]);
  });

  testWidgets('the switch stays reachable when no device has ever connected',
      (tester) async {
    // The switch is what grants access, so it must not be gated on the roster
    // being non-empty — otherwise a fresh machine has no way to turn it on.
    await _pumpPanel(tester, devices: _EmptyNotifier.new);

    expect(find.byKey(const Key('remote-access-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-panel-pair-cta')), findsOneWidget);
  });
}
