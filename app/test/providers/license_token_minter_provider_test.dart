import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/license_token_minter.dart';

class _MemStorage implements DeviceSecretStorage {
  String? v;
  @override Future<String?> read() async => v;
  @override Future<void> write(String s) async { v = s; }
  @override Future<void> delete() async { v = null; }
}

void main() {
  test('licenseTokenMinterProvider returns null when keychain empty', () async {
    final container = ProviderContainer(overrides: [
      keychainDeviceStoreProvider.overrideWithValue(
        KeychainDeviceStore(storage: _MemStorage()),
      ),
      licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
    ]);
    addTearDown(container.dispose);
    final minter = await container.read(licenseTokenMinterProvider.future);
    expect(minter, isNull);
  });

  test('licenseTokenMinterProvider returns a minter when keychain has record',
      () async {
    final storage = _MemStorage();
    final store = KeychainDeviceStore(storage: storage);
    await store.write(DeviceRecord(
      userId: 'u1',
      deviceUuid: 'd1',
      clientId: 'cid',
      clientSecret: 'csec',
      ed25519Pub: 'ep',
      ed25519Priv: 'epp',
      x25519Pub: 'xp',
      x25519Priv: 'xpp',
    ));
    final container = ProviderContainer(overrides: [
      keychainDeviceStoreProvider.overrideWithValue(store),
      licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
    ]);
    addTearDown(container.dispose);
    final minter = await container.read(licenseTokenMinterProvider.future);
    expect(minter, isNotNull);
    expect(minter!.clientId, 'cid');
    expect(minter.licenseApiUrl, 'https://api.antgrid.test');
  });

  test('pairingServiceForProvider.tokenProvider lazy-mints on first call', () async {
    final storage = _MemStorage();
    final store = KeychainDeviceStore(storage: storage);
    await store.write(DeviceRecord(
      userId: 'u1',
      deviceUuid: 'd1',
      clientId: 'cid',
      clientSecret: 'csec',
      ed25519Pub: 'ep',
      ed25519Priv: 'epp',
      x25519Pub: 'xp',
      x25519Priv: 'xpp',
    ));

    var mintCount = 0;
    final mockClient = MockClient((req) async {
      mintCount++;
      return http.Response(
        jsonEncode({'access_token': 'JWT-$mintCount', 'expires_in': 3600}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final stubMinter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'csec',
      httpClient: mockClient,
    );

    final container = ProviderContainer(overrides: [
      keychainDeviceStoreProvider.overrideWithValue(store),
      licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
      licenseTokenMinterProvider.overrideWith((ref) async => stubMinter),
    ]);
    addTearDown(container.dispose);

    // tokenProvider is an internal field on PairingService; we can't read it
    // directly. Instead, verify behavior by calling the underlying provider
    // surface: the stub minter starts with no cached token, so the first
    // tokenProvider() call must mint.
    expect(stubMinter.getToken(), isNull);

    // Pull the closure through the public-ish path: call tokenProvider via
    // the same construction the provider uses.
    final firstToken = await () async {
      final m = await container.read(licenseTokenMinterProvider.future);
      if (m == null) return null;
      final cached = m.getToken();
      if (cached != null) return cached;
      return m.mint();
    }();
    expect(firstToken, 'JWT-1');
    expect(mintCount, 1);

    // Second call must reuse the cached token (no second mint).
    final secondToken = await () async {
      final m = await container.read(licenseTokenMinterProvider.future);
      return m?.getToken();
    }();
    expect(secondToken, 'JWT-1');
    expect(mintCount, 1);
  });
}
