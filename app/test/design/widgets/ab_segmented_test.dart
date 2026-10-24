import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_segmented.dart';

import '../test_harness.dart';

const _desktop = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.windows,
});

class _Host extends StatefulWidget {
  const _Host({this.disabled = const {}});
  final Set<String> disabled;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String selected = 'b';

  @override
  Widget build(BuildContext context) => AbSegmented<String>(
    semanticLabel: 'Mode',
    segments: [
      for (final v in ['a', 'b', 'c'])
        AbSegment(
          value: v,
          label: v,
          enabled: !widget.disabled.contains(v),
        ),
    ],
    selected: selected,
    onSelect: (v) => setState(() => selected = v),
  );
}

String _selected(WidgetTester tester) =>
    tester.state<_HostState>(find.byType(_Host)).selected;

void main() {
  group('AbSegmented (APG radio group)', () {
    testWidgets('cells are radios: one checked, in a mutually exclusive group', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAntgrid(tester, const _Host());

      expect(
        tester.getSemantics(find.text('B')),
        matchesSemantics(
          label: 'B',
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('A')),
        matchesSemantics(
          label: 'A',
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: false,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('Tab lands on the checked cell, not the first', (tester) async {
      await pumpAntgrid(tester, const _Host());
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      // Space on the focused (checked) cell changes nothing; arrows prove
      // where focus started.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_selected(tester), 'c');
    }, variant: _desktop);

    testWidgets('arrows move and select, wrapping at both ends', (
      tester,
    ) async {
      await pumpAntgrid(tester, const _Host());
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_selected(tester), 'c');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_selected(tester), 'a', reason: 'wraps past the last cell');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_selected(tester), 'c', reason: 'wraps past the first cell');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_selected(tester), 'b');
    }, variant: _desktop);

    testWidgets('arrows skip a disabled cell', (tester) async {
      await pumpAntgrid(tester, const _Host(disabled: {'c'}));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_selected(tester), 'a');
    }, variant: _desktop);
  });
}
