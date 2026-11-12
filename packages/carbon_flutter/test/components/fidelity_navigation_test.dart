// Compact-density measurements of tabs, content switcher, contained list and
// tag against upstream Carbon v11 (styles/scss/components/{tabs,
// content-switcher,contained-list,tag}).
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _abc = <CarbonOption<String>>[
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Beta'),
  CarbonOption(value: 'c', label: 'Gamma'),
];

final _theme = CarbonThemeData();

Widget _tabs({
  CarbonTabsVariant variant = CarbonTabsVariant.line,
  List<CarbonOption<String>> tabs = _abc,
  String value = 'a',
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: CarbonTabs<String>(
    tabs: tabs,
    value: value,
    variant: variant,
    onChanged: (_) {},
  ),
);

/// The tab's own decorated box: the nearest one around its label.
Finder _box(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(DecoratedBox)).first;

BoxDecoration _decoration(WidgetTester tester, Finder box) =>
    tester.widget<DecoratedBox>(box).decoration as BoxDecoration;

List<CarbonOption<String>> _many() => <CarbonOption<String>>[
  for (var i = 0; i < 12; i++)
    CarbonOption(value: 'tab$i', label: 'Tab number $i'),
];

Future<TestGesture> _press(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target));
  await tester.pump();
  return gesture;
}

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump();
  return mouse;
}

Color _textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  group('tabs', () {
    testWidgets('every line tab carries its own 2px border-subtle underline', (
      tester,
    ) async {
      await pumpCarbon(tester, _tabs());
      final beta = _decoration(tester, _box('Beta')).border! as Border;
      expect(beta.bottom.width, 2);
      expect(beta.bottom.color, _theme.borderSubtle(1));
      final alpha = _decoration(tester, _box('Alpha')).border! as Border;
      expect(alpha.bottom.color, _theme.colors.borderInteractive);
    });

    testWidgets('line tabs sit 1px apart with no rule under the list', (
      tester,
    ) async {
      await pumpCarbon(tester, _tabs());
      final gap =
          tester.getRect(_box('Beta')).left - tester.getRect(_box('Alpha')).right;
      expect(gap, 1);
      final hairlines = find.descendant(
        of: find.byType(CarbonTabs<String>),
        matching: find.byWidgetPredicate((w) {
          if (w is! DecoratedBox) return false;
          final d = w.decoration;
          return d is BoxDecoration &&
              d.border is Border &&
              (d.border! as Border).bottom.width == 1;
        }),
      );
      expect(hairlines, findsNothing);
    });

    testWidgets('the contained divider is border-strong', (tester) async {
      await pumpCarbon(tester, _tabs(variant: CarbonTabsVariant.contained));
      // tabs.scss: a contained tab's rule is on its leading edge.
      final gamma =
          _decoration(tester, _box('Gamma')).border! as BorderDirectional;
      expect(gamma.start.width, 1);
      expect(gamma.start.color, _theme.borderStrong(1));
    });

    testWidgets('no contained divider touches the selected tab', (
      tester,
    ) async {
      await pumpCarbon(tester, _tabs(variant: CarbonTabsVariant.contained));
      for (final label in ['Alpha', 'Beta']) {
        final border =
            _decoration(tester, _box(label)).border! as BorderDirectional;
        expect(border.start, BorderSide.none, reason: label);
        expect(border.end, BorderSide.none, reason: label);
      }
    });

    for (final contained in [false, true]) {
      testWidgets(
        'the icon follows the label by ${contained ? 16 : 8}px '
        '(${contained ? 'contained' : 'line'})',
        (tester) async {
          await pumpCarbon(
            tester,
            _tabs(
              variant: contained
                  ? CarbonTabsVariant.contained
                  : CarbonTabsVariant.line,
              tabs: const [
                CarbonOption(
                  value: 'a',
                  label: 'Settings',
                  icon: SizedBox(key: Key('icon'), width: 16, height: 16),
                ),
              ],
            ),
          );
          final icon = tester.getRect(find.byKey(const Key('icon')));
          final label = tester.getRect(find.text('Settings'));
          expect(icon.left - label.right, contained ? 16 : 8);
        },
      );
    }

    for (final contained in [false, true]) {
      testWidgets(
        'overflow buttons are ${contained ? 48 : 40}px wide '
        '(${contained ? 'contained' : 'line'})',
        (tester) async {
          await pumpCarbon(
            tester,
            _tabs(
              variant: contained
                  ? CarbonTabsVariant.contained
                  : CarbonTabsVariant.line,
              tabs: _many(),
              value: 'tab0',
            ),
            size: const Size(400, 400),
          );
          await tester.pump();
          await tester.pump();
          final button = find
              .ancestor(
                of: find.byType(CarbonIcon).last,
                matching: find.byType(Container),
              )
              .first;
          expect(tester.getSize(button).width, contained ? 48 : 40);
        },
      );
    }

    testWidgets('an overflow button hides when there is nothing to scroll', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _tabs(tabs: _many(), value: 'tab0'),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('Scroll back'), findsNothing);
      expect(find.bySemanticsLabel('Scroll forward'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Scroll forward'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Scroll back'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the forward button hides once the last tab is reached', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _tabs(tabs: _many(), value: 'tab11'),
        size: const Size(400, 400),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Scroll forward'), findsNothing);
      expect(find.bySemanticsLabel('Scroll back'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('line overflow buttons fill with background and press darker', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _tabs(tabs: _many(), value: 'tab0'),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      final button = find
          .ancestor(
            of: find.byType(CarbonIcon).last,
            matching: find.byType(Container),
          )
          .first;
      expect(tester.widget<Container>(button).color, _theme.colors.background);
      final gesture = await _press(tester, button);
      expect(
        tester.widget<Container>(button).color,
        _theme.colors.backgroundActive,
      );
      await gesture.up();
    });

    testWidgets('contained overflow buttons press to layer-accent-active', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _tabs(
          variant: CarbonTabsVariant.contained,
          tabs: _many(),
          value: 'tab0',
        ),
        size: const Size(400, 400),
      );
      await tester.pump();
      await tester.pump();
      final button = find
          .ancestor(
            of: find.byType(CarbonIcon).last,
            matching: find.byType(Container),
          )
          .first;
      final gesture = await _press(tester, button);
      expect(
        tester.widget<Container>(button).color,
        _theme.colors.layerAccentActive01,
      );
      await gesture.up();
    });

    testWidgets('pressing a contained tab keeps its resting fill', (
      tester,
    ) async {
      await pumpCarbon(tester, _tabs(variant: CarbonTabsVariant.contained));
      final gesture = await _press(tester, _box('Beta'));
      expect(
        _decoration(tester, _box('Beta')).color,
        _theme.colors.layerAccent01,
      );
      await gesture.up();
    });

    testWidgets('pressing a line tab leaves it transparent', (tester) async {
      await pumpCarbon(tester, _tabs());
      final gesture = await _press(tester, _box('Beta'));
      expect(_decoration(tester, _box('Beta')).color, isNull);
      await gesture.up();
    });
  });

  group('content switcher', () {
    Widget switcher({
      CarbonContentSwitcherSize size = CarbonContentSwitcherSize.medium,
      bool iconOnly = false,
      bool icons = false,
      String value = 'a',
    }) => Align(
      alignment: AlignmentDirectional.topStart,
      child: CarbonContentSwitcher<String>(
        value: value,
        size: size,
        iconOnly: iconOnly,
        onChanged: (_) {},
        options: [
          for (final v in const ['a', 'b', 'c'])
            CarbonOption(
              value: v,
              label: 'Opt $v',
              icon: icons || iconOnly
                  ? SizedBox(key: Key('icon-$v'), width: 16, height: 16)
                  : null,
            ),
        ],
      ),
    );

    testWidgets('the outline and the selected fill have a 4px radius', (
      tester,
    ) async {
      await pumpCarbon(tester, switcher());
      final outline = tester
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(CarbonContentSwitcher<String>),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration as BoxDecoration;
      expect(outline.borderRadius, BorderRadius.circular(4));
      expect(
        _decoration(tester, _box('Opt a')).borderRadius,
        BorderRadius.circular(4),
      );
    });

    Finder rules() => find.byWidgetPredicate(
      (w) => w is SizedBox && w.width == 1 && w.height == 16,
    );

    testWidgets('dividers are 1x16 and centred', (tester) async {
      await pumpCarbon(tester, switcher());
      expect(rules(), findsOneWidget);
      final rule = tester.getRect(rules());
      expect(rule.height, 16);
      expect(rule.center.dy, tester.getRect(_box('Opt b')).center.dy);
    });

    testWidgets('a divider disappears beside a hovered segment', (
      tester,
    ) async {
      await pumpCarbon(tester, switcher());
      await _hover(tester, find.text('Opt c'));
      expect(rules(), findsNothing);
    });

    testWidgets('pressing a segment fills layer-hover with primary text', (
      tester,
    ) async {
      await pumpCarbon(tester, switcher());
      final gesture = await _press(tester, find.text('Opt b'));
      // The fill sits beside the label in a Stack, not above it.
      final fill = find
          .descendant(
            of: find
                .ancestor(of: find.text('Opt b'), matching: find.byType(Stack))
                .first,
            matching: find.byType(DecoratedBox),
          )
          .first;
      expect(_decoration(tester, fill).color, _theme.layerHover(1));
      expect(_textColor(tester, 'Opt b'), _theme.colors.textPrimary);
      await gesture.up();
    });

    testWidgets('icon-only icons use icon-primary, inverse when selected', (
      tester,
    ) async {
      await pumpCarbon(tester, switcher(iconOnly: true));
      Color iconColor(String v) =>
          IconTheme.of(tester.element(find.byKey(Key('icon-$v')))).color!;
      expect(iconColor('b'), _theme.colors.iconPrimary);
      expect(iconColor('a'), _theme.colors.iconInverse);
    });

    testWidgets('large segments use 20px icons, medium 16px', (tester) async {
      await pumpCarbon(
        tester,
        switcher(size: CarbonContentSwitcherSize.large, icons: true),
      );
      expect(
        IconTheme.of(tester.element(find.byKey(const Key('icon-b')))).size,
        20,
      );
      await pumpCarbon(tester, switcher(icons: true));
      expect(
        IconTheme.of(tester.element(find.byKey(const Key('icon-b')))).size,
        16,
      );
    });
  });

  group('contained list', () {
    Widget list({
      CarbonContainedListVariant variant = CarbonContainedListVariant.onPage,
      Widget? action,
      List<Widget>? rows,
    }) => Align(
      alignment: AlignmentDirectional.topStart,
      child: SizedBox(
        width: 400,
        child: CarbonContainedList(
          key: const Key('list'),
          label: 'Header',
          variant: variant,
          action: action,
          children:
              rows ?? const [CarbonContainedListRow(title: 'Row title')],
        ),
      ),
    );

    testWidgets('a disclosed header is filled with the layer', (tester) async {
      await pumpCarbon(
        tester,
        list(variant: CarbonContainedListVariant.disclosed),
      );
      expect(_decoration(tester, _box('Header')).color, _theme.layer(1));
    });

    testWidgets('row titles are body-01, 20px a line', (tester) async {
      await pumpCarbon(tester, list());
      expect(tester.getSize(find.text('Row title')).height, 20);
    });

    testWidgets('the leading icon sits 2px below the first line top', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        list(
          rows: const [
            CarbonContainedListRow(
              title: 'Row title',
              secondary: 'More',
              leading: SizedBox(key: Key('lead'), width: 16, height: 16),
            ),
          ],
        ),
      );
      expect(
        tester.getRect(find.byKey(const Key('lead'))).top -
            tester.getRect(find.text('Row title')).top,
        2,
      );
    });

    testWidgets('header and row actions are flush with the trailing edge', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        list(
          action: const SizedBox(key: Key('head'), width: 24, height: 24),
          rows: const [
            CarbonContainedListRow(
              title: 'Row title',
              actions: [SizedBox(key: Key('act'), width: 24, height: 24)],
            ),
          ],
        ),
      );
      final right = tester.getRect(find.byKey(const Key('list'))).right;
      expect(tester.getRect(find.byKey(const Key('head'))).right, right);
      expect(tester.getRect(find.byKey(const Key('act'))).right, right);
    });

    testWidgets('a disabled row is text-disabled and ignores hover and taps', (
      tester,
    ) async {
      var taps = 0;
      await pumpCarbon(
        tester,
        list(
          rows: [
            CarbonContainedListRow(
              title: 'Row title',
              disabled: true,
              onPressed: () => taps++,
            ),
          ],
        ),
      );
      expect(_textColor(tester, 'Row title'), _theme.colors.textDisabled);
      await _hover(tester, find.text('Row title'));
      expect(_decoration(tester, _box('Row title')).color, _theme.layer(1));
      await tester.tap(find.text('Row title'));
      expect(taps, 0);
    });
  });

  group('tag', () {
    Widget tag({
      String label = 'Backend',
      CarbonTagSize size = CarbonTagSize.medium,
      Widget? icon,
      bool? selected,
      bool disabled = false,
      VoidCallback? onDismissed,
      double width = 600,
    }) => Align(
      alignment: AlignmentDirectional.topStart,
      child: SizedBox(
        width: width,
        // A tight parent would pin the tag's width; the tag sizes itself.
        child: Align(
          alignment: AlignmentDirectional.topStart,
          child: CarbonTag(
            key: const Key('tag'),
            label: label,
            size: size,
            icon: icon,
            selected: selected,
            onSelectedChanged: selected == null ? null : (_) {},
            disabled: disabled,
            onDismissed: onDismissed,
          ),
        ),
      ),
    );

    Finder pillFinder() => find
        .descendant(
          of: find.byType(CarbonTag),
          matching: find.byType(DecoratedBox),
        )
        .first;

    testWidgets('a selected selectable tag fills layer-selected-inverse', (
      tester,
    ) async {
      await pumpCarbon(tester, tag(selected: true));
      expect(
        _decoration(tester, pillFinder()).color,
        _theme.colors.layerSelectedInverse,
      );
      await _hover(tester, find.text('Backend'));
      final colors = [
        for (final e in find
            .descendant(
              of: find.byType(CarbonTag),
              matching: find.byType(DecoratedBox),
            )
            .evaluate())
          ((e.widget as DecoratedBox).decoration as BoxDecoration).color,
      ];
      expect(colors, isNot(contains(_theme.colors.backgroundInverseHover)));
      expect(colors, contains(_theme.colors.layerSelectedInverse));
    });

    const sides = <CarbonTagSize, double>{
      CarbonTagSize.small: 8,
      CarbonTagSize.medium: 8,
      CarbonTagSize.large: 12,
    };
    for (final entry in sides.entries) {
      testWidgets('${entry.key.name} tag pads ${entry.value}px a side', (
        tester,
      ) async {
        await pumpCarbon(tester, tag(size: entry.key));
        final pill = tester.getRect(pillFinder());
        final label = tester.getRect(find.text('Backend'));
        expect(label.left - pill.left, entry.value);
        expect(pill.right - label.right, entry.value);
      });
    }

    const iconStart = <CarbonTagSize, double>{
      CarbonTagSize.medium: 4,
      CarbonTagSize.large: 8,
    };
    for (final entry in iconStart.entries) {
      testWidgets(
        '${entry.key.name} tag with an icon starts ${entry.value}px in and '
        'gaps the label by 4px',
        (tester) async {
          await pumpCarbon(
            tester,
            tag(
              size: entry.key,
              icon: const SizedBox(key: Key('icon'), width: 16, height: 16),
            ),
          );
          final pill = tester.getRect(pillFinder());
          final icon = tester.getRect(find.byKey(const Key('icon')));
          final label = tester.getRect(find.text('Backend'));
          expect(icon.left - pill.left, entry.value);
          expect(label.left - icon.right, 4);
        },
      );
    }

    testWidgets('a tag is at least 32px wide', (tester) async {
      await pumpCarbon(tester, tag(label: 'x'));
      expect(tester.getSize(find.byKey(const Key('tag'))).width, 32);
    });

    testWidgets('a tag is at most 208px wide', (tester) async {
      await pumpCarbon(tester, tag(label: 'W' * 80));
      expect(tester.getSize(find.byKey(const Key('tag'))).width, 208);
    });

    testWidgets('disabled read-only and dismissible tags have no outline', (
      tester,
    ) async {
      await pumpCarbon(tester, tag(disabled: true));
      expect(_decoration(tester, pillFinder()).border, isNull);
      await pumpCarbon(tester, tag(disabled: true, onDismissed: () {}));
      expect(_decoration(tester, pillFinder()).border, isNull);
    });

    testWidgets('a disabled selectable tag keeps the disabled outline', (
      tester,
    ) async {
      await pumpCarbon(tester, tag(selected: false, disabled: true));
      expect(
        (_decoration(tester, pillFinder()).border! as Border).top.color,
        _theme.colors.borderDisabled,
      );
    });
  });
}
