import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/memory/memory_off_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _mount(WidgetTester tester, {String? machineName}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: MemoryOffState(onTurnOn: () {}, machineName: machineName),
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
}
