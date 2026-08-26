// TDD: Task 5 — always carry machine creds into the host bootstrap.
//
// Drives the LOCAL path of agentTransportForProvider and asserts that
// device/licenseApiUrl/relayUrl are passed to LocalAgentLauncher.openProject
// whenever a device record exists in the keychain, unconditionally.
//
// Pattern mirrors agent_transport_test.dart: inject fakes via Riverpod
// overrides, poll a call counter (the fake's openProject resolves instantly
// but the provider body has multiple awaits; we don't await the full future).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/local_agent_launcher.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

// ---------------------------------------------------------------------------
// Fake KeychainDeviceStore — returns a pre-configured DeviceRecord or null.
// ---------------------------------------------------------------------------

class _InMemoryKeychainStore extends KeychainDeviceStore {
  final DeviceRecord? _record;
  _InMemoryKeychainStore(this._record) : super(storage: _NullStorage());

  @override
  Future<DeviceRecord?> read() async => _record;

  @override
  Future<void> write(DeviceRecord rec) async {}

  @override
  Future<void> clear() async {}
}

class _NullStorage implements DeviceSecretStorage {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String v) async {}
  @override
  Future<void> delete() async {}
}

// ---------------------------------------------------------------------------
// Fake LocalAgentLauncher — captures openProject args.
// Does NOT invoke the real HostController (overrides openProject entirely).
// ---------------------------------------------------------------------------

class _CapturingLauncher extends LocalAgentLauncher {
  int callCount = 0;
  DeviceRecord? capturedDevice;
  String? capturedLicenseApiUrl;
  String? capturedRelayUrl;

  // Provide a minimal HostController so the super() constructor doesn't fail;
  // openProject is fully overridden so _host is never used.
  _CapturingLauncher() : super(host: HostController());

  @override
  Future<LaunchResult> openProject(
    String folder, {
    DeviceRecord? device,
    String? licenseApiUrl,
    String? relayUrl,
  }) async {
    callCount++;
    capturedDevice = device;
    capturedLicenseApiUrl = licenseApiUrl;
    capturedRelayUrl = relayUrl;
    // Use a LocalTransport with port 0 / empty token — connect() is never
    // called, so _ch stays null and send/dispose are safe no-ops.
    return LaunchResult(
      transport: LocalTransport(port: 0, token: '', appPid: 0),
      agentPid: 0,
      owned: false,
      projectId: 'fake-project',
      events: const Stream.empty(),
    );
  }
}

// ---------------------------------------------------------------------------
// Stub notifiers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const _testLicenseApiUrl = 'http://test-license.example.com';
const _testRelayUrl = 'ws://test-relay.example.com';
const _localProjectId = 'local-test-project';
const _localFolder = '/tmp/test-project';

DeviceRecord _fakeDeviceRecord() => DeviceRecord(
  userId: 'user-123',
  deviceUuid: 'device-uuid-abc',
  clientId: 'client-id-xyz',
  clientSecret: 'client-secret-xyz',
  ed25519Pub: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  ed25519Priv:
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  x25519Pub: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  x25519Priv: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
);

AbProject _localProject() => AbProject(
  projectId: _localProjectId,
  displayName: 'Test Local Project',
  folder: _localFolder,
  hostDeviceUuid: null,
  hostMachineName: '',
  lastOpenedAt: DateTime.now(),
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('agentTransportForProvider — machine creds always carried', () {
    late TestStoreOverrides stores;
    late _CapturingLauncher fakeLauncher;

    setUp(() async {
      useInMemoryPrefs();
      stores = await buildTestStoreOverrides();
      fakeLauncher = _CapturingLauncher();
    });

    tearDown(() async {
      await stores.close();
    });

    List<Override> baseOverrides({
      DeviceRecord? keychainRecord,
      CurrentUser? signedInUser,
      Object? userError,
    }) => [
      ...stores.overrides,
      // No relay agents — fall through to local path.
      accountAgentsProvider.overrideWith((_) async => const <InventoryAgent>[]),
      localDeviceUuidProvider.overrideWith((_) async => 'local-uuid'),
      // Test seam introduced in Task 5.
      localAgentLauncherProvider.overrideWithValue(fakeLauncher),
      // Inject pre-configured keychain (avoids real secure storage).
      keychainDeviceStoreProvider.overrideWithValue(
        _InMemoryKeychainStore(keychainRecord),
      ),
      // Known URL values so the test can assert exact captured args.
      licenseApiUrlProvider.overrideWithValue(_testLicenseApiUrl),
      defaultRelayUrlProvider.overrideWithValue(_testRelayUrl),
      // Auth state. `userError` simulates a transient /account/me failure: the
      // future rejects rather than resolving null.
      currentUserProvider.overrideWith((_) async {
        if (userError != null) throw userError;
        return signedInUser;
      }),
    ];

    test(
      'always carries device/licenseApiUrl/relayUrl when a device record exists',
      () async {
        final container = ProviderContainer(
          overrides: baseOverrides(
            keychainRecord: _fakeDeviceRecord(),
            signedInUser: CurrentUser(
              userId: 'user-123',
              email: 'test@example.com',
              tier: 'pro',
            ),
          ),
        );
        addTearDown(container.dispose);

        await stores.projectStore.upsert(_localProject());

        // Trigger the transport build; poll the call counter.
        container.read(agentTransportForProvider(_localProjectId));
        for (var i = 0; i < 100 && fakeLauncher.callCount == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(
          fakeLauncher.callCount,
          greaterThan(0),
          reason: 'openProject must be called for a local project',
        );
        // Machine-level bootstrap always carries creds unconditionally.
        expect(
          fakeLauncher.capturedDevice,
          isNotNull,
          reason: 'device must be passed when a device record exists',
        );
        expect(
          fakeLauncher.capturedLicenseApiUrl,
          equals(_testLicenseApiUrl),
          reason: 'licenseApiUrl must be passed when a device record exists',
        );
        expect(
          fakeLauncher.capturedRelayUrl,
          equals(_testRelayUrl),
          reason: 'relayUrl must be passed when a device record exists',
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a transient auth failure does NOT block opening a local project',
      () async {
        // Signed in, but /account/me is transiently unreachable → the
        // currentUserProvider future REJECTS. Provisioning must be skipped, not
        // propagated: the local project still opens (with a null device).
        final container = ProviderContainer(
          overrides: baseOverrides(
            keychainRecord:
                null, // empty keychain → provisioning branch entered
            userError: Exception('account/me unreachable'),
          ),
        );
        addTearDown(container.dispose);

        await stores.projectStore.upsert(_localProject());

        container.read(agentTransportForProvider(_localProjectId));
        for (var i = 0; i < 100 && fakeLauncher.callCount == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(
          fakeLauncher.callCount,
          greaterThan(0),
          reason: 'a flaky auth fetch must not abort the local transport build',
        );
        expect(
          fakeLauncher.capturedDevice,
          isNull,
          reason: 'provisioning is skipped when the auth check fails',
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'passes null device when keychain is empty (signed-out path, no error)',
      () async {
        final container = ProviderContainer(
          overrides: baseOverrides(
            keychainRecord: null, // empty keychain
            signedInUser: null, // signed out — no provisioning attempt
          ),
        );
        addTearDown(container.dispose);

        await stores.projectStore.upsert(_localProject());

        container.read(agentTransportForProvider(_localProjectId));
        for (var i = 0; i < 100 && fakeLauncher.callCount == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(fakeLauncher.callCount, greaterThan(0));
        expect(
          fakeLauncher.capturedDevice,
          isNull,
          reason: 'device must be null when keychain is empty',
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
