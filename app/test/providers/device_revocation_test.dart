// Revoking a device from the web must sign THIS app out — the relay kicks the
// socket while it is live, and the token mint answers 401 once it isn't. These
// pin the three properties the feature rests on: the teardown runs exactly once
// however many machines report it, an inconclusive (offline) probe never signs
// anyone out, and LICENSE_INVALID stays a connection fault rather than an
// account verdict.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/connection/relay_mechanisms.dart';
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

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(64),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingSignOut signOut;

  Future<ProviderContainer> containerWith({LicenseTokenMinter? minter}) async {
    useInMemoryPrefs();
    signOut = _CountingSignOut(await RecentAgentsStore.open());
    final container = ProviderContainer(
      overrides: [
        signOutServiceProvider.overrideWithValue(signOut),
        licenseTokenMinterProvider.overrideWith((ref) async => minter),
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

  group('RelayConnection error classification', () {
    late _ErrorOnlyRelay relay;

    setUp(() => relay = _ErrorOnlyRelay());
    tearDown(() async => relay.closeStreams());

    RelayConnection started({required void Function() onRevoked}) {
      final conn = RelayConnection(
        machineDeviceId: 'M',
        crypto: CryptoService(),
        relayOverride: relay,
        onDeviceRevoked: onRevoked,
      );
      addTearDown(conn.dispose);
      conn.ensureStarted(
        mechanisms: RelayMechanisms(
          relay: relay,
          crypto: CryptoService(),
          machineDeviceId: 'M',
          identity: _identity(),
          phoneDeviceId: 'phone-1',
          phoneEd25519Seed: List<int>.filled(32, 7),
          epoch: 1,
          // Null coords park the ladder before the dial: this test is about the
          // error stream, not the climb.
          resolveCoords: () async => null,
          mintToken: () async => 'token',
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
