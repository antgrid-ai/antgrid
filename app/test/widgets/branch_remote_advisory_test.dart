import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/branch_remote_status.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/new_session/branch_remote_advisory.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _target = PickerProject(
  id: 'proj',
  name: 'proj',
  detail: '/work/proj',
  isLocal: true,
);

const _behind = BranchRemoteStatus(
  branch: 'main',
  state: BranchRemoteState.behind,
  remote: 'origin',
  remoteBranch: 'main',
  behind: 3,
);

Widget _wrap({bool starting = false}) => ProviderScope(
  overrides: [
    selectedTargetProjectProvider.overrideWith(
      () => ValueController<PickerProject?>(_target),
    ),
    newSessionEffectiveBranchProvider.overrideWith((_) => 'main'),
    newSessionStartInFlightProvider.overrideWithValue(starting),
    newSessionBranchRemoteStatusProvider.overrideWith((ref, key) async {
      return _behind;
    }),
  ],
  child: const MaterialApp(
    home: Scaffold(
      body: AbCarbonScope(child: Align(child: BranchRemoteAdvisory())),
    ),
  ),
);

void main() {
  testWidgets('a stale base reads as one line with a Carbon warning glyph', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.pump();

    expect(find.text('main is 3 commits behind origin/main'), findsOneWidget);
    final icon = tester.widget<CarbonStatusIcon>(find.byType(CarbonStatusIcon));
    expect(icon.kind, CarbonStatusKind.warning);
  });

  testWidgets('the line paints no horizontal inset of its own', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.pump();

    final host = tester.getRect(find.byType(BranchRemoteAdvisory));
    final glyph = tester.getRect(find.byType(CarbonStatusIcon));
    // The mount owns the inset, so the glyph starts at the widget's own edge.
    expect(glyph.left, host.left);
  });

  testWidgets('it retires the moment a start is in flight', (tester) async {
    await tester.pumpWidget(_wrap(starting: true));
    await tester.pump();
    await tester.pump();

    expect(find.byType(CarbonStatusIcon), findsNothing);
    expect(find.textContaining('commits behind'), findsNothing);
  });
}
