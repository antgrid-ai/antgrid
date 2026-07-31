import 'dart:convert';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
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
  test('loads the policy and setEnabled(true) adopts the returned state', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(overrides: [
      hostControlClientProvider.overrideWith((ref) async => _fakeClient(calls)),
    ]);
    addTearDown(container.dispose);

    final initial = await container.read(mobileAccessPolicyProvider.future);
    expect(initial.enabled, isFalse);
    expect(calls['mobile-access:get'], 1);

    await container.read(mobileAccessPolicyProvider.notifier).setEnabled(true);
    expect(container.read(mobileAccessPolicyProvider).value!.enabled, isTrue);
    expect(calls['mobile-access:set'], 1);
    // The set response IS the new state, so no follow-up read is needed.
    expect(calls['mobile-access:get'], 1);
  });

  test('setEnabled(false) turns the machine back off', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(overrides: [
      hostControlClientProvider
          .overrideWith((ref) async => _fakeClient(calls, initial: true)),
    ]);
    addTearDown(container.dispose);

    expect((await container.read(mobileAccessPolicyProvider.future)).enabled, isTrue);

    await container.read(mobileAccessPolicyProvider.notifier).setEnabled(false);

    expect(container.read(mobileAccessPolicyProvider).value!.enabled, isFalse);
    expect(calls['mobile-access:set'], 1);
  });

  test('a failed set retains the last-known policy under the error', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(overrides: [
      hostControlClientProvider.overrideWith(
        (ref) async =>
            _fakeClient(calls, initial: true, failVerb: 'mobile-access:set'),
      ),
    ]);
    addTearDown(container.dispose);

    await container.read(mobileAccessPolicyProvider.future);

    await container.read(mobileAccessPolicyProvider.notifier).setEnabled(false);

    final state = container.read(mobileAccessPolicyProvider);
    expect(state.hasError, isTrue);
    // copyWithPrevious keeps the value readable so MobileAccessToggle keeps
    // rendering the prior state instead of collapsing to its inert CTA.
    expect(state.hasValue, isTrue);
    expect(state.value!.enabled, isTrue);
  });
}
