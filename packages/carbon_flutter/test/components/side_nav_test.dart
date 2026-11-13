import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void _noop() {}

CarbonThemeData _touch([double target = 44]) =>
    CarbonThemeData(density: CarbonDensity.touch, touchTarget: target);

Widget _panel(
  List<Widget> children, {
  double width = 288,
  bool endBorder = false,
  double? inset,
  double? endInset,
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: CarbonSideNav(
    width: width,
    endBorder: endBorder,
    inset: inset,
    endInset: endInset,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    ),
  ),
);

Finder _link(String label) => find.widgetWithText(CarbonSideNavLink, label);

Finder _menu(String title) => find.widgetWithText(CarbonSideNavMenu, title);

Iterable<DecoratedBox> _boxes(Finder within) => find
    .descendant(of: within, matching: find.byType(DecoratedBox))
    .evaluate()
    .map((e) => e.widget as DecoratedBox);

/// The row's resting/hover/selected fill: the first background box below the
/// foreground one that carries the start bar.
Color? _fill(Finder row) => (_boxes(row)
        .firstWhere((b) => b.position == DecorationPosition.background)
        .decoration
    as BoxDecoration)
    .color;

Finder _bar(Finder row) => find.descendant(
  of: row,
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.position == DecorationPosition.foreground &&
        (w.decoration as BoxDecoration).border != null,
  ),
);

TextStyle _style(WidgetTester tester, String text) =>
    DefaultTextStyle.of(tester.element(find.text(text))).style;

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: const Offset(790, 590));
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump();
  return mouse;
}

bool _shown(WidgetTester tester, Finder f) => tester
    .widget<Visibility>(
      find.ancestor(of: f, matching: find.byType(Visibility)).first,
    )
    .visible;

bool _holdsFocus(WidgetTester tester, Finder f) {
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null) return false;
  final target = tester.element(f);
  var found = false;
  focus.visitAncestorElements((e) {
    if (identical(e, target)) found = true;
    return !found;
  });
  return found;
}

Widget _delete(VoidCallback onPressed) => CarbonButton.iconOnly(
  icon: const CarbonIcon(CarbonIcons.trashCan),
  semanticLabel: 'Delete',
  onPressed: onPressed,
);

Finder get _deleteButton => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == 'Delete',
);

const Key _mark = Key('mark');
const Widget _markWidget = SizedBox(key: _mark, width: 24, height: 24);

Finder _glyph(CarbonIcons icon) =>
    find.byWidgetPredicate((w) => w is CarbonIcon && w.icon == icon);

void main() {
  group('CarbonSideNav', () {
    testWidgets('is a navigation landmark named by its label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _panel(const [CarbonSideNavLink(label: 'Home', onPressed: _noop)]),
      );
      var data = tester
          .getSemantics(find.byType(CarbonSideNav))
          .getSemanticsData();
      expect(data.role, SemanticsRole.navigation);
      expect(data.label, 'Side navigation');

      await pumpCarbon(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: CarbonSideNav(
            semanticLabel: 'Projects',
            width: 200,
            child: const SizedBox(height: 40),
          ),
        ),
      );
      data = tester.getSemantics(find.byType(CarbonSideNav)).getSemanticsData();
      expect(data.label, 'Projects');
      handle.dispose();
    });

    for (final scheme in CarbonThemeScheme.values) {
      testWidgets('fills with background in ${scheme.name}', (tester) async {
        final theme = CarbonThemeData(scheme: scheme);
        await pumpCarbon(
          tester,
          _panel(const [CarbonSideNavLink(label: 'Home', onPressed: _noop)]),
          theme: theme,
        );
        final box = _boxes(find.byType(CarbonSideNav)).first;
        expect((box.decoration as BoxDecoration).color, theme.colors.background);
      });
    }

    testWidgets('takes its width and leaves the border outside the items', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _panel(const [
          CarbonSideNavLink(label: 'Home', onPressed: _noop),
        ], width: 200),
      );
      expect(tester.getSize(find.byType(CarbonSideNav)).width, 200);

      await pumpCarbon(
        tester,
        _panel(const [
          CarbonSideNavLink(label: 'Home', onPressed: _noop),
        ], width: 200, endBorder: true, endInset: 0),
      );
      final panel = tester.getRect(find.byType(CarbonSideNav));
      // The 1px rule takes its own pixel, so the row ends before it.
      expect(tester.getRect(_link('Home')).right, panel.right - 1);
    });

    for (final dir in TextDirection.values) {
      testWidgets('draws the end border on the end edge in $dir', (
        tester,
      ) async {
        final theme = CarbonThemeData();
        await pumpCarbon(
          tester,
          _panel(const [
            CarbonSideNavLink(label: 'Home', onPressed: _noop),
          ], endBorder: true),
          dir: dir,
        );
        final decoration =
            _boxes(find.byType(CarbonSideNav)).first.decoration as BoxDecoration;
        final border = decoration.border! as BorderDirectional;
        final rule = border.end;
        final other = border.start;
        expect(rule.width, 1);
        expect(rule.color, theme.borderSubtle(0));
        expect(other.width, 0);
      });
    }
  });

  group('CarbonSideNavLink', () {
    for (final scheme in CarbonThemeScheme.values) {
      testWidgets('state colours in ${scheme.name}', (tester) async {
        final colors = CarbonThemeData(scheme: scheme).colors;
        await pumpCarbon(
          tester,
          _panel(const [
            CarbonSideNavLink(label: 'Rest', onPressed: _noop),
            CarbonSideNavLink(label: 'Now', current: true, onPressed: _noop),
          ]),
          theme: CarbonThemeData(scheme: scheme),
        );
        expect(_fill(_link('Rest')), isNull);
        expect(_style(tester, 'Rest').color, colors.textSecondary);
        expect(_fill(_link('Now')), colors.backgroundSelected);
        expect(_style(tester, 'Now').color, colors.textPrimary);
        expect(_style(tester, 'Now').fontWeight, FontWeight.w600);

        await _hover(tester, _link('Rest'));
        expect(_fill(_link('Rest')), colors.backgroundHover);
        expect(_style(tester, 'Rest').color, colors.textPrimary);
      });
    }

    testWidgets('is 32 compact, 44 touch, and 48 when large', (tester) async {
      Future<double> height(CarbonThemeData theme, {bool large = false}) async {
        await pumpCarbon(
          tester,
          _panel([
            CarbonSideNavLink(label: 'Home', large: large, onPressed: _noop),
          ]),
          theme: theme,
        );
        return tester.getSize(_link('Home')).height;
      }

      expect(await height(CarbonThemeData()), 32);
      expect(await height(CarbonThemeData(), large: true), 48);
      expect(await height(_touch()), 44);
      expect(await height(_touch(48)), 48);
      expect(await height(_touch(), large: true), 48);
    });

    testWidgets('keeps its own height inside a bounded parent', (tester) async {
      for (final theme in [CarbonThemeData(), _touch()]) {
        await pumpCarbon(
          tester,
          Align(
            alignment: AlignmentDirectional.topStart,
            // Loose, like a Scaffold body: a row must not grow to fill it.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 288, maxHeight: 600),
              child: CarbonSideNavScope(
                child: const CarbonSideNavLink(label: 'Home', onPressed: _noop),
              ),
            ),
          ),
          theme: theme,
        );
        expect(tester.getSize(_link('Home')).height, theme.isTouch ? 44 : 32);
      }
    });

    testWidgets('grows past its minimum height at 200% text', (tester) async {
      Future<double> height(CarbonThemeData theme) async {
        await pumpCarbon(
          tester,
          _panel([
            const CarbonSideNavLink(label: 'Home', onPressed: _noop),
          ]),
          theme: theme,
          textScale: 2,
        );
        return tester.getSize(_link('Home')).height;
      }

      expect(await height(CarbonThemeData()), greaterThan(32));
      expect(await height(_touch()), greaterThan(44));
    });

    testWidgets('the focus ring and press fill reach the row end', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(label: 'Home', focusNode: node, onPressed: _noop),
        ]),
      );
      node.requestFocus();
      await tester.pump();
      final ring = find.descendant(
        of: _link('Home'),
        matching: find.byType(CarbonFocusRing),
      );
      expect(tester.getRect(ring), tester.getRect(_link('Home')));
    });

    testWidgets('onDoublePressed reaches the interaction', (tester) async {
      var presses = 0;
      var doubles = 0;
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            onPressed: () => presses++,
            onDoublePressed: () => doubles++,
          ),
        ]),
      );
      await tester.tap(find.text('Home'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Home'));
      await tester.pump();
      expect(presses, 1);
      expect(doubles, 1);
      await tester.pump(kDoubleTapTimeout);
      expect(presses, 1);
      expect(doubles, 1);
    });

    testWidgets('touch swap shows marks inboard of the actions', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            onPressed: _noop,
            trailing: const [_markWidget],
            actions: [_delete(_noop)],
          ),
        ]),
        theme: _touch(),
      );
      expect(_shown(tester, _deleteButton), isTrue);
      expect(find.byKey(_mark), findsOneWidget);
      expect(
        tester.getRect(find.byKey(_mark)).right,
        lessThanOrEqualTo(tester.getRect(_deleteButton).left),
      );
    });

    testWidgets('covered marks stay in semantics', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            onPressed: _noop,
            trailing: [
              Semantics(
                label: 'Config error',
                child: const SizedBox(width: 24, height: 24),
              ),
            ],
            actions: [_delete(_noop)],
          ),
        ]),
      );
      await _hover(tester, _link('Home'));
      expect(find.bySemanticsLabel('Config error'), findsOneWidget);
      handle.dispose();
    });

    for (final dir in TextDirection.values) {
      testWidgets('insets by depth from the leading edge in $dir', (
        tester,
      ) async {
        const dot = Key('dot');
        await pumpCarbon(
          tester,
          _panel([
            const CarbonSideNavLink(
              label: 'Top',
              icon: CarbonIcons.folder,
              onPressed: _noop,
            ),
            CarbonSideNavMenu(
              title: 'Parent',
              icon: CarbonIcons.folder,
              expanded: true,
              onExpandedChanged: (_) {},
              children: const [
                CarbonSideNavLink(
                  label: 'Child',
                  leading: SizedBox(key: dot, width: 16, height: 16),
                  onPressed: _noop,
                ),
              ],
            ),
          ]),
          dir: dir,
        );
        final panel = tester.getRect(find.byType(CarbonSideNav));
        final ltr = dir == TextDirection.ltr;
        // Distance from the leading edge to each item's start.
        double fromStart(Rect r) => ltr ? r.left - panel.left : panel.right - r.right;
        final topIcon = tester.getRect(
          find.descendant(of: _link('Top'), matching: find.byType(CarbonIcon)),
        );
        expect(fromStart(topIcon), 16);
        expect(fromStart(tester.getRect(find.text('Parent'))), 40);
        // A nested item's leading slot sits under its parent's title.
        expect(fromStart(tester.getRect(find.byKey(dot))), 40);
        expect(fromStart(tester.getRect(find.text('Child'))), 64);
      });
    }

    testWidgets('uses heading at depth 0 and control when nested', (
      tester,
    ) async {
      final typography = CarbonThemeData().typography;
      await pumpCarbon(
        tester,
        _panel([
          const CarbonSideNavLink(label: 'Top', onPressed: _noop),
          CarbonSideNavMenu(
            title: 'Parent',
            expanded: true,
            onExpandedChanged: (_) {},
            children: const [CarbonSideNavLink(label: 'Child', onPressed: _noop)],
          ),
        ]),
      );
      expect(_style(tester, 'Top').fontSize, typography.heading.fontSize);
      expect(_style(tester, 'Child').fontSize, typography.control.fontSize);
      expect(_style(tester, 'Child').fontWeight, typography.control.fontWeight);
    });

    testWidgets('activates on Enter, Space and tap', (tester) async {
      var pressed = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            focusNode: node,
            onPressed: () => pressed++,
          ),
        ]),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(pressed, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(pressed, 2);
      await tester.tap(find.text('Home'));
      expect(pressed, 3);
    });

    for (final dir in TextDirection.values) {
      testWidgets('paints the 3px start bar over the fill in $dir', (
        tester,
      ) async {
        final colors = CarbonThemeData().colors;
        await pumpCarbon(
          tester,
          _panel(const [
            CarbonSideNavLink(label: 'Now', current: true, onPressed: _noop),
            CarbonSideNavLink(label: 'Other', onPressed: _noop),
          ]),
          dir: dir,
        );
        expect(_bar(_link('Other')), findsNothing);
        final bar = _bar(_link('Now'));
        expect(bar, findsOneWidget);
        final decoration = tester.widget<DecoratedBox>(bar).decoration
            as BoxDecoration;
        final start = (decoration.border! as BorderDirectional).start;
        expect(start.width, 3);
        expect(start.color, colors.borderInteractive);
        // The fill sits below the bar, so a hovered or pressed row cannot hide it.
        expect(
          find.descendant(
            of: bar,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.position == DecorationPosition.background &&
                  (w.decoration as BoxDecoration).color ==
                      colors.backgroundSelected,
            ),
          ),
          findsOneWidget,
        );
        await _hover(tester, _link('Now'));
        expect(_bar(_link('Now')), findsOneWidget);
        expect(_fill(_link('Now')), colors.backgroundSelected);
      });
    }

    testWidgets('swap shows marks at rest and actions on hover, focus and touch', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      Widget link() => _panel([
        CarbonSideNavLink(
          label: 'Home',
          focusNode: node,
          onPressed: _noop,
          trailing: const [_markWidget],
          actions: [_delete(_noop)],
        ),
      ]);
      await pumpCarbon(tester, link());
      expect(_shown(tester, find.byKey(_mark)), isTrue);
      expect(_shown(tester, _deleteButton), isFalse);
      final rowRect = tester.getRect(_link('Home'));
      final markRect = tester.getRect(find.byKey(_mark));

      // Hover.
      final mouse = await _hover(tester, _link('Home'));
      expect(_shown(tester, find.byKey(_mark)), isFalse);
      expect(_shown(tester, _deleteButton), isTrue);
      expect(tester.getRect(_link('Home')), rowRect);
      expect(tester.getRect(find.byKey(_mark)), markRect);

      // Focus alone, with the pointer away.
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump();
      expect(_shown(tester, _deleteButton), isFalse);
      node.requestFocus();
      await tester.pump();
      expect(_shown(tester, _deleteButton), isTrue);
      expect(_shown(tester, find.byKey(_mark)), isFalse);

      // Touch shows the actions with no hover to reveal them.
      node.unfocus();
      await tester.pump();
      expect(_shown(tester, _deleteButton), isFalse);
      await pumpCarbon(tester, link(), theme: _touch());
      expect(_shown(tester, _deleteButton), isTrue);
    });

    testWidgets('hidden actions stay reachable by keyboard', (tester) async {
      await pumpCarbon(
        tester,
        _panel([
          const CarbonButton(label: 'Before', onPressed: _noop),
          CarbonSideNavLink(
            label: 'Home',
            onPressed: _noop,
            trailing: const [_markWidget],
            actions: [_delete(_noop)],
          ),
        ]),
      );
      Focus.of(tester.element(find.text('Before'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_holdsFocus(tester, _deleteButton), isTrue);
    });

    testWidgets('reserved keeps marks and gives actions their own slot', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            onPressed: _noop,
            actionsMode: CarbonSideNavActions.reserved,
            trailing: const [_markWidget],
            actions: [_delete(_noop)],
          ),
        ]),
      );
      expect(find.byKey(_mark), findsOneWidget);
      expect(_shown(tester, _deleteButton), isFalse);
      final markRect = tester.getRect(find.byKey(_mark));
      final actionRect = tester.getRect(_deleteButton);
      expect(markRect.right <= actionRect.left, isTrue);

      await _hover(tester, _link('Home'));
      expect(_shown(tester, _deleteButton), isTrue);
      expect(tester.getRect(find.byKey(_mark)), markRect);
      expect(tester.getRect(_deleteButton), actionRect);
    });

    testWidgets('keepActionsRevealed holds the actions through pointer exit', (
      tester,
    ) async {
      Widget link(bool keep) => _panel([
        CarbonSideNavLink(
          label: 'Home',
          onPressed: _noop,
          keepActionsRevealed: keep,
          trailing: const [_markWidget],
          actions: [_delete(_noop)],
        ),
      ]);
      await pumpCarbon(tester, link(true));
      expect(_shown(tester, _deleteButton), isTrue);

      final mouse = await _hover(tester, _link('Home'));
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump();
      expect(_shown(tester, _deleteButton), isTrue);

      await pumpCarbon(tester, link(false));
      expect(_shown(tester, _deleteButton), isFalse);
    });

    testWidgets('a long press that cancels does not also activate', (
      tester,
    ) async {
      var pressed = 0;
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            cancelOnLongPress: true,
            onPressed: () => pressed++,
          ),
        ]),
      );
      await tester.longPress(find.text('Home'));
      await tester.pump();
      expect(pressed, 0);
    });

    testWidgets('content keeps the label as the accessible name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _panel(const [
          CarbonSideNavLink(
            label: 'Alpha',
            content: Text('Shown'),
            onPressed: _noop,
          ),
        ]),
      );
      expect(find.text('Shown'), findsOneWidget);
      expect(find.bySemanticsLabel('Alpha'), findsOneWidget);
      expect(find.bySemanticsLabel('Shown'), findsNothing);
      handle.dispose();
    });

    testWidgets('announces a button with its selected state', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _panel(const [
          CarbonSideNavLink(label: 'Rest', onPressed: _noop),
          CarbonSideNavLink(label: 'Now', current: true, onPressed: _noop),
        ]),
      );
      final rest = tester.getSemantics(find.text('Rest')).flagsCollection;
      final now = tester.getSemantics(find.text('Now')).flagsCollection;
      expect(rest.isButton, isTrue);
      expect(rest.isSelected, Tristate.isFalse);
      expect(now.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('disabled is inert and painted disabled', (tester) async {
      final handle = tester.ensureSemantics();
      var pressed = 0;
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            disabled: true,
            onPressed: () => pressed++,
          ),
        ]),
      );
      await tester.tap(find.text('Home'));
      await tester.pump();
      expect(pressed, 0);
      expect(_style(tester, 'Home').color, CarbonThemeData().colors.textDisabled);
      expect(
        tester.getSemantics(find.text('Home')).flagsCollection.isEnabled,
        Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('actions do not activate the link', (tester) async {
      var pressed = 0;
      var deleted = 0;
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavLink(
            label: 'Home',
            onPressed: () => pressed++,
            actions: [_delete(() => deleted++)],
          ),
        ]),
        theme: _touch(),
      );
      await tester.tap(_deleteButton);
      await tester.pump();
      expect(deleted, 1);
      expect(pressed, 0);
    });
  });

  group('CarbonSideNavMenu', () {
    Widget menu({
      bool expanded = false,
      ValueChanged<bool>? onChanged,
      FocusNode? focusNode,
      bool active = false,
      CarbonSideNavChevron chevron = CarbonSideNavChevron.end,
      bool hoverFill = true,
      List<Widget> actions = const [],
      List<Widget> children = const [
        CarbonSideNavLink(label: 'Child', onPressed: _noop),
      ],
    }) => _panel([
      CarbonSideNavMenu(
        title: 'Proj',
        icon: CarbonIcons.folder,
        expanded: expanded,
        onExpandedChanged: onChanged ?? (_) {},
        focusNode: focusNode,
        active: active,
        chevron: chevron,
        hoverFill: hoverFill,
        actions: actions,
        children: children,
      ),
    ]);

    testWidgets('flips its expanded semantics with the host', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, menu());
      expect(
        tester.getSemantics(find.text('Proj')).flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      await pumpCarbon(tester, menu(expanded: true));
      expect(
        tester.getSemantics(find.text('Proj')).flagsCollection.isExpanded,
        Tristate.isTrue,
      );
      handle.dispose();
    });

    testWidgets('Enter, Space and tap ask the host to toggle', (tester) async {
      final requests = <bool>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(tester, menu(onChanged: requests.add, focusNode: node));
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.tap(find.text('Proj'));
      // The host owns the state and never flipped it, so each asks to open.
      expect(requests, [true, true, true]);
    });

    testWidgets('rotates the end chevron, and skips the motion when reduced', (
      tester,
    ) async {
      await pumpCarbon(tester, menu(expanded: true));
      var rotation = tester.widget<AnimatedRotation>(
        find.byType(AnimatedRotation),
      );
      expect(rotation.turns, 0.5);
      expect(rotation.duration, CarbonMotion.fast02);

      await pumpCarbon(tester, menu(), reduceMotion: true);
      rotation = tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
      expect(rotation.turns, 0);
      expect(rotation.duration, Duration.zero);
    });

    testWidgets('builds children only while expanded', (tester) async {
      await pumpCarbon(tester, menu());
      expect(find.text('Child'), findsNothing);
      await pumpCarbon(tester, menu(expanded: true));
      expect(find.text('Child'), findsOneWidget);
    });

    testWidgets('nests each level one icon step deeper', (tester) async {
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavMenu(
            title: 'Outer',
            icon: CarbonIcons.folder,
            expanded: true,
            onExpandedChanged: (_) {},
            children: [
              CarbonSideNavMenu(
                title: 'Inner',
                icon: CarbonIcons.folder,
                expanded: true,
                onExpandedChanged: (_) {},
                children: const [
                  CarbonSideNavLink(label: 'Leaf', onPressed: _noop),
                ],
              ),
            ],
          ),
        ]),
      );
      expect(CarbonSideNavScope.depthOf(tester.element(find.text('Leaf'))), 2);
      expect(tester.getTopLeft(find.text('Outer')).dx, 40);
      expect(tester.getTopLeft(find.text('Inner')).dx, 64);
      expect(tester.getTopLeft(find.text('Leaf')).dx, 64);
    });

    testWidgets('an active branch is bold, and barred only while collapsed', (
      tester,
    ) async {
      await pumpCarbon(tester, menu(active: true));
      expect(_bar(_menu('Proj')), findsOneWidget);
      expect(_style(tester, 'Proj').fontWeight, FontWeight.w600);
      expect(_fill(_menu('Proj')), CarbonThemeData().colors.backgroundSelected);

      await pumpCarbon(tester, menu(active: true, expanded: true));
      expect(_bar(_menu('Proj')), findsNothing);
      expect(_style(tester, 'Proj').fontWeight, FontWeight.w600);
    });

    testWidgets('actions do not toggle the branch', (tester) async {
      final requests = <bool>[];
      var deleted = 0;
      await pumpCarbon(
        tester,
        menu(onChanged: requests.add, actions: [_delete(() => deleted++)]),
        theme: _touch(),
      );
      await tester.tap(_deleteButton);
      await tester.pump();
      expect(deleted, 1);
      expect(requests, isEmpty);
    });

    testWidgets('swapsIcon shows the chevron only under a pointer', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      Widget swapping() => menu(
        chevron: CarbonSideNavChevron.swapsIcon,
        focusNode: node,
      );
      await pumpCarbon(tester, swapping());
      expect(_glyph(CarbonIcons.folder), findsOneWidget);
      expect(_glyph(CarbonIcons.chevronDown), findsNothing);

      // Focus alone never swaps it.
      node.requestFocus();
      await tester.pump();
      expect(_glyph(CarbonIcons.chevronDown), findsNothing);
      node.unfocus();
      await tester.pump();

      final mouse = await _hover(tester, find.text('Proj'));
      expect(_glyph(CarbonIcons.chevronDown), findsOneWidget);
      expect(_glyph(CarbonIcons.folder), findsNothing);
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump();
      expect(_glyph(CarbonIcons.folder), findsOneWidget);

      // Touch density never swaps it, pointer or not.
      await pumpCarbon(tester, swapping(), theme: _touch());
      await mouse.moveTo(tester.getCenter(find.text('Proj')));
      await tester.pump();
      expect(_glyph(CarbonIcons.chevronDown), findsNothing);
      expect(_glyph(CarbonIcons.folder), findsOneWidget);
    });

    testWidgets('afterLabel puts a tree chevron right after the title', (
      tester,
    ) async {
      double turns() => tester
          .widget<AnimatedRotation>(
            find.ancestor(
              of: _glyph(CarbonIcons.chevronDown),
              matching: find.byType(AnimatedRotation),
            ),
          )
          .turns;
      for (final dir in TextDirection.values) {
        await pumpCarbon(
          tester,
          Directionality(
            textDirection: dir,
            child: menu(chevron: CarbonSideNavChevron.afterLabel),
          ),
        );
        await tester.pumpAndSettle();
        expect(_glyph(CarbonIcons.chevronDown), findsOneWidget);
        expect(_glyph(CarbonIcons.folder), findsOneWidget);
        // Closed, it points toward the reading end.
        expect(turns(), dir == TextDirection.ltr ? -0.25 : 0.25);
        final title = tester.getRect(find.text('Proj'));
        final chevron = tester.getRect(_glyph(CarbonIcons.chevronDown));
        final gap = dir == TextDirection.ltr
            ? chevron.left - title.right
            : title.left - chevron.right;
        expect(gap, CarbonSpacing.spacing02);
      }

      await pumpCarbon(
        tester,
        menu(chevron: CarbonSideNavChevron.afterLabel, expanded: true),
      );
      await tester.pumpAndSettle();
      expect(turns(), 0);
    });

    testWidgets('hoverFill false leaves the row unfilled under a pointer', (
      tester,
    ) async {
      await pumpCarbon(tester, menu(hoverFill: false));
      await _hover(tester, find.text('Proj'));
      expect(_fill(_menu('Proj')), isNull);

      await pumpCarbon(tester, menu());
      expect(_fill(_menu('Proj')), CarbonThemeData().colors.backgroundHover);
    });
  });

  group('CarbonSideNavMenu semantics and scope', () {
    testWidgets('content replaces the title text, which stays the name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavMenu(
            title: 'Proj, config error',
            content: const Text('Proj'),
            expanded: false,
            onExpandedChanged: (_) {},
            children: const [],
          ),
        ]),
      );
      expect(find.text('Proj'), findsOneWidget);
      expect(find.bySemanticsLabel('Proj, config error'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('nested puts sibling rows one level deeper', (tester) async {
      late BuildContext inner;
      await pumpCarbon(
        tester,
        _panel([
          Builder(
            builder: (context) => CarbonSideNavScope.nested(
              context: context,
              child: Builder(
                builder: (c) {
                  inner = c;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ]),
      );
      expect(CarbonSideNavScope.depthOf(inner), 1);
    });

    testWidgets('an active expanded header hovers as selected', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _panel([
          CarbonSideNavMenu(
            title: 'Proj',
            active: true,
            expanded: true,
            onExpandedChanged: (_) {},
            children: const [],
          ),
        ]),
      );
      await _hover(tester, find.text('Proj'));
      expect(
        _fill(_menu('Proj')),
        CarbonThemeData().colors.backgroundSelected,
      );
    });
  });

  group('CarbonSideNavDivider', () {
    testWidgets('is a 1px subtle rule with Carbon margins', (tester) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        const Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(
            width: 288,
            child: Column(
              children: [
                CarbonSideNavDivider(),
                CarbonSideNavDivider(inset: false),
              ],
            ),
          ),
        ),
      );
      final dividers = find.byType(CarbonSideNavDivider);
      expect(tester.getSize(dividers.first), const Size(288, 17));
      final rule = find.descendant(
        of: dividers.first,
        matching: find.byType(ColoredBox),
      );
      expect(tester.getSize(rule), const Size(256, 1));
      expect(tester.widget<ColoredBox>(rule).color, theme.borderSubtle(0));
      final flush = find.descendant(
        of: dividers.last,
        matching: find.byType(ColoredBox),
      );
      expect(tester.getSize(flush).width, 288);
    });
  });
}
