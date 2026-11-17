import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show MaterialApp, Scaffold, Scrollbar, ThemeData;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/host_theme.dart';

Widget _app(
  Widget child, {
  CarbonThemeScheme scheme = CarbonThemeScheme.white,
  ThemeData? host,
  double width = 500,
}) => MaterialApp(
  theme: host ?? hostileHostTheme,
  home: Scaffold(
    body: CarbonTheme(
      data: CarbonThemeData(scheme: scheme),
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

Future<TestGesture> _mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(location: const Offset(900, 900));
  return gesture;
}

int _visibleRings(WidgetTester tester) => tester
    .widgetList<CarbonFocusRing>(find.byType(CarbonFocusRing))
    .where((r) => r.visible)
    .length;

// Every solid fill painted by a DecoratedBox or ColoredBox under [of].
List<Color> _fills(WidgetTester tester, Finder of) => <Color>[
  for (final w in tester.widgetList<DecoratedBox>(
    find.descendant(of: of, matching: find.byType(DecoratedBox)),
  ))
    if (w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color != null)
      (w.decoration as BoxDecoration).color!,
  for (final w in tester.widgetList<ColoredBox>(
    find.descendant(of: of, matching: find.byType(ColoredBox)),
  ))
    w.color,
];

Color? _textColor(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).style?.color;

const List<CarbonThemeScheme> _schemes = <CarbonThemeScheme>[
  CarbonThemeScheme.white,
  CarbonThemeScheme.gray100,
];

void main() {
  group('interaction core', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      testWidgets('keyboard ring shows after a mouse connects on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await tester.pumpWidget(
            _app(
              CarbonTabs<String>(
                tabs: const <CarbonOption<String>>[
                  CarbonOption(value: 'a', label: 'Alpha'),
                  CarbonOption(value: 'b', label: 'Beta'),
                ],
                value: 'a',
                onChanged: (_) {},
              ),
            ),
          );
          await _mouse(tester);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(
            FocusManager.instance.highlightMode,
            FocusHighlightMode.traditional,
          );
          expect(_visibleRings(tester), 1);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('a control enabled under a resting pointer is hovered', (
      tester,
    ) async {
      final enabled = ValueNotifier<bool>(false);
      addTearDown(enabled.dispose);
      final seen = <CarbonInteractionState>[];
      final hovers = <bool>[];
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, on, _) => CarbonInteraction(
              onPressed: on ? () {} : null,
              onHoverChange: hovers.add,
              builder: (context, state, _) {
                seen.add(state);
                return const SizedBox(width: 100, height: 40);
              },
            ),
          ),
        ),
      );
      final mouse = await _mouse(tester);
      await mouse.moveTo(const Offset(50, 20));
      await tester.pump();
      expect(seen.last.hovered, isFalse);

      enabled.value = true;
      await tester.pump();
      await tester.pump();
      expect(seen.last.hovered, isTrue);
      expect(hovers, <bool>[true]);

      enabled.value = false;
      await tester.pump();
      await tester.pump();
      expect(seen.last.hovered, isFalse);
      expect(hovers, <bool>[true, false]);

      enabled.value = true;
      await tester.pump();
      await tester.pump();
      expect(seen.last.hovered, isTrue);
    });
  });

  group('tabs', () {
    Widget tabs({CarbonTabsVariant variant = CarbonTabsVariant.line}) =>
        CarbonTabs<String>(
          variant: variant,
          tabs: const <CarbonOption<String>>[
            CarbonOption(value: 'a', label: 'Alpha'),
            CarbonOption(value: 'b', label: 'Beta'),
            CarbonOption(value: 'c', label: 'Gamma'),
            CarbonOption(value: 'd', label: 'Delta', enabled: false),
          ],
          value: 'a',
          onChanged: (_) {},
        );

    for (final variant in CarbonTabsVariant.values) {
      testWidgets('a pressed ${variant.name} tab shows the ring alone', (
        tester,
      ) async {
        await tester.pumpWidget(_app(tabs(variant: variant)));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(_visibleRings(tester), 1);

        final mouse = await _mouse(tester);
        await mouse.moveTo(tester.getCenter(find.text('Gamma')));
        await mouse.down(tester.getCenter(find.text('Gamma')));
        await tester.pump(const Duration(milliseconds: 150));
        bool visibleAbove(String label) => tester
            .widget<CarbonFocusRing>(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byType(CarbonFocusRing),
                  )
                  .first,
            )
            .visible;
        expect(visibleAbove('Gamma'), isTrue);
        expect(visibleAbove('Alpha'), isFalse);
        expect(_visibleRings(tester), 1);
        await mouse.up();
        await tester.pump();
      });
    }

    for (final scheme in _schemes) {
      testWidgets('disabled contained label keeps text-disabled on $scheme', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(tabs(variant: CarbonTabsVariant.contained), scheme: scheme),
        );
        expect(
          _textColor(tester, find.text('Delta')),
          scheme.colors.textDisabled,
        );
      });
    }
  });

  group('loading overlay', () {
    testWidgets('a press in flight does not activate under the scrim', (
      tester,
    ) async {
      final loading = ValueNotifier<bool>(false);
      addTearDown(loading.dispose);
      var taps = 0;
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: loading,
            builder: (context, on, _) => CarbonLoadingOverlay(
              loading: on,
              child: SizedBox(
                height: 200,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: CarbonButton(label: 'Go', onPressed: () => taps++),
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Go')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      loading.value = true;
      await tester.pump();
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(taps, 0);
    });
  });

  group('contained list row', () {
    Widget list({bool selected = false}) => CarbonContainedList(
      label: 'List',
      children: <Widget>[
        CarbonContainedListRow(
          title: 'Row one',
          selected: selected,
          onPressed: () {},
          actions: <Widget>[
            CarbonButton.iconOnly(
              key: const Key('act'),
              icon: const CarbonIcon(CarbonIcons.close),
              semanticLabel: 'Act',
              onPressed: () {},
            ),
          ],
        ),
      ],
    );

    for (final scheme in _schemes) {
      testWidgets('hovering the action leaves the content at rest on $scheme', (
        tester,
      ) async {
        await tester.pumpWidget(_app(list(), scheme: scheme));
        final hover = scheme.colors.layerHover01;
        final row = find.byType(CarbonContainedListRow);
        final mouse = await _mouse(tester);
        await mouse.moveTo(tester.getCenter(find.byKey(const Key('act'))));
        await tester.pump();
        expect(_fills(tester, row), isNot(contains(hover)));

        await mouse.moveTo(tester.getCenter(find.text('Row one')));
        await tester.pump();
        expect(_fills(tester, row), contains(hover));
        final filled = tester
            .widgetList<ColoredBox>(
              find.descendant(of: row, matching: find.byType(ColoredBox)),
            )
            .firstWhere((b) => b.color == hover);
        final rect = tester.getRect(find.byWidget(filled));
        expect(
          rect.right,
          lessThanOrEqualTo(tester.getRect(find.byKey(const Key('act'))).left),
        );
      });
    }

    testWidgets('the selection bar paints above the pressed fill', (
      tester,
    ) async {
      await tester.pumpWidget(_app(list(selected: true)));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Row one')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      final bar = find.descendant(
        of: find.byType(CarbonContainedListRow),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.position == DecorationPosition.foreground &&
              (w.decoration as BoxDecoration).border != null,
        ),
      );
      expect(bar, findsOneWidget);
      final pressed = CarbonThemeScheme.white.colors.layerActive01;
      expect(
        _fills(tester, find.byType(CarbonContainedListRow)),
        contains(pressed),
      );
      final border =
          (tester.widget<DecoratedBox>(bar).decoration as BoxDecoration).border!
              as BorderDirectional;
      expect(
        border.start.color,
        CarbonThemeScheme.white.colors.borderInteractive,
      );
      // The pressed fill is a descendant of the bar's box, and the bar paints
      // in the foreground, so it is above that fill.
      expect(
        find.descendant(
          of: bar,
          matching: find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == pressed,
          ),
        ),
        findsOneWidget,
      );
      await gesture.up();
    });
  });

  group('notification', () {
    Widget note({required bool high}) => CarbonNotification(
      kind: CarbonNotificationKind.info,
      title: 'Saved',
      highContrast: high,
      onClose: () {},
      action: CarbonNotificationAction(label: 'Undo', onPressed: () {}),
    );

    Finder undo() => find.ancestor(
      of: find.text('Undo'),
      matching: find.byType(CarbonButton),
    );

    for (final scheme in _schemes) {
      final c = scheme.colors;
      testWidgets(
        'low contrast action hovers and presses with '
        'notification-action-hover on $scheme',
        (tester) async {
          await tester.pumpWidget(_app(note(high: false), scheme: scheme));
          final mouse = await _mouse(tester);
          final at = tester.getCenter(find.text('Undo'));
          await mouse.moveTo(at);
          await tester.pump();
          expect(_fills(tester, undo()), contains(c.notificationActionHover));
          await mouse.down(at);
          await tester.pump();
          expect(_fills(tester, undo()), contains(c.notificationActionHover));
          await mouse.up();
        },
      );

      testWidgets(
        'high contrast action hovers and presses with '
        'background-inverse-hover and keeps link-inverse on $scheme',
        (tester) async {
          await tester.pumpWidget(_app(note(high: true), scheme: scheme));
          final mouse = await _mouse(tester);
          final at = tester.getCenter(find.text('Undo'));
          await mouse.moveTo(at);
          await tester.pump();
          expect(_fills(tester, undo()), contains(c.backgroundInverseHover));
          expect(_textColor(tester, find.text('Undo')), c.linkInverse);
          await mouse.down(at);
          await tester.pump();
          expect(_fills(tester, undo()), contains(c.backgroundInverseHover));
          expect(_textColor(tester, find.text('Undo')), c.linkInverse);
          await mouse.up();
        },
      );

      testWidgets('high contrast close icon is icon-inverse on $scheme', (
        tester,
      ) async {
        await tester.pumpWidget(_app(note(high: true), scheme: scheme));
        final close = find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel != null,
        );
        final icon = tester.widget<IconTheme>(
          find.descendant(of: close, matching: find.byType(IconTheme)).first,
        );
        expect(icon.data.color, c.iconInverse);
      });
    }
  });

  group('modal', () {
    Widget modal({int lines = 80}) => SizedBox(
      height: 400,
      child: CarbonModal(
        title: 'Title',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[for (var i = 0; i < lines; i++) Text('Line $i')],
        ),
      ),
    );

    for (final scheme in _schemes) {
      testWidgets('close button hovers with layer-hover on $scheme', (
        tester,
      ) async {
        await tester.pumpWidget(_app(modal(lines: 3), scheme: scheme));
        final close = find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel != null,
        );
        final mouse = await _mouse(tester);
        await mouse.moveTo(tester.getCenter(close));
        await tester.pump();
        expect(_fills(tester, close), contains(scheme.colors.layerHover01));
      });
    }

    testWidgets('the body draws no host scrollbar', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        // The host theme's platform decides whether Material builds a
        // scrollbar, and it is fixed when the ThemeData is constructed.
        await tester.pumpWidget(
          _app(
            modal(),
            host: hostileHostTheme.copyWith(platform: TargetPlatform.windows),
          ),
        );
        expect(
          find.descendant(
            of: find.byType(Scaffold),
            matching: find.byType(SingleChildScrollView),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(CarbonModal),
            matching: find.byType(Scrollbar),
          ),
          findsNothing,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
