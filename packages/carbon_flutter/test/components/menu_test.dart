import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Hosts a [CarbonMenu] anchored on a plain trigger and logs what happens.
class _Host extends StatefulWidget {
  const _Host({this.entries, this.closeOnToggle = true, this.log});

  final List<CarbonMenuEntry>? entries;
  final bool closeOnToggle;
  final List<String>? log;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final CarbonPopupController controller = CarbonPopupController();
  final FocusNode trigger = FocusNode(debugLabel: 'trigger');
  final List<String> log = <String>[];
  bool wide = false;
  bool checked = false;
  String? mode = 'a';

  List<String> get _log => widget.log ?? log;

  @override
  void dispose() {
    controller.dispose();
    trigger.dispose();
    super.dispose();
  }

  List<CarbonMenuEntry> _entries() =>
      widget.entries ??
      <CarbonMenuEntry>[
        CarbonMenuItem(
          label: 'Cut',
          shortcut: 'Ctrl+X',
          onPressed: () => _log.add('cut'),
        ),
        CarbonMenuItem(label: 'Copy', onPressed: () => _log.add('copy')),
        const CarbonMenuItem(label: 'Paste'),
        const CarbonMenuDivider(),
        CarbonMenuSubmenu(
          label: 'More',
          entries: <CarbonMenuEntry>[
            CarbonMenuItem(label: 'Sub one', onPressed: () => _log.add('s1')),
            const CarbonMenuItem(label: 'Sub two'),
            CarbonMenuSubmenu(
              label: 'Deeper',
              entries: <CarbonMenuEntry>[
                CarbonMenuItem(label: 'Deep one', onPressed: () => _log.add('d1')),
              ],
            ),
          ],
        ),
        CarbonMenuItem(
          label: 'Delete',
          kind: CarbonMenuItemKind.danger,
          onPressed: () => _log.add('delete'),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: CarbonMenu(
          controller: controller,
          entries: _entries(),
          restoreFocus: trigger,
          closeOnToggle: widget.closeOnToggle,
          onDismissed: (reason) => _log.add('dismissed ${reason.name}'),
          child: CarbonButton(
            label: 'Trigger',
            focusNode: trigger,
            onPressed: controller.toggle,
          ),
        ),
      ),
    );
  }
}

bool _hasFocus(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Trigger'));
  await tester.pump();
  await tester.pump();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump();
}

Future<void> _pump(
  WidgetTester tester,
  Widget host, {
  CarbonThemeData? theme,
  TextDirection dir = TextDirection.ltr,
  double textScale = 1,
}) => pumpCarbon(
  tester,
  host,
  theme: theme,
  dir: dir,
  textScale: textScale,
  size: const Size(800, 600),
);

void main() {
  testWidgets('opens with the first enabled item focused and renders rows', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    expect(find.text('Cut'), findsNothing);
    await _open(tester);
    for (final label in ['Cut', 'Ctrl+X', 'Copy', 'Paste', 'More', 'Delete']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(_hasFocus(tester, 'Cut'), isTrue);
  });

  testWidgets('Up and Down wrap and skip disabled items; Home and End jump', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'Copy'), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'More'), isTrue, reason: 'Paste is disabled');
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'Delete'), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'Cut'), isTrue, reason: 'wraps to the start');
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_hasFocus(tester, 'Delete'), isTrue, reason: 'wraps to the end');
    await _key(tester, LogicalKeyboardKey.home);
    expect(_hasFocus(tester, 'Cut'), isTrue);
    await _key(tester, LogicalKeyboardKey.end);
    expect(_hasFocus(tester, 'Delete'), isTrue);
  });

  testWidgets('Enter and Space activate: menu closes, focus returns, callback runs once', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(state.log, ['cut']);
    expect(find.text('Cut'), findsNothing);
    expect(state.trigger.hasPrimaryFocus, isTrue);
    // The callback must not count as an outside dismissal.
    expect(state.log.where((e) => e.startsWith('dismissed')), isEmpty);

    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.space);
    expect(state.log, ['cut', 'copy']);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('a disabled item ignores taps and leaves the menu open', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await tester.tap(find.text('Paste'));
    await tester.pump();
    expect(find.text('Paste'), findsOneWidget);
  });

  testWidgets('forward arrow opens a submenu and focuses its first item; back arrow closes it', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'More'), isTrue);
    expect(find.text('Sub one'), findsNothing);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Sub one'), findsOneWidget);
    expect(_hasFocus(tester, 'Sub one'), isTrue);

    // Sub two is disabled: traversal inside the submenu skips it.
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'Deeper'), isTrue);

    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text('Sub one'), findsNothing);
    expect(_hasFocus(tester, 'More'), isTrue);
    expect(find.text('Cut'), findsOneWidget, reason: 'root stays open');
  });

  testWidgets('Escape chain walks back one level at a time to the trigger', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Deep one'), findsOneWidget);
    expect(_hasFocus(tester, 'Deep one'), isTrue);

    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.text('Deep one'), findsNothing);
    expect(find.text('Sub one'), findsOneWidget);
    expect(_hasFocus(tester, 'Deeper'), isTrue);

    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.text('Sub one'), findsNothing);
    expect(find.text('Cut'), findsOneWidget);
    expect(_hasFocus(tester, 'More'), isTrue);

    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.text('Cut'), findsNothing);
    expect(state.trigger.hasPrimaryFocus, isTrue);
    expect(state.log, ['dismissed escape']);
  });

  testWidgets('Escape with focus on the parent row closes only its open submenu', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sub one'), findsOneWidget);
    // Put focus back on the parent without closing the submenu.
    Focus.of(tester.element(find.text('More'))).requestFocus();
    await tester.pump();
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.text('Sub one'), findsNothing);
    expect(find.text('Cut'), findsOneWidget);
    expect(_hasFocus(tester, 'More'), isTrue);
  });

  testWidgets('a submenu opens by tap, and activating inside it closes the whole tree', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await _open(tester);
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sub one'), findsOneWidget);
    expect(_hasFocus(tester, 'Sub one'), isTrue);

    // A tap inside the submenu is not an outside tap for the root.
    await tester.tap(find.text('Sub one'));
    await tester.pump();
    await tester.pump();
    expect(state.log, ['s1']);
    expect(find.text('Sub one'), findsNothing);
    expect(find.text('Cut'), findsNothing);
    expect(state.trigger.hasPrimaryFocus, isTrue);
  });

  testWidgets('tapping an open submenu row closes it', (tester) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sub one'), findsNothing);
    expect(find.text('Cut'), findsOneWidget);
  });

  testWidgets('the press that closed the menu is named; a later one is not', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    final closing = await tester.startGesture(
      const Offset(700, 500),
      pointer: 911,
    );
    await tester.pump();
    await closing.up();
    await tester.pump();
    expect(find.text('Cut'), findsNothing);
    expect(CarbonAnchoredPopup.dismissedByPointer(911), isTrue);

    final later = await tester.startGesture(
      const Offset(700, 500),
      pointer: 912,
    );
    await later.up();
    expect(CarbonAnchoredPopup.dismissedByPointer(912), isFalse);
  });

  testWidgets('a pointer down outside dismisses the whole tree', (tester) async {
    await _pump(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await _open(tester);
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump();
    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    await tester.pump();
    expect(find.text('Cut'), findsNothing);
    expect(find.text('Sub one'), findsNothing);
    expect(state.log, ['dismissed outsideTap']);
  });

  testWidgets('the trigger toggles the menu without reopening it', (tester) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await tester.tap(find.text('Trigger'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Cut'), findsNothing);
  });

  testWidgets('Tab closes the menu and returns focus to the trigger', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(find.text('Cut'), findsNothing);
    expect(state.trigger.hasPrimaryFocus, isTrue);
  });

  testWidgets('typeahead jumps to a matching enabled item', (tester) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await simulateKeyDownEvent(LogicalKeyboardKey.keyD, character: 'd');
    await simulateKeyUpEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(_hasFocus(tester, 'Delete'), isTrue);
  });

  testWidgets('menu keys do not leak: arrows pressed in the menu never move outside focus', (
    tester,
  ) async {
    final outside = FocusNode();
    addTearDown(outside.dispose);
    await _pump(
      tester,
      Column(
        children: [
          Focus(focusNode: outside, child: const Text('outside')),
          const Expanded(child: _Host()),
        ],
      ),
    );
    await _open(tester);
    for (var i = 0; i < 8; i++) {
      await _key(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(outside.hasFocus, isFalse);
  });

  testWidgets('check items and radio groups report requested values', (
    tester,
  ) async {
    final log = <String>[];
    await _pump(
      tester,
      _Host(
        log: log,
        closeOnToggle: false,
        entries: <CarbonMenuEntry>[
          CarbonMenuCheckItem(
            label: 'Word wrap',
            checked: true,
            onChanged: (v) => log.add('wrap $v'),
          ),
          CarbonMenuCheckItem(label: 'Minimap', checked: false, onChanged: (v) => log.add('map $v')),
          const CarbonMenuDivider(),
          CarbonMenuRadioGroup<String>(
            label: 'Mode',
            value: 'a',
            options: const [
              CarbonOption(value: 'a', label: 'Alpha'),
              CarbonOption(value: 'b', label: 'Beta'),
            ],
            onChanged: (v) => log.add('mode $v'),
          ),
        ],
      ),
    );
    final handle = tester.ensureSemantics();
    await _open(tester);
    expect(
      tester.getSemantics(find.text('Word wrap')),
      isSemantics(label: 'Word wrap', hasCheckedState: true, isChecked: true),
    );
    expect(
      tester.getSemantics(find.text('Minimap')),
      isSemantics(label: 'Minimap', hasCheckedState: true, isChecked: false),
    );
    expect(
      tester.getSemantics(find.text('Beta')),
      isSemantics(label: 'Beta', hasCheckedState: true, isChecked: false),
    );
    expect(find.text('Mode'), findsOneWidget);

    await tester.tap(find.text('Minimap'));
    await tester.pump();
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    // Alpha is already selected, so no change is requested; the menu stays
    // open throughout.
    expect(log, ['map true', 'mode b']);
    expect(find.text('Alpha'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('checkable items close the menu by default', (tester) async {
    final log = <String>[];
    await _pump(
      tester,
      _Host(
        log: log,
        entries: <CarbonMenuEntry>[
          CarbonMenuCheckItem(label: 'Wrap', checked: false, onChanged: (v) => log.add('$v')),
        ],
      ),
    );
    await _open(tester);
    await tester.tap(find.text('Wrap'));
    await tester.pump();
    expect(log, ['true']);
    expect(find.text('Wrap'), findsNothing);
  });

  testWidgets('semantics: menu container, item labels, shortcut hint, enabled and expanded', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    final handle = tester.ensureSemantics();
    await _open(tester);
    expect(find.bySemanticsLabel('Menu'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Cut')),
      isSemantics(label: 'Cut', hint: 'Ctrl+X', hasEnabledState: true, isEnabled: true),
    );
    expect(
      tester.getSemantics(find.text('Paste')),
      isSemantics(label: 'Paste', hasEnabledState: true, isEnabled: false),
    );
    expect(
      tester.getSemantics(find.text('More')),
      isSemantics(label: 'More', hasExpandedState: true, isExpanded: false),
    );
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSemantics(find.text('More')),
      isSemantics(label: 'More', hasExpandedState: true, isExpanded: true),
    );
    handle.dispose();
  });

  testWidgets('row heights: 32 compact, 48 touch, growth at 200% text', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    double rowHeight(String label) => tester
        .getSize(find.ancestor(of: find.text(label), matching: find.byType(ConstrainedBox)).first)
        .height;
    Size row(String label) => tester.getSize(
      find
          .ancestor(of: find.text(label), matching: find.byType(CarbonInteraction))
          .first,
    );
    expect(row('Copy').height, 32);
    expect(rowHeight('Copy'), greaterThanOrEqualTo(32));

    await setCarbonTheme(tester, CarbonThemeData(density: CarbonDensity.touch));
    await tester.pump();
    expect(row('Copy').height, greaterThanOrEqualTo(48));

    await setCarbonTheme(tester, CarbonThemeData());
    await pumpCarbon(tester, const _Host(), textScale: 2, size: const Size(800, 600));
    await tester.pump();
    expect(row('Copy').height, greaterThan(32));
  });

  testWidgets('theme and density switches keep the menu open and the active item', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'Copy'), isTrue);
    await setCarbonTheme(
      tester,
      CarbonThemeData(scheme: CarbonThemeScheme.gray100, density: CarbonDensity.touch),
    );
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    expect(_hasFocus(tester, 'Copy'), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'More'), isTrue);
  });

  testWidgets('unmounting the trigger while open closes the menu and submenus', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sub one'), findsOneWidget);
    await _pump(tester, const SizedBox());
    await tester.pump();
    expect(find.text('Cut'), findsNothing);
    expect(find.text('Sub one'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL: the submenu opens toward the start side and the arrows mirror', (
    tester,
  ) async {
    await _pump(tester, const _Host(), dir: TextDirection.rtl);
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'More'), isTrue);

    // Right is "back" in RTL and does nothing on the root.
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Sub one'), findsNothing);

    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text('Sub one'), findsOneWidget);
    final parent = tester.getRect(
      find.ancestor(of: find.text('More'), matching: find.byType(CarbonInteraction)).first,
    );
    final sub = tester.getRect(
      find.ancestor(of: find.text('Sub one'), matching: find.byType(CarbonInteraction)).first,
    );
    expect(sub.right, lessThanOrEqualTo(parent.left + 2));

    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Sub one'), findsNothing);
    expect(_hasFocus(tester, 'More'), isTrue);
  });

  testWidgets('LTR: the submenu sits beside the parent row, level with it', (
    tester,
  ) async {
    await _pump(tester, const _Host());
    await _open(tester);
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump();
    final parent = tester.getRect(
      find.ancestor(of: find.text('More'), matching: find.byType(CarbonInteraction)).first,
    );
    final sub = tester.getRect(
      find.ancestor(of: find.text('Sub one'), matching: find.byType(CarbonInteraction)).first,
    );
    expect(sub.left, greaterThanOrEqualTo(parent.right - 2));
    expect((sub.top - parent.top).abs(), lessThanOrEqualTo(4));
  });

  testWidgets('danger items fill with the danger role on hover', (tester) async {
    await _pump(tester, const _Host());
    await _open(tester);
    final colors = CarbonTheme.of(tester.element(find.text('Delete'))).colors;
    Color? fillOf(String label) => tester
        .widget<ColoredBox>(
          find.ancestor(of: find.text(label), matching: find.byType(ColoredBox)).first,
        )
        .color;
    expect(fillOf('Delete'), isNot(colors.buttonDangerPrimary));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Delete')));
    await tester.pump();
    expect(fillOf('Delete'), colors.buttonDangerPrimary);
    await mouse.moveTo(tester.getCenter(find.text('Copy')));
    await tester.pump();
    expect(fillOf('Delete'), isNot(colors.buttonDangerPrimary));
  });

  testWidgets('a tall menu scrolls and keeps the focused item in view', (
    tester,
  ) async {
    final entries = <CarbonMenuEntry>[
      for (var i = 0; i < 30; i++) CarbonMenuItem(label: 'Item $i', onPressed: () {}),
    ];
    await pumpCarbon(
      tester,
      _Host(entries: entries),
      size: const Size(800, 300),
    );
    await _open(tester);
    for (var i = 0; i < 20; i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(_hasFocus(tester, 'Item 20'), isTrue);
    final rect = tester.getRect(find.text('Item 20'));
    expect(rect.bottom, lessThanOrEqualTo(300));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('entries changing while open rebuild in place', (tester) async {
    final controller = CarbonPopupController();
    addTearDown(controller.dispose);
    Widget build(List<CarbonMenuEntry> entries) => Align(
      alignment: Alignment.topLeft,
      child: CarbonMenu(
        controller: controller,
        entries: entries,
        child: const SizedBox(width: 40, height: 40),
      ),
    );
    await pumpCarbon(tester, build([CarbonMenuItem(label: 'A', onPressed: () {})]));
    controller.open();
    await tester.pump();
    await tester.pump();
    expect(find.text('A'), findsOneWidget);
    await pumpCarbon(
      tester,
      build([
        CarbonMenuItem(label: 'A', onPressed: () {}),
        CarbonMenuItem(label: 'B', onPressed: () {}),
      ]),
    );
    await tester.pump();
    expect(find.text('B'), findsOneWidget);
    await pumpCarbon(tester, build([CarbonMenuItem(label: 'C', onPressed: () {})]));
    await tester.pump();
    await tester.pump();
    expect(find.text('B'), findsNothing);
    expect(find.text('C'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('CarbonContextMenu', () {
    Widget region(List<String> log) => CarbonContextMenu(
      entries: <CarbonMenuEntry>[
        CarbonMenuItem(label: 'Rename', onPressed: () => log.add('rename')),
      ],
      child: const SizedBox.expand(),
    );

    testWidgets('opens at the pointer on right click', (tester) async {
      final log = <String>[];
      await _pump(tester, region(log));
      final gesture = await tester.startGesture(
        const Offset(300, 200),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(find.text('Rename'), findsOneWidget);
      final rect = tester.getRect(
        find.ancestor(of: find.text('Rename'), matching: find.byType(CarbonInteraction)).first,
      );
      expect(rect.left, closeTo(300, 2));
      expect(rect.top, closeTo(200, 6));

      await tester.tap(find.text('Rename'));
      await tester.pump();
      expect(log, ['rename']);
      expect(find.text('Rename'), findsNothing);
    });

    testWidgets('opens on touch long press and dismisses on outside tap', (
      tester,
    ) async {
      await _pump(tester, region(<String>[]));
      await tester.longPressAt(const Offset(100, 100));
      await tester.pump();
      await tester.pump();
      expect(find.text('Rename'), findsOneWidget);
      await tester.tapAt(const Offset(700, 500));
      await tester.pump();
      await tester.pump();
      expect(find.text('Rename'), findsNothing);
    });

    testWidgets('a second right click moves the menu', (tester) async {
      await _pump(tester, region(<String>[]));
      Future<void> rightClick(Offset at) async {
        final g = await tester.startGesture(
          at,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await g.up();
        await tester.pump();
        await tester.pump();
      }

      await rightClick(const Offset(100, 100));
      await rightClick(const Offset(400, 300));
      expect(find.text('Rename'), findsOneWidget);
      final rect = tester.getRect(find.text('Rename'));
      expect(rect.left, greaterThan(300));
    });
  });
}
