import 'dart:async';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/carbon_confirm.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _mount(
  WidgetTester tester,
  void Function(Future<bool> Function({bool danger})) onReady,
) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(
        body: AbCarbonScope(
          child: Builder(
            builder: (context) {
              onReady(
                ({bool danger = false}) => showCarbonConfirm(
                  context,
                  title: 'Delete session',
                  body: 'This cannot be undone.',
                  confirmLabel: 'Delete',
                  danger: danger,
                ),
              );
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('Confirm answers true', (tester) async {
    late Future<bool> Function({bool danger}) ask;
    await _mount(tester, (f) => ask = f);
    bool? answer;
    unawaited(ask().then((v) => answer = v));
    await _settle(tester);

    expect(find.text('Delete session'), findsWidgets);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await _settle(tester);
    expect(answer, isTrue);
    expect(find.text('This cannot be undone.'), findsNothing);
  });

  testWidgets('Cancel answers false', (tester) async {
    late Future<bool> Function({bool danger}) ask;
    await _mount(tester, (f) => ask = f);
    bool? answer;
    unawaited(ask().then((v) => answer = v));
    await _settle(tester);

    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(answer, isFalse);
  });

  testWidgets('Escape dismisses as false', (tester) async {
    late Future<bool> Function({bool danger}) ask;
    await _mount(tester, (f) => ask = f);
    bool? answer;
    unawaited(ask().then((v) => answer = v));
    await _settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(answer, isFalse);
  });

  testWidgets('a danger confirmation opens on Cancel and Enter declines', (
    tester,
  ) async {
    late Future<bool> Function({bool danger}) ask;
    await _mount(tester, (f) => ask = f);
    bool? answer;
    unawaited(ask(danger: true).then((v) => answer = v));
    await _settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(answer, isFalse);
  });

  testWidgets('a plain confirmation does not take focus on Cancel', (
    tester,
  ) async {
    late Future<bool> Function({bool danger}) ask;
    await _mount(tester, (f) => ask = f);
    unawaited(ask());
    await _settle(tester);

    final cancel = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Cancel'),
    );
    expect(cancel.autofocus, isFalse);
  });

  testWidgets('the danger confirm button uses the danger kind', (tester) async {
    late Future<bool> Function({bool danger}) ask;
    await _mount(tester, (f) => ask = f);
    unawaited(ask(danger: true));
    await _settle(tester);

    final confirm = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Delete'),
    );
    expect(confirm.kind, CarbonButtonKind.danger);
    final cancel = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Cancel'),
    );
    expect(cancel.autofocus, isTrue);
  });
}
