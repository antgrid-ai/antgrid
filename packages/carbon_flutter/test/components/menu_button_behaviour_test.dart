import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

List<CarbonMenuEntry> _entries(List<String> log) => <CarbonMenuEntry>[
  CarbonMenuItem(label: 'Rename', onPressed: () => log.add('rename')),
];

Widget _pad(Widget child) => Align(
  alignment: AlignmentDirectional.topStart,
  child: Padding(padding: const EdgeInsets.all(40), child: child),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

SemanticsNode? _find(SemanticsNode node, bool Function(SemanticsNode) test) {
  if (test(node)) return node;
  SemanticsNode? found;
  node.visitChildren((child) {
    found ??= _find(child, test);
    return found == null;
  });
  return found;
}

void main() {
  testWidgets('pressing the split button action closes its open menu', (
    tester,
  ) async {
    var primary = 0;
    await pumpCarbon(
      tester,
      _pad(
        CarbonSplitButton(
          label: 'Run',
          onPressed: () => primary++,
          entries: _entries(<String>[]),
        ),
      ),
      size: const Size(800, 600),
    );
    await tester.tap(find.bySemanticsLabel('Open menu'));
    await _settle(tester);
    expect(find.text('Rename'), findsOneWidget);
    await tester.tap(find.text('Run'));
    await _settle(tester);
    expect(primary, 1);
    expect(find.text('Rename'), findsNothing);
  });

  testWidgets('onOpenChanged reports open, the close before an item callback, '
      'and a close forced by disabling', (tester) async {
    final events = <String>[];
    final enabled = ValueNotifier<bool>(true);
    addTearDown(enabled.dispose);
    await pumpCarbon(
      tester,
      _pad(
        ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, value, _) => CarbonOverflowMenu(
            enabled: value,
            onOpenChanged: (open) => events.add('open:$open'),
            entries: <CarbonMenuEntry>[
              CarbonMenuItem(
                label: 'Forget',
                onPressed: () => events.add('forget'),
              ),
            ],
          ),
        ),
      ),
      size: const Size(800, 600),
    );
    await tester.tap(find.byType(CarbonOverflowMenu));
    await _settle(tester);
    expect(events, <String>['open:true']);
    await tester.tap(find.text('Forget'));
    await _settle(tester);
    expect(events, <String>['open:true', 'open:false', 'forget']);

    events.clear();
    await tester.tap(find.byType(CarbonOverflowMenu));
    await _settle(tester);
    enabled.value = false;
    await _settle(tester);
    expect(events, <String>['open:true', 'open:false']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabling a trigger closes its open menu', (tester) async {
    final log = <String>[];
    final enabled = ValueNotifier<bool>(true);
    addTearDown(enabled.dispose);
    await pumpCarbon(
      tester,
      _pad(
        ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CarbonMenuButton(
                label: 'Actions',
                enabled: value,
                entries: _entries(log),
              ),
              CarbonOverflowMenu(
                enabled: value,
                entries: <CarbonMenuEntry>[
                  CarbonMenuItem(label: 'Forget', onPressed: () {}),
                ],
              ),
              CarbonSplitButton(
                label: 'Run',
                onPressed: () {},
                menuEnabled: value,
                entries: <CarbonMenuEntry>[
                  CarbonMenuItem(label: 'Schedule', onPressed: () {}),
                ],
              ),
            ],
          ),
        ),
      ),
      size: const Size(800, 600),
    );
    final openers = <(Finder, String)>[
      (find.text('Actions'), 'Rename'),
      (find.byType(CarbonOverflowMenu), 'Forget'),
      (find.bySemanticsLabel('Open menu'), 'Schedule'),
    ];
    for (final (opener, item) in openers) {
      await tester.tap(opener);
      await _settle(tester);
      expect(find.text(item), findsOneWidget, reason: item);
      enabled.value = false;
      await _settle(tester);
      expect(find.text(item), findsNothing, reason: item);
      enabled.value = true;
      await _settle(tester);
    }
    expect(log, isEmpty);
  });

  testWidgets(
    'an open trigger controls its menu and the split menu is named after the action',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _pad(
          CarbonSplitButton(
            label: 'Run',
            onPressed: () {},
            entries: _entries(<String>[]),
          ),
        ),
        size: const Size(800, 600),
      );
      await tester.tap(find.bySemanticsLabel('Open menu'));
      await _settle(tester);
      final root =
          tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
      final trigger = _find(
        root,
        (n) => n.getSemanticsData().controlsNodes != null,
      );
      expect(trigger, isNotNull);
      final controlled = trigger!.getSemanticsData().controlsNodes!;
      expect(controlled, isNotEmpty);
      final menu = _find(
        root,
        (n) => controlled.contains(n.getSemanticsData().identifier),
      );
      expect(menu, isNotNull);
      expect(menu!.label, 'Run');
      handle.dispose();
    },
  );
}
