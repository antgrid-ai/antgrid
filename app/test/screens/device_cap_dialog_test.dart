import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/screens/device_cap_dialog.dart';
import 'package:antgrid/services/devices_api.dart';

DeviceCapInfo _info() => DeviceCapInfo(
  message:
      'Device limit reached (10/10). Remove a device to register this one.',
  kind: DeviceCapKind.appDevice,
  limit: 10,
  devices: [
    CappedDevice(id: 'd1', deviceId: 'uuid-aaa', displayName: 'Old laptop'),
    CappedDevice(id: 'd2', deviceId: 'uuid-bbb', displayName: 'Spare phone'),
  ],
);

DeviceCapInfo _workerInfo({int devices = 2}) => DeviceCapInfo(
  message: 'Machine limit reached (1/1). Sign out a machine to add this one.',
  kind: DeviceCapKind.worker,
  limit: 1,
  devices: [
    for (var i = 0; i < devices; i++)
      CappedDevice(
        id: 'w$i',
        deviceId: 'uuid-worker-$i',
        displayName: 'Build box $i',
      ),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  List<Override> overrides = const [],
  DeviceCapInfo? info,
  double textScale = 1,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: DeviceCapDialog(info: info ?? _info()),
      ),
    ),
  );
}

Finder _button(String label) => find.widgetWithText(CarbonButton, label);

CarbonButton _buttonWidget(WidgetTester tester, String label) =>
    tester.widget<CarbonButton>(_button(label));

void main() {
  testWidgets('lists capped devices with an actionable, non-upgrade message', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Device limit reached'), findsOneWidget);
    expect(find.textContaining('Remove a device'), findsOneWidget);
    // The app-device ceiling is an abuse bound pricing never mentions, so no
    // plan can raise it and the message must never push an upgrade.
    expect(find.textContaining('upgrade', skipOffstage: false), findsNothing);
    expect(find.text('Old laptop'), findsOneWidget);
    expect(find.text('Spare phone'), findsOneWidget);
    expect(find.text('uuid-aaa'), findsOneWidget);
    // One Remove per device + a Close.
    expect(_button('Remove'), findsNWidgets(2));
    expect(_button('Close'), findsOneWidget);
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

    await tester.tap(_button('Remove').first);
    await tester.pumpAndSettle();

    // Confirm dialog is up; confirm the removal (its button is pushed last).
    await tester.tap(_button('Remove').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not remove'), findsOneWidget);
    // Revoke failed, so the device stays in the list.
    expect(find.text('Old laptop'), findsOneWidget);
    // The failure reads as Carbon's inline error notification, not bare text.
    final notification = tester.widget<CarbonNotification>(
      find.byType(CarbonNotification),
    );
    expect(notification.kind, CarbonNotificationKind.error);
  });

  testWidgets('the app-limit footer is Close alone, as a secondary button', (
    tester,
  ) async {
    await _pump(tester);

    expect(_button('Join the waitlist'), findsNothing);
    expect(_buttonWidget(tester, 'Close').kind, CarbonButtonKind.secondary);
    // Footer buttons are flush Carbon actions: the lone Close hangs off the
    // modal's bottom edge rather than floating in a padded wrap.
    final modal = tester.getRect(find.byType(CarbonModal));
    final close = tester.getRect(_button('Close'));
    expect(close.bottom, closeTo(modal.bottom, 2));
    expect(close.right, closeTo(modal.right, 2));
  });

  testWidgets('the worker footer is Close then a primary Join the waitlist', (
    tester,
  ) async {
    await _pump(tester, info: _workerInfo());

    expect(find.text('Machine limit reached'), findsOneWidget);
    expect(_buttonWidget(tester, 'Close').kind, CarbonButtonKind.secondary);
    expect(
      _buttonWidget(tester, 'Join the waitlist').kind,
      CarbonButtonKind.primary,
    );
    final close = tester.getRect(_button('Close'));
    final join = tester.getRect(_button('Join the waitlist'));
    // Test fonts are about 2x real width, so the set may stack instead of
    // sitting in one row; either way Join is first (left, or on top).
    final inRow = close.right <= join.left + 0.5;
    final stacked = join.bottom <= close.top + 0.5;
    expect(inRow || stacked, isTrue);
    expect(close.width, closeTo(join.width, 0.5));
  });

  testWidgets('the not-on-sale line sits in the body above the device list', (
    tester,
  ) async {
    await _pump(tester, info: _workerInfo());

    final line = find.text('More machines aren\'t on sale yet.');
    expect(
      find.descendant(of: find.byType(CarbonModal), matching: line),
      findsOneWidget,
    );
    final lineRect = tester.getRect(line);
    final firstRow = tester.getRect(find.text('Build box 0'));
    final footer = tester.getRect(_button('Close'));
    expect(lineRect.bottom, lessThanOrEqualTo(firstRow.top));
    // Not beside the footer buttons: it ends before the footer begins.
    expect(lineRect.bottom, lessThanOrEqualTo(footer.top));
    expect(find.text('More machines aren\'t on sale yet.'), findsOneWidget);
  });

  testWidgets('Remove is a danger ghost button and the id is in code type', (
    tester,
  ) async {
    await _pump(tester);

    for (final button in tester.widgetList<CarbonButton>(_button('Remove'))) {
      expect(button.kind, CarbonButtonKind.dangerGhost);
    }
    final id = tester.widget<Text>(find.text('uuid-aaa'));
    expect(id.style?.fontFamily, contains(CarbonTypography.monoFamily));
    final name = tester.widget<Text>(find.text('Old laptop'));
    expect(name.style?.fontFamily, isNot(contains(CarbonTypography.monoFamily)));
  });

  testWidgets('the worker rows say Sign out, not Remove', (tester) async {
    await _pump(tester, info: _workerInfo());

    expect(_button('Sign out'), findsNWidgets(2));
    expect(_button('Remove'), findsNothing);
    for (final b in tester.widgetList<CarbonButton>(_button('Sign out'))) {
      expect(b.kind, CarbonButtonKind.dangerGhost);
    }
  });

  testWidgets('a row is named by device and id so same-named devices differ', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      info: DeviceCapInfo(
        message: 'Device limit reached (2/2).',
        kind: DeviceCapKind.appDevice,
        limit: 2,
        devices: [
          CappedDevice(id: 'a', deviceId: 'uuid-aaa', displayName: 'iPhone'),
          CappedDevice(id: 'b', deviceId: 'uuid-bbb', displayName: 'iPhone'),
        ],
      ),
    );

    expect(find.bySemanticsLabel(RegExp('iPhone.*uuid-aaa')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('iPhone.*uuid-bbb')), findsOneWidget);
    handle.dispose();
  });

  testWidgets("the scrim is Carbon's overlay, not the Material barrier", (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showDeviceCapDialog(context, ref, _info()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final overlay = CarbonTheme.of(tester.element(find.byType(CarbonModal)))
        .colors
        .overlay;
    expect(
      find.descendant(
        of: find.byType(DeviceCapDialog),
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == overlay,
        ),
      ),
      findsOneWidget,
    );
    // The route's own barrier must add no second, Material-black dimming.
    for (final b in tester.widgetList<ModalBarrier>(find.byType(ModalBarrier))) {
      expect((b.color?.toARGB32() ?? 0) >>> 24, 0);
    }
  });

  testWidgets('while a revoke is in flight every action is disabled', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    final slowApi = DevicesApi(
      licenseApiUrl: 'https://api.test',
      cookieProvider: () async => 'session=v',
      httpClient: MockClient((_) => gate.future),
    );
    await _pump(
      tester,
      info: _workerInfo(),
      overrides: [devicesApiProvider.overrideWithValue(slowApi)],
    );

    await tester.tap(_button('Sign out').first);
    await tester.pumpAndSettle();
    await tester.tap(_button('Sign out').last);
    await tester.pump();
    // Outlast the confirm modal's exit animation, which would otherwise leave
    // its own Sign out button mounted beside the row's.
    await tester.pump(const Duration(milliseconds: 300));

    expect(_button('Signing out…'), findsOneWidget);
    expect(_buttonWidget(tester, 'Signing out…').onPressed, isNull);
    expect(_buttonWidget(tester, 'Close').onPressed, isNull);
    expect(_buttonWidget(tester, 'Sign out').onPressed, isNull);
    // The waitlist stays reachable: it is not part of the revoke.
    expect(_buttonWidget(tester, 'Join the waitlist').onPressed, isNotNull);

    gate.complete(http.Response('nope', 500));
    await tester.pumpAndSettle();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('at 320x640 and ${scale}x text nothing overflows, leaves the '
        'view or crushes a device name', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      await _pump(tester, info: _workerInfo(devices: 8));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final modal = tester.getRect(find.byType(CarbonModal));
      expect(modal.left, greaterThanOrEqualTo(0));
      expect(modal.right, lessThanOrEqualTo(320));
      expect(modal.top, greaterThanOrEqualTo(0));
      expect(modal.bottom, lessThanOrEqualTo(640));
      // The footer stays reachable however long the list is.
      for (final label in ['Close', 'Join the waitlist']) {
        final r = tester.getRect(_button(label));
        expect(r.bottom, lessThanOrEqualTo(640));
        expect(r.right, lessThanOrEqualTo(320));
      }
      // The first row: its action sits beside the name or under it, and the
      // name keeps at least half the row either way.
      final name = tester.getRect(find.text('Build box 0'));
      final action = tester.getRect(_button('Sign out').first);
      expect(
        action.left >= name.right || action.top >= name.bottom,
        isTrue,
        reason: 'the action must not overlap the name',
      );
      final nameBox = tester.getRect(
        find
            .ancestor(of: find.text('Build box 0'), matching: find.byType(Column))
            .first,
      );
      expect(nameBox.width, greaterThanOrEqualTo(modal.width / 2 - 32));
    });
  }
}
