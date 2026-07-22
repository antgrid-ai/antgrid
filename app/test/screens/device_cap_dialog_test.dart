import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/screens/device_cap_dialog.dart';
import 'package:antgrid/services/devices_api.dart';

DeviceCapInfo _info() => DeviceCapInfo(
  message:
      'Device limit reached (10/10). Remove a device to register this one.',
  limit: 10,
  devices: [
    CappedDevice(id: 'd1', deviceId: 'uuid-aaa', displayName: 'Old laptop'),
    CappedDevice(id: 'd2', deviceId: 'uuid-bbb', displayName: 'Spare phone'),
  ],
);

Future<void> _pump(WidgetTester tester, {List<Override> overrides = const []}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(home: DeviceCapDialog(info: _info())),
    ),
  );
}

void main() {
  testWidgets('lists capped devices with an actionable, non-upgrade message', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Device limit reached'), findsOneWidget);
    expect(find.textContaining('Remove a device'), findsOneWidget);
    // The cap message must never push an upgrade — deviceLimit is flat by tier.
    expect(find.textContaining('upgrade', skipOffstage: false), findsNothing);
    expect(find.text('Old laptop'), findsOneWidget);
    expect(find.text('Spare phone'), findsOneWidget);
    expect(find.text('uuid-aaa'), findsOneWidget);
    // One Remove per device + a Close.
    expect(find.widgetWithText(AbButton, 'Remove'), findsNWidgets(2));
    expect(find.widgetWithText(AbButton, 'Close'), findsOneWidget);
  });

  testWidgets('a failed revoke surfaces an error and keeps the device listed', (
    tester,
  ) async {
    // DELETE → 500 so DevicesApi.revoke returns false (the failure branch).
    final failingApi = DevicesApi(
      licenseApiUrl: 'https://api.test',
      cookieProvider: () async => 'session=v',
      httpClient: MockClient((_) async => http.Response('nope', 500)),
    );

    await _pump(
      tester,
      overrides: [devicesApiProvider.overrideWithValue(failingApi)],
    );

    await tester.tap(find.widgetWithText(AbButton, 'Remove').first);
    await tester.pumpAndSettle();

    // Confirm dialog is up; confirm the removal (its button is pushed last).
    await tester.tap(find.widgetWithText(AbButton, 'Remove').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not remove'), findsOneWidget);
    // Revoke failed, so the device stays in the list.
    expect(find.text('Old laptop'), findsOneWidget);
  });
}
