import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show
        AdaptiveTextSelectionToolbar,
        Material,
        MaterialApp,
        Scaffold,
        Scrollbar;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/host_theme.dart';

Widget _host(Widget child, {double width = 320}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

// A MaterialApp, which supplies the Cupertino strings the iOS toolbar needs.
Widget _hostileApp(Widget child, {CarbonThemeData? theme}) => MaterialApp(
  theme: hostileHostTheme,
  home: Scaffold(
    body: CarbonTheme(data: theme ?? _theme, child: _host(child)),
  ),
);

Finder get _editable => find.byType(EditableText);

CarbonThemeData get _theme => CarbonThemeData();

Future<TestGesture> _mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  return gesture;
}

Color _boxFill(WidgetTester tester) {
  final box = find
      .descendant(
        of: find.byType(CarbonFieldBox),
        matching: find.byType(DecoratedBox),
      )
      .first;
  return ((tester.widget<DecoratedBox>(box)).decoration as BoxDecoration)
      .color!;
}

void main() {
  group('selection handles are Carbon colours', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      for (final search in <bool>[false, true]) {
        testWidgets('${search ? 'search' : 'text input'} on $platform', (
          tester,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            final controller = TextEditingController(text: 'hello world');
            addTearDown(controller.dispose);
            await tester.pumpWidget(
              _hostileApp(
                search
                    ? CarbonSearch(controller: controller)
                    : CarbonTextInput(controller: controller, label: 'L'),
              ),
            );
            await tester.longPressAt(
              tester.getTopLeft(_editable) + const Offset(10, 8),
            );
            await tester.pumpAndSettle();
            final handles = find.byWidgetPredicate(
              (w) =>
                  w is CustomPaint &&
                  w.painter.runtimeType.toString().contains('Handle'),
            );
            expect(handles, findsWidgets);
            for (final e in handles.evaluate()) {
              final painter = (e.widget as CustomPaint).painter! as dynamic;
              expect(
                painter.color,
                _theme.colors.textPrimary,
                reason: 'handle painted in a host colour',
              );
            }
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }
  });

  testWidgets('a multi-line text area shows no host scrollbar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final controller = TextEditingController(
        text: List.generate(12, (i) => 'line $i').join('\n'),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: hostileHostTheme,
          home: Scaffold(
            body: CarbonTheme(
              data: _theme,
              child: _host(
                CarbonTextInput(
                  label: 'L',
                  controller: controller,
                  variant: CarbonTextInputVariant.multiline,
                  maxLines: 4,
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(CarbonTextInput),
          matching: find.byType(Scrollbar),
        ),
        findsNothing,
      );
      final painters = <ScrollbarPainter>[];
      void visit(RenderObject r) {
        if (r is RenderCustomPaint && r.foregroundPainter is ScrollbarPainter) {
          painters.add(r.foregroundPainter! as ScrollbarPainter);
        }
        r.visitChildren(visit);
      }

      visit(tester.renderObject(find.byType(CarbonTextInput)));
      expect(painters, isNotEmpty, reason: 'the platform scrollbar remains');
      for (final p in painters) {
        expect(hostColors, isNot(contains(p.color)));
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final search in <bool>[false, true]) {
    testWidgets(
      '${search ? 'search' : 'text input'} selection toolbar is not themed by '
      'the host',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final controller = TextEditingController(text: 'hello world');
          addTearDown(controller.dispose);
          // Gray 100, not the default White: the toolbar is built in the
          // root overlay, above this CarbonTheme, and a lookup there would
          // find the White fallback.
          final g100 = CarbonThemeData.forBrightness(Brightness.dark);
          await tester.pumpWidget(
            _hostileApp(
              search
                  ? CarbonSearch(controller: controller)
                  : CarbonTextInput(controller: controller, label: 'L'),
              theme: g100,
            ),
          );
          await tester.longPressAt(
            tester.getTopLeft(_editable) + const Offset(10, 8),
          );
          await tester.pumpAndSettle();
          final toolbar = find.byType(AdaptiveTextSelectionToolbar);
          expect(toolbar, findsOneWidget);
          final colors = tester
              .widgetList<Material>(
                find.descendant(of: toolbar, matching: find.byType(Material)),
              )
              .map((m) => m.color)
              .whereType<Color>();
          expect(colors, contains(g100.colors.layer01));
          expect(hostColors.intersection(colors.toSet()), isEmpty);
          final labels = tester.renderObjectList<RenderParagraph>(
            find.descendant(of: toolbar, matching: find.byType(RichText)),
          );
          expect(labels, isNotEmpty);
          for (final p in labels) {
            final style = p.text.style!;
            expect(style.color, g100.colors.textPrimary);
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets('enabling a box under a resting pointer shows its hover fill', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _host(const CarbonFieldBox(enabled: false, child: Text('x'))),
    );
    final mouse = await _mouse(tester);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(CarbonFieldBox)),
    );
    await tester.pump();
    await pumpCarbon(
      tester,
      _host(const CarbonFieldBox(enabled: true, child: Text('x'))),
    );
    await tester.pump();
    await mouse.moveBy(const Offset(2, 0));
    await tester.pump();
    expect(_boxFill(tester), _theme.fieldHover(1));
  });

  testWidgets('a warning leaves the action hover fill uninset like rest', (
    tester,
  ) async {
    Future<List<double>> insets(String? warn) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            label: 'L',
            controller: TextEditingController(text: 'abc'),
            warnText: warn,
            clearable: true,
          ),
        ),
      );
      final mouse = await _mouse(tester);
      await mouse.addPointer(
        location: tester.getCenter(find.byType(CarbonFieldAction)),
      );
      await tester.pump();
      final fill = tester.getRect(
        find
            .descendant(
              of: find.byType(CarbonFieldAction),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      final box = tester.getRect(find.byType(CarbonFieldBox));
      await mouse.removePointer();
      return <double>[
        fill.top - box.top,
        box.bottom - fill.bottom,
        box.right - fill.right,
      ];
    }

    final rest = await insets(null);
    final warn = await insets('W');
    expect(warn, rest);
  });

  for (final search in <bool>[false, true]) {
    testWidgets(
      'a disabled ${search ? 'search' : 'text input'} shows not-allowed over '
      'its text',
      (tester) async {
        await pumpCarbon(
          tester,
          _host(
            search
                ? const CarbonSearch(enabled: false)
                : const CarbonTextInput(label: 'Dis', enabled: false),
          ),
        );
        final mouse = await _mouse(tester);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(_editable));
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.forbidden,
        );
      },
    );
  }
}
