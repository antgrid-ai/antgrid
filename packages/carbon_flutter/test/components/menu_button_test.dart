import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

List<CarbonMenuEntry> _entries(List<String> log) => <CarbonMenuEntry>[
  CarbonMenuItem(label: 'Rename', onPressed: () => log.add('rename')),
  CarbonMenuItem(label: 'Duplicate', onPressed: () => log.add('duplicate')),
  const CarbonMenuDivider(),
  CarbonMenuItem(
    label: 'Remove',
    kind: CarbonMenuItemKind.danger,
    onPressed: () => log.add('remove'),
  ),
];

Widget _pad(Widget child) => Align(
  alignment: AlignmentDirectional.topStart,
  child: Padding(padding: const EdgeInsets.all(40), child: child),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  CarbonThemeData? theme,
  TextDirection dir = TextDirection.ltr,
  double textScale = 1,
}) => pumpCarbon(
  tester,
  _pad(child),
  theme: theme,
  dir: dir,
  textScale: textScale,
  size: const Size(800, 600),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

bool _hasFocus(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

void main() {
  group('CarbonMenuButton', () {
    testWidgets('opens on tap, flips the chevron and reports expanded', (
      tester,
    ) async {
      final log = <String>[];
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        CarbonMenuButton(label: 'Actions', entries: _entries(log)),
      );
      expect(
        tester.getSemantics(find.text('Actions')),
        isSemantics(
          label: 'Actions',
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
        ),
      );
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      expect(find.text('Rename'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Actions')),
        isSemantics(
          label: 'Actions',
          hasExpandedState: true,
          isExpanded: true,
        ),
      );
      // The open menu is named after its trigger.
      expect(find.bySemanticsLabel('Actions'), findsNWidgets(2));
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      expect(find.text('Rename'), findsNothing);
      handle.dispose();
    });

    testWidgets('the trigger and the menu can carry different names', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        CarbonMenuButton(
          label: 'Laptop',
          triggerSemanticLabel: 'Machine: Laptop, change',
          semanticLabel: 'Machines',
          entries: _entries(<String>[]),
        ),
      );
      expect(
        tester.getSemantics(find.text('Laptop')),
        isSemantics(label: 'Machine: Laptop, change', isButton: true),
      );
      await tester.tap(find.text('Laptop'));
      await _settle(tester);
      expect(find.bySemanticsLabel('Machines'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('keyboard: Enter opens, Escape closes and restores focus', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await _pump(
        tester,
        CarbonMenuButton(
          label: 'Actions',
          focusNode: node,
          entries: _entries(<String>[]),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(find.text('Rename'), findsOneWidget);
      expect(_hasFocus(tester, 'Rename'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Rename'), findsNothing);
      expect(node.hasPrimaryFocus, isTrue);
    });

    testWidgets('mouse open still returns focus to the trigger on close', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await _pump(
        tester,
        CarbonMenuButton(
          label: 'Actions',
          focusNode: node,
          entries: _entries(<String>[]),
        ),
      );
      expect(node.hasFocus, isFalse);
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(node.hasPrimaryFocus, isTrue);
    });

    testWidgets('disabled trigger is inert', (tester) async {
      await _pump(
        tester,
        CarbonMenuButton(
          label: 'Actions',
          enabled: false,
          entries: _entries(<String>[]),
        ),
      );
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      expect(find.text('Rename'), findsNothing);
    });

    testWidgets('outside tap closes; dismissal is reported', (tester) async {
      final reasons = <CarbonPopupDismissReason>[];
      await _pump(
        tester,
        CarbonMenuButton(
          label: 'Actions',
          entries: _entries(<String>[]),
          onDismissed: reasons.add,
        ),
      );
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      await tester.tapAt(const Offset(700, 500));
      await _settle(tester);
      expect(find.text('Rename'), findsNothing);
      expect(reasons, [CarbonPopupDismissReason.outsideTap]);
    });

    testWidgets('trigger height is 32 compact, 48 touch, and ghost/tertiary work', (
      tester,
    ) async {
      await _pump(
        tester,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CarbonMenuButton(label: 'One', entries: _entries(<String>[])),
            CarbonMenuButton(
              label: 'Two',
              kind: CarbonButtonKind.tertiary,
              entries: _entries(<String>[]),
            ),
            CarbonMenuButton(
              label: 'Three',
              kind: CarbonButtonKind.ghost,
              entries: _entries(<String>[]),
            ),
          ],
        ),
      );
      Size sizeOf(String label) => tester.getSize(
        find.ancestor(of: find.text(label), matching: find.byType(CarbonButton)).first,
      );
      expect(sizeOf('One').height, 32);
      expect(sizeOf('Two').height, 32);
      await setCarbonTheme(tester, CarbonThemeData(density: CarbonDensity.touch));
      expect(sizeOf('Three').height, greaterThanOrEqualTo(48));
    });

    testWidgets('theme switch while open keeps the menu and its focus', (
      tester,
    ) async {
      await _pump(
        tester,
        CarbonMenuButton(label: 'Actions', entries: _entries(<String>[])),
      );
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_hasFocus(tester, 'Duplicate'), isTrue);
      await setCarbonTheme(
        tester,
        CarbonThemeData(scheme: CarbonThemeScheme.gray90, density: CarbonDensity.touch),
      );
      await tester.pump();
      expect(find.text('Duplicate'), findsOneWidget);
      expect(_hasFocus(tester, 'Duplicate'), isTrue);
    });

    testWidgets('unmounting the button while open closes the menu', (
      tester,
    ) async {
      await _pump(
        tester,
        CarbonMenuButton(label: 'Actions', entries: _entries(<String>[])),
      );
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      await _pump(tester, const SizedBox());
      await _settle(tester);
      expect(find.text('Rename'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('replacing the supplied focus node keeps working', (tester) async {
      final a = FocusNode();
      final b = FocusNode();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      Widget build(FocusNode n) =>
          CarbonMenuButton(label: 'Actions', focusNode: n, entries: _entries(<String>[]));
      await _pump(tester, build(a));
      await _pump(tester, build(b));
      await tester.tap(find.text('Actions'));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(b.hasPrimaryFocus, isTrue);
    });
  });

  group('CarbonOverflowMenu', () {
    testWidgets('has the localized default name, ghost footprint 32 / 48', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, CarbonOverflowMenu(entries: _entries(<String>[])));
      expect(find.bySemanticsLabel('Options'), findsOneWidget);
      final trigger = find.byType(CarbonButton);
      expect(tester.getSize(trigger), const Size(32, 32));
      await setCarbonTheme(tester, CarbonThemeData(density: CarbonDensity.touch));
      expect(tester.getSize(trigger), const Size(48, 48));
      handle.dispose();
    });

    testWidgets('custom name and horizontal glyph', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        CarbonOverflowMenu(
          horizontal: true,
          semanticLabel: 'Row actions',
          entries: _entries(<String>[]),
        ),
      );
      expect(find.bySemanticsLabel('Row actions'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the menu aligns to the trigger end edge', (tester) async {
      await _pump(
        tester,
        Align(
          alignment: Alignment.topRight,
          child: CarbonOverflowMenu(entries: _entries(<String>[])),
        ),
      );
      await tester.tap(find.byType(CarbonButton));
      await _settle(tester);
      final trigger = tester.getRect(find.byType(CarbonButton));
      final menu = tester.getRect(find.bySemanticsLabel('Options').first);
      expect(menu.right, closeTo(trigger.right, 1));
    });

    testWidgets('a danger item callback can push a modal after the menu closed', (
      tester,
    ) async {
      final trigger = FocusNode();
      addTearDown(trigger.dispose);
      final harness = await pumpCarbon(
        tester,
        _pad(
          Builder(
            builder: (context) => CarbonOverflowMenu(
              focusNode: trigger,
              entries: <CarbonMenuEntry>[
                CarbonMenuItem(
                  label: 'Remove',
                  kind: CarbonMenuItemKind.danger,
                  onPressed: () {
                    // The menu must be closed and focus restored by now.
                    expect(trigger.hasPrimaryFocus, isTrue);
                    expect(find.text('Remove'), findsOneWidget,
                        reason: 'overlay entry leaves with the next frame');
                    Navigator.of(context).push(
                      PageRouteBuilder<void>(
                        opaque: false,
                        transitionDuration: Duration.zero,
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (context, _, _) =>
                            const Center(child: Text('Confirm removal')),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        size: const Size(800, 600),
      );
      await tester.tap(find.byType(CarbonButton));
      await _settle(tester);
      await tester.tap(find.text('Remove'));
      await _settle(tester);
      expect(find.text('Confirm removal'), findsOneWidget);
      expect(find.text('Remove'), findsNothing);
      expect(tester.takeException(), isNull);

      harness.navigatorKey.currentState!.pop();
      await _settle(tester);
      expect(find.text('Confirm removal'), findsNothing);
      expect(trigger.hasPrimaryFocus, isTrue);
    });

    testWidgets('the same works from the keyboard', (tester) async {
      final trigger = FocusNode();
      addTearDown(trigger.dispose);
      await pumpCarbon(
        tester,
        _pad(
          Builder(
            builder: (context) => CarbonOverflowMenu(
              focusNode: trigger,
              entries: <CarbonMenuEntry>[
                CarbonMenuItem(
                  label: 'Remove',
                  onPressed: () => Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      transitionDuration: Duration.zero,
                      pageBuilder: (context, _, _) =>
                          const Center(child: Text('Dialog')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        size: const Size(800, 600),
      );
      trigger.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(find.text('Dialog'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('RTL aligns the menu end edge (left) to the trigger and extends toward the start', (
      tester,
    ) async {
      await _pump(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: CarbonOverflowMenu(entries: _entries(<String>[])),
        ),
        dir: TextDirection.rtl,
      );
      await tester.tap(find.byType(CarbonButton));
      await _settle(tester);
      final trigger = tester.getRect(find.byType(CarbonButton));
      final item = tester.getRect(
        find.ancestor(of: find.text('Rename'), matching: find.byType(CarbonInteraction)).first,
      );
      // End alignment in RTL puts the menu's left edge on the trigger's left.
      expect(item.left, closeTo(trigger.left, 1));
    });
  });

  group('CarbonSplitButton', () {
    testWidgets('action and trigger are independent controls', (tester) async {
      final log = <String>[];
      var primary = 0;
      await _pump(
        tester,
        CarbonSplitButton(
          label: 'Run',
          onPressed: () => primary++,
          entries: _entries(log),
        ),
      );
      await tester.tap(find.text('Run'));
      await _settle(tester);
      expect(primary, 1);
      expect(find.text('Rename'), findsNothing, reason: 'action never opens the menu');

    });

    testWidgets('trigger opens the menu without firing the action', (tester) async {
      var primary = 0;
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        CarbonSplitButton(
          label: 'Run',
          onPressed: () => primary++,
          entries: _entries(<String>[]),
        ),
      );
      await tester.tap(find.bySemanticsLabel('Open menu'));
      await _settle(tester);
      expect(primary, 0);
      expect(find.text('Rename'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Open menu')),
        isSemantics(label: 'Open menu', hasExpandedState: true, isExpanded: true),
      );
      await tester.tap(find.text('Duplicate'));
      await _settle(tester);
      expect(primary, 0);
      handle.dispose();
    });

    testWidgets('both controls take focus separately and Enter activates only the focused one', (
      tester,
    ) async {
      var primary = 0;
      final action = FocusNode();
      final trigger = FocusNode();
      addTearDown(action.dispose);
      addTearDown(trigger.dispose);
      await _pump(
        tester,
        CarbonSplitButton(
          label: 'Run',
          focusNode: action,
          triggerFocusNode: trigger,
          onPressed: () => primary++,
          entries: _entries(<String>[]),
        ),
      );
      action.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(primary, 1);
      expect(find.text('Rename'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(trigger.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(primary, 1);
      expect(find.text('Rename'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(trigger.hasPrimaryFocus, isTrue);
    });

    testWidgets('a disabled action leaves the menu usable and vice versa', (
      tester,
    ) async {
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CarbonSplitButton(label: 'First', onPressed: null, entries: _entries(<String>[])),
            CarbonSplitButton(
              label: 'Second',
              onPressed: () {},
              menuEnabled: false,
              entries: _entries(<String>[]),
            ),
          ],
        ),
      );
      final triggers = find.byType(CarbonButton);
      // First action is the first CarbonButton, its trigger the second, etc.
      await tester.tap(triggers.at(1));
      await _settle(tester);
      expect(find.text('Rename'), findsOneWidget);
      await tester.tapAt(const Offset(700, 500));
      await _settle(tester);
      await tester.tap(triggers.at(3));
      await _settle(tester);
      expect(find.text('Rename'), findsNothing);
    });

    testWidgets('targets are 32 compact and at least 48 touch, trigger square', (
      tester,
    ) async {
      await _pump(
        tester,
        CarbonSplitButton(label: 'Run', onPressed: () {}, entries: _entries(<String>[])),
      );
      Size trigger() => tester.getSize(find.byType(CarbonButton).at(1));
      expect(trigger(), const Size(32, 32));
      await setCarbonTheme(tester, CarbonThemeData(density: CarbonDensity.touch));
      expect(trigger().width, greaterThanOrEqualTo(48));
      expect(trigger().height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byType(CarbonButton).first).height, greaterThanOrEqualTo(48));
    });

    testWidgets('long label wraps at 200% text without overflow', (tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 240,
          child: CarbonSplitButton(
            label: 'Run the whole workspace test suite',
            onPressed: () {},
            entries: _entries(<String>[]),
          ),
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('menu aligns to the end edge of the whole control', (tester) async {
      await _pump(
        tester,
        Align(
          alignment: Alignment.topRight,
          child: CarbonSplitButton(label: 'Run', onPressed: () {}, entries: _entries(<String>[])),
        ),
      );
      await tester.tap(find.byType(CarbonButton).at(1));
      await _settle(tester);
      final split = tester.getRect(find.byType(CarbonSplitButton));
      final item = tester.getRect(
        find.ancestor(of: find.text('Rename'), matching: find.byType(CarbonInteraction)).first,
      );
      expect(item.right, closeTo(split.right, 1));
    });
  });

  group('maxLines', () {
    testWidgets('reaches the trigger button', (tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 200,
          child: CarbonMenuButton(
            label: 'A rather long menu button label that must not wrap',
            maxLines: 1,
            entries: _entries(<String>[]),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.widget<CarbonButton>(find.byType(CarbonButton)).maxLines, 1);
    });
  });
}
