import 'dart:async';

import 'package:antgrid/services/devices_api.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final operation in ['list', 'revoke', 'create']) {
    test('$operation times out without replay or a late success', () {
      fakeAsync((clock) {
        final response = Completer<http.Response>();
        var calls = 0;
        final api = DevicesApi(
          licenseApiUrl: 'https://api.antgrid.test',
          cookieProvider: () async => 'session=value',
          httpClient: MockClient((_) {
            calls++;
            return response.future;
          }),
        );
        final Future<Object?> request = switch (operation) {
          'list' => api.list(),
          'revoke' => api.revoke('device'),
          _ => api.createDevice(
            deviceUuid: 'device',
            ed25519Pub: 'ed',
            x25519Pub: 'x',
            platform: 'android',
            displayName: 'Phone',
          ),
        };
        Object? error;
        var succeeded = false;
        request.then<void>(
          (_) => succeeded = true,
          onError: (Object e) {
            error = e;
          },
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 15));
        expect(
          error,
          operation == 'create'
              ? isA<ProvisioningException>().having(
                  (e) => e.code,
                  'code',
                  'NETWORK',
                )
              : isA<TimeoutException>(),
        );
        response.complete(http.Response('{}', 200));
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 1));
        expect(succeeded, isFalse);
        expect(calls, 1);
      });
    });
  }
}
