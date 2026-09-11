// app/test/providers/local_host_warmup_test.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/local_agent_launcher.dart';
import 'package:antgrid/providers/agent_transport.dart'
    show localAgentLauncherProvider;
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart'
    show keychainDeviceStoreProvider;
import 'package:antgrid/providers/local_host_warmup.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/app_settings_service.dart'
    show defaultRelayUrlProvider, telemetryEnabledProvider;
import 'package:antgrid/services/auth_service.dart' show CurrentUser;
import 'package:antgrid/services/keychain_device_store.dart';

class _RecordingLauncher extends LocalAgentLauncher {
  _RecordingLauncher()
    : super(
        host: HostController(spawnHost: () async => throw UnimplementedError()),
      );
  final calls = <({bool hasDevice, bool forceRespawn})>[];

  /// Which OAuth client each spawn carried — the host caches this pair for its
  /// whole lifetime, so a respawn that reuses a rotated-away client is the bug
  /// these tests guard.
  final clientIds = <String?>[];

  /// The consent the provider read for each spawn — pinned because a host that
  /// reports without it is the failure this whole path exists to prevent.
  final telemetryFlags = <bool>[];

  /// When set, warmHost records its call then parks until completed — holds a
  /// respawn open so a second event can be delivered mid-flight.
  Completer<void>? block;

  @override
  Future<void> warmHost({
    DeviceRecord? device,
    String? licenseApiUrl,
    String? relayUrl,
    bool forceRespawn = false,
    bool telemetryEnabled = false,
  }) async {
    calls.add((hasDevice: device != null, forceRespawn: forceRespawn));
    clientIds.add(device?.clientId);
    telemetryFlags.add(telemetryEnabled);
    final gate = block;
    if (gate != null) await gate.future;
  }
}

DeviceRecord _device({String clientId = 'cid'}) => DeviceRecord(
  userId: 'u-1',
  deviceUuid: 'uuid-1',
  clientId: clientId,
  clientSecret: 'csec',
  ed25519Pub: 'e-pub',
  ed25519Priv: 'e-priv',
  x25519Pub: 'x-pub',
  x25519Priv: 'x-priv',
);

// Two microtask turns: enough for a FutureProvider override returning a sync
// value to propagate through `.future` → AsyncData → the `ref.listen` callback.
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

// `currentUserProvider` is a FutureProvider<CurrentUser?> (app/lib/providers/auth.dart:22),
// so it can't be overridden with a Stream. Back it with a StateProvider we can
// flip mid-test: overriding the FutureProvider to `ref.watch` this StateProvider
// makes it re-resolve (and re-emit AsyncData) whenever we mutate the state.
final _authState =
    NotifierProvider<ValueController<CurrentUser?>, CurrentUser?>(
      () => ValueController(null),
    );

void main() {
  late TargetPlatform? prevPlatform;
  setUp(() {
    prevPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows; // desktop
  });
  tearDown(() => debugDefaultTargetPlatformOverride = prevPlatform);

  test(
    'signed-out launch warms machine-less; sign-in force-respawns with device',
    () async {
      final launcher = _RecordingLauncher();
      // A keychain that starts empty, then returns a device after "sign-in".
      DeviceRecord? stored;
      final keychain = _FakeKeychain(read: () async => stored);

      final container = ProviderContainer(
        overrides: [
          localAgentLauncherProvider.overrideWithValue(launcher),
          keychainDeviceStoreProvider.overrideWithValue(keychain),
          currentUserProvider.overrideWith(
            (ref) => ref.watch(_authState),
          ), // signed out
          defaultRelayUrlProvider.overrideWithValue('ws://test.relay'),
          licenseApiUrlProvider.overrideWithValue('http://test.license'),
          telemetryEnabledProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);

      // `listen` (not a bare `read`) keeps the hook's internal
      // `ref.listen(currentUserProvider, ...)` live: riverpod 3 deactivates a
      // provider's own dependency subscriptions once it has zero listeners,
      // and `read` closes its subscription immediately after resolving.
      container.listen(localHostWarmupProvider, (_, _) {});
      await _settle();

      // Initial warm-up: machine-less, no respawn.
      expect(launcher.calls, [(hasDevice: false, forceRespawn: false)]);
      // The provider must READ the setting and hand it down; dropping the
      // argument would leave the host permanently unable to report.
      expect(launcher.telemetryFlags, [isTrue]);

      // Simulate sign-in: device now provisioned + currentUser non-null. Flipping
      // _authState re-resolves currentUserProvider, which fires the warm-up's listener.
      stored = _device();
      container
          .read(_authState.notifier)
          .set(CurrentUser(userId: 'u-1', email: 'a@b.c', tier: 'pro'));
      await _settle();

      // Second call: force-respawn carrying the device.
      expect(launcher.calls.last, (hasDevice: true, forceRespawn: true));
      expect(launcher.calls.length, 2);
    },
  );

  // The host reads its OAuth credentials once, from its stdin bootstrap, and
  // never re-reads them. Signing out rotates the account device and the web
  // deletes its OAuth client, so a host left running on the old pair mints
  // nothing, never reaches the relay, and shows up on phones as offline
  // forever. Only a respawn can hand it the new pair.
  test(
    'sign-in with a ROTATED device respawns the already-device-bearing host',
    () async {
      final launcher = _RecordingLauncher();
      var stored = _device(clientId: 'cid-old');
      final keychain = _FakeKeychain(read: () async => stored);

      final container = ProviderContainer(
        overrides: [
          localAgentLauncherProvider.overrideWithValue(launcher),
          keychainDeviceStoreProvider.overrideWithValue(keychain),
          currentUserProvider.overrideWith((ref) => ref.watch(_authState)),
          defaultRelayUrlProvider.overrideWithValue('ws://test.relay'),
          licenseApiUrlProvider.overrideWithValue('http://test.license'),
          telemetryEnabledProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);

      container.listen(localHostWarmupProvider, (_, _) {});
      await _settle();
      expect(launcher.clientIds, ['cid-old']);

      // Sign out and back in: same user, brand-new device + OAuth client.
      stored = _device(clientId: 'cid-new');
      container
          .read(_authState.notifier)
          .set(CurrentUser(userId: 'u-1', email: 'a@b.c', tier: 'pro'));
      await _settle();

      expect(launcher.calls.last, (hasDevice: true, forceRespawn: true));
      expect(launcher.clientIds, ['cid-old', 'cid-new']);
    },
  );

  // currentUserProvider is invalidated on app resume as well as on sign-in
  // (main.dart, sign_in_screen.dart), so two AsyncData emissions can land
  // inside one respawn's window. spawnedClientId only updates when warmHost
  // returns, so without an in-flight guard the second event re-passes the
  // mismatch check and tears the host down a second time.
  test('overlapping sign-in events respawn only once', () async {
    final launcher = _RecordingLauncher();
    var stored = _device(clientId: 'cid-old');
    final keychain = _FakeKeychain(read: () async => stored);

    final container = ProviderContainer(
      overrides: [
        localAgentLauncherProvider.overrideWithValue(launcher),
        keychainDeviceStoreProvider.overrideWithValue(keychain),
        currentUserProvider.overrideWith((ref) => ref.watch(_authState)),
        defaultRelayUrlProvider.overrideWithValue('ws://test.relay'),
        licenseApiUrlProvider.overrideWithValue('http://test.license'),
        telemetryEnabledProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);

    container.listen(localHostWarmupProvider, (_, _) {});
    await _settle();
    expect(launcher.clientIds, ['cid-old']);

    stored = _device(clientId: 'cid-new');
    final notifier = container.read(_authState.notifier);

    // Park the first respawn inside warmHost, so spawnedClientId is still
    // 'cid-old' when the second event arrives — the exact window a resume
    // landing on the heels of a sign-in falls into.
    final gate = Completer<void>();
    launcher.block = gate;
    notifier.set(CurrentUser(userId: 'u-1', email: 'a@b.c', tier: 'pro'));
    await _settle();
    expect(launcher.clientIds, ['cid-old', 'cid-new']); // respawn in flight

    // Distinct email so this is a second emission, not a deduped rebuild.
    notifier.set(CurrentUser(userId: 'u-1', email: 'a2@b.c', tier: 'pro'));
    await _settle();
    await _settle();

    gate.complete();
    await _settle();

    // Without the in-flight guard the second event finds spawnedClientId still
    // 'cid-old' and force-respawns again → a third entry.
    expect(launcher.clientIds, ['cid-old', 'cid-new']);
  });

  test('sign-in on the SAME device does not respawn', () async {
    final launcher = _RecordingLauncher();
    final keychain = _FakeKeychain(
      read: () async => _device(clientId: 'cid-1'),
    );

    final container = ProviderContainer(
      overrides: [
        localAgentLauncherProvider.overrideWithValue(launcher),
        keychainDeviceStoreProvider.overrideWithValue(keychain),
        currentUserProvider.overrideWith((ref) => ref.watch(_authState)),
        defaultRelayUrlProvider.overrideWithValue('ws://test.relay'),
        licenseApiUrlProvider.overrideWithValue('http://test.license'),
        telemetryEnabledProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);

    container.listen(localHostWarmupProvider, (_, _) {});
    await _settle();

    container
        .read(_authState.notifier)
        .set(CurrentUser(userId: 'u-1', email: 'a@b.c', tier: 'pro'));
    await _settle();

    // A respawn tears down the live host (and any open project's loopback
    // transport), so an unchanged device must not trigger one.
    expect(launcher.calls, [(hasDevice: true, forceRespawn: false)]);
  });

  test('warm-up failure is swallowed (does not throw)', () async {
    final launcher = _ThrowingLauncher();
    final container = ProviderContainer(
      overrides: [
        localAgentLauncherProvider.overrideWithValue(launcher),
        keychainDeviceStoreProvider.overrideWithValue(
          _FakeKeychain(read: () async => null),
        ),
        currentUserProvider.overrideWith((ref) => ref.watch(_authState)),
        defaultRelayUrlProvider.overrideWithValue('ws://test.relay'),
        // Present so the swallowed failure is the launcher's own throw, not an
        // unresolved provider read on the way to it.
        telemetryEnabledProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);

    container.listen(
      localHostWarmupProvider,
      (_, _) {},
    ); // must not throw synchronously
    await _settle(); // the swallowed async failure must not surface here either
    // Provider<void> — the meaningful signal is that read + settle completed without
    // rethrowing. Verify the provider built by confirming it has a value in state.
    expect(container.exists(localHostWarmupProvider), isTrue);
  });

  test('mobile is a no-op (no warm-up)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final launcher = _RecordingLauncher();
    final container = ProviderContainer(
      overrides: [
        localAgentLauncherProvider.overrideWithValue(launcher),
        keychainDeviceStoreProvider.overrideWithValue(
          _FakeKeychain(read: () async => null),
        ),
        currentUserProvider.overrideWith((ref) => ref.watch(_authState)),
        defaultRelayUrlProvider.overrideWithValue('ws://test.relay'),
      ],
    );
    addTearDown(container.dispose);
    container.listen(localHostWarmupProvider, (_, _) {});
    await _settle();
    expect(launcher.calls, isEmpty);
  });
}

class _ThrowingLauncher extends LocalAgentLauncher {
  _ThrowingLauncher()
    : super(
        host: HostController(spawnHost: () async => throw UnimplementedError()),
      );
  @override
  Future<void> warmHost({
    DeviceRecord? device,
    String? licenseApiUrl,
    String? relayUrl,
    bool forceRespawn = false,
    bool telemetryEnabled = false,
  }) async {
    throw StateError('spawn boom');
  }
}

// KeychainDeviceStore is a concrete class; a fake must implement ALL its public
// methods — both the main and the controller slot — or it won't satisfy the
// implicit interface. Only the main slot is exercised here (local-host warm-up
// never reads the remote-control controller record).
class _FakeKeychain implements KeychainDeviceStore {
  _FakeKeychain({required Future<DeviceRecord?> Function() read})
    : _read = read;
  final Future<DeviceRecord?> Function() _read;
  @override
  Future<DeviceRecord?> read() => _read();
  @override
  Future<DeviceRecord?> readIfMatchesUser(String userId) => _read();
  @override
  Future<void> write(DeviceRecord record) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<DeviceRecord?> readController() async => null;
  @override
  Future<DeviceRecord?> readControllerIfMatchesUser(String userId) async =>
      null;
  @override
  Future<void> writeController(DeviceRecord record) async {}
  @override
  Future<void> clearController() async {}
}
