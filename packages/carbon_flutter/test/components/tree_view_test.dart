import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

CarbonThemeData _touch() =>
    CarbonThemeData(density: CarbonDensity.touch, touchTarget: 44);

Finder _row(Object id) => find.byKey(ValueKey<Object>(id));

// src
//   main.dart
//   lib
//     util.dart
// README.md
// Loading...   (not a node)
const Map<String, List<String>> _children = <String, List<String>>{
  'src': ['main.dart', 'lib'],
  'lib': ['util.dart'],
};

class _Host extends StatefulWidget {
  const _Host({
    required this.log,
    this.expanded = const {'src'},
    this.size = CarbonTreeViewSize.sm,
    this.focusNode,
    this.tweak,
  });

  final List<String> log;
  final Set<String> expanded;
  final CarbonTreeViewSize size;
  final FocusNode? focusNode;
  final CarbonTreeNodeData Function(CarbonTreeNodeData row)? tweak;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late final Set<String> _expanded = {...widget.expanded};
  String? _selected;
  String? _active;

  List<CarbonTreeNodeData> _rows() {
    final rows = <CarbonTreeNodeData>[];
    void walk(String id, int depth) {
      final kids = _children[id];
      final row = CarbonTreeNodeData(
        id: id,
        label: id,
        depth: depth,
        isBranch: kids != null,
        expanded: _expanded.contains(id),
        selected: _selected == id,
        active: _active == id,
      );
      rows.add(widget.tweak?.call(row) ?? row);
      if (kids != null && _expanded.contains(id)) {
        for (final kid in kids) {
          walk(kid, depth + 1);
        }
      }
    }

    walk('src', 0);
    walk('README.md', 0);
    final notice = const CarbonTreeNodeData(
      id: 'notice',
      label: 'Loading...',
      interactive: false,
    );
    rows.add(widget.tweak?.call(notice) ?? notice);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return CarbonTreeView(
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i],
      size: widget.size,
      focusNode: widget.focusNode,
      onToggle: (id) => setState(() {
        widget.log.add('toggle:$id');
        if (!_expanded.add(id as String)) _expanded.remove(id);
      }),
      onSelect: (id) => setState(() {
        widget.log.add('select:$id');
        _selected = id as String;
      }),
      onActivate: (id) => setState(() {
        widget.log.add('activate:$id');
        _active = id as String;
      }),
    );
  }
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

/// Space selects whatever row holds focus, which names it in the log.
Future<String> _focusedRow(WidgetTester tester, List<String> log) async {
  log.clear();
  await _key(tester, LogicalKeyboardKey.space);
  final line = log.firstWhere((e) => e.startsWith('select:'));
  log.clear();
  return line.substring('select:'.length);
}

Future<FocusNode> _pumpFocused(
  WidgetTester tester,
  List<String> log, {
  CarbonTreeNodeData Function(CarbonTreeNodeData row)? tweak,
}) async {
  final node = FocusNode();
  addTearDown(node.dispose);
  await pumpCarbon(
    tester,
    _Host(log: log, focusNode: node, tweak: tweak),
  );
  node.requestFocus();
  await tester.pump();
  return node;
}

void main() {
  group('CarbonTreeView rendering', () {
    testWidgets('indents each depth level by 1.5rem', (tester) async {
      await pumpCarbon(tester, _Host(log: []));
      final src = tester.getTopLeft(find.text('src')).dx;
      final child = tester.getTopLeft(find.text('main.dart')).dx;
      expect(src, 40);
      expect(child - src, 24);
      expect(tester.getTopLeft(find.text('README.md')).dx, src);
    });

    testWidgets('hides the children of a collapsed branch', (tester) async {
      await pumpCarbon(tester, _Host(log: [], expanded: const {}));
      expect(find.text('main.dart'), findsNothing);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('selected and active rows fill, and only active has a bar', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(tester, _Host(log: []));
      await tester.tap(find.text('main.dart'));
      await tester.pump();
      Iterable<DecoratedBox> boxes(Object id) => find
          .descendant(of: _row(id), matching: find.byType(DecoratedBox))
          .evaluate()
          .map((e) => e.widget as DecoratedBox);
      bool hasBar(Object id) => boxes(id).any(
        (b) =>
            b.position == DecorationPosition.foreground &&
            (b.decoration as BoxDecoration).border != null,
      );
      expect(hasBar('main.dart'), isTrue);
      expect(hasBar('README.md'), isFalse);
      final fills = find
          .descendant(of: _row('main.dart'), matching: find.byType(ColoredBox))
          .evaluate()
          .map((e) => (e.widget as ColoredBox).color);
      expect(fills, contains(theme.layerSelected(1)));
    });

    testWidgets('an active row that is not selected has no fill', (
      tester,
    ) async {
      final theme = CarbonThemeData();
      await pumpCarbon(
        tester,
        CarbonTreeView(
          itemCount: 1,
          itemBuilder: (context, i) => const CarbonTreeNodeData(
            id: 'a',
            label: 'a',
            active: true,
          ),
        ),
      );
      final fills = find
          .descendant(of: _row('a'), matching: find.byType(ColoredBox))
          .evaluate()
          .map((e) => (e.widget as ColoredBox).color);
      expect(fills, isNot(contains(theme.layerSelected(1))));
    });
  });

  group('CarbonTreeView row extent', () {
    for (final scale in <double>[1, 2]) {
      testWidgets('is constant across row kinds at text scale $scale', (
        tester,
      ) async {
        await pumpCarbon(
          tester,
          _Host(
            log: [],
            expanded: const {'src', 'lib'},
            tweak: (row) => switch (row.id) {
              'main.dart' => CarbonTreeNodeData(
                id: row.id,
                label: row.label,
                depth: row.depth,
                leading: const CarbonIcon(CarbonIcons.document),
              ),
              'lib' => CarbonTreeNodeData(
                id: row.id,
                label: row.label,
                depth: row.depth,
                isBranch: true,
                expanded: true,
                trailing: const Text('12'),
              ),
              _ => row,
            },
          ),
          textScale: scale,
          size: const Size(400, 800),
        );
        final expected = CarbonTreeView.rowExtent(
          CarbonThemeData(),
          TextScaler.linear(scale),
        );
        for (final id in <Object>[
          'src',
          'main.dart',
          'lib',
          'util.dart',
          'README.md',
          'notice',
        ]) {
          expect(tester.getSize(_row(id)).height, expected, reason: '$id');
        }
        expect(expected, scale == 1 ? 32 : greaterThan(32));
      });
    }

    testWidgets('xs is 24 and sm is 32 at normal text size', (tester) async {
      final theme = CarbonThemeData();
      expect(
        CarbonTreeView.rowExtent(
          theme,
          TextScaler.noScaling,
          size: CarbonTreeViewSize.xs,
        ),
        24,
      );
      expect(CarbonTreeView.rowExtent(theme, TextScaler.noScaling), 32);
      await pumpCarbon(
        tester,
        _Host(log: [], size: CarbonTreeViewSize.xs),
      );
      expect(tester.getSize(_row('src')).height, 24);
    });

    testWidgets('touch density rows are 44 tall', (tester) async {
      await pumpCarbon(tester, _Host(log: []), theme: _touch());
      for (final id in <Object>['src', 'main.dart', 'notice']) {
        expect(tester.getSize(_row(id)).height, 44, reason: '$id');
      }
      expect(
        CarbonTreeView.rowExtent(
          _touch(),
          TextScaler.noScaling,
          size: CarbonTreeViewSize.xs,
        ),
        44,
      );
    });
  });

  group('CarbonTreeView pointer', () {
    testWidgets('tapping a leaf selects and activates it', (tester) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(log: log));
      await tester.tap(find.text('main.dart'));
      await tester.pump();
      expect(log, ['select:main.dart', 'activate:main.dart']);
    });

    testWidgets('tapping a branch selects and toggles it, never activates', (
      tester,
    ) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(log: log));
      await tester.tap(find.text('src'));
      await tester.pump();
      expect(log, ['select:src', 'toggle:src']);
      expect(find.text('main.dart'), findsNothing);
    });

    testWidgets('a non-node row ignores taps', (tester) async {
      final log = <String>[];
      await pumpCarbon(tester, _Host(log: log));
      await tester.tap(find.text('Loading...'));
      await tester.pump();
      expect(log, isEmpty);
    });

    testWidgets('a disabled row ignores taps', (tester) async {
      final log = <String>[];
      await pumpCarbon(
        tester,
        _Host(
          log: log,
          tweak: (row) => row.id == 'README.md'
              ? CarbonTreeNodeData(id: row.id, label: row.label, disabled: true)
              : row,
        ),
      );
      await tester.tap(find.text('README.md'));
      await tester.pump();
      expect(log, isEmpty);
    });

    testWidgets('hover fills the row', (tester) async {
      await pumpCarbon(tester, _Host(log: []));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('README.md')));
      await tester.pump();
      final fills = find
          .descendant(of: _row('README.md'), matching: find.byType(ColoredBox))
          .evaluate()
          .map((e) => (e.widget as ColoredBox).color);
      expect(fills, contains(CarbonThemeData().layerHover(1)));
    });
  });

  group('CarbonTreeView keyboard', () {
    testWidgets('takes one tab stop', (tester) async {
      final before = FocusNode();
      final after = FocusNode();
      final tree = FocusNode();
      addTearDown(before.dispose);
      addTearDown(after.dispose);
      addTearDown(tree.dispose);
      await pumpCarbon(
        tester,
        Column(
          children: [
            Focus(
              focusNode: before,
              autofocus: true,
              child: const SizedBox(height: 20),
            ),
            Expanded(child: _Host(log: [], focusNode: tree)),
            Focus(focusNode: after, child: const SizedBox(height: 20)),
          ],
        ),
      );
      expect(before.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.tab);
      expect(tree.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.tab);
      expect(after.hasFocus, isTrue);
      expect(tree.hasFocus, isFalse);
    });

    testWidgets('focus lands on the first row, then Down and Up move', (
      tester,
    ) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      expect(await _focusedRow(tester, log), 'src');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(await _focusedRow(tester, log), 'main.dart');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(await _focusedRow(tester, log), 'README.md');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(await _focusedRow(tester, log), 'README.md');
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(await _focusedRow(tester, log), 'lib');
    });

    testWidgets('Home and End skip rows that are not nodes', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.end);
      expect(await _focusedRow(tester, log), 'README.md');
      await _key(tester, LogicalKeyboardKey.home);
      expect(await _focusedRow(tester, log), 'src');
    });

    testWidgets('Right opens a closed branch then enters it', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(await _focusedRow(tester, log), 'lib');
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(log, ['toggle:lib']);
      expect(find.text('util.dart'), findsOneWidget);
      log.clear();
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(await _focusedRow(tester, log), 'util.dart');
    });

    testWidgets('Right on a leaf does nothing', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(log, isEmpty);
      expect(await _focusedRow(tester, log), 'main.dart');
    });

    testWidgets('Left closes an open branch then goes to the parent', (
      tester,
    ) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(log, ['toggle:src']);
      expect(find.text('main.dart'), findsNothing);
      log.clear();
      await _key(tester, LogicalKeyboardKey.arrowRight);
      log.clear();
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(await _focusedRow(tester, log), 'src');
    });

    testWidgets('Left on a top-level leaf does nothing', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.end);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(log, isEmpty);
      expect(await _focusedRow(tester, log), 'README.md');
    });

    testWidgets('Enter on a leaf selects and activates', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(log, ['select:main.dart', 'activate:main.dart']);
    });

    testWidgets('Enter on a branch selects and toggles it', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(log, ['select:src', 'toggle:src']);
    });

    testWidgets('Space on a branch selects without toggling', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.space);
      expect(log, ['select:src']);
    });

    testWidgets('Space on a leaf selects and activates', (tester) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.space);
      expect(log, ['select:main.dart', 'activate:main.dart']);
    });

    testWidgets('typing jumps to the next row with that prefix', (
      tester,
    ) async {
      final log = <String>[];
      await _pumpFocused(tester, log);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR, character: 'r');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      expect(await _focusedRow(tester, log), 'README.md');
    });

    testWidgets('focus lands on the selected row when there is one', (
      tester,
    ) async {
      final log = <String>[];
      await _pumpFocused(
        tester,
        log,
        tweak: (row) => row.id == 'README.md'
            ? CarbonTreeNodeData(id: row.id, label: row.label, selected: true)
            : row,
      );
      expect(await _focusedRow(tester, log), 'README.md');
    });

    testWidgets('focus returns to the row it left', (tester) async {
      final log = <String>[];
      final node = await _pumpFocused(tester, log);
      await _key(tester, LogicalKeyboardKey.end);
      await _key(tester, LogicalKeyboardKey.enter);
      node.unfocus();
      await tester.pump();
      node.requestFocus();
      await tester.pump();
      expect(await _focusedRow(tester, log), 'README.md');
    });

    testWidgets('mirrors Left and Right in RTL', (tester) async {
      final log = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(log: log, focusNode: node, expanded: const {}),
        dir: TextDirection.rtl,
      );
      node.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(log, ['toggle:src']);
    });
  });

  group('CarbonTreeView semantics', () {
    testWidgets('branches report expanded, leaves do not', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _Host(log: []));
      expect(
        tester.getSemantics(find.text('src')).flagsCollection.isExpanded,
        Tristate.isTrue,
      );
      expect(
        tester.getSemantics(find.text('main.dart')).flagsCollection.isExpanded,
        Tristate.none,
      );
      await tester.tap(find.text('src'));
      await tester.pump();
      expect(
        tester.getSemantics(find.text('src')).flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('selected rows announce as selected', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _Host(log: []));
      await tester.tap(find.text('main.dart'));
      await tester.pump();
      expect(
        tester.getSemantics(find.text('main.dart')).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(
        tester.getSemantics(find.text('README.md')).flagsCollection.isSelected,
        Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('semanticLabel replaces the label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _Host(
          log: [],
          tweak: (row) => row.id == 'README.md'
              ? CarbonTreeNodeData(
                  id: row.id,
                  label: row.label,
                  semanticLabel: 'Readme file',
                )
              : row,
        ),
      );
      expect(find.bySemanticsLabel('Readme file'), findsOneWidget);
      handle.dispose();
    });
  });

  group('CarbonTreeView trailing', () {
    testWidgets('shows a trailing mark and keeps the row height', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _Host(
          log: [],
          tweak: (row) => row.id == 'README.md'
              ? CarbonTreeNodeData(
                  id: row.id,
                  label: row.label,
                  trailing: const Text('M'),
                )
              : row,
        ),
      );
      expect(find.text('M'), findsOneWidget);
      expect(tester.getSize(_row('README.md')).height, 32);
      expect(
        tester.getTopRight(find.text('M')).dx,
        lessThanOrEqualTo(tester.getTopRight(_row('README.md')).dx),
      );
    });

    testWidgets('trailingOnHover reveals on pointer hover and focus', (
      tester,
    ) async {
      bool visible() => tester
          .widget<Visibility>(
            find.ancestor(of: find.text('3'), matching: find.byType(Visibility)),
          )
          .visible;
      final log = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(
          log: log,
          focusNode: node,
          tweak: (row) => row.id == 'README.md'
              ? CarbonTreeNodeData(
                  id: row.id,
                  label: row.label,
                  trailing: const Text('3'),
                  trailingOnHover: true,
                )
              : row,
        ),
      );
      expect(visible(), isFalse);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('README.md')));
      await tester.pump();
      expect(visible(), isTrue);
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(visible(), isFalse);
      node.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.end);
      expect(visible(), isTrue);
    });

    testWidgets('trailingOnHover is always shown under touch density', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _Host(
          log: [],
          tweak: (row) => row.id == 'README.md'
              ? CarbonTreeNodeData(
                  id: row.id,
                  label: row.label,
                  trailing: const Text('3'),
                  trailingOnHover: true,
                )
              : row,
        ),
        theme: _touch(),
      );
      expect(
        tester
            .widget<Visibility>(
              find.ancestor(
                of: find.text('3'),
                matching: find.byType(Visibility),
              ),
            )
            .visible,
        isTrue,
      );
    });
  });

  group('CarbonTreeViewSliver', () {
    testWidgets('scrolls the focused row into view', (tester) async {
      final controller = ScrollController();
      final node = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        SizedBox(
          height: 200,
          child: CustomScrollView(
            controller: controller,
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
              CarbonTreeViewSliver(
                itemCount: 100,
                focusNode: node,
                itemBuilder: (context, i) =>
                    CarbonTreeNodeData(id: i, label: 'Row $i'),
              ),
            ],
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.end);
      expect(controller.offset, controller.position.maxScrollExtent);
      expect(find.text('Row 99'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.home);
      expect(controller.offset, 100);
      expect(find.text('Row 0'), findsOneWidget);
    });
  });
}
