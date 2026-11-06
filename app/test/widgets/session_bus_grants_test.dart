import 'dart:convert';

import 'package:antgrid/design/widgets/ab_switch.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/widgets/remote_access_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/toast_host.dart';

class _Devices extends RemoteDevicesNotifier {
  @override
  Future<PhonesList> build() async =>
      const PhonesList(phones: [], knownProjects: []);
}

class _Policy extends RemoteAccessPolicyNotifier {
  @override
  Future<RemoteAccessPolicy> build() async =>
      const RemoteAccessPolicy(enabled: true);
}

class _Reach extends AgentReachPolicyNotifier {
  @override
  Future<AgentReachPolicy> build() async =>
      AgentReachPolicy(enabled: true);
}

final _orchestrator = find.byKey(const Key('orchestrator-switch'));

DeviceSummary _self({bool? orchestrator}) => DeviceSummary(
  id: 'row-1',
  deviceId: 'me-uuid',
  kind: 'agent',
  platform: 'windows',
  displayName: 'Desk',
  orchestrator: orchestrator,
);

const _failedToast = 'Could not update agent control. Try again.';

Future<List<http.Request>> _pump(
  WidgetTester tester, {
  required DeviceSummary self,
  int status = 200,
  String? responseBody,
  bool devicesFail = false,
}) async {
  final calls = <http.Request>[];
  final api = DevicesApi(
    licenseApiUrl: 'http://web.test',
    cookieProvider: () async => 'session=abc',
    httpClient: MockClient((req) async {
      calls.add(req);
      return http.Response(
        responseBody ?? jsonEncode({'orchestrator': false}),
        status,
      );
    }),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localDeviceUuidProvider.overrideWith((ref) async => 'me-uuid'),
        accountDevicesByBridgeIdProvider.overrideWith(
          (ref) async => devicesFail
              ? throw http.ClientException('offline')
              : {'me-uuid': self},
        ),
        devicesApiProvider.overrideWithValue(api),
        remoteDevicesProvider.overrideWith(_Devices.new),
        remoteAccessPolicyProvider.overrideWith(_Policy.new),
        agentReachPolicyProvider.overrideWith(_Reach.new),
      ],
      child: const MaterialApp(
        builder: abToastHostBuilder,
        home: Scaffold(body: RemoteAccessPanel()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return calls;
}

void main() {
  testWidgets('renders the orchestrator grant from the account row', (
    tester,
  ) async {
    await _pump(tester, self: _self(orchestrator: true));

    expect(
      find.text('Orchestrator: may drive other machines'),
      findsOneWidget,
    );
    expect(find.text('Accept control from orchestrators'), findsNothing);
    expect(tester.widget<AbSwitch>(_orchestrator).value, isTrue);
  });

  testWidgets('toggling orchestrator PATCHes only orchestrator', (tester) async {
    final calls = await _pump(
      tester,
      self: _self(orchestrator: false),
      responseBody: jsonEncode({'orchestrator': true}),
    );

    await tester.tap(_orchestrator);
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'PATCH');
    expect(calls.single.url.path, '/account/devices/row-1/session-bus');
    expect(calls.single.headers['cookie'], 'session=abc');
    expect(jsonDecode(calls.single.body), {'orchestrator': true});
    // The switch shows what the server answered, not what was tapped.
    expect(tester.widget<AbSwitch>(_orchestrator).value, isTrue);
  });

  testWidgets('a refused PATCH leaves the switch where it was', (tester) async {
    final calls = await _pump(
      tester,
      self: _self(orchestrator: false),
      status: 403,
      responseBody: '{}',
    );

    await tester.tap(_orchestrator);
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(tester.widget<AbSwitch>(_orchestrator).value, isFalse);
    expect(find.text(_failedToast), findsOneWidget);
  });

  testWidgets('a failed read of the account row shows no switch and no toast', (
    tester,
  ) async {
    final calls = await _pump(
      tester,
      self: _self(orchestrator: false),
      devicesFail: true,
    );
    await tester.pumpAndSettle();

    expect(_orchestrator, findsNothing);
    expect(find.text(_failedToast), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('no switch when the row carries no grant', (tester) async {
    await _pump(tester, self: _self());

    expect(_orchestrator, findsNothing);
  });
}
