import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/new_session/context_picker.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

const _entries = <CarbonMenuEntry>[
  CarbonMenuItem(label: 'Alpha'),
  CarbonMenuItem(label: 'Beta'),
];

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  CarbonDensity density = CarbonDensity.compact,
  Size size = const Size(800, 600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(
        body: AbCarbonScope(density: density, child: child),
      ),
    ),
  );
}

ContextPicker _picker({
  String label = 'Local',
  CarbonIcons? icon = CarbonIcons.screen,
  bool shedToIcon = true,
}) => ContextPicker(
  icon: icon,
  label: label,
  field: 'Environment',
  entries: _entries,
  shedToIcon: shedToIcon,
);

Widget _slot(double width, Widget child) => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(width: width, child: child),
);

CarbonThemeData _theme(WidgetTester tester) =>
    CarbonTheme.of(tester.element(find.byType(ContextPicker)));

void main() {
  for (final density in CarbonDensity.values) {
    group('${density.name} density', () {
      Future<double> measuredChrome(WidgetTester tester) async {
        // An empty label leaves exactly the trigger's chrome and glyphs.
        await _mount(
          tester,
          Align(alignment: Alignment.topLeft, child: _picker(label: '')),
          density: density,
        );
        return tester.getSize(find.byType(CarbonMenuButton)).width;
      }

      testWidgets('the full floor is the rendered chrome plus a label stub', (
        tester,
      ) async {
        final chrome = await measuredChrome(tester);
        expect(
          contextPickerFullMinWidth(_theme(tester)),
          closeTo(chrome + CarbonSpacing.spacing08, 0.5),
        );
      });

      testWidgets('the trigger is one control tall at the floor', (
        tester,
      ) async {
        await _mount(tester, _slot(400, _picker()), density: density);
        final t = _theme(tester);
        expect(
          tester.getSize(find.byType(CarbonMenuButton)).height,
          t.controlHeight,
        );
      });

      testWidgets('keeps the labelled trigger at the floor', (tester) async {
        await _mount(tester, _slot(400, _picker()), density: density);
        final floor = contextPickerFullMinWidth(_theme(tester));
        await _mount(tester, _slot(floor, _picker()), density: density);
        expect(find.byType(CarbonMenuButton), findsOneWidget);
        expect(find.byType(CarbonOverflowMenu), findsNothing);
        expect(
          tester.getSize(find.byType(CarbonMenuButton)).width,
          lessThanOrEqualTo(floor + 0.5),
        );
      });

      testWidgets('sheds to a glyph-only trigger below the floor', (
        tester,
      ) async {
        await _mount(tester, _slot(400, _picker()), density: density);
        final t = _theme(tester);
        await _mount(
          tester,
          _slot(contextPickerFullMinWidth(t) - 1, _picker()),
          density: density,
        );
        expect(find.byType(CarbonMenuButton), findsNothing);
        final size = tester.getSize(find.byType(CarbonOverflowMenu));
        expect(size.width, contextPickerGlyphWidth(t));
        expect(size.height, t.minTarget);
        expect(find.text('Local'), findsNothing);
      });

      testWidgets('a picker without a glyph never sheds', (tester) async {
        await _mount(
          tester,
          _slot(CarbonSpacing.spacing09, _picker(icon: null)),
          density: density,
        );
        expect(find.byType(CarbonMenuButton), findsOneWidget);
        expect(find.byType(CarbonOverflowMenu), findsNothing);
      });

      testWidgets('shedToIcon false keeps the labelled trigger', (
        tester,
      ) async {
        await _mount(
          tester,
          _slot(CarbonSpacing.spacing09, _picker(shedToIcon: false)),
          density: density,
        );
        expect(find.byType(CarbonMenuButton), findsOneWidget);
      });

      testWidgets('scales down under one target and vanishes at zero', (
        tester,
      ) async {
        await _mount(tester, _slot(400, _picker()), density: density);
        final t = _theme(tester);
        await _mount(
          tester,
          _slot(t.minTarget / 2, _picker()),
          density: density,
        );
        expect(find.byType(FittedBox), findsWidgets);
        expect(
          // Scaled by the FittedBox, so measure the painted rect, not layout size.
          tester.getRect(find.byType(CarbonOverflowMenu)).width,
          lessThanOrEqualTo(t.minTarget / 2 + 0.5),
        );
        expect(tester.takeException(), isNull);

        await _mount(tester, _slot(0, _picker()), density: density);
        expect(find.byType(CarbonMenuButton), findsNothing);
        expect(find.byType(CarbonOverflowMenu), findsNothing);
      });

      testWidgets('caps a long label when the slot is unbounded', (
        tester,
      ) async {
        final chrome = await measuredChrome(tester);
        await _mount(
          tester,
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _picker(label: 'A very long machine name ' * 8),
          ),
          density: density,
        );
        expect(
          tester.getSize(find.byType(CarbonMenuButton)).width,
          closeTo(chrome + CarbonSpacing.spacing13, 0.5),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('is named by field and value in both forms', (tester) async {
        final handle = tester.ensureSemantics();
        await _mount(tester, _slot(400, _picker()), density: density);
        expect(find.bySemanticsLabel('Environment: Local'), findsOneWidget);

        final floor = contextPickerFullMinWidth(_theme(tester));
        await _mount(tester, _slot(floor - 1, _picker()), density: density);
        expect(find.bySemanticsLabel('Environment: Local'), findsOneWidget);
        handle.dispose();
      });
    });
  }

  testWidgets('opens above the trigger when there is room', (tester) async {
    await _mount(
      tester,
      Align(alignment: Alignment.bottomLeft, child: _picker()),
    );
    final trigger = tester.getRect(find.byType(CarbonMenuButton));
    await tester.tap(find.byType(CarbonMenuButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Alpha'), findsOneWidget);
    expect(tester.getRect(find.text('Alpha')).bottom, lessThan(trigger.top));
  });

  testWidgets('the shed glyph trigger also opens above', (tester) async {
    await _mount(
      tester,
      Align(
        alignment: Alignment.bottomLeft,
        child: SizedBox(width: 60, child: _picker()),
      ),
    );
    final trigger = tester.getRect(find.byType(CarbonOverflowMenu));
    await tester.tap(find.byType(CarbonOverflowMenu));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Alpha'), findsOneWidget);
    expect(tester.getRect(find.text('Alpha')).bottom, lessThan(trigger.top));
  });

  testWidgets('reports opening and closing', (tester) async {
    final events = <bool>[];
    await _mount(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: ContextPicker(
          icon: CarbonIcons.screen,
          label: 'Local',
          field: 'Environment',
          entries: _entries,
          onOpenChanged: events.add,
        ),
      ),
    );
    await tester.tap(find.byType(CarbonMenuButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(events, [true]);
  });

  testWidgets('draws no Ab widget', (tester) async {
    await _mount(tester, _slot(400, _picker()));
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('the labelled trigger is a neutral ghost menu button', (
    tester,
  ) async {
    await _mount(tester, _slot(400, _picker()));
    final menu = tester.widget<CarbonMenuButton>(find.byType(CarbonMenuButton));
    expect(menu.kind, CarbonButtonKind.ghost);
    expect(menu.neutral, isTrue);
  });

  testWidgets('a mark leads the label of a picker with no glyph', (
    tester,
  ) async {
    const mark = SizedBox.square(key: Key('mark'), dimension: 16);
    await _mount(
      tester,
      _slot(
        400,
        const ContextPicker(
          label: 'Claude Code',
          field: 'Agent',
          mark: mark,
          entries: _entries,
        ),
      ),
    );
    expect(find.byKey(const Key('mark')), findsOneWidget);
    expect(tester.widget<CarbonMenuButton>(find.byType(CarbonMenuButton)).leading,
        same(mark));
  });

  testWidgets('a mark is dropped, not scaled, between the two floors', (
    tester,
  ) async {
    const mark = SizedBox.square(key: Key('mark'), dimension: 16);
    ContextPicker picker() => const ContextPicker(
      label: 'Claude Code',
      field: 'Agent',
      mark: mark,
      entries: _entries,
    );
    await _mount(tester, _slot(400, picker()));
    final t = _theme(tester);
    final withMark = contextPickerFullMinWidth(t);
    final without = withMark - t.iconSize - CarbonSpacing.spacing03;

    await _mount(tester, _slot((withMark + without) / 2, picker()));
    expect(find.byKey(const Key('mark')), findsNothing);
    expect(
      tester.widget<CarbonMenuButton>(find.byType(CarbonMenuButton)).leading,
      isNull,
    );
    expect(find.byType(FittedBox), findsNothing);

    await _mount(tester, _slot(withMark, picker()));
    expect(find.byKey(const Key('mark')), findsOneWidget);
  });
}
