import 'dart:convert';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/providers/screen_control.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Stands in for the bridge's screen-control store: `screen-control:set` writes
/// the boolean and, like the real verb, answers with the resulting state rather
/// than echoing the request.
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
    if (type == 'screen-control:set') enabled = body['enabled'] == true;
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

ProviderContainer _container(HostControlClient Function() client) {
  final c = ProviderContainer(
    overrides: [
      hostControlClientProvider.overrideWith((ref) async => client()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('the policy reads off until the bridge answers', () async {
    final calls = <String, int>{};
    final c = _container(() => _fakeClient(calls, initial: true));
    final policy = c.read(hostScreenControlPolicyProvider);

    // A capture host that starts before the first read lands must refuse rather
    // than share on an assumption — even though this machine is in fact ON.
    expect(policy.enabled, isFalse);

    await policy.refresh();
    expect(policy.enabled, isTrue);
  });

  test('every revocation is announced, including a redundant one', () async {
    final calls = <String, int>{};
    final c = _container(() => _fakeClient(calls, initial: true));
    final policy = c.read(hostScreenControlPolicyProvider);
    await policy.refresh();

    final seen = <bool>[];
    final sub = policy.changes.listen(seen.add);
    addTearDown(sub.cancel);

    await policy.setEnabled(false);
    await policy.setEnabled(false);
    await pumpEventQueue();
    // The capability lives in a peer connection nothing here can see, so a
    // second off must still reach whoever holds one. A change-only stream would
    // swallow it.
    expect(seen, [false, false]);

    await policy.setEnabled(true);
    await policy.setEnabled(true);
    await pumpEventQueue();
    // Grants are not urgent the way withdrawals are, so those do dedup.
    expect(seen, [false, false, true]);
  });

  test('a failed read leaves the last-known value alone', () async {
    final calls = <String, int>{};
    final c = _container(
      () => _fakeClient(calls, initial: true, failVerb: 'screen-control:get'),
    );
    final policy = c.read(hostScreenControlPolicyProvider);

    // Seed a known-on state through the path that still works...
    await policy.setEnabled(true);
    expect(policy.enabled, isTrue);

    final seen = <bool>[];
    final sub = policy.changes.listen(seen.add);
    addTearDown(sub.cancel);

    await expectLater(policy.refresh(), throwsA(isA<HostControlException>()));
    await pumpEventQueue();

    // ...and a loopback blip is not evidence of revocation. Flipping the cache
    // off here would tear down a live session the user never ended, and the
    // bridge's own store is the authority the outbound gate consults anyway.
    expect(policy.enabled, isTrue);
    expect(seen, isEmpty);
  });

  test('the UI notifier and the capture host see one switch, not two', () async {
    final calls = <String, int>{};
    final c = _container(() => _fakeClient(calls));
    final policy = c.read(hostScreenControlPolicyProvider);

    expect(await c.read(screenControlSwitchProvider.future), isFalse);
    await c.read(screenControlSwitchProvider.notifier).setEnabled(true);

    // The panel's flip has to reach the services directly: they hold `policy`,
    // never the notifier, and a second cached copy would let the two disagree
    // about whether a remote peer still has the mouse.
    expect(c.read(screenControlSwitchProvider).value, isTrue);
    expect(policy.enabled, isTrue);
    expect(calls['screen-control:set'], 1);
  });

  test('a failed flip retains the last-known state under the error', () async {
    final calls = <String, int>{};
    final c = _container(
      () => _fakeClient(calls, initial: true, failVerb: 'screen-control:set'),
    );

    await c.read(screenControlSwitchProvider.future);
    await c.read(screenControlSwitchProvider.notifier).setEnabled(false);

    final state = c.read(screenControlSwitchProvider);
    expect(state.hasError, isTrue);
    // The panel surfaces the failure separately; a switch that vanishes mid-flip
    // tells the user less than one still showing where the machine stands.
    expect(state.value, isTrue);
  });
}
