import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';

/// [failVerb], when set, makes that verb's POST return a 500 so the notifier's
/// catch path is exercised (the bridge would surface a control error this way).
HostControlClient _fakeClient(Map<String, int> calls, {String? failVerb}) {
  final mock = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final type = body['type'] as String;
    calls[type] = (calls[type] ?? 0) + 1;
    if (type == failVerb) {
      return http.Response(jsonEncode({'id': body['id'], 'ok': false}), 500);
    }
    if (type == 'phones:list') {
      return http.Response(
        jsonEncode({
          'id': body['id'],
          'ok': true,
          'type': 'phones:list',
          'phones': [
            {
              'phonePubkey': 'pk-1',
              'phoneDeviceId': 'ph-1',
              'label': 'iPhone',
              'pairedAt': 'x',
              'lastSeenAt': 'y',
              'allowedProjects': ['p1'],
            },
          ],
          'knownProjects': [
            {'projectId': 'p1', 'label': 'P', 'path': '/p', 'running': false},
          ],
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode({'id': body['id'], 'ok': true, 'type': type}),
      200,
    );
  });
  return HostControlClient(port: 1, token: 't', httpClient: mock);
}

void main() {
  test('loads phones, and allow() re-issues the verb then refreshes', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls),
        ),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(mobileDevicesHubProvider.future);
    expect(state.phones.single.phonePubkey, 'pk-1');
    expect(calls['phones:list'], 1);

    await container
        .read(mobileDevicesHubProvider.notifier)
        .allow(phonePubkey: 'pk-1', projectId: 'p2');
    expect(calls['phones:allow'], 1);
    expect(calls['phones:list'], 2); // refreshed after mutation
  });

  test('a failed mutation verb leaves the notifier in AsyncError', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls, failVerb: 'phones:deny'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(mobileDevicesHubProvider.future);
    expect(calls['phones:list'], 1);

    await container
        .read(mobileDevicesHubProvider.notifier)
        .deny(phonePubkey: 'pk-1', projectId: 'p1');

    expect(calls['phones:deny'], 1);
    final state = container.read(mobileDevicesHubProvider);
    expect(state.hasError, isTrue);
  });

  test(
    'a mutation retains the previous data while reloading (no spinner flash)',
    () async {
      final calls = <String, int>{};
      final container = ProviderContainer(
        overrides: [
          hostControlClientProvider.overrideWith(
            (ref) async => _fakeClient(calls),
          ),
        ],
      );
      addTearDown(container.dispose);

      final loaded = await container.read(mobileDevicesHubProvider.future);
      expect(loaded.phones.single.phonePubkey, 'pk-1');

      // Fire the mutation but DON'T await — the notifier synchronously flips to
      // AsyncLoading BEFORE its first await. With copyWithPrevious the prior list
      // must remain readable so the screen (skipLoadingOnReload) keeps it visible
      // instead of flashing a full-screen spinner.
      final fut = container
          .read(mobileDevicesHubProvider.notifier)
          .allow(phonePubkey: 'pk-1', projectId: 'p2');
      final mid = container.read(mobileDevicesHubProvider);
      expect(mid.isLoading, isTrue);
      expect(mid.hasValue, isTrue);
      expect(mid.value!.phones.single.phonePubkey, 'pk-1');

      await fut;
    },
  );

  test('deny() and unpair() issue their own verbs', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(mobileDevicesHubProvider.future);
    final notifier = container.read(mobileDevicesHubProvider.notifier);

    await notifier.deny(phonePubkey: 'pk-1', projectId: 'p1');
    expect(calls['phones:deny'], 1);

    await notifier.unpair(phonePubkey: 'pk-1');
    expect(calls['phones:unpair'], 1);
  });

  test('setMobileAccessForAll(enabled:true) grants only to phones missing it, '
      'then refreshes once', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(mobileDevicesHubProvider.future);
    expect(calls['phones:list'], 1);

    // pk-1 allows p1 but not p2 → only a grant for p2 should be issued.
    await container
        .read(mobileDevicesHubProvider.notifier)
        .setMobileAccessForAll(projectId: 'p2', enabled: true);

    expect(calls['phones:allow'], 1);
    expect(calls['phones:deny'], isNull);
    expect(calls['phones:list'], 2); // single _mutate refresh, not per-phone
  });

  test('setMobileAccessForAll skips phones already in the target state but '
      'still refreshes', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(mobileDevicesHubProvider.future);

    // pk-1 already allows p1 → enabling p1 issues no allow/deny.
    await container
        .read(mobileDevicesHubProvider.notifier)
        .setMobileAccessForAll(projectId: 'p1', enabled: true);

    expect(calls['phones:allow'], isNull);
    expect(calls['phones:deny'], isNull);
    expect(calls['phones:list'], 2);
  });

  test('a failed mutation retains the last-known list under the error '
      '(toggle does not vanish)', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls, failVerb: 'phones:deny'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final loaded = await container.read(mobileDevicesHubProvider.future);
    expect(loaded.phones.single.phonePubkey, 'pk-1');

    await container
        .read(mobileDevicesHubProvider.notifier)
        .deny(phonePubkey: 'pk-1', projectId: 'p1');

    final state = container.read(mobileDevicesHubProvider);
    expect(state.hasError, isTrue);
    // copyWithPrevious keeps the value readable so value-based consumers
    // (the agent-panel toggle) keep showing the last state instead of vanishing.
    expect(state.hasValue, isTrue);
    expect(state.value!.phones.single.phonePubkey, 'pk-1');
  });
}
