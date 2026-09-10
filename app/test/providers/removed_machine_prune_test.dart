import 'dart:convert';

import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/removed_machine_prune.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _localUuid = 'local-uuid';

RecentAgent _recent(String uuid) => RecentAgent(
  agentDeviceId: uuid,
  agentLabel: uuid,
  agentEd25519Pubkey: 'pub',
  relayUrl: 'wss://relay.test',
  pairedAt: DateTime(2026),
  lastConnectedAt: DateTime(2026),
);

/// A device-list response naming [uuids] as still on the account.
MockClient _listing(List<String> uuids) => MockClient(
  (_) async => http.Response(
    jsonEncode({
      'devices': [
        for (final u in uuids)
          {
            'id': 'row-$u',
            'device_id': u,
            'kind': 'agent',
            'platform': 'windows',
            'display_name': u,
          },
      ],
    }),
    200,
  ),
);

Future<({ProviderContainer container, RecentAgentsStore recents})> _harness({
  required MockClient client,
  required List<String> seededRecents,
  String? focused,
  String? localUuid = _localUuid,
}) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  for (final uuid in seededRecents) {
    await stores.recentAgentsStore.upsert(_recent(uuid));
  }
  final container = ProviderContainer(
    overrides: [
      ...stores.overrides,
      devicesApiProvider.overrideWithValue(
        DevicesApi(
          licenseApiUrl: 'https://lic.test',
          cookieProvider: () async => 'session=abc',
          httpClient: client,
        ),
      ),
      currentUserProvider.overrideWith(
        (ref) => CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro'),
      ),
      localDeviceUuidProvider.overrideWith((ref) async => localUuid),
    ],
  );
  addTearDown(container.dispose);
  // Settle signedInProvider, which reads through currentUserProvider.
  await container.read(currentUserProvider.future);
  if (focused != null) {
    container
        .read(selectedTargetProvider.notifier)
        .set(RemoteTarget.legacy(focused));
  }
  return (container: container, recents: stores.recentAgentsStore);
}

List<String> _ids(RecentAgentsStore s) =>
    s.list().map((r) => r.agentDeviceId).toList()..sort();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forgets a machine that has left the account', () async {
    final h = await _harness(
      client: _listing([_localUuid, 'kept']),
      seededRecents: ['kept', 'removed'],
    );

    await pruneRemovedMachines(h.container);

    expect(_ids(h.recents), ['kept']);
  });

  test('a failed device read never prunes', () async {
    final h = await _harness(
      client: MockClient((_) async => http.Response('boom', 500)),
      seededRecents: ['kept', 'removed'],
    );

    await pruneRemovedMachines(h.container);

    expect(
      _ids(h.recents),
      ['kept', 'removed'],
      reason: 'a 500 must not read as "this account has no devices"',
    );
  });

  test('a response without THIS machine is not authoritative', () async {
    // The window right after sign-in, before provisioning has registered this
    // device — and the shape a response for another account would take.
    final h = await _harness(
      client: _listing(['someone-else']),
      seededRecents: ['kept', 'removed'],
    );

    await pruneRemovedMachines(h.container);

    expect(_ids(h.recents), ['kept', 'removed']);
  });

  test('never prunes the machine the user is working on', () async {
    final h = await _harness(
      client: _listing([_localUuid]),
      seededRecents: ['focused', 'removed'],
      focused: 'focused',
    );

    await pruneRemovedMachines(h.container);

    expect(
      _ids(h.recents),
      ['focused'],
      reason: 'forgetMachine clears the selection and would yank the workspace',
    );
  });

  test('is a no-op while signed out', () async {
    useInMemoryPrefs();
    final stores = await buildTestStoreOverrides();
    await stores.recentAgentsStore.upsert(_recent('removed'));
    var called = false;
    final container = ProviderContainer(
      overrides: [
        ...stores.overrides,
        devicesApiProvider.overrideWithValue(
          DevicesApi(
            licenseApiUrl: 'https://lic.test',
            cookieProvider: () async => 'session=abc',
            httpClient: MockClient((_) async {
              called = true;
              return http.Response('{"devices":[]}', 200);
            }),
          ),
        ),
        currentUserProvider.overrideWith((ref) => null),
        localDeviceUuidProvider.overrideWith((ref) async => _localUuid),
      ],
    );
    addTearDown(container.dispose);
    await container.read(currentUserProvider.future);

    await pruneRemovedMachines(container);

    expect(called, isFalse);
    expect(_ids(stores.recentAgentsStore), ['removed']);
  });

  test('the cooldown keeps a resume storm off the account API', () async {
    var calls = 0;
    final h = await _harness(
      client: MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'devices': [
              {
                'id': 'r',
                'device_id': _localUuid,
                'kind': 'agent',
                'platform': 'windows',
                'display_name': 'me',
              },
            ],
          }),
          200,
        );
      }),
      seededRecents: [],
    );

    await pruneRemovedMachines(h.container);
    await pruneRemovedMachines(h.container);
    await pruneRemovedMachines(h.container);

    expect(calls, 1);
  });
}
