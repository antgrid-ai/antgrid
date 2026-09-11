import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ProviderContainer _container({
  required MockClient client,
  required CurrentUser? user,
}) {
  final container = ProviderContainer(
    overrides: [
      devicesApiProvider.overrideWithValue(
        DevicesApi(
          licenseApiUrl: 'https://lic.test',
          cookieProvider: () async => 'session=abc',
          httpClient: client,
        ),
      ),
      currentUserProvider.overrideWith((ref) => user),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final _user = CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro');

void main() {
  test('an unreachable account is unresolved, never empty', () async {
    final container = _container(
      client: MockClient((_) async => http.Response('nope', 502)),
      user: _user,
    );
    // Deliberately NOT `await ...future`: this provider keeps Riverpod 3's
    // default retry, so a failed fetch leaves `.future` pending until dispose
    // (see currentUserProvider's `noProviderRetry` note) while it backs off and
    // tries again. `.value` is the channel the panel reads, and the retry is
    // what eventually clears the wait when the network returns.
    final sub = container.listen(accountDevicesByBridgeIdProvider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 100; i++) {
      if (container.read(accountDevicesByBridgeIdProvider).hasError) break;
      await Future<void>.delayed(Duration.zero);
    }

    final state = container.read(accountDevicesByBridgeIdProvider);
    expect(state.hasError, isTrue);
    // `.value` is what `remote_access_panel.dart` reads, and it tells three
    // states apart: null waits, a hit offers "Sign out", and a MISS offers
    // "Forget" on the premise that the device is gone from the account.
    // Answering a failed read with an empty map lands every still-trusted
    // phone in that third branch.
    expect(
      state.value,
      isNull,
      reason: 'a 502 must not read as "this device left the account"',
    );
  });

  test('signed out is empty, and asks the account nothing', () async {
    var called = false;
    final container = _container(
      client: MockClient((_) async {
        called = true;
        return http.Response('{"devices":[]}', 200);
      }),
      user: null,
    );

    expect(await container.read(accountDevicesByBridgeIdProvider.future), isEmpty);
    expect(called, isFalse);
  });

  test('a reachable account resolves the join', () async {
    final container = _container(
      client: MockClient(
        (_) async => http.Response(
          '{"devices":[{"id":"r1","device_id":"phone-1","kind":"app",'
          '"platform":"android","display_name":"Pixel"}]}',
          200,
        ),
      ),
      user: _user,
    );

    final byId = await container.read(accountDevicesByBridgeIdProvider.future);

    expect(byId.keys, ['phone-1']);
    expect(byId['phone-1']!.displayName, 'Pixel');
  });
}
