import 'dart:async';
import 'dart:convert';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/widgets/remote_access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HostControlClient _fakeClient(Map<String, int> calls) {
  var enabled = false;
  final mock = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final type = body['type'] as String;
    calls[type] = (calls[type] ?? 0) + 1;
    if (type == 'mobile-access:set') enabled = body['enabled'] == true;
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'ok': true,
        'type': type,
        'enabled': enabled,
        'phones': const [],
        'knownProjects': const [],
      }),
      200,
    );
  });
  return HostControlClient(port: 1, token: 't', httpClient: mock);
}

Future<void> _pump(
  WidgetTester tester,
  Future<HostControlClient> Function() client,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [hostControlClientProvider.overrideWith((ref) => client())],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: RemoteAccessControl())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('reports the machine state, and never an action', (tester) async {
    final calls = <String, int>{};
    await _pump(tester, () async => _fakeClient(calls));

    expect(find.text('Remote off'), findsOneWidget);
    // The chip is not the switch: tapping it must not write anything.
    await tester.tap(find.text('Remote off'));
    await tester.pump();
    expect(calls['mobile-access:set'], isNull);
  });

  testWidgets('opens the panel, where the switch lives', (tester) async {
    final calls = <String, int>{};
    await _pump(tester, () async => _fakeClient(calls));

    await tester.tap(find.byKey(const Key('remote-access-chip')));
    await tester.pump();
    await tester.pump();

    expect(find.text('REMOTE ACCESS'), findsOneWidget);
    expect(find.byKey(const Key('remote-access-switch')), findsOneWidget);
  });

  testWidgets('stays visible while the host client is still loading', (
    tester,
  ) async {
    final completer = Completer<HostControlClient>();
    await _pump(tester, () => completer.future);

    // The chip must NOT vanish while the policy is unknown — a missing control
    // leaves no affordance and no retry surface on a persistent host error. It
    // reports "unknown" rather than guessing a state.
    expect(find.text('Remote'), findsOneWidget);
    expect(find.text('Remote off'), findsNothing);

    completer.complete(_fakeClient(<String, int>{}));
    await tester.pump();
    await tester.pump();
    expect(find.text('Remote off'), findsOneWidget);
  });

  testWidgets('reads on when the machine is enabled', (tester) async {
    final calls = <String, int>{};
    final client = _fakeClient(calls);
    await client.remoteAccessSet(true);

    await _pump(tester, () async => client);

    expect(find.text('Remote on'), findsOneWidget);
  });
}
