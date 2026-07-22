import 'dart:async';
import 'dart:convert';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
import 'package:antgrid/widgets/mobile_access_toggle.dart';
import 'package:flutter/material.dart';
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
  testWidgets('enable with zero paired phones sends project-level enable', (tester) async {
    final calls = <String, int>{};
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostControlClientProvider.overrideWith((ref) async => _fakeClient(calls)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: MobileAccessToggle(projectId: 'p1')),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Enable mobile access'), findsOneWidget);
    await tester.tap(find.text('Enable mobile access'));
    await tester.pump();
    await tester.pump();

    expect(calls['mobile-access:enable-project'], 1);
    expect(find.text('Disable mobile access'), findsOneWidget);
  });

  testWidgets('stays visible but inert while the host client is still loading', (tester) async {
    final calls = <String, int>{};
    final completer = Completer<HostControlClient>();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostControlClientProvider.overrideWith((ref) => completer.future),
      ],
      child: const MaterialApp(
        home: Scaffold(body: MobileAccessToggle(projectId: 'p1')),
      ),
    ));
    await tester.pump();

    // The control must NOT vanish (no SizedBox.shrink) while policy is unknown —
    // the user keeps an affordance. Tapping it is a no-op until data arrives.
    expect(find.text('Enable mobile access'), findsOneWidget);
    await tester.tap(find.text('Enable mobile access'));
    await tester.pump();
    expect(calls['mobile-access:enable-project'], isNull);

    completer.complete(_fakeClient(calls));
    await tester.pump();
    await tester.pump();
    expect(find.text('Enable mobile access'), findsOneWidget);
  });

  testWidgets('disable sends project-level disable', (tester) async {
    final calls = <String, int>{};
    final client = _fakeClient(calls);
    await client.mobileAccessEnableProject('p1');

    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostControlClientProvider.overrideWith((ref) async => client),
      ],
      child: const MaterialApp(
        home: Scaffold(body: MobileAccessToggle(projectId: 'p1')),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Disable mobile access'), findsOneWidget);
    await tester.tap(find.text('Disable mobile access'));
    await tester.pump();
    await tester.pump();

    expect(calls['mobile-access:disable-project'], 1);
    expect(find.text('Enable mobile access'), findsOneWidget);
  });
}
