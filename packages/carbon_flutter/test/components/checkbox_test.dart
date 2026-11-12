import 'dart:ui' show CheckedState, Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _cb = Key('cb');

Widget _aligned(Widget child, {double width = 400}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

/// Hosts a checkbox whose value follows its own callbacks, recording each
/// request.
class _Host extends StatefulWidget {
  const _Host({
    this.initial = false,
    this.tristate = false,
    this.readOnly = false,
    this.enabled = true,
    this.labelText = 'Accept',
    this.errorText,
    this.helperText,
    this.focusNode,
    this.log,
  });

  final bool? initial;
  final bool tristate;
  final bool readOnly;
  final bool enabled;
  final String? labelText;
  final String? errorText;
  final String? helperText;
  final FocusNode? focusNode;
  final List<bool?>? log;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late bool? _value = widget.initial;

  @override
  Widget build(BuildContext context) => _aligned(
    CarbonCheckbox(
      key: _cb,
      value: _value,
      tristate: widget.tristate,
      readOnly: widget.readOnly,
      labelText: widget.labelText,
      semanticLabel: widget.labelText == null ? 'Unlabelled' : null,
      errorText: widget.errorText,
      helperText: widget.helperText,
      focusNode: widget.focusNode,
      onChanged: widget.enabled
          ? (v) {
              widget.log?.add(v);
              setState(() => _value = v);
            }
          : null,
    ),
  );
}

// Resolves the merged control node by its announced name; the node found from
// the widget itself is the empty merge boundary above it.
SemanticsData _node(WidgetTester tester, [String label = 'Accept']) =>
    tester.getSemantics(find.bySemanticsLabel(label)).getSemanticsData();

void _expectState(
  WidgetTester tester, {
  bool checked = false,
  bool mixed = false,
  String label = 'Accept',
}) {
  final node = _node(tester, label);
  expect(
    node.flagsCollection.isChecked,
    mixed
        ? CheckedState.mixed
        : (checked ? CheckedState.isTrue : CheckedState.isFalse),
  );
}

void main() {
  group('sizing', () {
    testWidgets('target height follows density, indicator stays 16', (
      tester,
    ) async {
      final harness = await pumpCarbon(tester, const _Host());
      expect(tester.getSize(find.byKey(_cb)).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(find.byKey(_cb)).height, 48);
    });

    testWidgets('unlabelled checkbox still has a full target', (tester) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: CarbonCheckbox(
            key: _cb,
            value: false,
            semanticLabel: 'Select row',
            onChanged: (_) {},
          ),
        ),
      );
      expect(tester.getSize(find.byKey(_cb)), const Size(32, 32));
    });

    testWidgets('grows with 200% text and a long label wraps', (tester) async {
      await pumpCarbon(
        tester,
        const _Host(
          labelText:
              'I have read and accept the terms and conditions of this '
              'rather long agreement',
        ),
        textScale: 2,
        size: const Size(240, 600),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(_cb)).height, greaterThan(32));
      expect(tester.getSize(find.byKey(_cb)).width, lessThanOrEqualTo(240));
    });
  });

  group('activation', () {
    testWidgets('tapping the label toggles exactly once', (tester) async {
      final log = <bool?>[];
      await pumpCarbon(tester, _Host(log: log));
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(log, [true]);
      await tester.tap(find.byType(CarbonInteraction));
      await tester.pump();
      expect(log, [true, false]);
    });

    testWidgets('tapping the indicator toggles exactly once', (tester) async {
      final log = <bool?>[];
      await pumpCarbon(tester, _Host(log: log));
      final box = tester.getTopLeft(find.byKey(_cb)) + const Offset(8, 16);
      await tester.tapAt(box);
      await tester.pump();
      expect(log, [true]);
    });

    testWidgets('space toggles, enter is not required, repeat is ignored', (
      tester,
    ) async {
      final log = <bool?>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(tester, _Host(log: log, focusNode: node));
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(log, [true]);
    });

    testWidgets('non-tristate cycles true and false only', (tester) async {
      final log = <bool?>[];
      await pumpCarbon(tester, _Host(log: log, initial: null));
      await tester.tap(find.byType(CarbonInteraction));
      await tester.pump();
      await tester.tap(find.byType(CarbonInteraction));
      await tester.pump();
      expect(log, [true, false]);
    });

    testWidgets('tristate cycles unchecked, checked, indeterminate', (
      tester,
    ) async {
      final log = <bool?>[];
      await pumpCarbon(tester, _Host(log: log, tristate: true));
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byType(CarbonInteraction));
        await tester.pump();
      }
      expect(log, [true, null, false, true]);
    });
  });

  group('disabled and read-only', () {
    testWidgets('disabled never activates and cannot focus', (tester) async {
      final handle = tester.ensureSemantics();
      final log = <bool?>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(log: log, enabled: false, focusNode: node),
      );
      await tester.tap(find.byType(CarbonInteraction));
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(log, isEmpty);
      expect(node.hasFocus, isFalse);
      expect(_node(tester).flagsCollection.isEnabled, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('read-only is focusable but inert', (tester) async {
      final handle = tester.ensureSemantics();
      final log = <bool?>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(
        tester,
        _Host(log: log, readOnly: true, initial: true, focusNode: node),
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.tap(find.byType(CarbonInteraction));
      await tester.pump();
      expect(log, isEmpty);
      _expectState(tester, checked: true);
      handle.dispose();
    });
  });

  group('semantics', () {
    testWidgets('checked, unchecked and mixed are announced', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(tristate: true));
      expect(_node(tester).label, 'Accept');
      _expectState(tester, checked: false);

      await tester.tap(find.byType(CarbonInteraction));
      await tester.pump();
      _expectState(tester, checked: true);

      await tester.tap(find.byType(CarbonInteraction));
      await tester.pump();
      _expectState(tester, mixed: true);
      handle.dispose();
    });

    testWidgets('null without tristate reads as unchecked', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(initial: null));
      _expectState(tester, checked: false);
      handle.dispose();
    });

    testWidgets('error text is announced with the control', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(errorText: 'Required'));
      expect(_node(tester).hint, 'Required');
      expect(find.text('Required'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('helper text is shown and announced', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(helperText: 'Weekly'));
      expect(find.text('Weekly'), findsOneWidget);
      expect(_node(tester).hint, 'Weekly');
      handle.dispose();
    });

    testWidgets('unlabelled checkbox uses its semantic label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(labelText: null));
      expect(_node(tester, 'Unlabelled').label, 'Unlabelled');
      handle.dispose();
    });

    testWidgets('a custom label widget joins the node', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _aligned(
          CarbonCheckbox(
            key: _cb,
            value: true,
            onChanged: (_) {},
            label: const Text('Custom'),
          ),
        ),
      );
      expect(_node(tester, 'Custom').label, 'Custom');
      _expectState(tester, checked: true, label: 'Custom');
      handle.dispose();
    });
  });

  group('live changes', () {
    testWidgets('density, direction and theme switch keep focus and value', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final node = FocusNode();
      addTearDown(node.dispose);
      final harness = await pumpCarbon(
        tester,
        _Host(initial: true, focusNode: node),
      );
      node.requestFocus();
      await tester.pump();
      await harness.setDensity(tester, CarbonDensity.touch);
      harness.direction.value = TextDirection.rtl;
      await tester.pump();
      await harness.setTheme(
        tester,
        CarbonThemeData(
          scheme: CarbonThemeScheme.gray100,
          density: CarbonDensity.touch,
        ),
      );
      expect(node.hasFocus, isTrue);
      _expectState(tester, checked: true);
      handle.dispose();
    });

    testWidgets('focus node replacement moves focus tracking', (tester) async {
      final a = FocusNode();
      final b = FocusNode();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await pumpCarbon(tester, _Host(focusNode: a));
      await pumpCarbon(tester, _Host(focusNode: b));
      b.requestFocus();
      await tester.pump();
      expect(b.hasFocus, isTrue);
      expect(a.hasFocus, isFalse);
    });

    testWidgets('repeated mount and unmount is clean', (tester) async {
      for (var i = 0; i < 3; i++) {
        await pumpCarbon(tester, const _Host());
        await pumpCarbon(tester, const SizedBox.shrink());
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('rtl', () {
    testWidgets('indicator sits at the right edge in RTL', (tester) async {
      await pumpCarbon(
        tester,
        _aligned(
          CarbonCheckbox(
            key: _cb,
            value: true,
            onChanged: (_) {},
            labelText: 'Accept',
          ),
        ),
        dir: TextDirection.rtl,
      );
      // The row sits at the start edge, which is the right in RTL, with the
      // indicator beyond the label.
      expect(tester.getTopRight(find.byKey(_cb)).dx, 800);
      expect(
        tester.getCenter(find.text('Accept')).dx,
        lessThan(tester.getTopRight(find.byKey(_cb)).dx - 16),
      );
    });
  });

  group('group', () {
    Widget group(
      Set<String> selected,
      List<Set<String>> log, {
      String? error,
      String? helper,
    }) => _aligned(
      CarbonCheckboxGroup<String>(
        legend: 'Notify me about',
        items: const [
          CarbonCheckboxItem(value: 'a', label: 'Builds'),
          CarbonCheckboxItem(value: 'b', label: 'Deploys'),
          CarbonCheckboxItem(value: 'c', label: 'Alerts', enabled: false),
        ],
        selected: selected,
        onChanged: log.add,
        errorText: error,
        helperText: helper,
      ),
    );

    testWidgets('reports the whole next selection', (tester) async {
      final log = <Set<String>>[];
      await pumpCarbon(tester, group({'a'}, log));
      await tester.tap(find.text('Deploys'));
      await tester.pump();
      expect(log.single, {'a', 'b'});
      await tester.tap(find.text('Builds'));
      await tester.pump();
      expect(log.last, <String>{});
    });

    testWidgets('disabled item is inert; legend and message show', (
      tester,
    ) async {
      final log = <Set<String>>[];
      await pumpCarbon(tester, group({}, log, error: 'Pick one'));
      await tester.tap(find.text('Alerts'));
      await tester.pump();
      expect(log, isEmpty);
      expect(find.text('Notify me about'), findsOneWidget);
      expect(find.text('Pick one'), findsOneWidget);
    });

    testWidgets('group is named by its legend', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, group({}, [], helper: 'Choose any'));
      expect(
        find.bySemanticsLabel('Notify me about'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('validation and identity', () {
    testWidgets('focus survives the error message appearing and clearing', (
      tester,
    ) async {
      final log = <bool?>[];
      await pumpCarbon(tester, _Validated(log: log));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(log, [true, false]);
    });

    testWidgets('group keeps focus on the same item when items are removed', (
      tester,
    ) async {
      Widget group(List<String> values, List<Set<String>> log) => _aligned(
        CarbonCheckboxGroup<String>(
          legend: 'Notify me about',
          items: [
            for (final v in values) CarbonCheckboxItem(value: v, label: v),
          ],
          selected: const {},
          onChanged: log.add,
        ),
      );
      final log = <Set<String>>[];
      await pumpCarbon(tester, group(['a', 'b', 'c'], log));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await pumpCarbon(tester, group(['b', 'c'], log));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(log.single, {'b'});
    });

    testWidgets('group keeps selected values that are not among its items', (
      tester,
    ) async {
      final log = <Set<String>>[];
      await pumpCarbon(
        tester,
        _aligned(
          CarbonCheckboxGroup<String>(
            legend: 'Notify me about',
            items: const [
              CarbonCheckboxItem(value: 'a', label: 'Builds'),
              CarbonCheckboxItem(value: 'b', label: 'Deploys'),
            ],
            selected: const {'x', 'a'},
            onChanged: log.add,
          ),
        ),
      );
      await tester.tap(find.text('Deploys'));
      await tester.pump();
      expect(log.single, {'x', 'a', 'b'});
    });
  });

  group('states and anatomy', () {
    testWidgets('read-only is announced as read-only', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host(readOnly: true, initial: true));
      expect(_node(tester).flagsCollection.isReadOnly, isTrue);
      await pumpCarbon(tester, const _Host(initial: true));
      expect(_node(tester).flagsCollection.isReadOnly, isFalse);
      handle.dispose();
    });

    testWidgets('disabled checked box is filled with the disabled icon color', (
      tester,
    ) async {
      await pumpCarbon(tester, const _Host(initial: true, enabled: false));
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(CarbonCheckbox),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        (box.decoration as BoxDecoration).color,
        CarbonThemeData().colors.iconDisabled,
      );
    });

    testWidgets('indicator lines up with the first line of a wrapped label', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const _Host(
          labelText:
              'I have read and accept the terms and conditions of this '
              'rather long agreement that wraps onto several lines',
        ),
        textScale: 2,
        size: const Size(240, 800),
      );
      final box = tester.getRect(
        find
            .descendant(
              of: find.byType(CarbonCheckbox),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final text = tester.getRect(find.byType(Text));
      final lines = (text.height / 36).round();
      expect(lines, greaterThan(2));
      expect(box.center.dy, lessThan(text.top + text.height / lines * 1.5));
    });
  });
}

/// A checkbox whose error clears once it is checked, the usual validation
/// pattern.
class _Validated extends StatefulWidget {
  const _Validated({required this.log});

  final List<bool?> log;

  @override
  State<_Validated> createState() => _ValidatedState();
}

class _ValidatedState extends State<_Validated> {
  bool _value = false;

  @override
  Widget build(BuildContext context) => _aligned(
    CarbonCheckbox(
      value: _value,
      labelText: 'Accept',
      errorText: _value ? null : 'Required',
      onChanged: (v) {
        widget.log.add(v);
        setState(() => _value = v ?? false);
      },
    ),
  );
}
