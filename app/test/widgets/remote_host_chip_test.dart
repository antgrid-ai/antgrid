import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/remote_host_chip.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_tooltip.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, RemoteHostChip chip) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(body: Center(child: chip)),
      ),
    );

/// The chip's own tooltip. CarbonTag mounts a second, usually disabled, one for
/// truncation, so a bare type finder matches two.
final _hostTooltip = find.byWidgetPredicate(
  (w) => w is CarbonTooltip && w.message.startsWith('Running on'),
);

void main() {
  testWidgets('the host RAM shows on hover only, never in the chip', (
    tester,
  ) async {
    await _pump(
      tester,
      const RemoteHostChip(
        hostMachineName: 'DESKTOP-TMDH9M9',
        platform: 'windows',
        ram: 'RAM 20.0 GB / 32.0 GB',
      ),
    );

    expect(find.text('DESKTOP-TMDH9M9'), findsOneWidget);
    expect(find.textContaining('RAM'), findsNothing);
    final tooltip = tester.widget<CarbonTooltip>(_hostTooltip);
    expect(tooltip.message, 'Running on DESKTOP-TMDH9M9\nRAM 20.0 GB / 32.0 GB');
  });

  testWidgets('the host CPU is in the tooltip, never in the chip', (
    tester,
  ) async {
    await _pump(
      tester,
      const RemoteHostChip(
        hostMachineName: 'DESKTOP-TMDH9M9',
        platform: 'windows',
        ram: 'RAM 20.0 GB / 32.0 GB',
        cpuPercent: 37,
      ),
    );

    expect(find.text('DESKTOP-TMDH9M9'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    final tooltip = tester.widget<CarbonTooltip>(_hostTooltip);
    expect(
      tooltip.message,
      'Running on DESKTOP-TMDH9M9\nCPU 37%\nRAM 20.0 GB / 32.0 GB',
    );
  });

  testWidgets('hovering the chip asks the host for its stats', (tester) async {
    var requests = 0;
    await _pump(
      tester,
      RemoteHostChip(
        hostMachineName: 'DESKTOP-TMDH9M9',
        platform: 'windows',
        onRequestStats: () => requests++,
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(RemoteHostChip)));
    await tester.pump();

    expect(requests, 1);
  });

  testWidgets('a host that has not reported names itself alone on hover', (
    tester,
  ) async {
    await _pump(
      tester,
      const RemoteHostChip(hostMachineName: 'DESKTOP-TMDH9M9', platform: null),
    );

    final tooltip = tester.widget<CarbonTooltip>(_hostTooltip);
    expect(tooltip.message, 'Running on DESKTOP-TMDH9M9');
  });

  CarbonIcons glyph(WidgetTester tester) => tester
      .widget<CarbonIcon>(
        find.descendant(
          of: find.byType(CarbonTag),
          matching: find.byType(CarbonIcon),
        ),
      )
      .icon;

  for (final (platform, expected) in <(String?, CarbonIcons)>[
    (null, CarbonIcons.laptop),
    ('windows', CarbonIcons.laptop),
    ('macos', CarbonIcons.laptop),
    ('ios', CarbonIcons.mobile),
    ('android', CarbonIcons.mobile),
    ('plan9', CarbonIcons.serverDns),
  ]) {
    testWidgets('the glyph for platform $platform is $expected', (tester) async {
      await _pump(
        tester,
        RemoteHostChip(hostMachineName: 'box', platform: platform),
      );
      expect(glyph(tester), expected);
    });
  }

  testWidgets('it is a read-only Carbon tag with no Antgrid pieces', (
    tester,
  ) async {
    await _pump(
      tester,
      const RemoteHostChip(hostMachineName: 'box', platform: 'linux'),
    );

    final tag = tester.widget<CarbonTag>(find.byType(CarbonTag));
    expect(tag.label, 'box');
    expect(tag.onPressed, isNull);
    expect(find.byType(AbIcon), findsNothing);
    expect(find.byType(AbTooltip), findsNothing);
  });

  testWidgets('an empty name degrades to "Remote host"', (tester) async {
    await _pump(
      tester,
      const RemoteHostChip(hostMachineName: '', platform: null),
    );
    expect(find.text('Remote host'), findsOneWidget);
    expect(tester.widget<CarbonTag>(find.byType(CarbonTag)).label, 'Remote host');
  });
}
