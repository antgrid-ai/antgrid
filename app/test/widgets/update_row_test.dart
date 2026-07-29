import 'package:antgrid/providers/update_available.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:antgrid/widgets/update_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStrategy extends UpdateStrategy {
  int installs = 0;

  @override
  bool get active => true;

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async =>
      UpdateCheckOutcome.none;

  @override
  Future<void> install(BuildContext context) async {
    installs++;
  }
}

class _RestartCopyStrategy extends _FakeStrategy {
  @override
  String get rowTitle => 'Update ready';

  @override
  String get rowActionLabel => 'Restart';
}

Future<ProviderContainer> _pumpRow(
  WidgetTester tester,
  UpdateStrategy? strategy, {
  bool lit = true,
}) async {
  final container = ProviderContainer(
    overrides: [updateStrategyProvider.overrideWithValue(strategy)],
  );
  addTearDown(container.dispose);
  if (lit) container.read(updateAvailableProvider.notifier).set(true);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: UpdateRow())),
    ),
  );
  return container;
}

void main() {
  testWidgets('collapses while no update is pending', (tester) async {
    final strategy = _FakeStrategy();
    await _pumpRow(tester, strategy, lit: false);
    expect(find.text('Update available'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('lit row renders the strategy copy and taps into install', (
    tester,
  ) async {
    final strategy = _FakeStrategy();
    await _pumpRow(tester, strategy);

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);

    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(strategy.installs, 1);
  });

  testWidgets('a strategy with stronger install semantics owns its copy', (
    tester,
  ) async {
    // Play's tap restarts the app in place — the row must say so instead of
    // the generic download-promise copy.
    await _pumpRow(tester, _RestartCopyStrategy());

    expect(find.text('Update ready'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('Update available'), findsNothing);
  });
}
