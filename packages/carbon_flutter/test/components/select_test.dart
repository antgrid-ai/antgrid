import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:carbon_flutter/src/components/option_listbox.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _select = Key('select');

const List<CarbonOption<String>> _options = [
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Bravo', enabled: false),
  CarbonOption(value: 'c', label: 'Charlie'),
  CarbonOption(value: 'd', label: 'Delta'),
];

/// Hosts the select with committed state, like a real form.
class _Host extends StatefulWidget {
  const _Host({
    this.initial,
    this.options = _options,
    this.enabled = true,
    this.readOnly = false,
    this.errorText,
    this.focusNode,
    this.onChanged,
  });

  final String? initial;
  final List<CarbonOption<String>> options;
  final bool enabled;
  final bool readOnly;
  final String? errorText;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String? value = widget.initial;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topStart,
    child: SizedBox(
      width: 300,
      child: CarbonSelect<String>(
        key: _select,
        label: 'Mode',
        options: widget.options,
        value: value,
        enabled: widget.enabled,
        readOnly: widget.readOnly,
        errorText: widget.errorText,
        focusNode: widget.focusNode,
        onChanged: (v) {
          widget.onChanged?.call(v);
          setState(() => value = v);
        },
      ),
    ),
  );
}

Finder _row(String label) => find.descendant(
  of: find.byType(CarbonOptionListbox<String>),
  matching: find.text(label),
);

Finder get _list => find.byType(CarbonOptionListbox<String>);

Future<void> _openByTap(WidgetTester tester) async {
  await tester.tap(find.byKey(_select));
  await tester.pump();
  await tester.pump();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump();
}

void main() {
  group('display', () {
    testWidgets('shows placeholder, then the committed value', (tester) async {
      await pumpCarbon(tester, const _Host());
      expect(find.text('Choose an option'), findsOneWidget);
      await pumpCarbon(tester, const SizedBox());
      await pumpCarbon(tester, const _Host(initial: 'c'));
      expect(find.text('Charlie'), findsOneWidget);
    });

    testWidgets('custom placeholder', (tester) async {
      await pumpCarbon(
        tester,
        CarbonSelect<String>(
          options: _options,
          value: null,
          onChanged: (_) {},
          placeholder: 'Pick one',
        ),
      );
      expect(find.text('Pick one'), findsOneWidget);
    });

    testWidgets('value missing from options is shown honestly and kept', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(initial: 'zzz', onChanged: changes.add),
      );
      expect(find.text('Unavailable'), findsOneWidget);
      await _openByTap(tester);
      // No row is selected, and opening never substitutes a value.
      expect(_list, findsOneWidget);
      expect(changes, isEmpty);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(changes, isEmpty);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('empty options show No results and never commit', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(options: const [], onChanged: changes.add),
      );
      await _openByTap(tester);
      expect(find.text('No results'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, isEmpty);
    });

    testWidgets('unavailable value with empty options', (tester) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(initial: 'a', options: const [], onChanged: changes.add),
      );
      expect(find.text('Unavailable'), findsOneWidget);
      await _openByTap(tester);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, isEmpty);
    });
  });

  group('sizing', () {
    testWidgets('field height follows density, rows meet the floor', (
      tester,
    ) async {
      final harness = await pumpCarbon(tester, const _Host(initial: 'a'));
      expect(tester.getSize(find.byType(CarbonFieldBox)).height, 32);
      await _openByTap(tester);
      expect(tester.getSize(_row('Alpha')).height, lessThanOrEqualTo(32));
      final compactRow = tester.getRect(
        find
            .ancestor(of: _row('Alpha'), matching: find.byType(DecoratedBox))
            .first,
      );
      expect(compactRow.height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byType(CarbonFieldBox)).height, 48);
      final touchRow = tester.getRect(
        find
            .ancestor(of: _row('Alpha'), matching: find.byType(DecoratedBox))
            .first,
      );
      expect(touchRow.height, 48);
    });

    testWidgets('rows and field grow with text scale', (tester) async {
      await pumpCarbon(tester, const _Host(initial: 'a'), textScale: 2);
      await _openByTap(tester);
      final row = tester.getRect(
        find
            .ancestor(of: _row('Alpha'), matching: find.byType(DecoratedBox))
            .first,
      );
      expect(row.height, greaterThan(32));
      expect(tester.takeException(), isNull);
    });

    testWidgets('list matches the anchor width and scrolls past six rows', (
      tester,
    ) async {
      final many = [
        for (var i = 0; i < 40; i++)
          CarbonOption(value: 'v$i', label: 'Option $i'),
      ];
      await pumpCarbon(
        tester,
        _Host(options: many),
        size: const Size(400, 800),
      );
      await _openByTap(tester);
      expect(
        tester.getSize(_list).width,
        tester.getSize(find.byType(CarbonFieldBox)).width,
      );
      // Rows are built lazily.
      expect(find.text('Option 0'), findsOneWidget);
      expect(find.text('Option 39'), findsNothing);
      expect(tester.getSize(_list).height, 6 * 32 + 2);
    });
  });

  group('pointer', () {
    testWidgets('tap opens, tapping a row commits and closes', (tester) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(onChanged: changes.add));
      await _openByTap(tester);
      expect(_list, findsOneWidget);
      await tester.tap(_row('Charlie'));
      await tester.pump();
      await tester.pump();
      expect(changes, ['c']);
      expect(_list, findsNothing);
      expect(find.text('Charlie'), findsOneWidget);
    });

    testWidgets('tapping the field again closes without committing', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(initial: 'a', onChanged: changes.add));
      await _openByTap(tester);
      await tester.tap(find.byKey(_select));
      await tester.pump();
      await tester.pump();
      expect(_list, findsNothing);
      expect(changes, isEmpty);
    });

    testWidgets('disabled option cannot be committed by tap', (tester) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(onChanged: changes.add));
      await _openByTap(tester);
      await tester.tap(_row('Bravo'));
      await tester.pump();
      expect(changes, isEmpty);
      expect(_list, findsOneWidget);
    });

    testWidgets('outside tap dismisses without committing', (tester) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        Column(
          children: [
            _Host(initial: 'a', onChanged: changes.add),
            const SizedBox(width: 50, height: 50, key: Key('outside')),
          ],
        ),
        size: const Size(400, 800),
      );
      await _openByTap(tester);
      expect(_list, findsOneWidget);
      await tester.tapAt(const Offset(390, 790));
      await tester.pump();
      await tester.pump();
      expect(_list, findsNothing);
      expect(changes, isEmpty);
    });

    testWidgets('selecting the committed value again does not call onChanged', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(initial: 'a', onChanged: changes.add));
      await _openByTap(tester);
      await tester.tap(_row('Alpha'));
      await tester.pump();
      expect(changes, isEmpty);
      expect(_list, findsNothing);
    });

    testWidgets('hover moves the highlight', (tester) async {
      await pumpCarbon(tester, const _Host(initial: 'a'));
      await _openByTap(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_row('Delta')));
      await tester.pump();
      // Enter via keyboard commits the hovered row.
      await _key(tester, LogicalKeyboardKey.enter);
      expect(find.text('Delta'), findsOneWidget);
    });
  });

  group('keyboard', () {
    Future<FocusNode> focused(
      WidgetTester tester, {
      String? initial,
      List<String>? changes,
    }) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(initial: initial, focusNode: node, onChanged: changes?.add),
      );
      node.requestFocus();
      await tester.pump();
      return node;
    }

    testWidgets('Enter, Space, Alt+Down and arrows open', (tester) async {
      await focused(tester);
      for (final open in <Future<void> Function()>[
        () => _key(tester, LogicalKeyboardKey.enter),
        () => _key(tester, LogicalKeyboardKey.space),
        () async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
          await tester.pump();
          await tester.pump();
        },
        () => _key(tester, LogicalKeyboardKey.arrowDown),
        () => _key(tester, LogicalKeyboardKey.arrowUp),
      ]) {
        await open();
        expect(_list, findsOneWidget);
        await _key(tester, LogicalKeyboardKey.escape);
        expect(_list, findsNothing);
      }
    });

    testWidgets('arrows skip disabled options and wrap', (tester) async {
      final changes = <String>[];
      await focused(tester, changes: changes);
      await _key(tester, LogicalKeyboardKey.enter); // opens, highlights Alpha
      await _key(tester, LogicalKeyboardKey.arrowDown); // Bravo skipped
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['c']);
    });

    testWidgets('Home, End and wrapping', (tester) async {
      final changes = <String>[];
      await focused(tester, changes: changes);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.end);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['d']);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown); // wraps to Alpha
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['d', 'a']);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowUp); // wraps to Delta
      await _key(tester, LogicalKeyboardKey.home);
      await _key(tester, LogicalKeyboardKey.space);
      expect(changes, ['d', 'a']); // Alpha was already committed
    });

    testWidgets('Escape closes without committing and keeps focus', (
      tester,
    ) async {
      final changes = <String>[];
      final node = await focused(tester, initial: 'a', changes: changes);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(_list, findsNothing);
      expect(changes, isEmpty);
      expect(node.hasFocus, isTrue);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('opens on the committed option', (tester) async {
      final changes = <String>[];
      await focused(tester, initial: 'c', changes: changes);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['d']);
    });

    testWidgets('Enter on a pointer-opened list without highlight closes', (
      tester,
    ) async {
      final changes = <String>[];
      await focused(tester, changes: changes);
      await _openByTap(tester);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(_list, findsNothing);
      expect(changes, isEmpty);
    });

    testWidgets('typeahead jumps to a matching enabled option', (tester) async {
      final changes = <String>[];
      await focused(tester, changes: changes);
      await _key(tester, LogicalKeyboardKey.keyD);
      expect(_list, findsOneWidget);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['d']);
    });

    testWidgets('typeahead never lands on a disabled option', (tester) async {
      final changes = <String>[];
      await focused(tester, changes: changes);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
      await tester.pump();
      expect(_list, findsNothing);
      expect(changes, isEmpty);
    });

    testWidgets('focus is restored to the field after close', (tester) async {
      final node = await focused(tester);
      await _key(tester, LogicalKeyboardKey.enter);
      await tester.tap(_row('Alpha'));
      await tester.pump();
      await tester.pump();
      expect(node.hasFocus, isTrue);
    });

    testWidgets('Tab closes the list', (tester) async {
      await focused(tester);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.tab);
      expect(_list, findsNothing);
    });

    testWidgets('highlight scrolls into view in long lists', (tester) async {
      final many = [
        for (var i = 0; i < 40; i++)
          CarbonOption(value: 'v$i', label: 'Option $i'),
      ];
      final changes = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(options: many, focusNode: node, onChanged: changes.add),
        size: const Size(400, 800),
      );
      node.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.end);
      await tester.pump();
      expect(find.text('Option 39'), findsOneWidget);
      expect(find.text('Option 0'), findsNothing);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['v39']);
    });
  });

  group('disabled and read-only', () {
    testWidgets('disabled never opens and is not focusable', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(initial: 'a', enabled: false, focusNode: node),
      );
      await tester.tap(find.byKey(_select));
      await tester.pump();
      expect(_list, findsNothing);
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isFalse);
    });

    testWidgets('null onChanged disables', (tester) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(
            width: 300,
            child: CarbonSelect<String>(
              key: _select,
              options: _options,
              value: 'a',
              onChanged: null,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_select));
      await tester.pump();
      expect(_list, findsNothing);
    });

    testWidgets('read-only shows the value, focuses, never opens', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(
          initial: 'a',
          readOnly: true,
          focusNode: node,
          onChanged: changes.add,
        ),
      );
      expect(find.text('Alpha'), findsOneWidget);
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await tester.tap(find.byKey(_select));
      await tester.pump();
      expect(_list, findsNothing);
      expect(changes, isEmpty);
    });

    testWidgets('error text is suppressed when read-only', (tester) async {
      await pumpCarbon(tester, const _Host(initial: 'a', errorText: 'Bad'));
      expect(find.text('Bad'), findsOneWidget);
      await pumpCarbon(
        tester,
        const _Host(initial: 'a', errorText: 'Bad', readOnly: true),
      );
      expect(find.text('Bad'), findsNothing);
    });
  });

  group('semantics', () {
    testWidgets('field is a labelled button with value and expanded state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _Host(initial: 'c', errorText: 'Pick a valid mode'),
      );
      var node = tester.getSemantics(find.byKey(_select));
      var data = node.getSemanticsData();
      expect(data.label, contains('Mode'));
      expect(data.value, 'Charlie');
      expect(data.hint, contains('Pick a valid mode'));
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.flagsCollection.isExpanded, Tristate.isFalse);

      await _openByTap(tester);
      node = tester.getSemantics(find.byKey(_select));
      data = node.getSemanticsData();
      expect(data.flagsCollection.isExpanded, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('options expose selected and enabled state', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(initial: 'c'));
      await _openByTap(tester);
      final charlie = tester
          .getSemantics(
            find.ancestor(of: _row('Charlie'), matching: find.byType(Semantics)).first,
          )
          .getSemanticsData();
      expect(charlie.flagsCollection.isSelected, Tristate.isTrue);
      expect(charlie.flagsCollection.isEnabled, Tristate.isTrue);
      final bravo = tester
          .getSemantics(
            find.ancestor(of: _row('Bravo'), matching: find.byType(Semantics)).first,
          )
          .getSemanticsData();
      expect(bravo.flagsCollection.isEnabled, Tristate.isFalse);
      expect(bravo.flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('read-only flag and required marker are announced', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        CarbonSelect<String>(
          key: _select,
          label: 'Mode',
          required: true,
          readOnly: true,
          options: _options,
          value: 'a',
          onChanged: (_) {},
        ),
      );
      final data = tester
          .getSemantics(find.byKey(_select))
          .getSemanticsData();
      expect(data.flagsCollection.isReadOnly, isTrue);
      expect(data.flagsCollection.isRequired, Tristate.isTrue);
      handle.dispose();
    });
  });

  group('direction', () {
    testWidgets('RTL aligns the list with the field and mirrors the chevron', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(initial: 'a'),
        dir: TextDirection.rtl,
        size: const Size(500, 800),
      );
      await _openByTap(tester);
      final field = tester.getRect(find.byType(CarbonFieldBox));
      final list = tester.getRect(_list);
      expect(list.right, closeTo(field.right, 0.5));
      expect(list.left, closeTo(field.left, 0.5));
      // Text sits at the start (right) edge in RTL.
      expect(
        tester.getRect(find.text('Alpha').first).right,
        greaterThan(field.center.dx),
      );
    });
  });

  group('live changes', () {
    testWidgets('theme and density switch while open keep the list and value', (
      tester,
    ) async {
      final harness = await pumpCarbon(tester, const _Host(initial: 'c'));
      await _openByTap(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await harness.setTheme(
        tester,
        CarbonThemeData(scheme: CarbonThemeScheme.gray100),
      );
      expect(_list, findsOneWidget);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(_list, findsOneWidget);
      expect(find.text('Charlie'), findsWidgets);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(find.text('Delta'), findsOneWidget);
      expect(_list, findsNothing);
    });

    testWidgets('options replaced while open keep it open', (tester) async {
      await pumpCarbon(tester, const _Host(initial: 'a'));
      await _openByTap(tester);
      await pumpCarbon(
        tester,
        const _Host(
          initial: 'a',
          options: [CarbonOption(value: 'a', label: 'Alpha')],
        ),
      );
      await tester.pump();
      expect(_list, findsOneWidget);
      expect(_row('Delta'), findsNothing);
    });

    testWidgets('focus node replacement and repeated mount', (tester) async {
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await pumpCarbon(tester, _Host(initial: 'a', focusNode: first));
      first.requestFocus();
      await tester.pump();
      await pumpCarbon(tester, _Host(initial: 'a', focusNode: second));
      second.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      expect(_list, findsOneWidget);
      await _key(tester, LogicalKeyboardKey.escape);
      await pumpCarbon(tester, const SizedBox());
      await pumpCarbon(tester, const _Host(initial: 'a'));
      await _openByTap(tester);
      expect(_list, findsOneWidget);
      await pumpCarbon(tester, const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('removing the field while open removes the list', (
      tester,
    ) async {
      await pumpCarbon(tester, const _Host(initial: 'a'));
      await _openByTap(tester);
      await pumpCarbon(tester, const SizedBox());
      await tester.pump();
      expect(_list, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('descriptions grow the rows', (tester) async {
    await pumpCarbon(
      tester,
      Align(
        alignment: AlignmentDirectional.topStart,
        child: SizedBox(
          width: 300,
          child: CarbonSelect<String>(
            key: _select,
            options: const [
              CarbonOption(value: 'a', label: 'Alpha', description: 'First'),
            ],
            value: null,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await _openByTap(tester);
    expect(find.text('First'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
