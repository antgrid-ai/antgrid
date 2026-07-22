import 'dart:convert';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HostControlClient _fakeClient(Map<String, int> calls) {
  final projects = <String>{};
  final mock = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final type = body['type'] as String;
    calls[type] = (calls[type] ?? 0) + 1;
    if (type == 'mobile-access:enable-project') projects.add(body['projectId'] as String);
    if (type == 'mobile-access:disable-project') projects.remove(body['projectId'] as String);
    return http.Response(jsonEncode({
      'id': body['id'],
      'ok': true,
      'type': type,
      'projectIds': projects.toList()..sort(),
    }), 200);
  });
  return HostControlClient(port: 1, token: 't', httpClient: mock);
}

void main() {
  test('loads policy and enableProject refreshes state', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(overrides: [
      hostControlClientProvider.overrideWith((ref) async => _fakeClient(calls)),
    ]);
    addTearDown(container.dispose);

    final initial = await container.read(mobileAccessPolicyProvider.future);
    expect(initial.projectIds, isEmpty);
    expect(calls['mobile-access:get'], 1);

    await container.read(mobileAccessPolicyProvider.notifier).enableProject('p1');
    expect(container.read(mobileAccessPolicyProvider).value!.projectIds, ['p1']);
    expect(calls['mobile-access:enable-project'], 1);
  });

  test('disableProject removes project from state', () async {
    final calls = <String, int>{};
    final container = ProviderContainer(overrides: [
      hostControlClientProvider.overrideWith((ref) async => _fakeClient(calls)),
    ]);
    addTearDown(container.dispose);

    await container.read(mobileAccessPolicyProvider.future);
    await container.read(mobileAccessPolicyProvider.notifier).enableProject('p1');
    await container.read(mobileAccessPolicyProvider.notifier).disableProject('p1');

    expect(container.read(mobileAccessPolicyProvider).value!.projectIds, isEmpty);
    expect(calls['mobile-access:disable-project'], 1);
  });
}
