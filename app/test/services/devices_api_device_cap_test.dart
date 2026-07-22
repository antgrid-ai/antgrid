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
    '402 DEVICE_CAP parses limit + devices into a structured exception',
    () async {
      final api = _apiReturning(
        402,
        jsonEncode({
          'error': 'DEVICE_CAP',
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
              .having((e) => e.code, 'code', 'DEVICE_CAP')
              .having((e) => e.message, 'message', contains('10'))
              // Never an upgrade prompt — this is fair-use, identical across tiers.
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

  test(
    '402 with an unparseable body still yields DEVICE_CAP (generic, no devices)',
    () async {
      final api = _apiReturning(402, 'not json at all');
      await expectLater(
        _create(api),
        throwsA(
          isA<ProvisioningException>()
              .having((e) => e.code, 'code', 'DEVICE_CAP')
              .having((e) => e.cap?.limit, 'cap.limit', isNull)
              .having((e) => e.cap?.devices, 'cap.devices', isEmpty),
        ),
      );
    },
  );

  test(
    'a blank display_name falls back to a placeholder, missing id drops the row',
    () async {
      final api = _apiReturning(
        402,
        jsonEncode({
          'error': 'DEVICE_CAP',
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
