import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const List<CarbonOption<String>> _options = [
  CarbonOption(value: 'nj', label: 'New Jersey'),
  CarbonOption(value: 'ny', label: 'New York'),
  CarbonOption(value: 'oh', label: 'Ohio'),
];

Future<void> _type(
  WidgetTester tester,
  LogicalKeyboardKey key,
  String character,
) async {
  await tester.sendKeyEvent(key, character: character);
  await tester.pump();
}

void main() {
  group('typeahead treats Space as a search character', () {
    Future<void> run(
      WidgetTester tester,
      Widget Function(FocusNode, List<String>) build,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final changes = <String>[];
      await pumpCarbon(tester, build(node, changes));
      node.requestFocus();
      await tester.pump();
      await _type(tester, LogicalKeyboardKey.keyN, 'n');
      await _type(tester, LogicalKeyboardKey.keyE, 'e');
      await _type(tester, LogicalKeyboardKey.keyW, 'w');
      await _type(tester, LogicalKeyboardKey.space, ' ');
      await _type(tester, LogicalKeyboardKey.keyY, 'y');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(changes, ['ny']);
    }

    testWidgets('select', (tester) async {
      await run(
        tester,
        (node, changes) => CarbonSelect<String>(
          options: _options,
          value: null,
          focusNode: node,
          onChanged: changes.add,
        ),
      );
    });

    testWidgets('dropdown', (tester) async {
      await run(
        tester,
        (node, changes) => CarbonDropdown<String>(
          options: _options,
          value: null,
          focusNode: node,
          onChanged: changes.add,
        ),
      );
    });
  });

  group('checkbox custom label', () {
    Future<SemanticsNode> node(WidgetTester tester, Widget box) async {
      await pumpCarbon(tester, Align(alignment: Alignment.topLeft, child: box));
      return find.semantics
          .byFlag(SemanticsFlag.hasCheckedState)
          .evaluate()
          .single;
    }

    testWidgets('a text name is read once, not twice', (tester) async {
      final handle = tester.ensureSemantics();
      final n = await node(
        tester,
        CarbonCheckbox(
          value: false,
          onChanged: (_) {},
          label: const Text('Email me updates'),
          labelText: 'Email me updates',
        ),
      );
      expect(n.label, 'Email me updates');
      handle.dispose();
    });

    testWidgets('a semanticLabel is not followed by the visible label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final n = await node(
        tester,
        CarbonCheckbox(
          value: false,
          onChanged: (_) {},
          label: const Text('Updates'),
          semanticLabel: 'Email me product updates',
        ),
      );
      expect(n.label, 'Email me product updates');
      handle.dispose();
    });

    testWidgets('a custom label alone still names the box', (tester) async {
      final handle = tester.ensureSemantics();
      final n = await node(
        tester,
        CarbonCheckbox(
          value: false,
          onChanged: (_) {},
          label: const Text('Updates'),
        ),
      );
      expect(n.label, 'Updates');
      handle.dispose();
    });

    testWidgets('a link in the label stays a separate reachable node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final log = <String>[];
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: CarbonCheckbox(
            value: false,
            onChanged: (v) => log.add('cb:$v'),
            labelText: 'I agree to the terms',
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('I agree to the '),
                Semantics(
                  link: true,
                  onTap: () => log.add('link'),
                  child: const Text('terms'),
                ),
              ],
            ),
          ),
        ),
      );
      final link = find.semantics.byLabel('terms');
      expect(link, findsOneWidget);
      expect(link.evaluate().single.flagsCollection.isLink, isTrue);
      final box = find.semantics.byFlag(SemanticsFlag.hasCheckedState);
      expect(box.evaluate().single.flagsCollection.isLink, isFalse);
      handle.dispose();
    });
  });
}
