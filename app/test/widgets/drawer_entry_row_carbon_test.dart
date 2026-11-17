// The sidebar's project row on Carbon: what it renders at rest, under a pointer
// and on touch. The rows are mounted bare, outside the drawer, so each test
// pins the row's own behaviour rather than the drawer's layout.
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/hover.dart';

const _name = 'antgrid';

Future<void> _pump(WidgetTester tester, Widget row) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AbCarbonScope(
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 300, child: row),
          ),
        ),
      ),
    ),
  );
  // Bounded pumps: a pulsing dot keeps frames coming, so nothing here may
  // settle.
  await tester.pump();
  await tester.pump();
}

DrawerProjectRow _row({List<Widget> marks = const []}) => DrawerProjectRow(
  name: _name,
  spokenName: '$_name, 1 need you',
  expanded: false,
  warm: true,
  onToggle: () {},
  marks: marks,
);

void main() {
  testWidgets('a collapsed project that needs the user is Carbon only and '
      'says so', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final handle = tester.ensureSemantics();
    try {
      await _pump(
        tester,
        _row(
          marks: const [DrawerAttentionDot(status: AgentWorkStatus.attention)],
        ),
      );

      expect(abWidgetsInScope(tester), isEmpty);
      expect(find.byType(DrawerAttentionDot), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('need you')), findsWidgets);
      // The attention dot pulses on a timer that must not outlive the tree.
      await tester.pumpWidget(const SizedBox());
    } finally {
      handle.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the folder swaps for a chevron under a mouse on desktop', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _pump(tester, _row());
      final swapped = find.descendant(
        of: find.byType(DrawerProjectRow),
        matching: find.byType(AnimatedRotation),
      );
      expect(swapped, findsNothing);
      await hoverRow(tester, find.text(_name));
      expect(swapped, findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('swapsIcon never shows on touch ($platform)', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await _pump(tester, _row());
        await hoverRow(tester, find.text(_name));
        expect(
          find.descendant(
            of: find.byType(DrawerProjectRow),
            matching: find.byType(AnimatedRotation),
          ),
          findsNothing,
        );
        expect(find.byType(CarbonSideNavMenu), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
