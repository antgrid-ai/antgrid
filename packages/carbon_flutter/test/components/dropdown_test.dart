import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:carbon_flutter/src/components/option_listbox.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _dd = Key('dd');

const List<CarbonOption<String>> _options = [
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Bravo', enabled: false),
  CarbonOption(value: 'c', label: 'Charlie'),
  CarbonOption(value: 'd', label: 'Delta'),
  CarbonOption(value: 'e', label: 'Alpine'),
];

Finder get _list => find.byType(CarbonOptionListbox<String>);
Finder _row(String label) =>
    find.descendant(of: _list, matching: find.text(label));
Finder get _input => find.byType(EditableText);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _settle(tester);
}

String _text(WidgetTester tester) =>
    tester.widget<EditableText>(_input).controller.text;

class _Host extends StatefulWidget {
  const _Host({
    this.initial,
    this.options = _options,
    this.controller,
    this.focusNode,
    this.enabled = true,
    this.readOnly = false,
    this.allowCustom = false,
    this.loading = false,
    this.listError,
    this.onChanged,
    this.onCustom,
    this.onInput,
    this.acceptChanges = true,
    this.combo = true,
  });

  final String? initial;
  final List<CarbonOption<String>> options;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool enabled;
  final bool readOnly;
  final bool allowCustom;
  final bool loading;
  final String? listError;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onCustom;
  final ValueChanged<String>? onInput;
  final bool acceptChanges;
  final bool combo;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String? value = widget.initial;

  void _changed(String v) {
    widget.onChanged?.call(v);
    if (widget.acceptChanges) setState(() => value = v);
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topStart,
    child: SizedBox(
      width: 300,
      child: widget.combo
          ? CarbonComboBox<String>(
              key: _dd,
              label: 'Project',
              options: widget.options,
              value: value,
              onChanged: _changed,
              controller: widget.controller,
              focusNode: widget.focusNode,
              enabled: widget.enabled,
              readOnly: widget.readOnly,
              allowCustomValue: widget.allowCustom,
              onCustomValue: widget.onCustom,
              onInputChanged: widget.onInput,
              loading: widget.loading,
              listErrorText: widget.listError,
            )
          : CarbonDropdown<String>(
              key: _dd,
              label: 'Project',
              options: widget.options,
              value: value,
              onChanged: _changed,
              focusNode: widget.focusNode,
              enabled: widget.enabled,
              readOnly: widget.readOnly,
              loading: widget.loading,
              listErrorText: widget.listError,
            ),
    ),
  );
}

void main() {
  group('CarbonDropdown', () {
    testWidgets('shows value, opens, commits and closes', (tester) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(combo: false, onChanged: changes.add),
      );
      expect(find.text('Choose an option'), findsOneWidget);
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      expect(_list, findsOneWidget);
      await tester.tap(_row('Delta'));
      await _settle(tester);
      expect(changes, ['d']);
      expect(_list, findsNothing);
      expect(find.text('Delta'), findsOneWidget);
    });

    testWidgets('keyboard navigation skips disabled and Escape dismisses', (
      tester,
    ) async {
      final changes = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(combo: false, focusNode: node, onChanged: changes.add),
      );
      node.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(_list, findsNothing);
      expect(changes, isEmpty);
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['c']);
      expect(node.hasFocus, isTrue);
    });

    testWidgets('loading row shows the localized label and a spinner', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(combo: false, options: [], loading: true),
      );
      await tester.tap(find.byKey(_dd));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Loading'), findsOneWidget);
      expect(find.byType(CarbonSpinner), findsOneWidget);
      expect(find.text('No results'), findsNothing);
    });

    testWidgets('error row replaces the empty message', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(combo: false, options: [], listError: 'Could not load'),
      );
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('No results'), findsNothing);
    });

    testWidgets('loading with options keeps them above the status row', (
      tester,
    ) async {
      await pumpCarbon(tester, const _Host(combo: false, loading: true));
      await tester.tap(find.byKey(_dd));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_row('Alpha'), findsOneWidget);
      expect(find.text('Loading'), findsOneWidget);
    });

    testWidgets('unavailable value is shown and never replaced', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(combo: false, initial: 'zzz', onChanged: changes.add),
      );
      expect(find.text('Unavailable'), findsOneWidget);
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(changes, isEmpty);
    });

    testWidgets('read-only and disabled never open', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(combo: false, initial: 'a', readOnly: true),
      );
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      expect(_list, findsNothing);
      await pumpCarbon(
        tester,
        const _Host(combo: false, initial: 'a', enabled: false),
      );
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      expect(_list, findsNothing);
    });
  });

  group('CarbonComboBox filtering', () {
    testWidgets('shows the committed label in the input', (tester) async {
      await pumpCarbon(tester, const _Host(initial: 'c'));
      expect(_text(tester), 'Charlie');
    });

    testWidgets('typing filters, highlights and never commits', (
      tester,
    ) async {
      final changes = <String>[];
      final inputs = <String>[];
      await pumpCarbon(
        tester,
        _Host(onChanged: changes.add, onInput: inputs.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'al');
      await _settle(tester);
      expect(_list, findsOneWidget);
      expect(_row('Alpha'), findsOneWidget);
      expect(_row('Alpine'), findsOneWidget);
      expect(_row('Delta'), findsNothing);
      expect(_row('Charlie'), findsNothing);
      expect(changes, isEmpty);
      expect(inputs, ['al']);
    });

    testWidgets('Enter commits the highlighted match exactly once', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(onChanged: changes.add));
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'alp');
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown); // Alpha -> Alpine
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['e']);
      expect(_text(tester), 'Alpine');
      expect(_list, findsNothing);
    });

    testWidgets('arrow keys skip disabled rows', (tester) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(initial: 'a', onChanged: changes.add));
      await tester.tap(_input);
      await _settle(tester);
      expect(_list, findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowDown); // Bravo disabled
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['c']);
    });

    testWidgets('no matches shows No results and Enter commits nothing', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(onChanged: changes.add));
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'zzz');
      await _settle(tester);
      expect(find.text('No results'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, isEmpty);
      expect(_text(tester), 'zzz');
    });

    testWidgets('Escape closes the list, a second Escape discards the filter', (
      tester,
    ) async {
      final changes = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(initial: 'c', focusNode: node, onChanged: changes.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'del');
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(_list, findsNothing);
      expect(_text(tester), 'del');
      await _key(tester, LogicalKeyboardKey.escape);
      expect(_text(tester), 'Charlie');
      expect(changes, isEmpty);
      expect(node.hasFocus, isTrue);
    });

    testWidgets('blur without commit restores the committed label', (
      tester,
    ) async {
      final changes = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        Column(
          children: [
            _Host(initial: 'c', focusNode: node, onChanged: changes.add),
            const Focus(child: SizedBox(width: 10, height: 10)),
          ],
        ),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'xyz');
      await _settle(tester);
      node.unfocus();
      await _settle(tester);
      expect(_text(tester), 'Charlie');
      expect(_list, findsNothing);
      expect(changes, isEmpty);
    });

    testWidgets('clearing the text only filters; blur restores', (
      tester,
    ) async {
      final changes = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(initial: 'c', focusNode: node, onChanged: changes.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, '');
      await _settle(tester);
      expect(_row('Alpha'), findsOneWidget);
      expect(_row('Delta'), findsOneWidget);
      node.unfocus();
      await _settle(tester);
      expect(_text(tester), 'Charlie');
      expect(changes, isEmpty);
    });

    testWidgets('tapping a row commits it; the popup tap keeps focus', (
      tester,
    ) async {
      final changes = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(focusNode: node, onChanged: changes.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'ch');
      await _settle(tester);
      await tester.tap(_row('Charlie'));
      await _settle(tester);
      expect(changes, ['c']);
      expect(_text(tester), 'Charlie');
      expect(_list, findsNothing);
      expect(node.hasFocus, isTrue);
    });

    testWidgets('disabled row cannot be committed', (tester) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(onChanged: changes.add));
      await tester.tap(_input);
      await _settle(tester);
      await tester.tap(_row('Bravo'));
      await _settle(tester);
      expect(changes, isEmpty);
      expect(_list, findsOneWidget);
    });

    testWidgets('custom filter replaces the default', (tester) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(
            width: 300,
            child: CarbonComboBox<String>(
              key: _dd,
              options: _options,
              value: null,
              onChanged: (_) {},
              filter: (o, q) => o.value == q,
            ),
          ),
        ),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'd');
      await _settle(tester);
      expect(_row('Delta'), findsOneWidget);
      expect(_row('Alpha'), findsNothing);
    });

    testWidgets('host rejecting a commit restores the held value', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(initial: 'a', acceptChanges: false, onChanged: changes.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.tap(_row('Delta'));
      await _settle(tester);
      await tester.pump();
      expect(changes, ['d']);
      expect(_text(tester), 'Alpha');
    });

    testWidgets('external value change updates the input when not editing', (
      tester,
    ) async {
      await pumpCarbon(tester, const _Host(initial: 'a'));
      expect(_text(tester), 'Alpha');
      await pumpCarbon(tester, const _Host(initial: 'a'));
      final state = tester.state<State>(find.byType(_Host));
      // Drive a new committed value through the host.
      (state as dynamic).setState(() => (state as dynamic).value = 'd');
      await tester.pump();
      expect(_text(tester), 'Delta');
    });

    testWidgets('external value change while editing keeps the typed text', (
      tester,
    ) async {
      await pumpCarbon(tester, const _Host(initial: 'a'));
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'del');
      await _settle(tester);
      final state = tester.state<State>(find.byType(_Host));
      (state as dynamic).setState(() => (state as dynamic).value = 'c');
      await tester.pump();
      expect(_text(tester), 'del');
    });
  });

  group('CarbonComboBox custom values', () {
    testWidgets('Enter submits typed text only when explicitly enabled', (
      tester,
    ) async {
      final custom = <String>[];
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(allowCustom: true, onCustom: custom.add, onChanged: changes.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'my-project');
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(custom, ['my-project']);
      expect(changes, isEmpty);
      // The host did not accept it, so the committed (empty) display returns.
      await tester.pump();
      expect(_text(tester), '');
    });

    testWidgets('an arrowed-to row wins over custom text', (tester) async {
      final custom = <String>[];
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(allowCustom: true, onCustom: custom.add, onChanged: changes.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'al');
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['a']);
      expect(custom, isEmpty);
    });

    testWidgets('without allowCustomValue Enter never submits text', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(onChanged: changes.add));
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'qqq');
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, isEmpty);
    });
  });

  group('CarbonComboBox states', () {
    testWidgets('empty option set', (tester) async {
      await pumpCarbon(tester, const _Host(options: []));
      await tester.tap(_input);
      await _settle(tester);
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('loading and error rows', (tester) async {
      await pumpCarbon(tester, const _Host(options: [], loading: true));
      await tester.tap(_input);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Loading'), findsOneWidget);
      await pumpCarbon(
        tester,
        const _Host(options: [], listError: 'Search failed'),
      );
      await tester.pump();
      expect(find.text('Search failed'), findsOneWidget);
    });

    testWidgets('unavailable value shows as the hint and is not replaced', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(tester, _Host(initial: 'zzz', onChanged: changes.add));
      expect(_text(tester), '');
      expect(find.text('Unavailable'), findsOneWidget);
      await tester.tap(_input);
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(changes, isEmpty);
    });

    testWidgets('read-only shows the value and never opens', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(initial: 'a', readOnly: true, focusNode: node),
      );
      await tester.tap(_input);
      await _settle(tester);
      expect(node.hasFocus, isTrue);
      expect(_list, findsNothing);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_list, findsNothing);
      expect(_text(tester), 'Alpha');
    });

    testWidgets('disabled does not open or focus', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(initial: 'a', enabled: false, focusNode: node),
      );
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      expect(_list, findsNothing);
      expect(node.hasFocus, isFalse);
    });

    testWidgets('large option sets build rows lazily and scroll', (
      tester,
    ) async {
      final many = [
        for (var i = 0; i < 5000; i++)
          CarbonOption(value: 'v$i', label: 'Item $i'),
      ];
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(options: many, onChanged: changes.add),
        size: const Size(400, 800),
      );
      await tester.tap(_input);
      await _settle(tester);
      expect(find.byType(Text).evaluate().length, lessThan(30));
      await _key(tester, LogicalKeyboardKey.arrowUp); // wraps to the last
      expect(find.text('Item 4999'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['v4999']);
    });

    testWidgets('typing filters a large set', (tester) async {
      final many = [
        for (var i = 0; i < 2000; i++)
          CarbonOption(value: 'v$i', label: 'Item $i'),
      ];
      await pumpCarbon(
        tester,
        _Host(options: many),
        size: const Size(400, 800),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'Item 1999');
      await _settle(tester);
      expect(_row('Item 1999'), findsOneWidget);
      expect(_row('Item 0'), findsNothing);
    });
  });

  group('CarbonComboBox lifecycle', () {
    testWidgets('supplied controller is not disposed and is replaceable', (
      tester,
    ) async {
      final first = TextEditingController();
      final second = TextEditingController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await pumpCarbon(tester, _Host(initial: 'a', controller: first));
      expect(first.text, 'Alpha');
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'del');
      await _settle(tester);
      await pumpCarbon(tester, _Host(initial: 'a', controller: second));
      await tester.pump();
      expect(second.text, 'del');
      expect(_text(tester), 'del');
      // The old controller no longer drives the field.
      first.text = 'ignored';
      await tester.pump();
      expect(_text(tester), 'del');
      // Typing through the new controller still filters.
      await tester.enterText(_input, 'ch');
      await _settle(tester);
      expect(_row('Charlie'), findsOneWidget);
      await pumpCarbon(tester, const SizedBox());
      // Supplied controllers survive unmount.
      second.text = 'still usable';
      expect(second.text, 'still usable');
    });

    testWidgets('does not rewrite text on rebuilds while the user types', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpCarbon(tester, _Host(controller: controller));
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'al');
      await _settle(tester);
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
      await pumpCarbon(tester, _Host(controller: controller));
      await tester.pump();
      expect(controller.text, 'al');
      expect(controller.selection.extentOffset, 1);
    });

    testWidgets('focus node replacement keeps working', (tester) async {
      final a = FocusNode();
      final b = FocusNode();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await pumpCarbon(tester, _Host(focusNode: a));
      await tester.tap(_input);
      await _settle(tester);
      await pumpCarbon(tester, _Host(focusNode: b));
      await _settle(tester);
      expect(b.hasFocus, isTrue);
      await tester.enterText(_input, 'de');
      await _settle(tester);
      expect(_row('Delta'), findsOneWidget);
    });

    testWidgets('repeated mount and unmount while open', (tester) async {
      for (var i = 0; i < 3; i++) {
        await pumpCarbon(tester, const _Host(initial: 'a'));
        await tester.tap(_input);
        await _settle(tester);
        expect(_list, findsOneWidget);
        await pumpCarbon(tester, const SizedBox());
        await tester.pump();
        expect(_list, findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('live changes', () {
    testWidgets('theme and density switch keep filter, highlight and value', (
      tester,
    ) async {
      final changes = <String>[];
      final harness = await pumpCarbon(
        tester,
        _Host(initial: 'c', onChanged: changes.add),
      );
      await tester.tap(_input);
      await _settle(tester);
      await tester.enterText(_input, 'al');
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown); // Alpha -> Alpine
      await harness.setTheme(
        tester,
        CarbonThemeData(scheme: CarbonThemeScheme.gray90),
      );
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(_text(tester), 'al');
      expect(_list, findsOneWidget);
      expect(_row('Delta'), findsNothing);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['e']);
      expect(_text(tester), 'Alpine');
    });

    testWidgets('density changes the field and row floors', (tester) async {
      final harness = await pumpCarbon(tester, const _Host(initial: 'a'));
      expect(tester.getSize(find.byType(CarbonFieldBox)).height, 32);
      await tester.tap(_input);
      await _settle(tester);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byType(CarbonFieldBox)).height, 48);
      final row = tester.getRect(
        find.ancestor(of: _row('Alpha'), matching: find.byType(DecoratedBox)).first,
      );
      expect(row.height, 48);
    });

    testWidgets('200% text does not overflow', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(initial: 'a'),
        textScale: 2,
        size: const Size(320, 700),
      );
      await tester.tap(_input);
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('RTL and semantics', () {
    testWidgets('RTL aligns the list with the field', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(initial: 'a'),
        dir: TextDirection.rtl,
        size: const Size(500, 800),
      );
      await tester.tap(_input);
      await _settle(tester);
      final field = tester.getRect(find.byType(CarbonFieldBox));
      final list = tester.getRect(_list);
      expect(list.right, closeTo(field.right, 0.5));
      expect(list.left, closeTo(field.left, 0.5));
    });

    testWidgets('combo field announces label, text and expanded state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(initial: 'a'));
      var node = tester.getSemantics(find.byType(EditableText));
      var data = node.getSemanticsData();
      expect(data.label, contains('Project'));
      expect(data.value, 'Alpha');
      expect(data.flagsCollection.isTextField, isTrue);
      expect(data.flagsCollection.isExpanded, Tristate.isFalse);
      await tester.tap(_input);
      await _settle(tester);
      node = tester.getSemantics(find.byType(EditableText));
      data = node.getSemanticsData();
      expect(data.flagsCollection.isExpanded, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('dropdown options expose selected state', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(combo: false, initial: 'c'));
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      final charlie = tester
          .getSemantics(
            find.ancestor(of: _row('Charlie'), matching: find.byType(Semantics)).first,
          )
          .getSemanticsData();
      expect(charlie.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('hover moves the highlight in a dropdown', (tester) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(combo: false, onChanged: changes.add),
      );
      await tester.tap(find.byKey(_dd));
      await _settle(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_row('Delta')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
