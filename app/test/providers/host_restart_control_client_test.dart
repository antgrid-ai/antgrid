import 'dart:async';
import 'dart:convert';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/providers/host_status.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HostControlClient _client(int build) => HostControlClient(
  port: build,
  token: 't$build',
  httpClient: MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'ok': true,
        'type': body['type'],
        'enabled': false,
      }),
      200,
    );
  }),
);

/// Lets the StreamProvider deliver and the listener run.
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  // The rebind is desktop-only, and `flutter test` reports android by default.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('a host replacement drops the cached loopback control client', () async {
    var builds = 0;
    final status = StreamController<HostStatus>.broadcast();
    addTearDown(status.close);

    final container = ProviderContainer(
      overrides: [
        hostStatusProvider.overrideWith((ref) => status.stream),
        hostControlClientProvider.overrideWith(
          (ref) async => _client(++builds),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Listened for the app's whole life from bootstrap (main.dart).
    container.listen(hostRestartRebindProvider, (_, _) {});
    await container.read(hostControlClientProvider.future);
    expect(builds, 1);

    // First `up` only records the generation — nothing was bound before it.
    status.add(const HostStatus(HostPhase.up, generation: 1));
    await _settle();
    await container.read(hostControlClientProvider.future);
    expect(
      builds,
      1,
      reason: 'same process, so the cached client is still live',
    );

    // The process was REPLACED: the respawn binds a fresh port under a fresh
    // token, so a client cached against the old pair posts into a closed
    // socket — the whole remote-access UI dies silently until an app restart.
    status.add(const HostStatus(HostPhase.up, generation: 2));
    await _settle();
    await container.read(hostControlClientProvider.future);
    expect(builds, 2);
  });

  test('the client is re-resolved even with no local project open', () async {
    // The rebind's project loop returns early on an empty workspace; the
    // control client is stale regardless, so its invalidation must not sit
    // behind that return.
    var builds = 0;
    final status = StreamController<HostStatus>.broadcast();
    addTearDown(status.close);

    final container = ProviderContainer(
      overrides: [
        hostStatusProvider.overrideWith((ref) => status.stream),
        hostControlClientProvider.overrideWith(
          (ref) async => _client(++builds),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.listen(hostRestartRebindProvider, (_, _) {});
    await container.read(hostControlClientProvider.future);

    status.add(const HostStatus(HostPhase.up, generation: 1));
    await _settle();
    status.add(const HostStatus(HostPhase.up, generation: 2));
    await _settle();

    await container.read(hostControlClientProvider.future);
    expect(builds, 2);
  });
}
