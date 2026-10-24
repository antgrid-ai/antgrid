import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/remote_host_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, RemoteHostChip chip) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(body: Center(child: chip)),
      ),
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
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, 'Running on DESKTOP-TMDH9M9\nRAM 20.0 GB / 32.0 GB');
  });

  testWidgets('a host that has not reported names itself alone on hover', (
    tester,
  ) async {
    await _pump(
      tester,
      const RemoteHostChip(hostMachineName: 'DESKTOP-TMDH9M9', platform: null),
    );

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, 'Running on DESKTOP-TMDH9M9');
  });
}
