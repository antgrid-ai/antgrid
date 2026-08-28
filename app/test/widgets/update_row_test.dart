import 'package:antgrid/design/widgets/ab_progress_rule.dart';
import 'package:antgrid/providers/update_available.dart';
import 'package:antgrid/update/update_install_controller.dart';
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
  Future<UpdateInstallResult> install(BuildContext context) async {
    installs++;
    return UpdateInstallResult.handedOff;
  }
}

class _RestartCopyStrategy extends _FakeStrategy {
  @override
  String get rowTitle => 'Update ready';

  @override
  String get rowActionLabel => 'Restart';
}

/// Stands in for the real sequence and seeds the state the row renders. The
/// row's only job is to hand the tap over, so entries here — not what the
/// sequence then does — are what these tests assert.
class _SpyController extends UpdateInstallController {
  _SpyController(this._seed);

  final UpdateInstallState _seed;
  int starts = 0;

  /// Deliberately skips `super.build()`: the real one resolves
  /// `hostControllerProvider`, reaching the process-global launcher singleton
  /// and attaching an `unsealSpawns()` to this container's disposal. The row
  /// only renders state, so the seed is the whole contract here.
  @override
  UpdateInstallState build() => _seed;

  @override
  Future<void> start(BuildContext context, {bool confirm = true}) async {
    starts++;
  }
}

Future<({ProviderContainer container, _SpyController install})> _pumpRow(
  WidgetTester tester,
  UpdateStrategy? strategy, {
  bool lit = true,
  UpdateInstallState install = const UpdateInstallIdle(),
}) async {
  final spy = _SpyController(install);
  final container = ProviderContainer(
    overrides: [
      updateStrategyProvider.overrideWithValue(strategy),
      updateInstallControllerProvider.overrideWith(() => spy),
    ],
  );
  addTearDown(container.dispose);
  if (lit) container.read(updateAvailableProvider.notifier).set(true);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: UpdateRow())),
    ),
  );
  return (container: container, install: spy);
}

void main() {
  testWidgets('collapses while no update is pending', (tester) async {
    final strategy = _FakeStrategy();
    await _pumpRow(tester, strategy, lit: false);
    expect(find.text('Update available'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('lit row renders the strategy copy and taps into the sequence', (
    tester,
  ) async {
    final strategy = _FakeStrategy();
    final h = await _pumpRow(tester, strategy);

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);

    await tester.tap(find.byType(InkWell));
    await tester.pump();
    // Through the controller, never straight at the strategy: the confirm,
    // the host drain and the debounce all live there.
    expect(h.install.starts, 1);
    expect(strategy.installs, 0);
  });

  testWidgets('a running install reports progress and refuses a second tap', (
    tester,
  ) async {
    // The first seconds of a Windows install are silent — the Store re-scans
    // its pending set before showing anything of its own — which is long enough
    // for an impatient second tap to start a second install.
    final h = await _pumpRow(
      tester,
      _FakeStrategy(),
      install: const UpdateInstallWorking(42),
    );

    expect(find.text('Updating... 42%'), findsOneWidget);
    expect(
      tester.widget<AbProgressRule>(find.byType(AbProgressRule)).fraction,
      0.42,
    );
    // An action label on a row that refuses taps reads as a dead button.
    expect(find.text('Update'), findsNothing);

    await tester.tap(find.byType(InkWell), warnIfMissed: false);
    await tester.pump();
    expect(h.install.starts, 0);
  });

  testWidgets('the pre-download plateau reads as waiting, not as stuck at 0%', (
    tester,
  ) async {
    // Nothing ticks until the Store has re-scanned and taken the user through
    // both of its consent dialogs — minutes, potentially. A hard "0%" over a
    // rule pinned at zero is indistinguishable from a wedged install.
    await _pumpRow(
      tester,
      _FakeStrategy(),
      install: const UpdateInstallWorking(0),
    );

    expect(find.text('Updating...'), findsOneWidget);
    expect(
      tester.widget<AbProgressRule>(find.byType(AbProgressRule)).fraction,
      isNull,
      reason: 'indeterminate, not zero',
    );
  });

  testWidgets('a handed-over install never becomes tappable again', (
    tester,
  ) async {
    // Done is reached only where the process is already dying around the row;
    // offering a second install there would be offering a second restart.
    final h = await _pumpRow(
      tester,
      _FakeStrategy(),
      install: const UpdateInstallDone(),
    );

    expect(find.text('Updating...'), findsOneWidget);
    expect(find.text('Update'), findsNothing);

    await tester.tap(find.byType(InkWell), warnIfMissed: false);
    await tester.pump();
    expect(h.install.starts, 0);
  });

  testWidgets('a failed attempt leaves the row offering the update again', (
    tester,
  ) async {
    // The update stays pending until the app restarts, so a declined or
    // cancelled install must not spend the affordance.
    final h = await _pumpRow(
      tester,
      _FakeStrategy(),
      install: const UpdateInstallFailed(UpdateInstallResult.notInstalled),
    );

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);

    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(h.install.starts, 1);
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
