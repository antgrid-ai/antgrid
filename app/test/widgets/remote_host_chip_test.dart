import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/remote_host_chip.dart';
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
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
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

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, 'Running on DESKTOP-TMDH9M9');
  });
}
