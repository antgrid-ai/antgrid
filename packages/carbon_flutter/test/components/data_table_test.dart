import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _columns = <CarbonDataTableColumn>[
  CarbonDataTableColumn(label: 'Name'),
  CarbonDataTableColumn(label: 'Runs', align: CarbonDataTableAlign.end),
];

List<CarbonDataTableRow> _rows([
  List<String> names = const ['alpha', 'beta'],
]) => [
  for (final name in names)
    CarbonDataTableRow(cells: [Text(name), Text('${name.length}')]),
];

Widget _table({
  List<CarbonDataTableColumn> columns = _columns,
  List<CarbonDataTableRow>? rows,
  CarbonDataTableSize size = CarbonDataTableSize.large,
  String? title,
  String? description,
  Widget? emptyState,
  double width = 400,
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(
    width: width,
    child: CarbonDataTable(
      columns: columns,
      rows: rows ?? _rows(),
      size: size,
      title: title,
      description: description,
      emptyState: emptyState,
    ),
  ),
);

Finder _row(String cell) => find
    .ancestor(of: find.text(cell), matching: find.byType(MouseRegion))
    .first;

bool _isFilledHeader(Widget w) =>
    w is DecoratedBox &&
    (w.decoration as BoxDecoration).color != null &&
    (w.decoration as BoxDecoration).border == null;

Finder _headerRow(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(_isFilledHeader),
    )
    .first;

BoxDecoration _ruled(WidgetTester tester, String cell) =>
    tester
            .widget<DecoratedBox>(
              find
                  .ancestor(
                    of: find.text(cell),
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is DecoratedBox &&
                          (w.decoration as BoxDecoration).border != null,
                    ),
                  )
                  .first,
            )
            .decoration
        as BoxDecoration;

TextStyle _style(WidgetTester tester, String text) =>
    DefaultTextStyle.of(tester.element(find.text(text))).style;

Future<void> _hover(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  addTearDown(mouse.removePointer);
  await tester.pump();
}

void main() {
  final light = CarbonThemeData();

  testWidgets('header is layer-accent with heading-compact-01 text-primary', (
    tester,
  ) async {
    await pumpCarbon(tester, _table(), theme: light);
    final fill =
        (tester.widget<DecoratedBox>(_headerRow('Name')).decoration
                as BoxDecoration)
            .color;
    expect(fill, light.layerAccent(1));
    final style = _style(tester, 'Name');
    expect(style.color, light.colors.textPrimary);
    expect(style.fontWeight, FontWeight.w600);
    expect(style.fontSize, 14);
    expect(style.height! * style.fontSize!, closeTo(18, 0.01));
  });

  testWidgets('body text is body-compact-01 text-secondary', (tester) async {
    await pumpCarbon(tester, _table(), theme: light);
    final style = _style(tester, 'alpha');
    expect(style.color, light.colors.textSecondary);
    expect(style.fontSize, 14);
    expect(style.fontWeight, FontWeight.w400);
  });

  testWidgets('rows are as tall as their size and header matches', (
    tester,
  ) async {
    const heights = {
      CarbonDataTableSize.extraSmall: 24.0,
      CarbonDataTableSize.small: 32.0,
      CarbonDataTableSize.medium: 40.0,
      CarbonDataTableSize.large: 48.0,
      CarbonDataTableSize.extraLarge: 64.0,
    };
    for (final entry in heights.entries) {
      await pumpCarbon(tester, _table(size: entry.key), theme: light);
      expect(
        tester.getSize(_row('alpha')).height,
        entry.value,
        reason: '${entry.key}',
      );
      expect(tester.getSize(_headerRow('Name')).height, entry.value);
    }
  });

  testWidgets('touch density floors every row at touchTarget', (tester) async {
    for (final target in [44.0, 48.0]) {
      final touch = CarbonThemeData(
        density: CarbonDensity.touch,
        touchTarget: target,
      );
      for (final size in CarbonDataTableSize.values) {
        await pumpCarbon(tester, _table(size: size), theme: touch);
        final height = tester.getSize(_row('alpha')).height;
        expect(height, greaterThanOrEqualTo(target), reason: '$size');
        if (size == CarbonDataTableSize.extraSmall) {
          expect(height, target);
        }
      }
    }
  });

  testWidgets('a row rests on a border-subtle bottom rule and a layer top', (
    tester,
  ) async {
    await pumpCarbon(tester, _table(), theme: light);
    final decoration = _ruled(tester, 'alpha');
    final border = decoration.border! as Border;
    expect(decoration.color, light.layer(1));
    expect(border.bottom.color, light.borderSubtle(1));
    expect(border.bottom.width, 1);
    expect(border.top.color, light.layer(1));
  });

  testWidgets('hover fills with layer-hover and turns text primary', (
    tester,
  ) async {
    await pumpCarbon(tester, _table(), theme: light);
    await _hover(tester, tester.getCenter(find.text('alpha')));
    final decoration = _ruled(tester, 'alpha');
    final border = decoration.border! as Border;
    expect(decoration.color, light.layerHover(1));
    expect(border.top.color, light.layerHover(1));
    expect(border.bottom.color, light.layerHover(1));
    expect(_style(tester, 'alpha').color, light.colors.textPrimary);
    expect(
      _ruled(tester, 'beta').color,
      light.layer(1),
      reason: 'only the hovered row changes',
    );
    expect(_style(tester, 'beta').color, light.colors.textSecondary);
  });

  testWidgets('an end-aligned column hugs the trailing edge', (tester) async {
    await pumpCarbon(tester, _table(), theme: light);
    final table = tester.getRect(find.byType(CarbonDataTable));
    expect(
      tester.getRect(find.text('Runs')).right,
      closeTo(table.right - CarbonSpacing.spacing05, 0.01),
    );
    expect(
      tester.getRect(find.text('5')).right,
      closeTo(table.right - CarbonSpacing.spacing05, 0.01),
    );
    expect(
      tester.getRect(find.text('Name')).left,
      closeTo(table.left + CarbonSpacing.spacing05, 0.01),
    );
  });

  testWidgets('RTL mirrors start and end columns', (tester) async {
    await pumpCarbon(tester, _table(), theme: light, dir: TextDirection.rtl);
    final table = tester.getRect(find.byType(CarbonDataTable));
    expect(
      tester.getRect(find.text('Name')).right,
      closeTo(table.right - CarbonSpacing.spacing05, 0.01),
    );
    expect(
      tester.getRect(find.text('Runs')).left,
      closeTo(table.left + CarbonSpacing.spacing05, 0.01),
    );
    expect(
      tester.getRect(find.text('5')).left,
      closeTo(table.left + CarbonSpacing.spacing05, 0.01),
    );
  });

  testWidgets('header and body columns share their edges', (tester) async {
    const columns = [
      CarbonDataTableColumn(label: 'Fixed', width: 100),
      CarbonDataTableColumn(label: 'One'),
      CarbonDataTableColumn(label: 'Two', flex: 2),
    ];
    final rows = [
      const CarbonDataTableRow(cells: [Text('a'), Text('b'), Text('c')]),
    ];
    await pumpCarbon(
      tester,
      _table(columns: columns, rows: rows, width: 400),
      theme: light,
    );
    for (final pair in [('Fixed', 'a'), ('One', 'b'), ('Two', 'c')]) {
      expect(
        tester.getRect(find.text(pair.$1)).left,
        tester.getRect(find.text(pair.$2)).left,
        reason: pair.$1,
      );
    }
    final one = tester.getRect(find.text('One')).left;
    final two = tester.getRect(find.text('Two')).left;
    // 300 is left after the fixed column, split 1:2.
    expect(two - one, closeTo(100, 0.5));
    expect(one - tester.getRect(find.text('Fixed')).left, closeTo(100, 0.01));
  });

  testWidgets('a multi-line cell grows its row and keeps clear of the rules', (
    tester,
  ) async {
    const tallText = 'line one\nline two\nline three';
    final rows = [
      const CarbonDataTableRow(cells: [Text('one'), Text('1')]),
      const CarbonDataTableRow(cells: [Text(tallText), Text('3')]),
    ];
    await pumpCarbon(tester, _table(rows: rows), theme: light);
    final short = tester.getSize(_row('one')).height;
    final tall = tester.getSize(_row(tallText)).height;
    expect(short, 48);
    expect(tall, greaterThan(short));
    final rowRect = tester.getRect(_row(tallText));
    final textRect = tester.getRect(find.text(tallText));
    expect(textRect.top - rowRect.top, greaterThanOrEqualTo(12));
    expect(rowRect.bottom - textRect.bottom, greaterThanOrEqualTo(12));
    expect(
      tester.getCenter(find.text('3')).dy,
      closeTo(rowRect.center.dy, 0.5),
      reason: 'sibling cells stay vertically centred',
    );
  });

  testWidgets('title block uses heading-03 and a secondary description', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _table(title: 'Schedules', description: 'All of them'),
      theme: light,
    );
    final title = tester.widget<Text>(find.text('Schedules')).style!;
    expect(title.fontSize, 20);
    expect(title.height! * title.fontSize!, closeTo(28, 0.01));
    expect(title.color, light.colors.textPrimary);
    final description = tester.widget<Text>(find.text('All of them')).style!;
    expect(description.color, light.colors.textSecondary);
    expect(description.fontSize, 14);
    final block = tester.getRect(find.text('Schedules'));
    expect(block.left, CarbonSpacing.spacing05);
    expect(block.top, CarbonSpacing.spacing05);
    expect(
      tester.getRect(find.text('Name')).top,
      greaterThan(tester.getRect(find.text('All of them')).bottom),
    );
  });

  testWidgets('empty rows show the empty state below the header', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _table(rows: const [], emptyState: const Text('Nothing here')),
      theme: light,
    );
    expect(find.text('Nothing here'), findsOneWidget);
    expect(
      tester.getRect(find.text('Nothing here')).top,
      greaterThanOrEqualTo(tester.getRect(_headerRow('Name')).bottom),
    );
  });

  testWidgets('semantics expose header and body cells; empty header skipped', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      _table(
        columns: const [
          CarbonDataTableColumn(label: ''),
          CarbonDataTableColumn(label: 'Name'),
        ],
        rows: [
          const CarbonDataTableRow(cells: [Text('x'), Text('alpha')]),
        ],
      ),
      theme: light,
    );
    final headers = <SemanticsNode>[];
    void walk(SemanticsNode node) {
      if (node.getSemanticsData().role == SemanticsRole.columnHeader) {
        headers.add(node);
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
    expect(headers.map((n) => n.label), ['Name']);
    expect(find.bySemanticsLabel('alpha'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('320 wide at 2x text with four columns does not overflow', (
    tester,
  ) async {
    const columns = [
      CarbonDataTableColumn(label: 'Name'),
      CarbonDataTableColumn(label: 'Status'),
      CarbonDataTableColumn(label: 'Next run'),
      CarbonDataTableColumn(label: 'Runs', align: CarbonDataTableAlign.end),
    ];
    final rows = [
      const CarbonDataTableRow(
        cells: [
          Text('Nightly build'),
          Text('Active'),
          Text('Tomorrow'),
          Text('12'),
        ],
      ),
    ];
    for (final density in CarbonDensity.values) {
      await pumpCarbon(
        tester,
        _table(columns: columns, rows: rows, width: 320),
        theme: CarbonThemeData(density: density),
        textScale: 2,
        // Tall: the test font wraps a 2x word to a letter per line, and only
        // horizontal fit is under test.
        size: const Size(320, 2000),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(CarbonDataTable)).width, 320);
    }
  });

  group('selected rows', () {
    List<CarbonDataTableRow> rows() => [
      const CarbonDataTableRow(
        cells: [Text('alpha'), Text('5')],
        selected: true,
      ),
      const CarbonDataTableRow(cells: [Text('beta'), Text('4')]),
    ];

    testWidgets('fill layer-selected, hover layer-selected-hover', (
      tester,
    ) async {
      await pumpCarbon(tester, _table(rows: rows()), theme: light);
      var decoration = _ruled(tester, 'alpha');
      expect(decoration.color, light.layerSelected(1));
      expect((decoration.border! as Border).top.color, light.layerSelected(1));
      expect(_ruled(tester, 'beta').color, light.layer(1));
      await _hover(tester, tester.getCenter(find.text('alpha')));
      decoration = _ruled(tester, 'alpha');
      expect(decoration.color, light.layerSelectedHover(1));
      expect(
        (decoration.border! as Border).bottom.color,
        light.layerSelectedHover(1),
      );
      expect(_style(tester, 'alpha').color, light.colors.textPrimary);
    });

    testWidgets('only the selected row is marked selected', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _table(rows: rows()), theme: light);
      Finder rowSemantics(String cell) => find
          .ancestor(
            of: find.text(cell),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.role == SemanticsRole.row,
            ),
          )
          .first;
      expect(
        tester.getSemantics(rowSemantics('alpha')),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(rowSemantics('beta')),
        isNot(isSemantics(isSelected: true)),
      );
      handle.dispose();
    });
  });

  group('expansion', () {
    const probe = Key('probe');
    List<CarbonDataTableRow> rows({Widget? expansion, bool selected = false}) =>
        [
          CarbonDataTableRow(
            cells: const [Text('alpha'), Text('5')],
            selected: selected,
            expansion: expansion,
          ),
          const CarbonDataTableRow(cells: [Text('beta'), Text('4')]),
        ];

    Finder block(Key key) => find
        .ancestor(
          of: find.byKey(key),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                (w.decoration as BoxDecoration).border != null,
          ),
        )
        .first;

    testWidgets('renders below the cells at full width inside the rule', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _table(rows: rows(expansion: const SizedBox(key: probe, height: 20))),
        theme: light,
      );
      final table = tester.getRect(find.byType(CarbonDataTable));
      final expansion = tester.getRect(find.byKey(probe));
      expect(
        expansion.top,
        greaterThanOrEqualTo(tester.getRect(find.text('alpha')).bottom),
      );
      expect(expansion.left, table.left + CarbonSpacing.spacing05);
      expect(expansion.right, table.right - CarbonSpacing.spacing05);
      final rect = tester.getRect(block(probe));
      expect(rect.width, table.width);
      expect(rect.bottom, greaterThan(expansion.bottom));
      expect(tester.getRect(find.text('beta')).top, greaterThan(rect.bottom));
      final border =
          (tester.widget<DecoratedBox>(block(probe)).decoration
                  as BoxDecoration)
              .border!
          as Border;
      expect(border.bottom.color, light.borderSubtle(1));
    });

    testWidgets('takes the row fill, selected and hovered', (tester) async {
      await pumpCarbon(
        tester,
        _table(rows: rows(expansion: const Text('details'), selected: true)),
        theme: light,
      );
      expect(_ruled(tester, 'details').color, light.layerSelected(1));
      await _hover(tester, tester.getCenter(find.text('details')));
      expect(_ruled(tester, 'details').color, light.layerSelectedHover(1));
    });

    testWidgets('hover does not recolour the expansion text', (tester) async {
      await pumpCarbon(
        tester,
        _table(rows: rows(expansion: const Text('details'))),
        theme: light,
      );
      await _hover(tester, tester.getCenter(find.text('alpha')));
      expect(_style(tester, 'alpha').color, light.colors.textPrimary);
      expect(_style(tester, 'details').color, light.colors.textSecondary);
    });

    testWidgets('absent when null', (tester) async {
      await pumpCarbon(tester, _table(rows: rows()), theme: light);
      expect(find.byKey(probe), findsNothing);
      expect(tester.getSize(_row('alpha')).height, 48);
    });

    testWidgets('does not overflow at 320 wide and 200% text', (tester) async {
      for (final density in CarbonDensity.values) {
        await pumpCarbon(
          tester,
          _table(
            width: 320,
            rows: rows(
              expansion: const Text(
                'Last run finished with warnings in the dependency step.',
              ),
            ),
          ),
          theme: CarbonThemeData(density: density),
          textScale: 2,
          size: const Size(320, 2000),
        );
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(CarbonDataTable)).width, 320);
      }
    });
  });
}
