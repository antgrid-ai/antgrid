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
  var enabled = false;
  final mock = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final type = body['type'] as String;
    calls[type] = (calls[type] ?? 0) + 1;
    if (type == 'mobile-access:set') enabled = body['enabled'] == true;
    return http.Response(jsonEncode({
      'id': body['id'],
      'ok': true,
      'type': type,
      'enabled': enabled,
    }), 200);
  });
  return HostControlClient(port: 1, token: 't', httpClient: mock);
}

void main() {
  testWidgets('enable flips the machine-wide switch on', (tester) async {
    final calls = <String, int>{};
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostControlClientProvider.overrideWith((ref) async => _fakeClient(calls)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: MobileAccessToggle()),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Enable mobile access'), findsOneWidget);
    await tester.tap(find.text('Enable mobile access'));
    await tester.pump();
    await tester.pump();

    expect(calls['mobile-access:set'], 1);
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
        home: Scaffold(body: MobileAccessToggle()),
      ),
    ));
    await tester.pump();

    // The control must NOT vanish (no SizedBox.shrink) while policy is unknown —
    // the user keeps an affordance. Tapping it is a no-op until data arrives.
    expect(find.text('Enable mobile access'), findsOneWidget);
    await tester.tap(find.text('Enable mobile access'));
    await tester.pump();
    expect(calls['mobile-access:set'], isNull);

    completer.complete(_fakeClient(calls));
    await tester.pump();
    await tester.pump();
    expect(find.text('Enable mobile access'), findsOneWidget);
  });

  testWidgets('disable flips the machine-wide switch off', (tester) async {
    final calls = <String, int>{};
    final client = _fakeClient(calls);
    await client.mobileAccessSet(true);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostControlClientProvider.overrideWith((ref) async => client),
      ],
      child: const MaterialApp(
        home: Scaffold(body: MobileAccessToggle()),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Disable mobile access'), findsOneWidget);
    await tester.tap(find.text('Disable mobile access'));
    await tester.pump();
    await tester.pump();

    expect(calls['mobile-access:set'], 2);
    expect(find.text('Enable mobile access'), findsOneWidget);
  });
}
