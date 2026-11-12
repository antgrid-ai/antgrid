import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:carbon_flutter/src/components/option_listbox.dart';
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

Finder get _list => find.byType(CarbonOptionListbox<String>);
Finder _row(String label) =>
    find.descendant(of: _list, matching: find.text(label));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _settle(tester);
}

class _Host extends StatefulWidget {
  const _Host({
    this.options = _options,
    this.focusNode,
    this.onChanged,
    this.dropdown = false,
    this.loading = false,
    this.listError,
  });

  final List<CarbonOption<String>> options;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final bool dropdown;
  final bool loading;
  final String? listError;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? value;

  void _changed(String v) {
    widget.onChanged?.call(v);
    setState(() => value = v);
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topStart,
    child: SizedBox(
      width: 300,
      child: widget.dropdown
          ? CarbonDropdown<String>(
              key: _select,
              label: 'Mode',
              options: widget.options,
              value: value,
              focusNode: widget.focusNode,
              loading: widget.loading,
              listErrorText: widget.listError,
              onChanged: _changed,
            )
          : CarbonSelect<String>(
              key: _select,
              label: 'Mode',
              options: widget.options,
              value: value,
              focusNode: widget.focusNode,
              onChanged: _changed,
            ),
    ),
  );
}

void main() {
  group('highlight identity', () {
    testWidgets('follows its option when the list is replaced while open', (
      tester,
    ) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(focusNode: focus, onChanged: changes.add),
      );
      focus.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      // Alpha is highlighted first, Bravo is disabled, so Down lands on
      // Charlie.
      await pumpCarbon(
        tester,
        _Host(
          focusNode: focus,
          onChanged: changes.add,
          options: const [
            CarbonOption(value: 'a', label: 'Alpha'),
            CarbonOption(value: 'x', label: 'Aardvark'),
            CarbonOption(value: 'b', label: 'Bravo', enabled: false),
            CarbonOption(value: 'c', label: 'Charlie'),
            CarbonOption(value: 'd', label: 'Delta'),
          ],
        ),
      );
      await _settle(tester);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, ['c']);
    });
  });

  group('focus node replacement', () {
    testWidgets('moves focus to the new node while the list is open', (
      tester,
    ) async {
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(focusNode: first, onChanged: changes.add),
      );
      first.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      expect(_list, findsOneWidget);

      await pumpCarbon(
        tester,
        _Host(focusNode: second, onChanged: changes.add),
      );
      await _settle(tester);
      await _settle(tester);
      expect(second.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(changes, isNotEmpty);
    });
  });

  group('semantics', () {
    testWidgets('the keyboard highlight is exposed as a focused row', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpCarbon(tester, _Host(focusNode: focus));
      focus.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      final charlie = tester
          .getSemantics(
            find
                .ancestor(of: _row('Charlie'), matching: find.byType(Semantics))
                .first,
          )
          .getSemanticsData();
      expect(charlie.flagsCollection.isFocused.name, 'isTrue');
      final delta = tester
          .getSemantics(
            find
                .ancestor(of: _row('Delta'), matching: find.byType(Semantics))
                .first,
          )
          .getSemanticsData();
      expect(delta.flagsCollection.isFocused.name, isNot('isTrue'));
      handle.dispose();
    });
  });

  group('list status rows', () {
    testWidgets('a long list still shows its error row', (tester) async {
      final many = [
        for (var i = 0; i < 20; i++) CarbonOption(value: '$i', label: 'Item $i'),
      ];
      await pumpCarbon(
        tester,
        _Host(
          dropdown: true,
          options: many,
          listError: 'Could not load',
        ),
      );
      await tester.tap(find.byKey(_select));
      await _settle(tester);
      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('Item 0'), findsOneWidget);
    });

    testWidgets('keyboard reveal accounts for the status row', (tester) async {
      final many = [
        for (var i = 0; i < 20; i++) CarbonOption(value: '$i', label: 'Item $i'),
      ];
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpCarbon(
        tester,
        _Host(dropdown: true, options: many, loading: true, focusNode: focus),
      );
      focus.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.end);
      await tester.pump();
      expect(_row('Item 19'), findsOneWidget);
    });
  });

  group('layers and states', () {
    testWidgets('a field on the deepest layer lists with that layer fill', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        const CarbonLayer(level: 3, child: _Host()),
      );
      await tester.tap(find.byKey(_select));
      await _settle(tester);
      final theme = CarbonTheme.of(tester.element(find.byKey(_select)));
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(of: _list, matching: find.byType(DecoratedBox))
            .first,
      );
      expect((box.decoration as BoxDecoration).color, theme.field(3));
    });

    testWidgets('resting options use the secondary text color', (tester) async {
      await pumpCarbon(tester, const _Host());
      await tester.tap(find.byKey(_select));
      await _settle(tester);
      final theme = CarbonTheme.of(tester.element(find.byKey(_select)));
      final text = tester.widget<Text>(_row('Delta'));
      expect(text.style!.color, theme.colors.textSecondary);
    });

    testWidgets('an unavailable value uses the localized label', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        CarbonSelect<String>(
          options: const [],
          value: 'zzz',
          onChanged: (_) {},
        ),
      );
      expect(
        find.text(const CarbonLocalizations().unavailableValue),
        findsOneWidget,
      );
      await pumpCarbon(
        tester,
        CarbonSelect<String>(
          options: const [],
          value: 'zzz',
          unavailableLabel: 'Gone',
          onChanged: (_) {},
        ),
      );
      expect(find.text('Gone'), findsOneWidget);
    });
  });
}
