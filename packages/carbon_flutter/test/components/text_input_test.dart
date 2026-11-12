import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _input = Key('input');

Widget _host(Widget child, {double width = 320}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Finder get _box => find.byType(CarbonFieldBox);
Finder get _editable => find.byType(EditableText);
Finder _action(String label) => find.bySemanticsLabel(label);

EditableText _editableWidget(WidgetTester tester) =>
    tester.widget<EditableText>(_editable);

void main() {
  group('sizing', () {
    testWidgets('autocorrect and suggestions can be turned off; password '
        'never has them', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          const Column(
            children: [
              CarbonTextInput(label: 'Default'),
              CarbonTextInput(
                label: 'Cron',
                autocorrect: false,
                enableSuggestions: false,
              ),
              CarbonTextInput(
                label: 'Secret',
                variant: CarbonTextInputVariant.password,
              ),
            ],
          ),
        ),
      );
      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(
        [for (final f in fields) (f.autocorrect, f.enableSuggestions)],
        [(true, true), (false, false), (false, false)],
      );
    });

    testWidgets('field height follows density and grows with text scale', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Name')),
      );
      expect(tester.getSize(_box).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(_box).height, 48);
      harness.textScale.value = 2;
      await tester.pump();
      expect(tester.getSize(_box).height, greaterThanOrEqualTo(48));
    });

    testWidgets('explicit sizes, touch floor holds', (tester) async {
      for (final (size, expected) in [
        (CarbonFieldSize.small, 32.0),
        (CarbonFieldSize.medium, 40.0),
        (CarbonFieldSize.large, 48.0),
      ]) {
        await pumpCarbon(tester, _host(CarbonTextInput(size: size)));
        expect(tester.getSize(_box).height, expected, reason: '$size');
      }
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(size: CarbonFieldSize.small)),
        theme: CarbonThemeData(density: CarbonDensity.touch),
      );
      expect(tester.getSize(_box).height, 48);
    });

    testWidgets('enlarged text wraps the label and grows the column', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            label:
                'A very long label that has to wrap when the text is large',
            helperText: 'And a long helper that also has to wrap around',
          ),
          width: 200,
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('editing', () {
    testWidgets('typing reaches the controller and onChanged', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Name',
            onChanged: changes.add,
          ),
        ),
      );
      await tester.enterText(_editable, 'abc');
      expect(controller.text, 'abc');
      expect(changes, <String>['abc']);
    });

    testWidgets('onSubmitted and onEditingComplete fire on done', (
      tester,
    ) async {
      final submitted = <String>[];
      var completed = 0;
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            label: 'Name',
            onSubmitted: submitted.add,
            onEditingComplete: () => completed++,
          ),
        ),
      );
      await tester.enterText(_editable, 'x');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submitted, <String>['x']);
      expect(completed, 1);
    });

    testWidgets('keyboard options pass through to the editable', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            label: 'Email',
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const <String>[AutofillHints.email],
            textCapitalization: TextCapitalization.words,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.deny(RegExp('z')),
            ],
          ),
        ),
      );
      final editable = _editableWidget(tester);
      expect(editable.keyboardType, TextInputType.emailAddress);
      expect(editable.textInputAction, TextInputAction.next);
      expect(editable.autofillHints, <String>[AutofillHints.email]);
      expect(editable.textCapitalization, TextCapitalization.words);
      await tester.enterText(_editable, 'azb');
      expect(_editableWidget(tester).controller.text, 'ab');
    });

    testWidgets('tapping the field padding focuses the editable', (
      tester,
    ) async {
      await pumpCarbon(tester, _host(const CarbonTextInput(label: 'Name')));
      final rect = tester.getRect(_box);
      await tester.tapAt(rect.topLeft + const Offset(3, 3));
      await tester.pump();
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('placeholder shows while empty only', (tester) async {
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Name', placeholder: 'Ada')),
      );
      double hintOpacity() => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.text('Ada'),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity;
      expect(hintOpacity(), 1);
      await tester.enterText(_editable, 'x');
      await tester.pump(const Duration(milliseconds: 100));
      expect(hintOpacity(), 0);
    });

    testWidgets('selection and composing survive rebuilds', (tester) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(baseOffset: 2, extentOffset: 7);
      Widget tree(String helper) => _host(
        CarbonTextInput(
          controller: controller,
          label: 'Name',
          helperText: helper,
        ),
      );
      await pumpCarbon(tester, tree('a'));
      await pumpCarbon(tester, tree('b'));
      expect(controller.text, 'hello world');
      expect(controller.selection.start, 2);
      expect(controller.selection.end, 7);
    });
  });

  group('validation and semantics', () {
    testWidgets('label, required, helper and error sit on the editable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            label: 'Email',
            required: true,
            errorText: 'Enter a valid email',
            helperText: 'We never share it',
          ),
        ),
      );
      final node = tester.getSemantics(find.byType(TextField));
      expect(node.label, contains('Email'));
      expect(node.hint, contains('Required'));
      expect(node.hint, contains('Enter a valid email'));
      expect(node.hint, isNot(contains('We never share it')));
      expect(find.text('Enter a valid email'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('helper is announced when there is no error', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Name', helperText: 'As on passport')),
      );
      expect(
        tester.getSemantics(find.byType(TextField)).hint,
        contains('As on passport'),
      );
      handle.dispose();
    });

    testWidgets('semanticLabel names a field without a visible label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(semanticLabel: 'Filter by name')),
      );
      expect(
        tester.getSemantics(find.byType(TextField)).label,
        contains('Filter by name'),
      );
      handle.dispose();
    });

    testWidgets('error is text plus icon and suppressed when read-only', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Name', errorText: 'Required')),
      );
      expect(find.text('Required'), findsOneWidget);
      expect(find.byType(CarbonIcon), findsOneWidget);
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            label: 'Name',
            errorText: 'Required',
            readOnly: true,
          ),
        ),
      );
      expect(find.text('Required'), findsNothing);
      expect(tester.getSemantics(find.byType(TextField)).hint, isNot(contains('Required')));
      handle.dispose();
    });

    testWidgets('optional marker appends to the label', (tester) async {
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Nickname', showOptional: true)),
      );
      expect(find.text('Nickname (optional)'), findsOneWidget);
    });
  });

  group('clear action', () {
    testWidgets('appears with text, clears, keeps focus, fires onChanged', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final changes = <String>[];
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Name',
            clearable: true,
            onChanged: changes.add,
          ),
        ),
      );
      expect(_action('Clear'), findsNothing);
      await tester.enterText(_editable, 'abc');
      await tester.pump();
      expect(_action('Clear'), findsOneWidget);
      await tester.tap(_action('Clear'));
      await tester.pump();
      expect(controller.text, '');
      expect(changes.last, '');
      expect(_action('Clear'), findsNothing);
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('target is 32 compact and 48 touch without growing the field', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      final harness = await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Name',
            clearable: true,
          ),
        ),
      );
      final action = find.byType(CarbonFieldAction);
      expect(tester.getSize(action).width, 32);
      expect(tester.getSize(action).height, 32);
      expect(tester.getSize(_box).height, 32);
      await harness.setDensity(tester, CarbonDensity.touch);
      expect(tester.getSize(action).width, 48);
      expect(tester.getSize(action).height, 48);
      expect(tester.getSize(_box).height, 48);
    });

    testWidgets('is a keyboard-reachable button with a localized name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Name',
            clearable: true,
          ),
        ),
      );
      await tester.tap(_editable);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        tester.getSemantics(_action('Clear')),
        matchesSemantics(
          label: 'Clear',
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
      handle.dispose();
    });

    testWidgets('uses translated labels', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        CarbonLocalizationsScope(
          messages: const CarbonLocalizations(clear: 'Effacer'),
          child: _host(
            CarbonTextInput(
              controller: TextEditingController(text: 'abc'),
              clearable: true,
              label: 'Nom',
            ),
          ),
        ),
      );
      expect(_action('Effacer'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('hidden when read-only or disabled', (tester) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      for (final (readOnly, enabled) in [(true, true), (false, false)]) {
        await pumpCarbon(
          tester,
          _host(
            CarbonTextInput(
              controller: controller,
              clearable: true,
              readOnly: readOnly,
              enabled: enabled,
            ),
          ),
        );
        expect(find.byType(CarbonFieldAction), findsNothing);
      }
    });

    testWidgets('field keeps its text width logic in RTL', (tester) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Name',
            clearable: true,
            prefix: const SizedBox(key: Key('prefix'), width: 16, height: 16),
          ),
        ),
        dir: TextDirection.rtl,
      );
      final box = tester.getRect(_box);
      expect(tester.getRect(find.byType(CarbonFieldAction)).left, box.left);
      expect(tester.getRect(find.byKey(const Key('prefix'))).right, lessThan(box.right));
      expect(
        tester.getRect(find.byKey(const Key('prefix'))).right,
        greaterThan(box.center.dx),
      );
    });
  });

  group('password', () {
    testWidgets('obscures, disables suggestions, defaults autofill', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            label: 'Password',
            variant: CarbonTextInputVariant.password,
          ),
        ),
      );
      final editable = _editableWidget(tester);
      expect(editable.obscureText, isTrue);
      expect(editable.enableSuggestions, isFalse);
      expect(editable.autocorrect, isFalse);
      expect(editable.autofillHints, <String>[AutofillHints.password]);
      expect(editable.keyboardType, TextInputType.visiblePassword);
    });

    testWidgets('reveal toggles obscuring, label and keeps text and focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final controller = TextEditingController(text: 'secret');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Password',
            variant: CarbonTextInputVariant.password,
          ),
        ),
      );
      await tester.tap(_editable);
      await tester.pump();
      expect(_action('Show password'), findsOneWidget);
      await tester.tap(_action('Show password'));
      await tester.pump();
      expect(_editableWidget(tester).obscureText, isFalse);
      expect(_action('Hide password'), findsOneWidget);
      expect(controller.text, 'secret');
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
      await tester.tap(_action('Hide password'));
      await tester.pump();
      expect(_editableWidget(tester).obscureText, isTrue);
      handle.dispose();
    });

    testWidgets('reveal is a focus stop and activates by keyboard', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            label: 'Password',
            variant: CarbonTextInputVariant.password,
          ),
        ),
      );
      await tester.tap(_editable);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(_editableWidget(tester).obscureText, isFalse);
    });

    testWidgets('reveal target is 48 in touch', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            label: 'Password',
            variant: CarbonTextInputVariant.password,
          ),
        ),
        theme: CarbonThemeData(density: CarbonDensity.touch),
      );
      expect(tester.getSize(find.byType(CarbonFieldAction)), const Size(48, 48));
      expect(tester.getSize(_box).height, 48);
    });

    testWidgets('clear and reveal sit side by side', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: TextEditingController(text: 'abc'),
            label: 'Password',
            variant: CarbonTextInputVariant.password,
            clearable: true,
          ),
        ),
      );
      final actions = find.byType(CarbonFieldAction);
      expect(actions, findsNWidgets(2));
      final first = tester.getRect(actions.at(0));
      final second = tester.getRect(actions.at(1));
      expect(first.right, lessThanOrEqualTo(second.left));
      expect(second.right, tester.getRect(_box).right);
    });
  });

  group('multiline', () {
    testWidgets('is taller, wraps and accepts new lines', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Notes',
            variant: CarbonTextInputVariant.multiline,
          ),
        ),
      );
      final editable = _editableWidget(tester);
      expect(editable.minLines, 3);
      expect(editable.keyboardType, TextInputType.multiline);
      expect(tester.getSize(_box).height, greaterThan(48));
      await tester.enterText(_editable, 'a\nb');
      expect(controller.text, 'a\nb');
    });

    testWidgets('minLines and maxLines are honoured', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            variant: CarbonTextInputVariant.multiline,
            minLines: 5,
            maxLines: 8,
          ),
        ),
      );
      final editable = _editableWidget(tester);
      expect(editable.minLines, 5);
      expect(editable.maxLines, 8);
    });

    testWidgets('clear action is anchored to the top edge', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: TextEditingController(text: 'abc'),
            variant: CarbonTextInputVariant.multiline,
            clearable: true,
          ),
        ),
      );
      expect(
        tester.getRect(find.byType(CarbonFieldAction)).top,
        tester.getRect(_box).top,
      );
    });
  });

  group('maxLength and counter', () {
    testWidgets('counter tracks the length and the limit is enforced', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Code',
            maxLength: 5,
            showCounter: true,
          ),
        ),
      );
      expect(find.text('0/5'), findsOneWidget);
      await tester.enterText(_editable, 'abcdefgh');
      await tester.pump();
      expect(controller.text, 'abcde');
      expect(find.text('5/5'), findsOneWidget);
    });

    testWidgets('no counter unless asked for', (tester) async {
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Code', maxLength: 5)),
      );
      expect(find.text('0/5'), findsNothing);
    });

    testWidgets('multiline counter does not grow the field above its lines', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonTextInput(
            variant: CarbonTextInputVariant.multiline,
            maxLength: 20,
            showCounter: true,
          ),
        ),
      );
      expect(find.text('0/20'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('read-only and disabled', () {
    testWidgets('read-only focuses and selects but does not edit', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'copy me');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            controller: controller,
            label: 'Token',
            readOnly: true,
          ),
        ),
      );
      await tester.tap(_editable);
      await tester.pump();
      final editable = _editableWidget(tester);
      expect(editable.focusNode.hasFocus, isTrue);
      expect(editable.readOnly, isTrue);
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
      await tester.pump();
      expect(controller.selection.end, 4);
    });

    testWidgets('disabled is inert and unfocusable', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Name', enabled: false)),
      );
      await tester.tap(_box, warnIfMissed: false);
      await tester.pump();
      expect(_editableWidget(tester).focusNode.hasFocus, isFalse);
      expect(
        tester.getSemantics(find.byType(TextField)).flagsCollection.isEnabled,
        isNot(Tristate.isTrue),
      );
      handle.dispose();
    });
  });

  group('ownership', () {
    testWidgets('supplied controller and focus node outlive the widget', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'keep');
      final focus = FocusNode();
      await pumpCarbon(
        tester,
        _host(CarbonTextInput(controller: controller, focusNode: focus)),
      );
      await tester.pumpWidget(const SizedBox());
      controller.text = 'still usable';
      focus.requestFocus();
      controller.dispose();
      focus.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets('controller replacement moves listeners and shows new text', (
      tester,
    ) async {
      final a = TextEditingController(text: 'one');
      final b = TextEditingController();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      Widget tree(TextEditingController c) =>
          _host(CarbonTextInput(controller: c, label: 'Name', clearable: true));
      await pumpCarbon(tester, tree(a));
      expect(find.byType(CarbonFieldAction), findsOneWidget);
      await pumpCarbon(tester, tree(b));
      expect(find.text('one'), findsNothing);
      expect(find.byType(CarbonFieldAction), findsNothing);
      a.text = 'changed while detached';
      await tester.pump();
      expect(find.byType(CarbonFieldAction), findsNothing);
      b.text = 'two';
      await tester.pump();
      expect(find.byType(CarbonFieldAction), findsOneWidget);
      expect(find.text('two'), findsOneWidget);
    });

    testWidgets('owned to supplied to owned keeps what was typed', (
      tester,
    ) async {
      final supplied = TextEditingController(text: 'external');
      addTearDown(supplied.dispose);
      await pumpCarbon(tester, _host(const CarbonTextInput(label: 'Name')));
      await tester.enterText(_editable, 'typed');
      await pumpCarbon(
        tester,
        _host(CarbonTextInput(label: 'Name', controller: supplied)),
      );
      await tester.pump();
      expect(find.text('external'), findsOneWidget);
      await pumpCarbon(tester, _host(const CarbonTextInput(label: 'Name')));
      await tester.pump();
      expect(find.text('external'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('focus node replacement tracks focus', (tester) async {
      final a = FocusNode();
      final b = FocusNode();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      Widget tree(FocusNode n) => _host(CarbonTextInput(focusNode: n));
      await pumpCarbon(tester, tree(a));
      a.requestFocus();
      await tester.pump();
      expect(a.hasFocus, isTrue);
      await pumpCarbon(tester, tree(b));
      await tester.pump();
      expect(b.hasFocus, isFalse);
      b.requestFocus();
      await tester.pump();
      expect(b.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated mount and unmount is clean', (tester) async {
      for (var i = 0; i < 5; i++) {
        await pumpCarbon(
          tester,
          _host(CarbonTextInput(key: ValueKey<int>(i), label: 'Name')),
        );
        await tester.enterText(_editable, 'x$i');
      }
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  });

  group('live theme, density and direction', () {
    testWidgets('keep text, selection and focus while switching', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      final harness = await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            key: _input,
            controller: controller,
            label: 'Name',
            clearable: true,
          ),
        ),
      );
      await tester.tap(_editable);
      await tester.pump();
      controller.selection = const TextSelection(baseOffset: 1, extentOffset: 5);
      await tester.pump();
      final state = tester.state(find.byKey(_input));
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
      expect(tester.state(find.byKey(_input)), same(state));
      expect(controller.text, 'hello world');
      expect(controller.selection.start, 1);
      expect(controller.selection.end, 5);
      expect(_editableWidget(tester).focusNode.hasFocus, isTrue);
    });
  });

  group('forms', () {
    testWidgets('registers with the form so the first invalid is focused', (
      tester,
    ) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        _host(
          CarbonForm(
            controller: controller,
            children: const <Widget>[
              CarbonTextInput(label: 'First'),
              CarbonTextInput(label: 'Second', errorText: 'Bad second'),
              CarbonTextInput(label: 'Third', errorText: 'Bad third'),
            ],
          ),
        ),
      );
      expect(controller.invalidFieldCount, 2);
      expect(controller.focusFirstInvalid(), isTrue);
      await tester.pump();
      final focused = tester
          .widgetList<EditableText>(_editable)
          .where((e) => e.focusNode.hasFocus)
          .toList();
      expect(focused, hasLength(1));
      final secondField = tester.getRect(_editable.at(1));
      expect(tester.getRect(find.byWidget(focused.single)), secondField);
    });
  });
}
