import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/memory/memory_off_state.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _mount(
  WidgetTester tester, {
  String? machineName,
  String? error,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAbTheme(),
    home: Scaffold(
      body: AbCarbonScope(
        child: MemoryOffState(
          onTurnOn: () {},
          machineName: machineName,
          error: error,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('the first bullet says "this machine" without a name', (
    tester,
  ) async {
    await _mount(tester);
    expect(
      find.text('Stored only on this machine, never in your repository.'),
      findsOneWidget,
    );
  });

  testWidgets('the first bullet names the machine', (tester) async {
    await _mount(tester, machineName: 'Laptop');
    expect(
      find.text('Stored only on Laptop, never in your repository.'),
      findsOneWidget,
    );
    expect(find.textContaining('this machine'), findsNothing);
  });

  testWidgets('the scroll view spans the pane so the wheel works anywhere', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester);
    expect(
      tester.getSize(find.byType(SingleChildScrollView)),
      const Size(1000, 700),
    );
  });

  testWidgets('the error sits above the button as a Carbon notification', (
    tester,
  ) async {
    await _mount(tester, error: 'Memory is busy.');
    expect(find.byType(CarbonNotification), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Memory is busy.')).dy,
      lessThan(tester.getTopLeft(find.text('Turn on Memory')).dy),
    );
  });
}
