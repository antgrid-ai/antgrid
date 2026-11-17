import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

class _Host extends StatefulWidget {
  const _Host({required this.entries});

  final List<CarbonMenuEntry> entries;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final CarbonPopupController controller = CarbonPopupController();
  final FocusNode trigger = FocusNode(debugLabel: 'trigger');

  @override
  void dispose() {
    controller.dispose();
    trigger.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CarbonMenu(
      controller: controller,
      entries: widget.entries,
      restoreFocus: trigger,
      child: CarbonButton(
        label: 'Trigger',
        focusNode: trigger,
        onPressed: controller.toggle,
      ),
    );
  }
}

Future<void> _pump(WidgetTester tester, Widget child) => pumpCarbon(
  tester,
  Align(
    alignment: AlignmentDirectional.topStart,
    child: Padding(padding: const EdgeInsets.all(40), child: child),
  ),
  size: const Size(800, 600),
);

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

bool _hasFocus(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

Future<void> _type(
  WidgetTester tester,
  String char,
  LogicalKeyboardKey key,
) async {
  await simulateKeyDownEvent(key, character: char);
  await simulateKeyUpEvent(key);
  await tester.pump();
}

Rect _rowRect(WidgetTester tester, String label) => tester.getRect(
  find
      .ancestor(of: find.text(label), matching: find.byType(CarbonInteraction))
      .first,
);

void main() {
  testWidgets('keyboard focus follows the item when entries above it change', (
    tester,
  ) async {
    final log = <String>[];
    CarbonMenuItem item(String label) =>
        CarbonMenuItem(label: label, onPressed: () => log.add(label));
    await _pump(tester, _Host(entries: [item('A'), item('B')]));
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasFocus(tester, 'B'), isTrue);

    await _pump(tester, _Host(entries: [item('Z'), item('A'), item('B')]));
    await tester.pump();
    expect(_hasFocus(tester, 'B'), isTrue);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(log, ['B']);
  });

  testWidgets('Tab closes the menu and continues to the next control', (
    tester,
  ) async {
    final next = FocusNode(debugLabel: 'next');
    addTearDown(next.dispose);
    await pumpCarbon(
      tester,
      Align(
        alignment: AlignmentDirectional.topStart,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Host(
                entries: [
                  CarbonMenuItem(label: 'Cut', onPressed: () {}),
                  CarbonMenuItem(label: 'Copy', onPressed: () {}),
                ],
              ),
              const SizedBox(height: 8),
              CarbonButton(label: 'Next', focusNode: next, onPressed: () {}),
            ],
          ),
        ),
      ),
      size: const Size(800, 600),
    );
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.text('Cut'), findsNothing);
    expect(next.hasPrimaryFocus, isTrue);
  });

  testWidgets('repeating a letter cycles through the matching items', (
    tester,
  ) async {
    await _pump(
      tester,
      _Host(
        entries: [
          CarbonMenuItem(label: 'Cut', onPressed: () {}),
          CarbonMenuItem(label: 'Delete', onPressed: () {}),
          CarbonMenuItem(label: 'Duplicate', onPressed: () {}),
        ],
      ),
    );
    await _open(tester);
    expect(_hasFocus(tester, 'Cut'), isTrue);
    await _type(tester, 'd', LogicalKeyboardKey.keyD);
    expect(_hasFocus(tester, 'Delete'), isTrue);
    await _type(tester, 'd', LogicalKeyboardKey.keyD);
    expect(_hasFocus(tester, 'Duplicate'), isTrue);
    await _type(tester, 'd', LogicalKeyboardKey.keyD);
    expect(_hasFocus(tester, 'Delete'), isTrue);
  });

  testWidgets('context menu opens from the Menu key and Shift+F10', (
    tester,
  ) async {
    final node = FocusNode(debugLabel: 'row');
    addTearDown(node.dispose);
    await _pump(
      tester,
      CarbonContextMenu(
        entries: [CarbonMenuItem(label: 'Rename', onPressed: () {})],
        child: Focus(
          focusNode: node,
          child: const SizedBox(width: 200, height: 40),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await _key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.text('Rename'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.text('Rename'), findsNothing);
    expect(node.hasPrimaryFocus, isTrue);

    await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await simulateKeyDownEvent(LogicalKeyboardKey.f10);
    await simulateKeyUpEvent(LogicalKeyboardKey.f10);
    await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets(
    'a submenu with no room on the trailing side opens beside the parent, not over it',
    (tester) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.topRight,
          child: CarbonOverflowMenu(
            entries: [
              CarbonMenuSubmenu(
                label: 'More',
                entries: [CarbonMenuItem(label: 'Sub one', onPressed: () {})],
              ),
            ],
          ),
        ),
        size: const Size(800, 600),
      );
      await tester.tap(find.byType(CarbonOverflowMenu));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('More'));
      await tester.pump();
      await tester.pump();
      final parent = _rowRect(tester, 'More');
      final sub = _rowRect(tester, 'Sub one');
      expect(
        sub.right <= parent.left + 1 || sub.left >= parent.right - 1,
        isTrue,
        reason: 'parent $parent, submenu $sub',
      );
    },
  );

  testWidgets('a submenu keeps the menu width bounds', (tester) async {
    final longLabel = 'x' * 120;
    await _pump(
      tester,
      _Host(
        entries: [
          CarbonMenuSubmenu(
            label: 'Short',
            entries: [CarbonMenuItem(label: 'a', onPressed: () {})],
          ),
          CarbonMenuSubmenu(
            label: 'Long',
            entries: [CarbonMenuItem(label: longLabel, onPressed: () {})],
          ),
        ],
      ),
    );
    await _open(tester);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_rowRect(tester, 'a').width, greaterThanOrEqualTo(160));
    await _key(tester, LogicalKeyboardKey.escape);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_rowRect(tester, longLabel).width, lessThanOrEqualTo(320));
  });

  testWidgets(
    'rows rest in secondary text and emphasise on hover; danger is not red at rest',
    (tester) async {
      await _pump(
        tester,
        _Host(
          entries: [
            CarbonMenuItem(label: 'Copy', onPressed: () {}),
            CarbonMenuItem(
              label: 'Delete',
              kind: CarbonMenuItemKind.danger,
              onPressed: () {},
            ),
          ],
        ),
      );
      await _open(tester);
      final colors = CarbonTheme.of(tester.element(find.text('Copy'))).colors;
      Color? colorOf(String label) =>
          tester.widget<Text>(find.text(label)).style?.color;
      expect(colorOf('Delete'), colors.textSecondary);
      // Copy holds keyboard focus, which does not change its text colour.
      expect(colorOf('Copy'), colors.textSecondary);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Copy')));
      await tester.pump();
      expect(colorOf('Copy'), colors.textPrimary);
    },
  );

  group('showCarbonMenuAt', () {
    const hostKey = ValueKey<String>('host');

    Future<BuildContext> mount(WidgetTester tester, {FocusNode? node}) async {
      await pumpCarbon(
        tester,
        Focus(
          focusNode: node,
          child: const SizedBox.expand(key: hostKey),
        ),
        size: const Size(800, 600),
      );
      return tester.element(find.byKey(hostKey));
    }

    List<CarbonMenuEntry> entries(List<String> log) => <CarbonMenuEntry>[
      CarbonMenuItem(label: 'One', onPressed: () => log.add('one')),
      const CarbonMenuItem(label: 'Skipped'),
      CarbonMenuItem(label: 'Three', onPressed: () => log.add('three')),
    ];

    testWidgets('arrow keys move through items and Enter activates', (
      tester,
    ) async {
      final log = <String>[];
      final context = await mount(tester);
      showCarbonMenuAt(context, const Offset(200, 200), entries(log));
      await tester.pump();
      await tester.pump();
      expect(_hasFocus(tester, 'One'), isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_hasFocus(tester, 'Skipped'), isFalse);
      expect(_hasFocus(tester, 'Three'), isTrue);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(log, ['three']);
      expect(find.text('Three'), findsNothing);
    });

    testWidgets('Escape closes it, completes the future and restores focus', (
      tester,
    ) async {
      final node = FocusNode(debugLabel: 'previous');
      addTearDown(node.dispose);
      final context = await mount(tester, node: node);
      node.requestFocus();
      await tester.pump();
      var closed = false;
      showCarbonMenuAt(
        context,
        const Offset(200, 200),
        entries(<String>[]),
      ).closed.then((_) => closed = true);
      await tester.pump();
      await tester.pump();
      expect(_hasFocus(tester, 'One'), isTrue);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(find.text('One'), findsNothing);
      expect(closed, isTrue);
      expect(node.hasPrimaryFocus, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('back closes the menu instead of popping the route', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        const SizedBox.expand(key: hostKey),
        size: const Size(800, 600),
      );
      final context = tester.element(find.byKey(hostKey));
      var closed = false;
      showCarbonMenuAt(
        context,
        const Offset(200, 200),
        entries(<String>[]),
      ).closed.then((_) => closed = true);
      await tester.pump();
      await tester.pump();
      expect(find.text('One'), findsOneWidget);
      await harness.back(tester);
      await tester.pump();
      await tester.pump();
      expect(find.text('One'), findsNothing);
      expect(closed, isTrue);
      expect(find.byKey(hostKey), findsOneWidget);
    });

    testWidgets('close() on the handle closes it', (tester) async {
      final context = await mount(tester);
      final handle = showCarbonMenuAt(
        context,
        const Offset(200, 200),
        entries(<String>[]),
      );
      await tester.pump();
      await tester.pump();
      handle.close();
      await tester.pump();
      await tester.pump();
      await handle.closed;
      expect(find.text('One'), findsNothing);
    });

    testWidgets('closes when another route covers the presenting one', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        const SizedBox.expand(key: hostKey),
        size: const Size(800, 600),
      );
      final context = tester.element(find.byKey(hostKey));
      var closed = false;
      showCarbonMenuAt(
        context,
        const Offset(200, 200),
        entries(<String>[]),
      ).closed.then((_) => closed = true);
      await tester.pump();
      await tester.pump();
      expect(find.text('One'), findsOneWidget);
      harness.navigatorKey.currentState!.push(
        PageRouteBuilder<void>(
          pageBuilder: (c, a, s) => const SizedBox(key: ValueKey('next')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('One'), findsNothing);
      expect(closed, isTrue);
    });

    testWidgets('closes when the presenting widget unmounts', (tester) async {
      final show = ValueNotifier<bool>(true);
      addTearDown(show.dispose);
      await pumpCarbon(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: show,
          builder: (c, on, w) =>
              on ? const SizedBox.expand(key: hostKey) : const SizedBox(),
        ),
        size: const Size(800, 600),
      );
      final context = tester.element(find.byKey(hostKey));
      var closed = false;
      showCarbonMenuAt(
        context,
        const Offset(200, 200),
        entries(<String>[]),
      ).closed.then((_) => closed = true);
      await tester.pump();
      await tester.pump();
      show.value = false;
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('One'), findsNothing);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Escape with nothing focused beforehand closes cleanly', (
      tester,
    ) async {
      final context = await mount(tester);
      showCarbonMenuAt(context, const Offset(200, 200), entries(<String>[]));
      await tester.pump();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.escape);
      expect(find.text('One'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
