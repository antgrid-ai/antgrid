import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';

import '../test_harness.dart';

void main() {
  testWidgets('renders header and items', (tester) async {
    var deleted = false;
    await pumpAntgrid(
      tester,
      AbMenu(
        header: 'Session · refactor-auth-flow',
        items: [
          AbMenuItem(
            label: 'Export transcript',
            icon: AbIcons.arrowDown,
            shortcut: '⌘E',
            onTap: () {},
          ),
          const AbMenuDivider(),
          AbMenuItem(
            label: 'Delete session',
            icon: AbIcons.trash,
            shortcut: '⌫',
            danger: true,
            onTap: () => deleted = true,
          ),
        ],
      ),
    );
    expect(find.text('SESSION · REFACTOR-AUTH-FLOW'), findsOneWidget);
    expect(find.text('Export transcript'), findsOneWidget);
    await tester.tap(find.text('Delete session'));
    expect(deleted, isTrue);
  });

  group('AbPopupSurface quiet', () {
    Widget surface(double quiet) =>
        AbPopupSurface(quiet: quiet, child: const _StatefulProbe());

    testWidgets('the content keeps its State as quiet crosses 0', (
      tester,
    ) async {
      // The blur only exists above quiet 0, so this is the frame where a
      // wrapper-shaped implementation changes the tree's shape and Flutter
      // re-inflates everything under it — silently taking row state, focus and
      // scroll position with it on the last frame of every reveal.
      await pumpAntgrid(tester, surface(1));
      final receded = tester.state<_StatefulProbeState>(
        find.byType(_StatefulProbe),
      );

      for (final quiet in [0.5, 0.0, 0.5, 1.0]) {
        await pumpAntgrid(tester, surface(quiet));
        expect(
          tester.state<_StatefulProbeState>(find.byType(_StatefulProbe)),
          same(receded),
          reason: 'quiet $quiet re-inflated the popup content',
        );
      }
    });

    testWidgets('the drop shadow is never inside the blur clip', (
      tester,
    ) async {
      // `_popupDecoration` paints its shadow entirely OUTSIDE the popup's own
      // rect (negative spread, +24 y offset), so a clip anywhere above the
      // decorated box erases it — leaving a shadow that is invisible for every
      // quiet above 0 and then snaps in whole at 0.
      await pumpAntgrid(tester, surface(0.5));
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(_StatefulProbe),
          matching: find.byType(ClipRRect),
        ),
        findsNothing,
      );
    });
  });
}

class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe();

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 40, height: 40);
}
