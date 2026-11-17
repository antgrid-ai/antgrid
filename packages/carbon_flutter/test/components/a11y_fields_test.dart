import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _host(Widget child, {double width = 320}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

List<SemanticsNode> _liveRegions(WidgetTester tester) {
  final found = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isLiveRegion) found.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return found;
}

Finder _actionLabeled(String label) => find.byWidgetPredicate(
  (w) => w is CarbonFieldAction && w.semanticLabel == label,
);

void main() {
  group('field actions keep identity when the action list changes', () {
    testWidgets('focus on Show password survives the clear action leaving', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CarbonTextInput(
                label: 'Password',
                variant: CarbonTextInputVariant.password,
                clearable: true,
                controller: controller,
              ),
              const CarbonTextInput(label: 'Next'),
            ],
          ),
        ),
      );
      final revealFocus = tester
          .widgetList<Focus>(
            find.descendant(
              of: _actionLabeled('Show password'),
              matching: find.byType(Focus),
            ),
          )
          .map((f) => f.focusNode)
          .whereType<FocusNode>()
          .first;
      revealFocus.requestFocus();
      await tester.pump();
      expect(revealFocus.hasFocus, isTrue);
      controller.text = '';
      await tester.pump();
      expect(revealFocus.hasFocus, isTrue);
    });

    testWidgets('hover fill stays on the action under the pointer', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        _host(
          CarbonTextInput(
            label: 'Password',
            variant: CarbonTextInputVariant.password,
            clearable: true,
            controller: controller,
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(
        location: tester.getCenter(_actionLabeled('Show password')),
      );
      await tester.pump();
      controller.text = 'a';
      await tester.pump();

      Color? fillOf(Finder action) {
        Color? found;
        void visit(RenderObject o) {
          if (o is RenderDecoratedBox) {
            final d = o.decoration;
            if (d is BoxDecoration && d.color != null) found = d.color;
          }
          o.visitChildren(visit);
        }

        visit(tester.renderObject(action));
        return found;
      }

      final clearFill = fillOf(_actionLabeled('Clear'));
      expect(
        clearFill == null || clearFill.a == 0,
        isTrue,
        reason: 'Clear must not inherit the hover of the reveal action',
      );
    });
  });

  group('error announcements', () {
    testWidgets('focusFirstInvalid announces an error on the focused field', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final messages = <Object?>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        (message) async {
          messages.add(message);
          return null;
        },
      );
      addTearDown(
        () => messenger.setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
      );
      final form = CarbonFormController();
      Widget build(String? error) => _host(
        CarbonForm(
          controller: form,
          children: <Widget>[CarbonTextInput(label: 'Email', errorText: error)],
        ),
      );
      await pumpCarbon(tester, build(null));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await pumpCarbon(tester, build('Enter a valid email'));
      messages.clear();
      expect(form.focusFirstInvalid(), isTrue);
      await tester.pump();
      expect(
        messages.map((m) => m.toString()).join(),
        allOf(contains('Email'), contains('Enter a valid email')),
      );
      handle.dispose();
    });

    testWidgets('search error is a live region replacing the count', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _host(const CarbonSearch(resultCount: 3)));
      expect(_liveRegions(tester).map((n) => n.label), ['3 results']);
      await pumpCarbon(
        tester,
        _host(const CarbonSearch(resultCount: 3, errorText: 'Search failed')),
      );
      expect(
        _liveRegions(tester).map((n) => n.label),
        contains('Search failed'),
      );
      handle.dispose();
    });
  });

  testWidgets('default search name is announced once', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(tester, _host(const CarbonSearch()));
    expect(tester.getSemantics(find.byType(TextField)).label, 'Search');
    handle.dispose();
  });

  testWidgets('maxLength without a counter does not rebuild per keystroke', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'a');
    addTearDown(controller.dispose);
    await pumpCarbon(
      tester,
      _host(
        CarbonTextInput(label: 'Name', maxLength: 50, controller: controller),
      ),
    );
    var rebuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is CarbonTextInput) rebuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    for (final text in ['ab', 'abc', 'abcd']) {
      controller.text = text;
      await tester.pump();
    }
    expect(rebuilds, 0);
  });

  testWidgets('counter still tracks length when shown', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pumpCarbon(
      tester,
      _host(
        CarbonTextInput(
          label: 'Name',
          maxLength: 50,
          showCounter: true,
          controller: controller,
        ),
      ),
    );
    controller.text = 'abc';
    await tester.pump();
    expect(find.text('3/50'), findsOneWidget);
  });
}
