import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _btn = Key('btn');

Widget _aligned(Widget child) =>
    Align(alignment: AlignmentDirectional.topStart, child: child);

BoxDecoration _decoration(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find
                  .descendant(
                    of: find.byKey(_btn),
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
            )
            .decoration
        as BoxDecoration;

Color? _labelColor(WidgetTester tester) => tester
    .widget<Text>(find.descendant(of: find.byKey(_btn), matching: find.byType(Text)))
    .style
    ?.color;

Future<TestGesture> _mouse(WidgetTester tester, Finder at) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(at));
  await tester.pump();
  return gesture;
}

Future<void> _focusByKeyboard(WidgetTester tester, FocusNode node) async {
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  addTearDown(
    () => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic,
  );
  node.requestFocus();
  await tester.pump();
}

void _noop() {}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

// The menu panel's scroll view hugs the rows plus the panel padding.
Finder get _panel => find.byType(SingleChildScrollView);

List<CarbonMenuEntry> _two() => <CarbonMenuEntry>[
  CarbonMenuItem(label: 'Rename', onPressed: _noop),
  CarbonMenuItem(label: 'Duplicate', onPressed: _noop),
];

void main() {
  group('button states', () {
    testWidgets('a focused tertiary button is filled with the inverse label', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Go',
            kind: CarbonButtonKind.tertiary,
            focusNode: node,
            onPressed: _noop,
          ),
        ),
        theme: theme,
      );
      await _focusByKeyboard(tester, node);
      expect(_decoration(tester).color, theme.colors.buttonTertiary);
      expect(_labelColor(tester), theme.colors.textInverse);
    });

    testWidgets('a focused danger tertiary button fills with danger primary', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Go',
            kind: CarbonButtonKind.dangerTertiary,
            focusNode: node,
            onPressed: _noop,
          ),
        ),
        theme: theme,
      );
      await _focusByKeyboard(tester, node);
      expect(_decoration(tester).color, theme.colors.buttonDangerPrimary);
      expect(_labelColor(tester), theme.colors.textOnColor);
    });

    testWidgets('a ghost button label turns link-hover on hover and press', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Go',
            kind: CarbonButtonKind.ghost,
            onPressed: _noop,
          ),
        ),
        theme: theme,
      );
      expect(_labelColor(tester), theme.colors.linkPrimary);
      final mouse = await _mouse(tester, find.byKey(_btn));
      expect(_labelColor(tester), theme.colors.linkPrimaryHover);
      await mouse.down(tester.getCenter(find.byKey(_btn)));
      await tester.pump();
      expect(_labelColor(tester), theme.colors.linkPrimaryHover);
      await mouse.up();
    });

    testWidgets('a disabled icon-only ghost button uses the on-color disabled icon', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        _aligned(
          const CarbonButton.iconOnly(
            key: _btn,
            icon: SizedBox.square(key: Key('glyph'), dimension: 16),
            semanticLabel: 'Delete',
          ),
        ),
        theme: theme,
      );
      final color = IconTheme.of(tester.element(find.byKey(const Key('glyph')))).color;
      expect(color, theme.colors.iconOnColorDisabled);
    });

    testWidgets('outlined buttons drop the accent frame once pressed', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        Column(
          children: [
            _aligned(
              CarbonButton(
                key: _btn,
                label: 'Go',
                kind: CarbonButtonKind.tertiary,
                onPressed: _noop,
              ),
            ),
          ],
        ),
        theme: theme,
      );
      final mouse = await _mouse(tester, find.byKey(_btn));
      // Hover keeps the accent frame, as Carbon's tertiary does.
      expect(
        (_decoration(tester).border! as Border).top.color,
        theme.colors.buttonTertiary,
      );
      await mouse.down(tester.getCenter(find.byKey(_btn)));
      await tester.pump();
      expect(_decoration(tester).color, theme.colors.buttonTertiaryActive);
      expect(
        (_decoration(tester).border! as Border).top.color,
        theme.colors.buttonTertiaryActive,
      );
      await mouse.up();
    });

    testWidgets('a hovered danger tertiary frame matches its fill', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: 'Go',
            kind: CarbonButtonKind.dangerTertiary,
            onPressed: _noop,
          ),
        ),
        theme: theme,
      );
      await _mouse(tester, find.byKey(_btn));
      expect(_decoration(tester).color, theme.colors.buttonDangerHover);
      expect(
        (_decoration(tester).border! as Border).top.color,
        theme.colors.buttonDangerHover,
      );
    });
  });

  group('button size', () {
    testWidgets('buttons in a row set are 196 px columns', (tester) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButtonSet(
            children: const [
              CarbonButton(
                key: Key('a'),
                label: 'Cancel',
                kind: CarbonButtonKind.secondary,
                onPressed: _noop,
              ),
              CarbonButton(key: Key('b'), label: 'Save', onPressed: _noop),
            ],
          ),
        ),
        size: const Size(800, 600),
      );
      expect(tester.getSize(find.byKey(const Key('a'))).width, 196);
      expect(tester.getSize(find.byKey(const Key('b'))).width, 196);
    });

    testWidgets('a long label wraps at the 320 px button cap', (tester) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonButton(
            key: _btn,
            label: List.filled(40, 'word').join(' '),
            onPressed: _noop,
          ),
        ),
        size: const Size(800, 600),
      );
      expect(tester.getSize(find.byKey(_btn)).width, lessThanOrEqualTo(320));
    });
  });

  group('menu button minWidth chevron', () {
    Future<double> gap(
      WidgetTester tester,
      CarbonButtonKind kind,
      CarbonButtonSize? size,
    ) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonMenuButton(
            key: _btn,
            label: 'A',
            kind: kind,
            size: size,
            entries: _two(),
          ),
        ),
        size: const Size(800, 600),
      );
      final button = tester.getRect(find.byKey(_btn));
      expect(button.width, 192);
      final icon = tester.getRect(
        find.descendant(of: find.byKey(_btn), matching: find.byType(CarbonIcon)),
      );
      return button.right - icon.right;
    }

    testWidgets('tertiary keeps the 16 px end padding', (tester) async {
      expect(await gap(tester, CarbonButtonKind.tertiary, null), 16);
    });

    testWidgets('extra small keeps its 8 px end padding', (tester) async {
      expect(
        await gap(tester, CarbonButtonKind.primary, CarbonButtonSize.extraSmall),
        8,
      );
    });
  });

  group('menu panel', () {
    Future<void> openMenuButton(
      WidgetTester tester, {
      CarbonButtonSize? size,
      List<CarbonMenuEntry>? entries,
    }) async {
      await pumpCarbon(
        tester,
        _aligned(
          Padding(
            padding: const EdgeInsets.all(40),
            child: CarbonMenuButton(
              key: _btn,
              label: 'Actions',
              size: size,
              entries: entries ?? _two(),
            ),
          ),
        ),
        size: const Size(800, 600),
      );
      await tester.tap(find.text('Actions'));
      await _settle(tester);
    }

    testWidgets('has 4 px above the first row and below the last', (
      tester,
    ) async {
      await openMenuButton(tester);
      final panel = tester.getRect(_panel);
      expect(panel.height, 2 * 32 + 8);
      expect(
        tester.getCenter(find.text('Rename')).dy - panel.top,
        4 + 16,
      );
    });

    testWidgets('draws no border, only the shadow', (tester) async {
      await openMenuButton(tester);
      final box = tester.widget<DecoratedBox>(
        find
            .ancestor(of: _panel, matching: find.byType(DecoratedBox))
            .first,
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.boxShadow, isNotEmpty);
    });

    testWidgets('rows match the trigger size', (tester) async {
      await openMenuButton(tester, size: CarbonButtonSize.medium);
      expect(tester.getRect(_panel).height, 2 * 40 + 8);
    });

    testWidgets('a pressed row keeps the hover fill', (tester) async {
      final theme = CarbonThemeData();
      await openMenuButton(tester);
      final mouse = await _mouse(tester, find.text('Duplicate'));
      await mouse.down(tester.getCenter(find.text('Duplicate')));
      await tester.pump();
      final fill = tester
          .widgetList<ColoredBox>(
            find.ancestor(
              of: find.text('Duplicate'),
              matching: find.byType(ColoredBox),
            ),
          )
          .first
          .color;
      expect(fill, theme.layerHover(CarbonLayer.of(tester.element(_panel))));
      await mouse.up();
    });

    testWidgets('the shortcut sits 8 px after the label', (tester) async {
      await openMenuButton(
        tester,
        entries: <CarbonMenuEntry>[
          CarbonMenuItem(
            label: 'Long label here',
            shortcut: 'F12',
            onPressed: _noop,
          ),
        ],
      );
      final label = tester.getRect(find.text('Long label here'));
      final shortcut = tester.getRect(find.text('F12'));
      expect(shortcut.left - label.right, 8);
    });

    testWidgets('a label longer than its shortcut keeps the room it needs', (
      tester,
    ) async {
      await openMenuButton(
        tester,
        entries: <CarbonMenuEntry>[
          CarbonMenuItem(
            label: 'Duplicate row',
            shortcut: 'Ctrl+D',
            onPressed: _noop,
          ),
        ],
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Duplicate row'),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
    });

    testWidgets('a truncated label is shown in full by a tooltip', (
      tester,
    ) async {
      const long =
          'A very long menu label that cannot fit inside the three hundred and twenty pixel panel';
      await openMenuButton(
        tester,
        entries: <CarbonMenuEntry>[
          CarbonMenuItem(label: long, onPressed: _noop),
          CarbonMenuItem(label: 'Short', onPressed: _noop),
        ],
      );
      Finder tooltipOn(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(CarbonTooltip),
      );
      expect(tooltipOn(long), findsOneWidget);
      expect(tooltipOn('Short'), findsNothing);
    });

    testWidgets('the shortcut turns primary with the label on hover', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await openMenuButton(
        tester,
        entries: <CarbonMenuEntry>[
          CarbonMenuItem(label: 'Copy', shortcut: 'F12', onPressed: _noop),
        ],
      );
      Color? shortcut() => tester.widget<Text>(find.text('F12')).style?.color;
      expect(shortcut(), theme.colors.textSecondary);
      await _mouse(tester, find.text('Copy'));
      expect(shortcut(), theme.colors.textPrimary);
    });

    testWidgets('a submenu row ends in a caret 8 px after the label', (
      tester,
    ) async {
      await openMenuButton(
        tester,
        entries: <CarbonMenuEntry>[
          CarbonMenuSubmenu(
            label: 'Long label here',
            entries: <CarbonMenuEntry>[
              CarbonMenuItem(label: 'Inner', onPressed: _noop),
            ],
          ),
        ],
      );
      final caret = find.byWidgetPredicate(
        (w) => w is CarbonIcon && w.icon == CarbonIcons.caretDown,
      );
      // The trigger chevron is also a caret-down; the row's is the last one.
      final row = find.descendant(of: _panel, matching: caret);
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: _panel,
          matching: find.byWidgetPredicate(
            (w) => w is RotatedBox && w.quarterTurns == 3,
          ),
        ),
        findsOneWidget,
      );
      final label = tester.getRect(find.text('Long label here'));
      expect(tester.getRect(row).left - label.right, 8);
    });

    testWidgets('a long label truncates inside a single-height row', (
      tester,
    ) async {
      await openMenuButton(
        tester,
        entries: <CarbonMenuEntry>[
          CarbonMenuItem(label: List.filled(30, 'lengthy').join(' '), onPressed: _noop),
        ],
      );
      expect(tester.getRect(_panel).height, 32 + 8);
      final text = tester.widget<Text>(find.textContaining('lengthy').first);
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('a submenu lines its first row up with its parent row', (
      tester,
    ) async {
      await openMenuButton(
        tester,
        entries: <CarbonMenuEntry>[
          CarbonMenuSubmenu(
            label: 'More',
            entries: <CarbonMenuEntry>[
              CarbonMenuItem(label: 'Inner', onPressed: _noop),
            ],
          ),
        ],
      );
      await tester.tap(find.text('More'));
      await _settle(tester);
      expect(
        tester.getCenter(find.text('Inner')).dy,
        tester.getCenter(find.text('More')).dy,
      );
    });
  });

  group('menu triggers', () {
    testWidgets('a primary menu button is at least 192 px with the chevron at the end', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonMenuButton(key: _btn, label: 'Go', entries: _two()),
        ),
        size: const Size(800, 600),
      );
      final rect = tester.getRect(find.byKey(_btn));
      expect(rect.width, 192);
      final icon = tester.getRect(find.byType(CarbonIcon));
      expect(rect.right - icon.right, 16);
    });

    testWidgets('a ghost menu button keeps its natural width', (tester) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonMenuButton(
            key: _btn,
            label: 'Go',
            kind: CarbonButtonKind.ghost,
            entries: _two(),
          ),
        ),
        size: const Size(800, 600),
      );
      expect(tester.getSize(find.byKey(_btn)).width, lessThan(192));
    });

    testWidgets('a split button is at least 160 px with a 127 px action', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonSplitButton(
            label: 'Run',
            onPressed: _noop,
            entries: _two(),
          ),
        ),
        size: const Size(800, 600),
      );
      expect(tester.getSize(find.byType(CarbonSplitButton)).width, 160);
      expect(tester.getSize(find.byType(CarbonButton).first).width, 127);
    });

    testWidgets('the chevron rotates open and shut instead of swapping', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _aligned(CarbonMenuButton(key: _btn, label: 'Go', entries: _two())),
        size: const Size(800, 600),
      );
      AnimatedRotation rotation() => tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(_btn),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation().turns, 0);
      expect(rotation().duration, CarbonMotion.fast02);
      await tester.tap(find.text('Go'));
      await _settle(tester);
      expect(rotation().turns, 0.5);
    });

    testWidgets('an open overflow trigger joins its menu with a layer fill and shadow', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        _aligned(
          Padding(
            padding: const EdgeInsets.all(40),
            child: CarbonOverflowMenu(entries: _two()),
          ),
        ),
        theme: theme,
        size: const Size(800, 600),
      );
      bool open() => find
          .descendant(
            of: find.byType(CarbonOverflowMenu),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).boxShadow != null &&
                  (w.decoration as BoxDecoration).color == theme.layer(1),
            ),
          )
          .evaluate()
          .isNotEmpty;
      expect(open(), isFalse);
      await tester.tap(find.byType(CarbonButton));
      await _settle(tester);
      expect(open(), isTrue);
    });
  });
}
