import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:antgrid/config/storage_scope.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/sign_out_service.dart';
import 'package:antgrid/services/push_identity.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import '../helpers/prefs_test_mock.dart';

class _MemAuthStorage implements AuthStorage {
  String? _cookie;
  String? _pending;
  _MemAuthStorage([this._cookie]);
  @override
  Future<String?> readCookie() async => _cookie;
  @override
  Future<void> writeCookie(String v) async => _cookie = v;
  @override
  Future<void> clearCookie() async => _cookie = null;
  @override
  Future<String?> readPendingSignIn() async => _pending;
  @override
  Future<void> writePendingSignIn(String v) async => _pending = v;
  @override
  Future<void> clearPendingSignIn() async => _pending = null;
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

/// Recording fake for the push-identity seam: sign-out only drives `clear`.
class _RecordingPushIdentity implements PushIdentity {
  bool cleared = false;
  @override
  Future<void> clear() async => cleared = true;
  @override
  Future<PushKeypair> ensureKeypair() async => throw UnimplementedError();
}

DeviceRecord _record(String uuid) => DeviceRecord(
  userId: 'u-1',
  deviceUuid: uuid,
  clientId: 'cid',
  clientSecret: 'secret',
  ed25519Pub: 'ep',
  ed25519Priv: 'epriv',
  x25519Pub: 'xp',
  x25519Priv: 'xpriv',
);

/// Builds an AuthService whose sign-out always succeeds, over the loopback
/// transport so the round-trip is actually attempted.
({AuthService auth, _MemAuthStorage storage}) _authWithCookie() {
  final storage = _MemAuthStorage('better-auth.session_token=signed.value');
  final auth = AuthService(
    licenseApiUrl: 'http://localhost:8787',
    storage: storage,
    httpClient: MockClient((_) async => http.Response('{}', 200)),
  );
  return (auth: auth, storage: storage);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SignOutService.hardSignOut', () {
    // Route the REAL default-constructed FlutterSecureStorage through the
    // plugin's own in-memory fake so the retired-key sweep is observed at the
    // keys it actually issues, not through a test double of our own.
    late Map<String, String> secureBacking;

    setUp(() {
      secureBacking = <String, String>{};
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        secureBacking,
      );
    });

    test(
      'revokes the matching device, signs out, and wipes local state',
      () async {
        useInMemoryPrefs();
        // Retired per-machine phone pairing seeds (PhoneIdentity, deleted in the
        // account-trust cutover). Pre-cutover installs can still have these at
        // rest, so leaving them on a shared or lost phone leaves stale key
        // material behind.
        final privA = scopedStorageKey('antgrid.phone_priv.agent-1');
        final pubA = scopedStorageKey('antgrid.phone_pub.agent-1');
        final privB = scopedStorageKey('antgrid.phone_priv.agent-2');
        final unrelated = scopedStorageKey('antgrid.analytics.install_id.v1');
        secureBacking[privA] = 'seed-a';
        secureBacking[pubA] = 'pub-a';
        secureBacking[privB] = 'seed-b';
        secureBacking[unrelated] = 'install-id';

        final recent = await RecentAgentsStore.open();
        await recent.upsert(
          RecentAgent(
            agentDeviceId: 'agent-1',
            agentLabel: 'Mac',
            agentEd25519Pubkey: 'pk',
            relayUrl: 'wss://r',
            pairedAt: DateTime(2026),
            lastConnectedAt: DateTime(2026),
          ),
        );

        final keychain = KeychainDeviceStore(
          storage: _MemDeviceSecret(),
          controllerStorage: _MemDeviceSecret(),
        );
        await keychain.write(_record('dev-1'));
        await keychain.writeController(_record('ctrl-1'));

        final deletedIds = <String>[];
        final devicesApi = DevicesApi(
          licenseApiUrl: 'http://localhost:8787',
          cookieProvider: () async => 'better-auth.session_token=signed.value',
          httpClient: MockClient((req) async {
            if (req.method == 'GET') {
              return http.Response(
                '{"devices":[{"id":"row-9","device_id":"dev-1",'
                '"kind":"app","platform":"windows","display_name":"PC"},'
                '{"id":"row-10","device_id":"ctrl-1",'
                '"kind":"app","platform":"windows","display_name":"PC controller"}]}',
                200,
              );
            }
            if (req.method == 'DELETE') {
              deletedIds.add(req.url.pathSegments.last);
              return http.Response('{}', 200);
            }
            return http.Response('{}', 404);
          }),
        );

        final push = _RecordingPushIdentity();
        final a = _authWithCookie();
        var minterStopped = false;
        var sessionsClosed = false;
        var pushCleared = false;
        var pushClearedBeforeSessionsClosed = false;
        var cachesCleared = false;
        var cachesClearedAfterSessionsClosed = false;

        final svc = SignOutService(
          authService: a.auth,
          keychainStore: keychain,
          devicesApi: devicesApi,
          pushIdentity: push,
          recentAgentsStore: recent,
          clearPushToken: () async {
            pushCleared = true;
            pushClearedBeforeSessionsClosed = !sessionsClosed;
          },
          stopMinter: () async => minterStopped = true,
          closeSessions: () async => sessionsClosed = true,
          clearCaches: () async {
            cachesCleared = true;
            cachesClearedAfterSessionsClosed = sessionsClosed;
          },
        );

        await svc.hardSignOut();

        expect(
          deletedIds,
          containsAll(['row-9', 'row-10']),
          reason: 'both the main and controller rows are revoked server-side',
        );
        expect(await a.storage.readCookie(), isNull, reason: 'cookie cleared');
        expect(await keychain.read(), isNull, reason: 'device record wiped');
        expect(
          await keychain.readController(),
          isNull,
          reason: 'controller record wiped',
        );
        expect(push.cleared, isTrue, reason: 'push seed wiped');
        expect(
          secureBacking.keys,
          isNot(anyElement(anyOf(privA, pubA, privB))),
          reason:
              'retired phone pairing seeds wiped — an un-swept agent still '
              'treats them as machine-level trust',
        );
        expect(
          secureBacking[unrelated],
          'install-id',
          reason: 'the sweep is prefix-scoped, not a deleteAll',
        );
        expect(recent.list(), isEmpty, reason: 'recent agents wiped');
        expect(minterStopped, isTrue);
        expect(sessionsClosed, isTrue);
        expect(
          pushCleared,
          isTrue,
          reason: 'paired agents told to stop pushing',
        );
        expect(
          pushClearedBeforeSessionsClosed,
          isTrue,
          reason: 'push-clear must send before sessions/transports teardown',
        );
        expect(
          cachesCleared,
          isTrue,
          reason:
              'account-derived caches (sessions, labels, paired machines) are '
              'wiped, not just identity material',
        );
        expect(
          cachesClearedAfterSessionsClosed,
          isTrue,
          reason:
              'the cache purge must follow session teardown — eviction writes '
              'the very caches it deletes',
        );

        await recent.close();
      },
    );

    test(
      'with no provisioned device, skips revoke but still clears the session',
      () async {
        useInMemoryPrefs();
        final recent = await RecentAgentsStore.open();
        final keychain = KeychainDeviceStore(
          storage: _MemDeviceSecret(),
          controllerStorage: _MemDeviceSecret(),
        );

        var listCalled = false;
        final devicesApi = DevicesApi(
          licenseApiUrl: 'http://localhost:8787',
          cookieProvider: () async => null,
          httpClient: MockClient((req) async {
            listCalled = true;
            return http.Response('{"devices":[]}', 200);
          }),
        );
        final push = _RecordingPushIdentity();
        final a = _authWithCookie();

        final svc = SignOutService(
          authService: a.auth,
          keychainStore: keychain,
          devicesApi: devicesApi,
          pushIdentity: push,
          recentAgentsStore: recent,
        );

        await svc.hardSignOut();

        expect(
          listCalled,
          isFalse,
          reason: 'no device record → no server lookup',
        );
        expect(await a.storage.readCookie(), isNull);
        await recent.close();
      },
    );

    test('server revoke failure does not block local teardown', () async {
      useInMemoryPrefs();
      final recent = await RecentAgentsStore.open();
      final keychain = KeychainDeviceStore(
        storage: _MemDeviceSecret(),
        controllerStorage: _MemDeviceSecret(),
      );
      await keychain.write(_record('dev-1'));

      final devicesApi = DevicesApi(
        licenseApiUrl: 'http://localhost:8787',
        cookieProvider: () async => 'better-auth.session_token=signed.value',
        httpClient: MockClient((_) async => throw http.ClientException('boom')),
      );
      final push = _RecordingPushIdentity();
      final a = _authWithCookie();

      final errors = <Object>[];
      final svc = SignOutService(
        authService: a.auth,
        keychainStore: keychain,
        devicesApi: devicesApi,
        pushIdentity: push,
        recentAgentsStore: recent,
        onStepError: (e, _) => errors.add(e),
      );

      await svc.hardSignOut();

      expect(
        await a.storage.readCookie(),
        isNull,
        reason: 'cookie still cleared',
      );
      expect(await keychain.read(), isNull, reason: 'keychain still wiped');
      // A swallowed server-revoke failure must still be surfaced to the logger,
      // otherwise a device left live on the account is invisible.
      expect(
        errors,
        isNotEmpty,
        reason: 'revoke failure reported to onStepError',
      );
      await recent.close();
    });
  });
}
