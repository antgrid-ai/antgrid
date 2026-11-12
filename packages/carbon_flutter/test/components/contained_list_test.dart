import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Finder _row(String title) => find
    .ancestor(of: find.text(title), matching: find.byType(CarbonInteraction))
    .first;

Size _rowSize(WidgetTester tester, String title) => tester.getSize(_row(title));

bool _focused(WidgetTester tester, Finder f) {
  final target = tester.element(f);
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null) return false;
  if (Focus.maybeOf(target)?.hasPrimaryFocus ?? false) return true;
  var found = false;
  focus.visitAncestorElements((e) {
    if (identical(e, target)) found = true;
    return !found;
  });
  return found;
}

Widget _action(String label, VoidCallback onPressed) => CarbonButton.iconOnly(
  icon: const CarbonIcon(CarbonIcons.trashCan),
  semanticLabel: label,
  onPressed: onPressed,
);

void main() {
  group('layout', () {
    testWidgets('rows are at least 32 compact and 48 touch tall', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'Files',
          children: [
            CarbonContainedListRow(title: 'one', onPressed: () {}),
            const CarbonContainedListRow(title: 'static'),
          ],
        ),
      );
      expect(_rowSize(tester, 'one').height, greaterThanOrEqualTo(32));
      expect(_rowSize(tester, 'one').height, lessThan(40));
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(_rowSize(tester, 'one').height, greaterThanOrEqualTo(48));
      final staticBox = tester.getSize(
        find.ancestor(
          of: find.text('static'),
          matching: find.byType(ConstrainedBox),
        ).first,
      );
      expect(staticBox.height, greaterThanOrEqualTo(48));
    });

    testWidgets('rows grow with text and wrap secondary text at 200%', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'Files',
          children: [
            CarbonContainedListRow(
              title: 'A title that is long enough to wrap on a narrow screen',
              secondary:
                  'And a secondary line that also needs several lines of room',
              onPressed: () {},
            ),
          ],
        ),
        size: const Size(320, 800),
      );
      final normal = _rowSize(
        tester,
        'A title that is long enough to wrap on a narrow screen',
      ).height;
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'Files',
          children: [
            CarbonContainedListRow(
              title: 'A title that is long enough to wrap on a narrow screen',
              secondary:
                  'And a secondary line that also needs several lines of room',
              onPressed: () {},
            ),
          ],
        ),
        size: const Size(320, 800),
        textScale: 2,
      );
      final scaled = _rowSize(
        tester,
        'A title that is long enough to wrap on a narrow screen',
      ).height;
      expect(scaled, greaterThan(normal * 1.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('header label wraps and keeps the action reachable at 200%', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'A long list heading that must wrap',
          action: CarbonButton(label: 'Add', onPressed: () {}),
          children: const [CarbonContainedListRow(title: 'x')],
        ),
        size: const Size(320, 800),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Add'), findsOneWidget);
      expect(tester.getRect(find.text('Add')).right, lessThanOrEqualTo(320));
    });

    testWidgets('leading content shows before the title', (tester) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'With icon',
              leading: CarbonIcon(CarbonIcons.star),
            ),
          ],
        ),
      );
      expect(
        tester.getTopLeft(find.byType(CarbonIcon)).dx,
        lessThan(tester.getTopLeft(find.text('With icon')).dx),
      );
    });

    testWidgets('right-to-left puts actions at the left', (tester) async {
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              onPressed: () {},
              actions: [_action('Delete', () {})],
            ),
          ],
        ),
        dir: TextDirection.rtl,
      );
      expect(
        tester.getCenter(find.byType(CarbonButton)).dx,
        lessThan(tester.getCenter(find.text('Row')).dx),
      );
    });

    testWidgets('disclosed variant and inset render', (tester) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          variant: CarbonContainedListVariant.disclosed,
          inset: true,
          children: [CarbonContainedListRow(title: 'x')],
        ),
      );
      expect(find.text('x'), findsOneWidget);
    });
  });

  group('activation', () {
    testWidgets('row tap activates the row only', (tester) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              onPressed: () => log.add('row'),
              actions: [_action('Delete', () => log.add('action'))],
            ),
          ],
        ),
      );
      await tester.tap(find.text('Row'));
      await tester.pump();
      expect(log, ['row']);
    });

    testWidgets('tapping a trailing action never activates the row', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              onPressed: () => log.add('row'),
              actions: [
                _action('Delete', () => log.add('delete')),
                _action('Other', () => log.add('other')),
              ],
            ),
          ],
        ),
      );
      await tester.tap(find.byType(CarbonButton).first);
      await tester.pump();
      await tester.tap(find.byType(CarbonButton).last);
      await tester.pump();
      expect(log, ['delete', 'other']);
    });

    testWidgets('keyboard: row first, then each action in order', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              onPressed: () => log.add('row'),
              actions: [
                _action('A1', () => log.add('a1')),
                _action('A2', () => log.add('a2')),
              ],
            ),
          ],
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, find.text('Row')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, find.byType(CarbonButton).first), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, find.byType(CarbonButton).last), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(log, ['row', 'a1', 'a2']);
    });

    testWidgets('a static row is not focusable or tappable', (tester) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          children: [CarbonContainedListRow(title: 'static')],
        ),
      );
      expect(find.byType(CarbonInteraction), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('onSelectedChanged reports the opposite of selected', (
      tester,
    ) async {
      final log = <bool>[];
      Future<void> mount(bool selected) => pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              selected: selected,
              onSelectedChanged: log.add,
            ),
          ],
        ),
      );
      await mount(false);
      await tester.tap(find.text('Row'));
      await tester.pump();
      await mount(true);
      await tester.tap(find.text('Row'));
      await tester.pump();
      expect(log, [true, false]);
    });

    testWidgets('a disabled row action does not fall through to the row', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              onPressed: () => log.add('row'),
              actions: const [
                CarbonButton.iconOnly(
                  icon: CarbonIcon(CarbonIcons.trashCan),
                  semanticLabel: 'Delete',
                ),
              ],
            ),
          ],
        ),
      );
      await tester.tap(find.byType(CarbonButton));
      await tester.pump();
      expect(log, isEmpty);
    });
  });

  group('semantics', () {
    testWidgets('selectable row exposes label, secondary and selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              secondary: 'Detail',
              selected: true,
              onSelectedChanged: (_) {},
            ),
          ],
        ),
      );
      expect(
        tester.getSemantics(find.text('Row')),
        isSemantics(
          label: 'Row\nDetail',
          isSelected: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('action keeps its own name beside the row', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              onPressed: () {},
              actions: [_action('Delete', () {})],
            ),
          ],
        ),
      );
      expect(find.bySemanticsLabel('Delete'), findsOneWidget);
      expect(find.bySemanticsLabel('Row'), findsOneWidget);
      handle.dispose();
    });
  });

  group('hover-revealed actions', () {
    Future<void> mount(WidgetTester tester, {CarbonDensity? density}) =>
        pumpCarbon(
          tester,
          CarbonContainedList(
            label: 'L',
            children: [
              CarbonContainedListRow(
                title: 'Row',
                onPressed: () {},
                revealActionsOnHover: true,
                actions: [_action('Delete', () {})],
              ),
            ],
          ),
          theme: density == null ? null : CarbonThemeData(density: density),
        );

    bool visible(WidgetTester tester) {
      final box = tester.renderObject(find.byType(CarbonButton));
      return box.paintBounds.isFinite &&
          find
              .descendant(
                of: find.byType(Visibility),
                matching: find.byType(CarbonButton),
              )
              .evaluate()
              .isNotEmpty &&
          (tester.widget<Visibility>(find.byType(Visibility)).visible);
    }

    testWidgets('compact: hidden until hover, then shown', (tester) async {
      await mount(tester);
      expect(visible(tester), isFalse);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Row')));
      await tester.pump();
      expect(visible(tester), isTrue);
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(visible(tester), isFalse);
    });

    testWidgets('compact: keyboard focus reveals the actions', (tester) async {
      await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(visible(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused(tester, find.byType(CarbonButton)), isTrue);
      expect(visible(tester), isTrue);
    });

    testWidgets('hidden actions keep their layout space', (tester) async {
      await mount(tester);
      final before = tester.getRect(find.byType(CarbonButton));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Row')));
      await tester.pump();
      expect(tester.getRect(find.byType(CarbonButton)), before);
    });

    testWidgets('touch density always shows them', (tester) async {
      await mount(tester, density: CarbonDensity.touch);
      expect(visible(tester), isTrue);
    });
  });

  group('status slots', () {
    testWidgets('loading replaces the rows with the localized default', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          status: CarbonContainedListStatus.loading,
          children: [CarbonContainedListRow(title: 'hidden')],
        ),
      );
      expect(find.text('hidden'), findsNothing);
      expect(find.byType(CarbonInlineLoading), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('error shows the host slot', (tester) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          status: CarbonContainedListStatus.error,
          errorContent: Text('Could not load files'),
          children: [CarbonContainedListRow(title: 'hidden')],
        ),
      );
      expect(find.text('Could not load files'), findsOneWidget);
      expect(find.text('hidden'), findsNothing);
    });

    testWidgets('error falls back to a localized message with an icon', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          status: CarbonContainedListStatus.error,
          children: [],
        ),
      );
      expect(find.text('Error'), findsOneWidget);
      expect(find.byType(CarbonIcon), findsOneWidget);
    });

    testWidgets('empty content shows only when there are no rows', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          emptyContent: Text('Nothing here'),
          children: [],
        ),
      );
      expect(find.text('Nothing here'), findsOneWidget);
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          emptyContent: Text('Nothing here'),
          children: [CarbonContainedListRow(title: 'x')],
        ),
      );
      expect(find.text('Nothing here'), findsNothing);
    });

    testWidgets('empty default is the localized no-results text', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(label: 'L', children: []),
      );
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('slot text grows at 200% without overflow', (tester) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'L',
          status: CarbonContainedListStatus.error,
          errorContent: Text('A long failure message that needs to wrap'),
          children: [],
        ),
        size: const Size(320, 600),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('lazy forms', () {
    testWidgets('builder creates only the visible rows', (tester) async {
      final built = <int>{};
      await pumpCarbon(
        tester,
        SizedBox(
          height: 300,
          child: CarbonContainedList.builder(
            label: 'Many',
            itemCount: 10000,
            itemBuilder: (context, i) {
              built.add(i);
              return CarbonContainedListRow(title: 'Row $i', onPressed: () {});
            },
          ),
        ),
        size: const Size(400, 600),
      );
      expect(built.length, lessThan(40));
      expect(find.text('Row 0'), findsOneWidget);
      await tester.drag(find.text('Row 1'), const Offset(0, -2000));
      await tester.pump();
      expect(built.length, lessThan(200));
    });

    testWidgets('builder with no items shows the empty slot', (tester) async {
      await pumpCarbon(
        tester,
        SizedBox(
          height: 300,
          child: CarbonContainedList.builder(
            label: 'Many',
            itemCount: 0,
            itemBuilder: (context, i) => const SizedBox(),
          ),
        ),
      );
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('sliver form works inside a CustomScrollView', (tester) async {
      await pumpCarbon(
        tester,
        CustomScrollView(
          slivers: [
            CarbonContainedListSliver(
              label: 'Sliver list',
              itemCount: 500,
              itemBuilder: (context, i) =>
                  CarbonContainedListRow(title: 'Item $i', onPressed: () {}),
            ),
          ],
        ),
        size: const Size(400, 600),
      );
      expect(find.text('Sliver list'), findsOneWidget);
      expect(find.text('Item 0'), findsOneWidget);
      expect(find.text('Item 400', skipOffstage: false), findsNothing);
      await tester.drag(find.text('Item 1'), const Offset(0, -3000));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('sliver form shows loading in place of rows', (tester) async {
      await pumpCarbon(
        tester,
        CustomScrollView(
          slivers: [
            CarbonContainedListSliver(
              label: 'Sliver list',
              itemCount: 5,
              status: CarbonContainedListStatus.loading,
              itemBuilder: (context, i) =>
                  CarbonContainedListRow(title: 'Item $i'),
            ),
          ],
        ),
      );
      expect(find.text('Item 0'), findsNothing);
      expect(find.byType(CarbonInlineLoading), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    });
  });

  group('lifecycle', () {
    testWidgets('selection and theme changes keep row focus', (tester) async {
      final harness = await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(title: 'Row', onPressed: () {}),
          ],
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(_focused(tester, find.text('Row')), isTrue);
    });

    testWidgets('supplied focus node is honoured and not disposed', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        CarbonContainedList(
          label: 'L',
          children: [
            CarbonContainedListRow(
              title: 'Row',
              onPressed: () {},
              focusNode: node,
            ),
          ],
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasPrimaryFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(node.hasFocus, isFalse);
    });
  });

  group('content slot', () {
    const body = Key('body');

    Widget row({bool selected = false, bool withContent = true}) =>
        CarbonContainedList(
          label: 'Files',
          children: [
            CarbonContainedListRow(
              title: 'Title text',
              secondary: 'Secondary text',
              selected: selected,
              onPressed: () {},
              content: withContent
                  ? const SizedBox(key: body, height: 20, child: Text('Body text'))
                  : null,
            ),
          ],
        );

    testWidgets('content replaces the title and secondary text', (
      tester,
    ) async {
      await pumpCarbon(tester, row());
      expect(find.text('Body text'), findsOneWidget);
      expect(find.text('Title text'), findsNothing);
      expect(find.text('Secondary text'), findsNothing);
    });

    testWidgets('the title stays the accessible name', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, row());
      final node = tester.getSemantics(
        find.ancestor(of: find.byKey(body), matching: find.byType(CarbonInteraction)).first,
      );
      expect(node.label, 'Title text');
      expect(find.bySemanticsLabel('Body text'), findsNothing);
      handle.dispose();
    });

    testWidgets('a static row is named by its title too', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'Files',
          children: [
            CarbonContainedListRow(title: 'Title text', content: Text('Body text')),
          ],
        ),
      );
      expect(find.bySemanticsLabel('Title text'), findsOneWidget);
      expect(find.bySemanticsLabel('Body text'), findsNothing);
      handle.dispose();
    });

    testWidgets('selected and hover fills match a row without content', (
      tester,
    ) async {
      List<Color> fills() => tester
          .widgetList<ColoredBox>(
            find.descendant(
              of: find.byType(CarbonContainedListRow),
              matching: find.byType(ColoredBox),
            ),
          )
          .map((b) => b.color)
          .toList();

      Future<List<List<Color>>> sample(bool withContent) async {
        await pumpCarbon(tester, row(selected: true, withContent: withContent));
        final rest = fills();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.byType(CarbonContainedListRow)));
        await tester.pump();
        final hover = fills();
        await mouse.removePointer();
        await tester.pump();
        return <List<Color>>[rest, hover];
      }

      final plain = await sample(false);
      final custom = await sample(true);
      expect(custom, plain);
    });

    testWidgets('no overflow at 320 wide with 2x text', (tester) async {
      await pumpCarbon(
        tester,
        SizedBox(
          width: 320,
          child: CarbonContainedList(
            label: 'Files',
            children: [
              CarbonContainedListRow(
                title: 'Title text',
                leading: const CarbonIcon(CarbonIcons.document),
                content: const Text(
                  'A long piece of free-form row content that has to wrap',
                ),
                onPressed: () {},
              ),
            ],
          ),
        ),
        textScale: 2,
        size: const Size(320, 600),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
