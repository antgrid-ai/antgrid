// app/test/providers/local_host_warmup_test.dart
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
    show defaultRelayUrlProvider;
import 'package:antgrid/services/auth_service.dart' show CurrentUser;
import 'package:antgrid/services/keychain_device_store.dart';

class _RecordingLauncher extends LocalAgentLauncher {
  _RecordingLauncher()
    : super(
        host: HostController(spawnHost: () async => throw UnimplementedError()),
      );
  final calls = <({bool hasDevice, bool forceRespawn})>[];
  @override
  Future<void> warmHost({
    DeviceRecord? device,
    String? licenseApiUrl,
    String? relayUrl,
    bool forceRespawn = false,
  }) async {
    calls.add((hasDevice: device != null, forceRespawn: forceRespawn));
  }
}

DeviceRecord _device() => DeviceRecord(
  userId: 'u-1',
  deviceUuid: 'uuid-1',
  clientId: 'cid',
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

      // Simulate sign-in: device now provisioned + currentUser non-null. Flipping
      // _authState re-resolves currentUserProvider, which fires the warm-up's listener.
      stored = _device();
      container.read(_authState.notifier).set(
        CurrentUser(userId: 'u-1', email: 'a@b.c', tier: 'pro'),
      );
      await _settle();

      // Second call: force-respawn carrying the device.
      expect(launcher.calls.last, (hasDevice: true, forceRespawn: true));
      expect(launcher.calls.length, 2);
    },
  );

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
      ],
    );
    addTearDown(container.dispose);

    container.listen(localHostWarmupProvider, (_, _) {}); // must not throw synchronously
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
  }) async {
    throw StateError('spawn boom');
  }
}

// KeychainDeviceStore (app/lib/services/keychain_device_store.dart:65) is a
// concrete class; a fake must implement ALL its public methods — read,
// readIfMatchesUser, write, clear — or it won't satisfy the implicit interface.
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
}
