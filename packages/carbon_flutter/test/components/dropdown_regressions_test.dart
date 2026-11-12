import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:carbon_flutter/src/components/option_listbox.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _combo = Key('combo');

const List<CarbonOption<String>> _options = [
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'd', label: 'Delta'),
  CarbonOption(value: 'x', label: 'Delta-2'),
];

Finder get _list => find.byType(CarbonOptionListbox<String>);
Finder get _input => find.byType(EditableText);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// A stateless layer between the host and the combo, as in any custom row.
class _Wrapper extends StatelessWidget {
  const _Wrapper({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _Host extends StatefulWidget {
  const _Host({
    this.controller,
    this.initial,
    this.options = _options,
    this.onChanged,
    this.onInput,
    this.remoteSearch = false,
  });

  final TextEditingController? controller;
  final String? initial;
  final List<CarbonOption<String>> options;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onInput;
  final bool remoteSearch;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String? value = widget.initial;
  bool hasText = false;

  void setValue(String? next) => setState(() => value = next);

  void _onText() {
    final next = widget.controller!.text.isNotEmpty;
    if (next != hasText) setState(() => hasText = next);
  }

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onText);
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onText);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topStart,
    child: SizedBox(
      width: 300,
      child: _Wrapper(
        child: CarbonComboBox<String>(
          key: _combo,
          label: 'Branch',
          options: widget.options,
          value: value,
          controller: widget.controller,
          filter: widget.remoteSearch ? (o, q) => true : null,
          onInputChanged: widget.onInput,
          onChanged: (v) {
            widget.onChanged?.call(v);
            setState(() => value = v);
          },
        ),
      ),
    ),
  );
}

_HostState _hostState(WidgetTester tester) =>
    tester.state<_HostState>(find.byType(_Host));

void main() {
  group('supplied controller', () {
    testWidgets('host listeners are not notified during build', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpCarbon(tester, _Host(controller: controller, initial: 'a'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(controller.text, 'Alpha');

      _hostState(tester).setValue('d');
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(controller.text, 'Delta');

      _hostState(tester).setValue(null);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(controller.text, '');
    });

    testWidgets('text held at mount is kept as the draft', (tester) async {
      final controller = TextEditingController(text: 'feat/');
      addTearDown(controller.dispose);
      await pumpCarbon(tester, _Host(controller: controller));
      await _settle(tester);
      expect(controller.text, 'feat/');
    });

    testWidgets('a host write while unfocused is not typing', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final input = <String>[];
      await pumpCarbon(
        tester,
        _Host(controller: controller, initial: 'a', onInput: input.add),
      );
      await _settle(tester);
      controller.clear();
      await _settle(tester);
      expect(input, isEmpty);

      _hostState(tester).setValue('d');
      await _settle(tester);
      await _settle(tester);
      expect(controller.text, 'Delta');
      expect(input, isEmpty);
    });
  });

  group('highlight', () {
    testWidgets('a host-filtered answer gets its first match highlighted', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(options: const [], remoteSearch: true, onChanged: changes.add),
      );
      await tester.tap(find.byKey(_combo));
      await _settle(tester);
      await tester.enterText(_input, 'de');
      await _settle(tester);
      await pumpCarbon(
        tester,
        _Host(options: _options.sublist(1), remoteSearch: true,
            onChanged: changes.add),
      );
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(changes, ['d']);
    });

    testWidgets('follows its option when the answer is re-ordered', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _Host(remoteSearch: true, onChanged: changes.add),
      );
      await tester.tap(find.byKey(_combo));
      await _settle(tester);
      await tester.enterText(_input, 'a');
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      // Delta-2 is highlighted; a new answer puts a row ahead of it.
      await pumpCarbon(
        tester,
        _Host(
          remoteSearch: true,
          onChanged: changes.add,
          options: [
            const CarbonOption(value: 'n', label: 'New'),
            ..._options,
          ],
        ),
      );
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(changes, ['x']);
    });
  });

  group('keyboard', () {
    testWidgets('Shift+Down stays with the text field', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpCarbon(tester, _Host(controller: controller));
      await tester.tap(find.byKey(_combo));
      await _settle(tester);
      await tester.enterText(_input, 'alpine');
      await _settle(tester);
      controller.selection = const TextSelection.collapsed(offset: 0);
      await _settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _settle(tester);
      expect(controller.selection.isCollapsed, isFalse);
    });
  });

  group('semantics', () {
    testWidgets('the expand action opens the list', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, const _Host());
      expect(_list, findsNothing);
      final node = tester.getSemantics(find.byKey(_combo));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.expand),
        isTrue,
      );
      tester.renderObject(find.byKey(_combo)).owner!.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.expand,
      );
      await _settle(tester);
      expect(_list, findsOneWidget);
      handle.dispose();
    });
  });
}
