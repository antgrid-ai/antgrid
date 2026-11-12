import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid/widgets/new_session/worktree_setup_nudge.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _message =
    'Isolated sessions start from a clean checkout — ignored files '
    "like .env and node_modules aren't there.";

const _target = PickerProject(
  id: 'proj',
  name: 'proj',
  detail: '/work/proj',
  isLocal: true,
);

/// Starts from a fixed answer and records writes in memory, so nothing touches
/// shared preferences.
class _FakeSeen extends WorktreeSetupNudgeSeen {
  _FakeSeen(this._initial);

  final Set<String> _initial;

  @override
  Future<Set<String>> build() async => _initial;

  @override
  Future<void> markSeen(String entryId) async {
    state = AsyncData({...?state.value, entryId});
  }
}

Widget _wrap({
  bool isolated = true,
  bool ready = true,
  PickerProject? target = _target,
  Set<String> seen = const {},
}) => ProviderScope(
  overrides: [
    newSessionIsolatedProvider.overrideWith(() => ValueController(isolated)),
    newSessionIsolationReadyProvider.overrideWithValue(ready),
    selectedTargetProjectProvider.overrideWith(
      () => ValueController<PickerProject?>(target),
    ),
    worktreeSetupNudgeSeenProvider.overrideWith(() => _FakeSeen(seen)),
  ],
  child: const MaterialApp(
    home: Scaffold(body: AbCarbonScope(child: WorktreeSetupNudge())),
  ),
);

void main() {
  testWidgets('shows the warning with its action while isolation is on', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.pump();

    expect(find.text(_message), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is CarbonNotification && w.kind == CarbonNotificationKind.info,
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Add setup steps'),
        matching: find.byType(CarbonButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('stays hidden when isolation is off', (tester) async {
    await tester.pumpWidget(_wrap(isolated: false));
    await tester.pump();
    await tester.pump();
    expect(find.text(_message), findsNothing);
  });

  testWidgets('stays hidden when the target cannot make worktrees', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(ready: false));
    await tester.pump();
    await tester.pump();
    expect(find.text(_message), findsNothing);
  });

  testWidgets('stays hidden with no target', (tester) async {
    await tester.pumpWidget(_wrap(target: null));
    await tester.pump();
    await tester.pump();
    expect(find.text(_message), findsNothing);
  });

  testWidgets('stays hidden for a project already dismissed', (tester) async {
    await tester.pumpWidget(_wrap(seen: {'proj'}));
    await tester.pump();
    await tester.pump();
    expect(find.text(_message), findsNothing);
  });

  testWidgets('the close button dismisses it for this project only', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is CarbonButton &&
            w.semanticLabel == "Dismiss — won't ask again for this project",
      ),
    );
    await tester.pump();

    expect(find.text(_message), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );
    expect(container.read(worktreeSetupNudgeSeenProvider).value, {'proj'});
  });
}
