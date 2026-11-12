import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _host(Widget child, {double width = 320}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Finder get _box => find.byType(CarbonFieldBox);
Finder get _editable => find.byType(EditableText);
Finder get _clear => find.bySemanticsLabel('Clear search');

EditableText _editableWidget(WidgetTester tester) =>
    tester.widget<EditableText>(_editable);

void main() {
  group('sizing', () {
    testWidgets('height follows density and grows with text scale', (
      tester,
    ) async {
      final harness = await pumpCarbon(tester, _host(const CarbonSearch()));
      expect(tester.getSize(_box).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(_box).height, 48);
      harness.textScale.value = 2;
      await tester.pump();
      expect(tester.getSize(_box).height, greaterThanOrEqualTo(48));
    });

    testWidgets('explicit sizes; touch keeps its floor', (tester) async {
      for (final (size, expected) in [
        (CarbonFieldSize.small, 32.0),
        (CarbonFieldSize.medium, 40.0),
        (CarbonFieldSize.large, 48.0),
      ]) {
        await pumpCarbon(tester, _host(CarbonSearch(size: size)));
        expect(tester.getSize(_box).height, expected, reason: '$size');
      }
      await pumpCarbon(
        tester,
        _host(const CarbonSearch(size: CarbonFieldSize.small)),
        theme: CarbonThemeData(density: CarbonDensity.touch),
      );
      expect(tester.getSize(_box).height, 48);
    });

    testWidgets('clear target is 32 compact and 48 touch', (tester) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      final harness = await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller)),
      );
      final action = find.byType(CarbonFieldAction);
      expect(tester.getSize(action), const Size(32, 32));
      expect(tester.getSize(_box).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(action), const Size(48, 48));
      expect(tester.getSize(_box).height, 48);
    });
  });

  group('labelling', () {
    testWidgets('defaults to the localized Search for name and placeholder', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _host(const CarbonSearch()));
      expect(find.text('Search'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(TextField)).label,
        contains('Search'),
      );
      handle.dispose();
    });

    testWidgets('semanticLabel and placeholder override the defaults', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(
          const CarbonSearch(
            semanticLabel: 'Search files',
            placeholder: 'Find a file',
          ),
        ),
      );
      expect(find.text('Find a file'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(TextField)).label,
        contains('Search files'),
      );
      handle.dispose();
    });

    testWidgets('translated strings are used', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        CarbonLocalizationsScope(
          messages: const CarbonLocalizations(
            search: 'Rechercher',
            clearSearch: 'Effacer la recherche',
          ),
          child: _host(
            CarbonSearch(controller: TextEditingController(text: 'x')),
          ),
        ),
      );
      expect(find.text('Rechercher'), findsOneWidget);
      expect(find.bySemanticsLabel('Effacer la recherche'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('leading search icon is decorative', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSearch()));
      expect(find.byType(CarbonIcon), findsOneWidget);
    });
  });

  group('typing and submission', () {
    testWidgets('onChanged and onSubmitted fire with the query', (
      tester,
    ) async {
      final changes = <String>[];
      final submitted = <String>[];
      await pumpCarbon(
        tester,
        _host(CarbonSearch(onChanged: changes.add, onSubmitted: submitted.add)),
      );
      await tester.enterText(_editable, 'term');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(changes, <String>['term']);
      expect(submitted, <String>['term']);
      expect(_editableWidget(tester).textInputAction, TextInputAction.search);
    });

    testWidgets('does not debounce or fetch: every change is delivered', (
      tester,
    ) async {
      final changes = <String>[];
      await pumpCarbon(tester, _host(CarbonSearch(onChanged: changes.add)));
      for (final text in ['a', 'ab', 'abc']) {
        await tester.enterText(_editable, text);
        await tester.pump();
      }
      expect(changes, <String>['a', 'ab', 'abc']);
    });
  });

  group('clear action', () {
    testWidgets('appears with text, clears only this field, keeps focus', (
      tester,
    ) async {
      final controller = TextEditingController();
      final other = TextEditingController(text: 'untouched');
      addTearDown(controller.dispose);
      addTearDown(other.dispose);
      final changes = <String>[];
      var cleared = 0;
      await pumpCarbon(
        tester,
        _host(
          Column(
            children: <Widget>[
              CarbonSearch(
                controller: controller,
                onChanged: changes.add,
                onCleared: () => cleared++,
              ),
              CarbonTextInput(controller: other, label: 'Other'),
            ],
          ),
        ),
      );
      expect(_clear, findsNothing);
      await tester.enterText(_editable.first, 'abc');
      await tester.pump();
      expect(_clear, findsOneWidget);
      await tester.tap(_clear);
      await tester.pump();
      expect(controller.text, '');
      expect(other.text, 'untouched');
      expect(changes.last, '');
      expect(cleared, 1);
      expect(_clear, findsNothing);
      expect(tester.widgetList<EditableText>(_editable).first.focusNode.hasFocus, isTrue);
    });

    testWidgets('is a keyboard-reachable button', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(tester, _host(CarbonSearch(controller: controller)));
      await tester.tap(_editable);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        tester.getSemantics(_clear),
        matchesSemantics(
          label: 'Clear search',
          isButton: true,
          isEnabled: true,
          isFocusable: true,
          isFocused: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.text, '');
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
      handle.dispose();
    });

    testWidgets('hidden when disabled or read-only', (tester) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller, readOnly: true)),
      );
      expect(find.byType(CarbonFieldAction), findsNothing);
      await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller, enabled: false)),
      );
      expect(find.byType(CarbonFieldAction), findsNothing);
    });

    testWidgets('sits at the start edge in RTL, search icon at the start', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller)),
        dir: TextDirection.rtl,
      );
      final box = tester.getRect(_box);
      expect(tester.getRect(find.byType(CarbonFieldAction)).left, box.left);
      expect(tester.getRect(find.byType(CarbonIcon).first).right, greaterThan(box.center.dx));
    });
  });

  group('Escape', () {
    testWidgets('clears non-empty text, keeps focus and is consumed', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var dismissed = 0;
      await pumpCarbon(
        tester,
        _host(
          Actions(
            actions: <Type, Action<Intent>>{
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  dismissed++;
                  return null;
                },
              ),
            },
            child: CarbonSearch(controller: controller),
          ),
        ),
      );
      await tester.enterText(_editable, 'abc');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.text, '');
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
      expect(dismissed, 0);
    });

    testWidgets('is not consumed when already empty', (tester) async {
      var dismissed = 0;
      await pumpCarbon(
        tester,
        _host(
          Actions(
            actions: <Type, Action<Intent>>{
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  dismissed++;
                  return null;
                },
              ),
            },
            child: const CarbonSearch(),
          ),
        ),
      );
      await tester.tap(_editable);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(dismissed, 1);
    });

    testWidgets('read-only does not clear and lets Escape through', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      var dismissed = 0;
      await pumpCarbon(
        tester,
        _host(
          Actions(
            actions: <Type, Action<Intent>>{
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  dismissed++;
                  return null;
                },
              ),
            },
            child: CarbonSearch(controller: controller, readOnly: true),
          ),
        ),
      );
      await tester.tap(_editable);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.text, 'abc');
      expect(dismissed, 1);
    });

    testWidgets('does not discard other fields on Escape', (tester) async {
      final other = TextEditingController(text: 'keep');
      addTearDown(other.dispose);
      await pumpCarbon(
        tester,
        _host(
          Column(
            children: <Widget>[
              const CarbonSearch(),
              CarbonTextInput(controller: other, label: 'Other'),
            ],
          ),
        ),
      );
      await tester.tap(_editable.first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(other.text, 'keep');
    });
  });

  group('busy, error and count', () {
    testWidgets('busy swaps the icon for a same-size spinner', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _host(const CarbonSearch()));
      final iconSize = tester.getSize(find.byType(CarbonIcon));
      expect(find.byType(CarbonSpinner), findsNothing);
      await pumpCarbon(tester, _host(const CarbonSearch(busy: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CarbonSpinner), findsOneWidget);
      expect(find.byType(CarbonIcon), findsNothing);
      expect(tester.getSize(find.byType(CarbonSpinner)), iconSize);
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
      expect(tester.getSize(_box).height, 32);
      handle.dispose();
    });

    testWidgets('busy keeps typing and focus available', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller, busy: true)),
      );
      await tester.enterText(_editable, 'abc');
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.text, 'abc');
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('error shows text and icon and is on the field', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(const CarbonSearch(errorText: 'Search is unavailable')),
      );
      expect(find.text('Search is unavailable'), findsOneWidget);
      expect(find.byType(CarbonIcon), findsNWidgets(2));
      expect(
        tester.getSemantics(find.byType(TextField)).hint,
        contains('Search is unavailable'),
      );
      handle.dispose();
    });

    testWidgets('result count is shown, localized and a polite live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _host(const CarbonSearch(resultCount: 3)));
      expect(find.text('3 results'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('3 results')),
        matchesSemantics(label: '3 results', isLiveRegion: true),
      );
      await pumpCarbon(tester, _host(const CarbonSearch(resultCount: 1)));
      expect(find.text('1 result'), findsOneWidget);
      await pumpCarbon(tester, _host(const CarbonSearch()));
      expect(find.text('1 result'), findsNothing);
      handle.dispose();
    });

    testWidgets('error replaces the result count', (tester) async {
      await pumpCarbon(
        tester,
        _host(const CarbonSearch(resultCount: 3, errorText: 'Failed')),
      );
      expect(find.text('3 results'), findsNothing);
      expect(find.text('Failed'), findsOneWidget);
    });

    testWidgets('zero results are announced too', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSearch(resultCount: 0)));
      expect(find.text('0 results'), findsOneWidget);
    });
  });

  group('disabled and read-only', () {
    testWidgets('disabled is inert', (tester) async {
      await pumpCarbon(tester, _host(const CarbonSearch(enabled: false)));
      await tester.tap(_box, warnIfMissed: false);
      await tester.pump();
      expect(_editableWidget(tester).focusNode.hasFocus, isFalse);
    });

    testWidgets('read-only keeps focus and the text', (tester) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller, readOnly: true)),
      );
      await tester.tap(_editable);
      await tester.pump();
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
      expect(_editableWidget(tester).readOnly, isTrue);
    });
  });

  group('ownership and live changes', () {
    testWidgets('supplied controller and node outlive the widget', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'keep');
      final focus = FocusNode();
      await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller, focusNode: focus)),
      );
      await tester.pumpWidget(const SizedBox());
      controller.text = 'usable';
      focus.requestFocus();
      controller.dispose();
      focus.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets('controller replacement moves the clear affordance', (
      tester,
    ) async {
      final a = TextEditingController(text: 'one');
      final b = TextEditingController();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await pumpCarbon(tester, _host(CarbonSearch(controller: a)));
      expect(find.byType(CarbonFieldAction), findsOneWidget);
      await pumpCarbon(tester, _host(CarbonSearch(controller: b)));
      expect(find.byType(CarbonFieldAction), findsNothing);
      a.text = 'detached change';
      await tester.pump();
      expect(find.byType(CarbonFieldAction), findsNothing);
      b.text = 'two';
      await tester.pump();
      expect(find.byType(CarbonFieldAction), findsOneWidget);
    });

    testWidgets('owned to supplied and back is clean', (tester) async {
      final supplied = TextEditingController(text: 'external');
      addTearDown(supplied.dispose);
      await pumpCarbon(tester, _host(const CarbonSearch()));
      await tester.enterText(_editable, 'typed');
      await pumpCarbon(tester, _host(CarbonSearch(controller: supplied)));
      await tester.pump();
      expect(find.text('external'), findsOneWidget);
      await pumpCarbon(tester, _host(const CarbonSearch()));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('theme, density and direction switches keep text and focus', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      final harness = await pumpCarbon(
        tester,
        _host(CarbonSearch(controller: controller)),
      );
      await tester.tap(_editable);
      await tester.pump();
      controller.selection = const TextSelection(baseOffset: 1, extentOffset: 5);
      await tester.pump();
      await harness.setDensity(tester, CarbonDensity.touch);
      await harness.setTheme(
        tester,
        CarbonThemeData(
          scheme: CarbonThemeScheme.gray100,
          density: CarbonDensity.touch,
        ),
      );
      harness.direction.value = TextDirection.rtl;
      await tester.pump();
      expect(controller.text, 'hello world');
      expect(controller.selection.start, 1);
      expect(controller.selection.end, 5);
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('repeated mount and unmount is clean', (tester) async {
      for (var i = 0; i < 5; i++) {
        await pumpCarbon(
          tester,
          _host(CarbonSearch(key: ValueKey<int>(i), busy: i.isOdd)),
        );
        await tester.enterText(_editable, 'x$i');
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  });
}
