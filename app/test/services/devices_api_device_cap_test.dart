import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/services/devices_api.dart';

DevicesApi _apiReturning(int status, String body) => DevicesApi(
  licenseApiUrl: 'https://api.test',
  cookieProvider: () async => 'session=v',
  httpClient: MockClient((_) async => http.Response(body, status)),
);

Future<void> _create(DevicesApi api) => api.createDevice(
  deviceUuid: 'new-uuid',
  ed25519Pub: 'ed',
  x25519Pub: 'x',
  platform: 'macos',
  displayName: 'New machine',
);

void main() {
  test(
    '402 APP_DEVICE_CAP parses limit + devices into a structured exception',
    () async {
      final api = _apiReturning(
        402,
        jsonEncode({
          'error': 'APP_DEVICE_CAP',
          'limit': 10,
          'devices': [
            {'id': 'd1', 'device_id': 'uuid-1', 'display_name': 'Old laptop'},
            {'id': 'd2', 'device_id': 'uuid-2', 'display_name': 'Phone'},
          ],
        }),
      );

      await expectLater(
        _create(api),
        throwsA(
          isA<ProvisioningException>()
              .having((e) => e.code, 'code', 'APP_DEVICE_CAP')
              .having((e) => e.cap?.kind, 'cap.kind', DeviceCapKind.appDevice)
              .having((e) => e.message, 'message', contains('10'))
              // Never an upgrade prompt — this ceiling is not sold.
              .having(
                (e) => e.message.toLowerCase(),
                'message',
                isNot(contains('upgrade')),
              )
              .having(
                (e) => e.message.toLowerCase(),
                'message',
                isNot(contains('subscription')),
              )
              .having((e) => e.cap?.limit, 'cap.limit', 10)
              .having((e) => e.cap?.devices.length, 'cap.devices.length', 2)
              .having(
                (e) => e.cap?.devices.first.displayName,
                'first name',
                'Old laptop',
              ),
        ),
      );
    },
  );

  test('402 WORKER_CAP yields the upgradable variant', () async {
    final api = _apiReturning(
      402,
      jsonEncode({
        'error': 'WORKER_CAP',
        'limit': 1,
        'devices': [
          {'id': 'd1', 'device_id': 'uuid-1', 'display_name': 'Build box'},
        ],
      }),
    );

    await expectLater(
      _create(api),
      throwsA(
        isA<ProvisioningException>()
            .having((e) => e.code, 'code', 'WORKER_CAP')
            .having((e) => e.cap?.kind, 'cap.kind', DeviceCapKind.worker)
            .having((e) => e.cap?.limit, 'cap.limit', 1)
            .having((e) => e.message, 'message', contains('worker machine')),
      ),
    );
  });

  test(
    '402 with an unparseable body falls back to WORKER_CAP, not the app ceiling',
    () async {
      // The fallback resolves to the axis a server CAN raise: a mislabelled
      // worker rejection still offers freeing a slot, while guessing the app
      // ceiling would hide the upgrade path from a user who needs it.
      final api = _apiReturning(402, 'not json at all');
      await expectLater(
        _create(api),
        throwsA(
          isA<ProvisioningException>()
              .having((e) => e.code, 'code', 'WORKER_CAP')
              .having((e) => e.cap?.kind, 'cap.kind', DeviceCapKind.worker)
              .having((e) => e.cap?.limit, 'cap.limit', isNull)
              .having((e) => e.cap?.devices, 'cap.devices', isEmpty),
        ),
      );
    },
  );

  test('an unknown 402 error code also falls back to WORKER_CAP', () async {
    final api = _apiReturning(402, jsonEncode({'error': 'SEAT_CAP'}));
    await expectLater(
      _create(api),
      throwsA(
        isA<ProvisioningException>().having((e) => e.code, 'code', 'WORKER_CAP'),
      ),
    );
  });

  test(
    'a blank display_name falls back to a placeholder, missing id drops the row',
    () async {
      final api = _apiReturning(
        402,
        jsonEncode({
          'error': 'APP_DEVICE_CAP',
          'limit': 2,
          'devices': [
            {'id': 'd1', 'device_id': 'uuid-1', 'display_name': '   '},
            {'device_id': 'uuid-2', 'display_name': 'No id'},
          ],
        }),
      );
      await expectLater(
        _create(api),
        throwsA(
          isA<ProvisioningException>()
              .having((e) => e.cap?.devices.length, 'kept rows', 1)
              .having(
                (e) => e.cap?.devices.single.displayName,
                'placeholder',
                'Unnamed device',
              ),
        ),
      );
    },
  );
}
