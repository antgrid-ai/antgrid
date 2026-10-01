import '../helpers/fixed_peer_connector.dart';
// Revoking a device from the web must sign THIS app out — the relay kicks the
// socket while it is live, and the token mint refuses its credentials once it isn't. These
// pin the three properties the feature rests on: the teardown runs exactly once
// however many machines report it, an inconclusive (offline) probe never signs
// anyone out, and LICENSE_INVALID stays a connection fault rather than an
// account verdict.
import 'dart:async';

import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/launcher/local_agent_launcher.dart' show AgentEvent;
import 'package:antgrid/providers/control_plane.dart'
    show hostControllerProvider;
import 'package:antgrid/providers/device_revocation.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/sign_out.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/license_token_minter.dart';
import 'package:antgrid/services/push_identity.dart';
import 'package:antgrid/services/sign_out_service.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/prefs_test_mock.dart';

class _MemAuthStorage implements AuthStorage {
  String? _cookie = 'better-auth.session_token=signed.value';
  @override
  Future<String?> readCookie() async => _cookie;
  @override
  Future<void> writeCookie(String v) async => _cookie = v;
  @override
  Future<void> clearCookie() async => _cookie = null;
  @override
  Future<String?> readPendingSignIn() async => null;
  @override
  Future<void> writePendingSignIn(String v) async {}
  @override
  Future<void> clearPendingSignIn() async {}
}

class _MemDeviceSecret implements DeviceSecretStorage {
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String v) async => _v = v;
  @override
  Future<void> delete() async => _v = null;
}

class _NoopPushIdentity implements PushIdentity {
  @override
  Future<void> clear() async {}
  @override
  Future<PushKeypair> ensureKeypair() async => throw UnimplementedError();
}

/// Real class, stubbed verb: the point under test is how many times the
/// teardown is *invoked*, not what it wipes (pinned in sign_out_service_test).
class _CountingSignOut extends SignOutService {
  _CountingSignOut(RecentAgentsStore recent)
    : super(
        authService: AuthService(
          licenseApiUrl: 'http://localhost:8787',
          storage: _MemAuthStorage(),
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        ),
        keychainStore: KeychainDeviceStore(
          storage: _MemDeviceSecret(),
          controllerStorage: _MemDeviceSecret(),
        ),
        devicesApi: DevicesApi(
          licenseApiUrl: 'http://localhost:8787',
          cookieProvider: () async => null,
        ),
        pushIdentity: _NoopPushIdentity(),
        recentAgentsStore: recent,
      );

  int calls = 0;

  @override
  Future<void> hardSignOut() async {
    calls++;
    // The real teardown awaits network + storage; a synchronous stub would hide
    // the concurrency the idempotence guard exists for.
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

LicenseTokenMinter _minter(Future<http.Response> Function() respond) =>
    LicenseTokenMinter(
      licenseApiUrl: 'http://localhost:8787',
      clientId: 'cid',
      clientSecret: 'secret',
      httpClient: MockClient((_) async => respond()),
    );

/// Only the streams `ensureStarted` subscribes to matter here; the ladder is
/// parked at the coords rung so nothing dials.
class _ErrorOnlyRelay extends RelayService {
  _ErrorOnlyRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _errors = StreamController<ErrorMessage>.broadcast();

  @override
  AppState get currentState => const AppState();
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  Stream<ErrorMessage> get errorStream => _errors.stream;

  void emit(String code) =>
      _errors.add(ErrorMessage(code: code, message: code, retryable: false));

  @override
  void dispose() => unawaited(closeStreams());

  Future<void> closeStreams() async {
    if (!_states.isClosed) await _states.close();
    if (!_presence.isClosed) await _presence.close();
    if (!_errors.isClosed) await _errors.close();
  }
}

/// Stands in for the host's stderr event tail.
class _EventHost extends HostController {
  _EventHost() : super(spawnHost: () async => throw UnimplementedError());
  final events = StreamController<AgentEvent>.broadcast();
  @override
  Stream<AgentEvent> get hostEvents => events.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingSignOut signOut;

  Future<ProviderContainer> containerWith({
    LicenseTokenMinter? minter,
    HostController? host,
  }) async {
    useInMemoryPrefs();
    signOut = _CountingSignOut(await RecentAgentsStore.open());
    final container = ProviderContainer(
      overrides: [
        signOutServiceProvider.overrideWithValue(signOut),
        licenseTokenMinterProvider.overrideWith((ref) async => minter),
        if (host != null) hostControllerProvider.overrideWithValue(host),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a 401 from the token endpoint signs the device out', () async {
    final container = await containerWith(
      minter: _minter(() async => http.Response('{"error":"x"}', 401)),
    );

    await checkDeviceRevoked(container);

    expect(signOut.calls, 1);
    expect(container.read(revokedNoticeProvider), isTrue);
  });

  test('400 invalid_client from a deleted device signs it out', () async {
    final container = await containerWith(
      minter: _minter(
        () async => http.Response('{"error":"invalid_client"}', 400),
      ),
    );
    await checkDeviceRevoked(container);
    expect(signOut.calls, 1);
    expect(container.read(revokedNoticeProvider), isTrue);
  });

  test('other 400 errors leave the session alone', () async {
    final container = await containerWith(
      minter: _minter(
        () async => http.Response('{"error":"invalid_scope"}', 400),
      ),
    );
    await checkDeviceRevoked(container);
    expect(signOut.calls, 0);
    expect(container.read(revokedNoticeProvider), isFalse);
  });

  test('an unreachable license service is NOT a revocation', () async {
    final container = await containerWith(
      minter: _minter(() async => throw http.ClientException('offline')),
    );

    await checkDeviceRevoked(container);

    expect(signOut.calls, 0);
    expect(container.read(revokedNoticeProvider), isFalse);
  });

  test('a 500 is inconclusive and leaves the session alone', () async {
    final container = await containerWith(
      minter: _minter(() async => http.Response('boom', 500)),
    );

    await checkDeviceRevoked(container);

    expect(signOut.calls, 0);
    expect(container.read(revokedNoticeProvider), isFalse);
  });

  test('an unprovisioned device has nothing to probe', () async {
    final container = await containerWith(minter: null);

    await checkDeviceRevoked(container);

    expect(signOut.calls, 0);
  });

  test('concurrent and repeated reports tear down exactly once', () async {
    final container = await containerWith();

    // One report per open machine socket, all in the same turn.
    await Future.wait([
      handleDeviceRevoked(container),
      handleDeviceRevoked(container),
      handleDeviceRevoked(container),
    ]);
    // And one more after the notice is already set.
    await handleDeviceRevoked(container);

    expect(signOut.calls, 1);
    expect(container.read(revokedNoticeProvider), isTrue);
  });

  test('the probe is skipped once the device is known revoked', () async {
    final container = await containerWith(
      minter: _minter(() async => http.Response('{"error":"x"}', 401)),
    );

    await handleDeviceRevoked(container);
    await checkDeviceRevoked(container);

    expect(signOut.calls, 1);
  });

  test('signing in again clears the notice, so a later revocation is '
      'handled afresh', () async {
    final container = await containerWith();

    await handleDeviceRevoked(container);
    clearRevokedNotice(container);
    expect(container.read(revokedNoticeProvider), isFalse);

    await handleDeviceRevoked(container);
    expect(signOut.calls, 2);
  });

  group('the local host reporting auth_revoked', () {
    Future<(ProviderContainer, _EventHost, void Function(int))>
    watching() async {
      // The watch is desktop-only, and this binding reports Android.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var status = 500;
      final host = _EventHost();
      addTearDown(host.events.close);
      final container = await containerWith(
        minter: _minter(() async => http.Response('{"error":"x"}', status)),
        host: host,
      );
      container.listen(hostRevocationWatchProvider, (_, _) {});
      return (container, host, (int s) => status = s);
    }

    test(
      'probes at once, inside the cooldown a resume probe just set',
      () async {
        final (container, host, respond) = await watching();
        // Inconclusive, but it starts the cooldown.
        await checkDeviceRevoked(container);
        expect(signOut.calls, 0);

        respond(401);
        host.events.add(AgentEvent('auth_revoked', const {}));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(signOut.calls, 1);
        expect(container.read(revokedNoticeProvider), isTrue);
      },
    );

    test(
      'lets the mint decide: credentials it still accepts stay signed in',
      () async {
        final (container, host, _) = await watching();
        host.events.add(AgentEvent('auth_revoked', const {}));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(signOut.calls, 0);
        expect(container.read(revokedNoticeProvider), isFalse);
      },
    );

    test('ignores the revoke that a sign-out of its own sets off', () async {
      final (container, host, respond) = await watching();
      respond(401);

      final signingOut = performHardSignOut(container);
      host.events.add(AgentEvent('auth_revoked', const {}));
      await signingOut;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(signOut.calls, 1, reason: 'one teardown: the user sign-out');
      expect(container.read(revokedNoticeProvider), isFalse);
    });
  });

  group('RelayConnection error classification', () {
    late _ErrorOnlyRelay relay;

    setUp(() => relay = _ErrorOnlyRelay());
    tearDown(() async => relay.closeStreams());

    MachineConnection started({required void Function() onRevoked}) {
      final conn = MachineConnection(
        machineDeviceId: 'M',
        crypto: CryptoService(),
        relayOverride: relay,
        onDeviceRevoked: onRevoked,
      );
      addTearDown(conn.dispose);
      conn.ensureStarted(
        mechanisms: PeerConnectionMechanisms(
          peerRuntime: FixedPeerConnector.stub(),
          machineDeviceId: 'M',
          // Null coords park the ladder before the dial: this test is about the
          // error stream, not the climb.
          resolveCoords: () async => null,
        ),
      );
      return conn;
    }

    test('LICENSE_REVOKED reports a revocation', () async {
      var revoked = 0;
      started(onRevoked: () => revoked++);

      relay.emit('LICENSE_REVOKED');
      await Future<void>.delayed(Duration.zero);

      expect(revoked, 1);
    });

    test('LICENSE_INVALID does not — it is a binding fault, which a coords or '
        'agent-pin bug produces just as easily', () async {
      var revoked = 0;
      started(onRevoked: () => revoked++);

      relay.emit('LICENSE_INVALID');
      relay.emit('LICENSE_EXPIRED');
      relay.emit('SUPERSEDED');
      relay.emit('AUTH_FAILED');
      await Future<void>.delayed(Duration.zero);

      expect(revoked, 0);
    });
  });
}
