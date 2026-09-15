import 'dart:convert';

import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/peer_runtime.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/license_token_minter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DeviceRecord _record({bool seeded = false}) => DeviceRecord(
  userId: 'owner',
  deviceUuid: 'device',
  clientId: 'client',
  clientSecret: 'secret',
  ed25519Pub: '',
  ed25519Priv: '',
  x25519Pub: '',
  x25519Priv: '',
  endpointSecret: seeded ? base64Encode(List.filled(32, 1)) : null,
);

void main() {
  test('token minter refresh preserves the enrollment runtime', () async {
    final container = ProviderContainer(
      overrides: [
        connectionDeviceRecordProvider.overrideWith(
          (_) async => _record(seeded: true),
        ),
        connectionTokenMinterProvider.overrideWith(
          (_) async => LicenseTokenMinter(
            licenseApiUrl: 'http://localhost:8787',
            clientId: 'client',
            clientSecret: 'secret',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final runtime = await container.read(peerRuntimeProvider.future);
    container.invalidate(connectionTokenMinterProvider);
    await container.pump();
    expect(await container.read(peerRuntimeProvider.future), same(runtime));
    container.invalidate(connectionDeviceRecordProvider);
    await container.pump();
    expect(
      await container.read(peerRuntimeProvider.future),
      isNot(same(runtime)),
    );
  });

  test(
    'missing protected endpoint seed cannot bypass remote authorization',
    () async {
      final container = ProviderContainer(
        overrides: [
          connectionDeviceRecordProvider.overrideWith((_) async => _record()),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(peerRuntimeProvider.future),
        throwsA(
          isA<ProvisioningException>().having(
            (error) => error.code,
            'code',
            'AUTH',
          ),
        ),
      );
    },
  );

  test(
    'missing device token minter cannot fall back to an unleased socket',
    () async {
      final container = ProviderContainer(
        overrides: [
          connectionDeviceRecordProvider.overrideWith(
            (_) async => _record(seeded: true),
          ),
          connectionTokenMinterProvider.overrideWith((_) async => null),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(peerRuntimeProvider.future),
        throwsA(
          isA<ProvisioningException>().having(
            (error) => error.code,
            'code',
            'AUTH',
          ),
        ),
      );
    },
  );
}
