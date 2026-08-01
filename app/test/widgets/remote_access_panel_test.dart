import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_switch.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/widgets/remote_access_panel.dart';

class _FakeNotifier extends RemoteDevicesNotifier {
  final List<String> unpaired = [];
  @override
  Future<PhonesList> build() async => const PhonesList(
        // No label, matching the bridge: nothing writes `PairedPhone.label`,
        // so a readable name can only come from the account join.
        phones: [PairedPhoneSummary(
          phonePubkey: 'pk-1', phoneDeviceId: 'ph-1',
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

/// The account inventory the roster joins against. `ph-1` is the bridge-side
/// id of the one device [_FakeNotifier] lists.
final _accountDevices = <String, DeviceSummary>{
  'ph-1': DeviceSummary(
    id: 'acct-uuid-1',
    deviceId: 'ph-1',
    kind: 'app',
    platform: 'ios',
    displayName: 'iPhone',
  ),
};

/// Pumps the panel with every provider faked. The real
/// [remoteAccessPolicyProvider] would reach for the loopback host through
/// `ensureHost()`, and [accountDevicesByBridgeIdProvider] would hit the account
/// API, so both must be overridden even in tests that only care about the
/// roster.
Future<void> _pumpPanel(
  WidgetTester tester, {
  required RemoteDevicesNotifier Function() devices,
  RemoteAccessPolicyNotifier Function()? policy,
  Map<String, DeviceSummary>? accounts,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      remoteDevicesProvider.overrideWith(devices),
      remoteAccessPolicyProvider.overrideWith(
        policy ?? () => _FakePolicyNotifier(false),
      ),
      accountDevicesByBridgeIdProvider.overrideWith(
        (ref) async => accounts ?? _accountDevices,
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: RemoteAccessPanel())),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a device still on the account offers sign-out, not forget',
      (tester) async {
    final fake = _FakeNotifier();
    await _pumpPanel(tester, devices: () => fake);

    // The name is the ACCOUNT device's, joined on the bridge id — the bridge
    // itself only knows 'ph-1'.
    expect(find.text('iPhone'), findsOneWidget);
    // Access is machine-wide, so no project ever appears against a device.
    expect(find.text('Proj One'), findsNothing);

    // Clearing the local record is not a remedy for an account device: it
    // re-creates its row on the next connect. The row must not offer it.
    expect(find.byKey(const ValueKey('forget-pk-1')), findsNothing);
    expect(find.byKey(const ValueKey('signout-pk-1')), findsOneWidget);
  });

  testWidgets('a device the account no longer has offers forget instead',
      (tester) async {
    final fake = _FakeNotifier();
    await _pumpPanel(tester, devices: () => fake, accounts: const {});

    // With no account record there is no name either; the row falls back to
    // the bridge id rather than going nameless.
    expect(find.text('ph-1'), findsOneWidget);
    // Nothing left to revoke, so clearing the leftover row IS the whole
    // remedy — the one case where Forget is honest.
    expect(find.byKey(const ValueKey('signout-pk-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('forget-pk-1')));
    await tester.pump();
    expect(fake.unpaired, ['pk-1']);
  });

  testWidgets('turning OFF needs no confirm', (tester) async {
    final policy = _FakePolicyNotifier(true);
    await _pumpPanel(tester, devices: _FakeNotifier.new, policy: () => policy);

    expect(find.text('REMOTE ACCESS'), findsOneWidget);
    expect(tester.widget<AbSwitch>(find.byType(AbSwitch)).value, isTrue);

    await tester.tap(find.byType(AbSwitch));
    await tester.pump();
    // Withdrawing access must never be slower than the fear that prompted it.
    expect(policy.writes, [false]);
  });

  testWidgets('turning ON is confirmed before anything is written',
      (tester) async {
    final policy = _FakePolicyNotifier(false);
    await _pumpPanel(tester, devices: _FakeNotifier.new, policy: () => policy);

    await tester.tap(find.byType(AbSwitch));
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
    // QR pairing is hidden for the initial release; an account device admits
    // itself, so the empty roster has no action to offer.
    expect(find.byType(AbButton), findsNothing);
  });
}
