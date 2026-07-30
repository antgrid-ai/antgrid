import 'package:antgrid/design/widgets/ab_toast.dart';
import 'package:antgrid/providers/update_available.dart';
import 'package:antgrid/update/update_gate.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStrategy extends UpdateStrategy {
  _FakeStrategy(this.outcome, {this.isActive = true});
  final UpdateCheckOutcome outcome;
  final bool isActive;
  final List<bool> litArgs = [];
  int installs = 0;

  @override
  bool get active => isActive;

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async {
    litArgs.add(rowAlreadyLit);
    return outcome;
  }

  @override
  Future<void> install(BuildContext context) async {
    installs++;
  }
}

Future<ProviderContainer> _pumpGate(
  WidgetTester tester,
  UpdateStrategy? strategy, {
  bool preLit = false,
}) async {
  final container = ProviderContainer(
    overrides: [updateStrategyProvider.overrideWithValue(strategy)],
  );
  addTearDown(container.dispose);
  if (preLit) container.read(updateAvailableProvider.notifier).set(true);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: UpdateGate(child: SizedBox.shrink())),
    ),
  );
  // First pump runs the post-frame check's future; second settles the
  // overlay insert it may trigger.
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  testWidgets('update-available lights the row and announces with a toast', (
    tester,
  ) async {
    final strategy = _FakeStrategy(UpdateCheckOutcome.updateAvailable);
    final container = await _pumpGate(tester, strategy);

    expect(container.read(updateAvailableProvider), isTrue);
    expect(strategy.litArgs, [false]);
    expect(find.byType(AbToast), findsOneWidget);
    expect(find.text('Update available'), findsOneWidget);

    // The toast's action routes to the same strategy install as the row.
    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(strategy.installs, 1);

    await tester.pump(const Duration(seconds: 11)); // expire the toast timer
  });

  testWidgets('a quiet outcome lights the row without a toast', (tester) async {
    // Windows' mandatory tier: the auto-launched Store dialog is already on
    // screen, so the gate must not stack an announcement on top of it.
    final strategy = _FakeStrategy(UpdateCheckOutcome.updateAvailableQuiet);
    final container = await _pumpGate(tester, strategy);

    expect(container.read(updateAvailableProvider), isTrue);
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('an already-lit row is not re-announced', (tester) async {
    final strategy = _FakeStrategy(UpdateCheckOutcome.updateAvailable);
    final container = await _pumpGate(tester, strategy, preLit: true);

    // Windows' optional tier keeps returning updateAvailable while lit —
    // the row must stay latched without a toast on every throttled check.
    expect(strategy.litArgs, [true]);
    expect(container.read(updateAvailableProvider), isTrue);
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('restart-ready prompts AND lights the row as a fallback', (
    tester,
  ) async {
    final strategy = _FakeStrategy(UpdateCheckOutcome.restartReady);
    final container = await _pumpGate(tester, strategy);

    // A missed 30-second toast must leave the drawer row as a durable
    // affordance; its tap runs the same install (completeFlexibleUpdate).
    expect(container.read(updateAvailableProvider), isTrue);
    expect(find.text('Update ready'), findsOneWidget);

    await tester.tap(find.text('Restart'));
    await tester.pump();
    expect(strategy.installs, 1);

    await tester.pump(const Duration(seconds: 31)); // expire the toast timer
  });

  testWidgets('an already-lit row is not re-prompted to restart', (
    tester,
  ) async {
    // Play keeps reporting a downloaded flexible update until the user
    // actually restarts, so every throttled resume re-enters this branch —
    // without the latch guard the same toast re-appears for the whole
    // process lifetime over a row already offering 'Restart'.
    final strategy = _FakeStrategy(UpdateCheckOutcome.restartReady);
    final container = await _pumpGate(tester, strategy, preLit: true);

    expect(container.read(updateAvailableProvider), isTrue);
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('an inactive strategy never checks', (tester) async {
    final strategy = _FakeStrategy(
      UpdateCheckOutcome.updateAvailable,
      isActive: false,
    );
    final container = await _pumpGate(tester, strategy);

    expect(strategy.litArgs, isEmpty);
    expect(container.read(updateAvailableProvider), isFalse);
    expect(find.byType(AbToast), findsNothing);
  });

  testWidgets('a platform with no strategy is an inert pass-through', (
    tester,
  ) async {
    final container = await _pumpGate(tester, null);
    expect(container.read(updateAvailableProvider), isFalse);
    expect(find.byType(AbToast), findsNothing);
  });
}
