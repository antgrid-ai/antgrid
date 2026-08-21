import 'dart:convert';
import 'dart:io';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Stands in for the bridge's machine-level policy store: `mobile-access:set`
/// writes the boolean and, like the real verb, answers with the resulting state
/// rather than echoing the request.
HostControlClient _fakeClient(
  Map<String, int> calls, {
  bool initial = false,
  String? failVerb,
}) {
  var enabled = initial;
  final mock = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final type = body['type'] as String;
    calls[type] = (calls[type] ?? 0) + 1;
    if (type == failVerb) {
      return http.Response(jsonEncode({'id': body['id'], 'ok': false}), 500);
    }
    if (type == 'mobile-access:set') enabled = body['enabled'] == true;
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'ok': true,
        'type': type,
        'enabled': enabled,
      }),
      200,
    );
  });
  return HostControlClient(port: 1, token: 't', httpClient: mock);
}

void main() {
  test(
    'loads the policy and setEnabled(true) adopts the returned state',
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

      final initial = await container.read(remoteAccessPolicyProvider.future);
      expect(initial.enabled, isFalse);
      expect(calls['mobile-access:get'], 1);

      await container
          .read(remoteAccessPolicyProvider.notifier)
          .setEnabled(true);
      expect(container.read(remoteAccessPolicyProvider).value!.enabled, isTrue);
      expect(calls['mobile-access:set'], 1);
      // The set response IS the new state, so no follow-up read is needed.
      expect(calls['mobile-access:get'], 1);
    },
  );

  test('setEnabled(false) turns the machine back off', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async => _fakeClient(calls, initial: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      (await container.read(remoteAccessPolicyProvider.future)).enabled,
      isTrue,
    );

    await container.read(remoteAccessPolicyProvider.notifier).setEnabled(false);

    expect(container.read(remoteAccessPolicyProvider).value!.enabled, isFalse);
    expect(calls['mobile-access:set'], 1);
  });

  test('a failed set retains the last-known policy under the error', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(
      overrides: [
        hostControlClientProvider.overrideWith(
          (ref) async =>
              _fakeClient(calls, initial: true, failVerb: 'mobile-access:set'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(remoteAccessPolicyProvider.future);

    await container.read(remoteAccessPolicyProvider.notifier).setEnabled(false);

    final state = container.read(remoteAccessPolicyProvider);
    expect(state.hasError, isTrue);
    // copyWithPrevious keeps the value readable so MobileAccessToggle keeps
    // rendering the prior state instead of collapsing to its inert CTA.
    expect(state.hasValue, isTrue);
    expect(state.value!.enabled, isTrue);
  });

  test(
    'an unreachable host drops the cached client so a retry can recover',
    () async {
      // The panel's Retry only invalidates the policy/roster provider. Without
      // the drop, every retry rebuilds around the SAME client — still pointed at
      // the dead process's port and token — so a host swap is unrecoverable
      // short of an app restart.
      var builds = 0;
      var reachable = false;
      final container = ProviderContainer(
        overrides: [
          hostControlClientProvider.overrideWith((ref) async {
            builds++;
            return HostControlClient(
              port: builds,
              token: 't$builds',
              httpClient: MockClient((req) async {
                // A real gap: the wedge this guards against only shows up once
                // the POST is not resolved within the same microtask.
                await Future<void>.delayed(const Duration(milliseconds: 1));
                if (!reachable)
                  throw const SocketException('connection refused');
                final body = jsonDecode(req.body) as Map<String, dynamic>;
                return http.Response(
                  jsonEncode({
                    'id': body['id'],
                    'ok': true,
                    'type': body['type'],
                    'enabled': true,
                  }),
                  200,
                );
              }),
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      // Read the STATE, not `.future`: Riverpod re-arms a failed provider, so its
      // future stays pending across the error the test is about.
      container.listen(
        remoteAccessPolicyProvider,
        (_, _) {},
        onError: (_, _) {},
      );

      await _until(() => container.read(remoteAccessPolicyProvider).hasError);
      expect(builds, 1);

      reachable = true;
      container.invalidate(remoteAccessPolicyProvider);

      await _until(() => container.read(remoteAccessPolicyProvider).hasValue);
      expect(container.read(remoteAccessPolicyProvider).value!.enabled, isTrue);
      expect(
        builds,
        greaterThan(1),
        reason: 'the client bound to the dead port must not be reused',
      );
    },
  );

  test(
    'a verb-level failure keeps the client — the host is still there',
    () async {
      // Only a TRANSPORT failure means the host is gone. An `ok:false` answer
      // came FROM the host, so dropping the client would throw away a live
      // connection on every ordinary rejection.
      var builds = 0;
      final calls = <String, int>{};
      final container = ProviderContainer(
        overrides: [
          hostControlClientProvider.overrideWith((ref) async {
            builds++;
            return _fakeClient(
              calls,
              initial: true,
              failVerb: 'mobile-access:set',
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(remoteAccessPolicyProvider.future);
      await container
          .read(remoteAccessPolicyProvider.notifier)
          .setEnabled(false);

      expect(container.read(remoteAccessPolicyProvider).hasError, isTrue);
      expect(builds, 1);
    },
  );
}

/// Polls [done] on the event loop; fails the test if it never becomes true.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition never became true');
}
