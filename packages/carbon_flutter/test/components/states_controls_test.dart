import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/host_theme.dart';

const Key _k = Key('target');

Widget _tl(Widget child) =>
    Align(alignment: AlignmentDirectional.topStart, child: child);

void _traditional() {
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  addTearDown(
    () => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic,
  );
}

Future<TestGesture> _mouse(WidgetTester tester, Offset at) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: const Offset(790, 590));
  addTearDown(g.removePointer);
  await g.moveTo(at);
  await tester.pump();
  return g;
}

Color? _fill(WidgetTester tester, Finder within) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: within, matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).color;
}

bool _strokes(List<dynamic> args, Color c) => args.any(
  (a) =>
      a is Paint &&
      a.color.toARGB32() == c.toARGB32() &&
      a.style == PaintingStyle.stroke,
);

RenderObject _ringPaint(WidgetTester tester, Finder within) =>
    tester.renderObject(
      find
          .descendant(
            of: find.descendant(
              of: within,
              matching: find.byType(CarbonFocusRing),
            ),
            matching: find.byType(CustomPaint),
          )
          .first,
    );

PaintPattern _paintsStroke(Color c) =>
    paints..something((Symbol m, List<dynamic> a) => _strokes(a, c));

void main() {
  group('CTL-1 focus ring follows the live highlight mode', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('a mouse connecting before focus still shows the ring on '
          '$platform', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final node = FocusNode();
          addTearDown(node.dispose);
          await pumpCarbon(
            tester,
            _tl(
              CarbonButton(
                key: _k,
                label: 'Go',
                focusNode: node,
                onPressed: () {},
              ),
            ),
          );
          await _mouse(tester, const Offset(700, 500));
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(node.hasFocus, isTrue);
          expect(
            FocusManager.instance.highlightMode,
            FocusHighlightMode.traditional,
          );
          expect(
            tester
                .widget<CarbonFocusRing>(find.byType(CarbonFocusRing))
                .visible,
            isTrue,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  group('CTL-2/3 outlined buttons keep focus over hover and press', () {
    for (final kind in [
      CarbonButtonKind.tertiary,
      CarbonButtonKind.dangerTertiary,
    ]) {
      for (final scheme in [
        CarbonThemeScheme.white,
        CarbonThemeScheme.gray100,
      ]) {
        testWidgets('$kind on $scheme', (tester) async {
          _traditional();
          final theme = CarbonThemeData(scheme: scheme);
          final c = theme.colors;
          final node = FocusNode();
          addTearDown(node.dispose);
          await pumpCarbon(
            tester,
            _tl(
              CarbonButton(
                key: _k,
                label: 'Go',
                kind: kind,
                focusNode: node,
                onPressed: () {},
              ),
            ),
            theme: theme,
          );
          node.requestFocus();
          await tester.pump();
          final focusFill = kind == CarbonButtonKind.tertiary
              ? c.buttonTertiary
              : c.buttonDangerPrimary;
          expect(_fill(tester, find.byKey(_k)), focusFill);
          expect(_ringPaint(tester, find.byKey(_k)), _paintsStroke(c.focusInset));

          final g = await _mouse(tester, tester.getCenter(find.byKey(_k)));
          expect(
            _fill(tester, find.byKey(_k)),
            focusFill,
            reason: 'focus+hover',
          );
          expect(
            _ringPaint(tester, find.byKey(_k)),
            _paintsStroke(c.focusInset),
            reason: 'inner ring kept on hover',
          );

          await g.down(tester.getCenter(find.byKey(_k)));
          await tester.pump();
          expect(
            _ringPaint(tester, find.byKey(_k)),
            _paintsStroke(c.focusInset),
            reason: 'inner ring kept on press',
          );
          await g.up();
        });
      }
    }
  });

  group('CTL-4 button set separators', () {
    Widget set(FocusNode node, {bool saveEnabled = true}) => _tl(
      SizedBox(
        width: 600,
        child: CarbonButtonSet(
          children: [
            CarbonButton(
              label: 'Cancel',
              kind: CarbonButtonKind.secondary,
              focusNode: node,
              onPressed: () {},
            ),
            CarbonButton(label: 'Save', onPressed: saveEnabled ? () {} : null),
          ],
        ),
      ),
    );

    testWidgets('a focused button drops the rule beside it', (tester) async {
      _traditional();
      final c = CarbonThemeData().colors;
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(tester, set(node));
      final box = find.byType(CarbonButtonSet);
      expect(tester.renderObject(box), paints..rect(color: c.buttonSeparator));
      node.requestFocus();
      await tester.pump();
      expect(
        tester.renderObject(box),
        isNot(paints..rect(color: c.buttonSeparator)),
      );
      node.unfocus();
      await tester.pump();
      await tester.pump();
      expect(tester.renderObject(box), paints..rect(color: c.buttonSeparator));
    });

    testWidgets('the rule before a disabled button uses the disabled colour', (
      tester,
    ) async {
      final c = CarbonThemeData().colors;
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(tester, set(node, saveEnabled: false));
      final box = tester.renderObject(find.byType(CarbonButtonSet));
      expect(box, paints..rect(color: c.iconOnColorDisabled));
      expect(box, isNot(paints..rect(color: c.buttonSeparator)));
    });
  });

  group('CTL-5 tag hover keeps the border', () {
    for (final selectable in [true, false]) {
      testWidgets(selectable ? 'selectable' : 'operational', (tester) async {
        await pumpCarbon(
          tester,
          _tl(
            selectable
                ? CarbonTag(
                    key: _k,
                    label: 'Agent run',
                    selected: false,
                    onSelectedChanged: (_) {},
                  )
                : CarbonTag(
                    key: _k,
                    label: 'Agent run',
                    color: CarbonTagColor.red,
                    onPressed: () {},
                  ),
          ),
        );
        await _mouse(tester, tester.getCenter(find.byKey(_k)));
        final hovers = find
            .descendant(of: find.byKey(_k), matching: find.byType(DecoratedBox))
            .evaluate()
            .map((e) => (e.widget as DecoratedBox).decoration)
            .whereType<BoxDecoration>()
            .where(
              (d) => d.borderRadius != null && (d.color?.a ?? 0) != 0,
            )
            .toList();
        // The pill fill and the hover fill; every one that fills must also
        // carry the border or the hover fill hides it.
        expect(hovers, isNotEmpty);
        expect(hovers.last.border, isNotNull);
      });
    }
  });

  testWidgets('CTL-6 read-only toggle keeps an unsquashed handle', (
    tester,
  ) async {
    for (final small in [false, true]) {
      await pumpCarbon(
        tester,
        _tl(
          CarbonToggle(
            key: _k,
            value: true,
            readOnly: true,
            small: small,
            hideStateText: true,
            semanticLabel: 'Sync',
            onChanged: (_) {},
          ),
        ),
      );
      final handle = tester.getRect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              (w.decoration as BoxDecoration?)?.shape == BoxShape.circle,
        ),
      );
      final d = small ? 10.0 : 18.0;
      expect(handle.size, Size(d, d), reason: 'small=$small');
      final track = tester.getRect(find.byType(AnimatedContainer));
      expect(handle.top - track.top, 3, reason: 'small=$small');
    }
  });

  group('CTL-7 checkbox ignores invalid when disabled or read-only', () {
    testWidgets('checkbox shows helper text', (tester) async {
      for (final readOnly in [true, false]) {
        await pumpCarbon(
          tester,
          _tl(
            CarbonCheckbox(
              value: true,
              labelText: 'Accept',
              helperText: 'Helper',
              errorText: 'Required',
              readOnly: readOnly,
              onChanged: readOnly ? (_) {} : null,
            ),
          ),
        );
        expect(
          find.text('Required'),
          findsNothing,
          reason: 'readOnly=$readOnly',
        );
        expect(find.text('Helper'), findsOneWidget);
      }
    });

    testWidgets('group shows helper text', (tester) async {
      for (final readOnly in [true, false]) {
        await pumpCarbon(
          tester,
          _tl(
            CarbonCheckboxGroup<String>(
              legend: 'Group',
              items: const [CarbonCheckboxItem(value: 'a', label: 'A')],
              selected: const {},
              helperText: 'Helper',
              errorText: 'Required',
              readOnly: readOnly,
              onChanged: readOnly ? (_) {} : null,
            ),
          ),
        );
        expect(
          find.text('Required'),
          findsNothing,
          reason: 'readOnly=$readOnly',
        );
        expect(find.text('Helper'), findsOneWidget);
      }
    });

    testWidgets('an enabled checkbox still shows its error', (tester) async {
      await pumpCarbon(
        tester,
        _tl(
          CarbonCheckbox(
            value: true,
            labelText: 'Accept',
            helperText: 'Helper',
            errorText: 'Required',
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('Helper'), findsNothing);
    });
  });

  testWidgets('CTL-8 a control enabled under a resting pointer is hovered', (
    tester,
  ) async {
    final c = CarbonThemeData().colors;
    Widget button(bool enabled) => _tl(
      CarbonButton(key: _k, label: 'Go', onPressed: enabled ? () {} : null),
    );
    await pumpCarbon(tester, button(true));
    await _mouse(tester, tester.getCenter(find.byKey(_k)));
    expect(_fill(tester, find.byKey(_k)), c.buttonPrimaryHover);
    await pumpCarbon(tester, button(false));
    await tester.pump();
    await pumpCarbon(tester, button(true));
    await tester.pump();
    expect(_fill(tester, find.byKey(_k)), c.buttonPrimaryHover);
  });

  testWidgets('CTL-9 high-contrast tag close button focuses with the inverse '
      'colour', (tester) async {
    _traditional();
    final c = CarbonThemeData().colors;
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(
      tester,
      _tl(
        CarbonTag(
          key: _k,
          label: 'Agent',
          color: CarbonTagColor.highContrast,
          onDismissed: () {},
          dismissFocusNode: node,
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    final ring = _ringPaint(tester, find.byKey(_k));
    expect(ring, _paintsStroke(c.focusInverse));
    expect(ring, isNot(_paintsStroke(c.focus)));
  });

  testWidgets('controls paint no host colour under a hostile host', (
    tester,
  ) async {
    _traditional();
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(
      tester,
      underHostileHost(
        _tl(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CarbonButton(
                key: _k,
                label: 'Go',
                kind: CarbonButtonKind.tertiary,
                focusNode: node,
                onPressed: () {},
              ),
              CarbonToggle(
                value: true,
                readOnly: true,
                semanticLabel: 'S',
                onChanged: (_) {},
              ),
              CarbonTag(
                label: 'T',
                color: CarbonTagColor.highContrast,
                onDismissed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await _mouse(tester, tester.getCenter(find.byKey(_k)));
    expect(
      tester.renderObject(find.byType(Column).first),
      isNot(paints..something(paintsHostColor)),
    );
  });
}
