import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/remote_access.dart';

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
  test(
    'loads phones, and unpair() re-issues the verb then refreshes',
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

      final state = await container.read(remoteDevicesProvider.future);
      expect(state.phones.single.phonePubkey, 'pk-1');
      expect(calls['phones:list'], 1);

      await container
          .read(remoteDevicesProvider.notifier)
          .unpair(phonePubkey: 'pk-1');
      expect(calls['phones:unpair'], 1);
      expect(calls['phones:list'], 2); // refreshed after mutation
    },
  );

  test('a failed mutation verb leaves the notifier in AsyncError', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls, failVerb: 'phones:unpair'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(remoteDevicesProvider.future);
    expect(calls['phones:list'], 1);

    await container
        .read(remoteDevicesProvider.notifier)
        .unpair(phonePubkey: 'pk-1');

    expect(calls['phones:unpair'], 1);
    final state = container.read(remoteDevicesProvider);
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

      final loaded = await container.read(remoteDevicesProvider.future);
      expect(loaded.phones.single.phonePubkey, 'pk-1');

      // Fire the mutation but DON'T await — the notifier synchronously flips to
      // AsyncLoading BEFORE its first await. With copyWithPrevious the prior list
      // must remain readable so the screen (skipLoadingOnReload) keeps it visible
      // instead of flashing a full-screen spinner.
      final fut = container
          .read(remoteDevicesProvider.notifier)
          .unpair(phonePubkey: 'pk-1');
      final mid = container.read(remoteDevicesProvider);
      expect(mid.isLoading, isTrue);
      expect(mid.hasValue, isTrue);
      expect(mid.value!.phones.single.phonePubkey, 'pk-1');

      await fut;
    },
  );

  test('a failed mutation retains the last-known list under the error '
      '(the roster does not vanish)', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls, failVerb: 'phones:unpair'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final loaded = await container.read(remoteDevicesProvider.future);
    expect(loaded.phones.single.phonePubkey, 'pk-1');

    await container
        .read(remoteDevicesProvider.notifier)
        .unpair(phonePubkey: 'pk-1');

    final state = container.read(remoteDevicesProvider);
    expect(state.hasError, isTrue);
    // copyWithPrevious keeps the value readable so value-based consumers keep
    // showing the last state instead of vanishing.
    expect(state.hasValue, isTrue);
    expect(state.value!.phones.single.phonePubkey, 'pk-1');
  });
}
