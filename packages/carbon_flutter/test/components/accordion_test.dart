import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _accordion(
  List<CarbonAccordionItem> items, {
  bool flush = false,
  CarbonAccordionAlign align = CarbonAccordionAlign.end,
  CarbonAccordionSize size = CarbonAccordionSize.medium,
  bool disabled = false,
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(
    width: 400,
    child: CarbonAccordion(
      flush: flush,
      align: align,
      size: size,
      disabled: disabled,
      children: items,
    ),
  ),
);

CarbonAccordionItem _plain(
  String title, {
  bool? open,
  bool initiallyOpen = false,
  ValueChanged<bool>? onOpenChanged,
  Key? key,
}) => CarbonAccordionItem(
  key: key,
  title: Text(title),
  open: open,
  initiallyOpen: initiallyOpen,
  onOpenChanged: onOpenChanged,
  child: Text('$title body'),
);

void main() {
  testWidgets('tap toggles an uncontrolled item and reports the new state', (
    tester,
  ) async {
    final reports = <bool>[];
    await pumpCarbon(
      tester,
      _accordion([_plain('Plan', onOpenChanged: reports.add)]),
    );
    expect(find.text('Plan body'), findsNothing);
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Plan body'), findsOneWidget);
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Plan body'), findsNothing);
    expect(reports, [true, false]);
  });

  testWidgets('initiallyOpen starts open', (tester) async {
    await pumpCarbon(tester, _accordion([_plain('Plan', initiallyOpen: true)]));
    expect(find.text('Plan body'), findsOneWidget);
  });

  testWidgets('Enter and Space toggle from the keyboard', (tester) async {
    await pumpCarbon(tester, _accordion([_plain('Plan')]));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Plan body'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Plan body'), findsNothing);
  });

  testWidgets('items open independently', (tester) async {
    await pumpCarbon(tester, _accordion([_plain('A'), _plain('B')]));
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(find.text('A body'), findsOneWidget);
    expect(find.text('B body'), findsOneWidget);
  });

  testWidgets('a controlled item only reports until the host updates', (
    tester,
  ) async {
    final reports = <bool>[];
    await pumpCarbon(
      tester,
      _accordion([_plain('Plan', open: false, onOpenChanged: reports.add)]),
    );
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(reports, [true]);
    expect(find.text('Plan body'), findsNothing);
    await pumpCarbon(tester, _accordion([_plain('Plan', open: true)]));
    await tester.pumpAndSettle();
    expect(find.text('Plan body'), findsOneWidget);
  });

  testWidgets('a new key resets uncontrolled state', (tester) async {
    await pumpCarbon(
      tester,
      _accordion([_plain('Plan', key: const ValueKey('a'))]),
    );
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Plan body'), findsOneWidget);
    await pumpCarbon(
      tester,
      _accordion([_plain('Plan', key: const ValueKey('b'))]),
    );
    expect(find.text('Plan body'), findsNothing);
  });

  testWidgets('a disabled accordion ignores taps', (tester) async {
    final reports = <bool>[];
    await pumpCarbon(
      tester,
      _accordion([_plain('Plan', onOpenChanged: reports.add)], disabled: true),
    );
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(reports, isEmpty);
    expect(find.text('Plan body'), findsNothing);
  });

  group('layout', () {
    double titleStart(WidgetTester tester) =>
        tester.getTopLeft(find.text('Plan')).dx;

    testWidgets('flush removes the title inset', (tester) async {
      await pumpCarbon(tester, _accordion([_plain('Plan')]));
      expect(titleStart(tester), 16);
      await pumpCarbon(tester, _accordion([_plain('Plan')], flush: true));
      expect(titleStart(tester), 0);
    });

    testWidgets('flush removes the content inset', (tester) async {
      await pumpCarbon(
        tester,
        _accordion([_plain('Plan', initiallyOpen: true)]),
      );
      expect(tester.getTopLeft(find.text('Plan body')).dx, 16);
      await pumpCarbon(
        tester,
        _accordion([_plain('Plan', initiallyOpen: true)], flush: true),
      );
      expect(tester.getTopLeft(find.text('Plan body')).dx, 0);
    });

    testWidgets('align decides which side the chevron is on', (tester) async {
      await pumpCarbon(tester, _accordion([_plain('Plan')]));
      final icon = find.byType(CarbonIcon);
      expect(
        tester.getCenter(icon).dx,
        greaterThan(tester.getCenter(find.text('Plan')).dx),
      );
      await pumpCarbon(
        tester,
        _accordion([_plain('Plan')], align: CarbonAccordionAlign.start),
      );
      expect(
        tester.getCenter(icon).dx,
        lessThan(tester.getCenter(find.text('Plan')).dx),
      );
    });

    testWidgets('heading heights follow size', (tester) async {
      for (final (size, height) in [
        (CarbonAccordionSize.small, 32.0),
        (CarbonAccordionSize.medium, 40.0),
        (CarbonAccordionSize.large, 48.0),
      ]) {
        await pumpCarbon(tester, _accordion([_plain('Plan')], size: size));
        // The heading plus the item's 1px top rule.
        expect(
          tester.getSize(find.byType(CarbonAccordionItem)).height,
          height + 1,
        );
      }
    });

    testWidgets('touch density raises every heading to the touch target', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _accordion([_plain('Plan')], size: CarbonAccordionSize.small),
        theme: CarbonThemeData(density: CarbonDensity.touch),
      );
      expect(
        tester.getSize(find.byType(CarbonAccordionItem)).height,
        greaterThanOrEqualTo(44 + 1),
      );
    });
  });

  group('semantics', () {
    testWidgets('a heading holds a button whose expanded flag follows state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, _accordion([_plain('Plan')]));
      // The heading and its button merge into one node.
      var data = tester.getSemantics(find.text('Plan')).getSemanticsData();
      expect(data.label, 'Plan');
      expect(data.flagsCollection.isHeader, isTrue);
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.flagsCollection.isExpanded, Tristate.isFalse);

      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      data = tester.getSemantics(find.text('Plan')).getSemanticsData();
      expect(data.flagsCollection.isExpanded, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('closing hides the content from assistive technology', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _accordion([_plain('Plan', initiallyOpen: true)]),
      );
      expect(find.semantics.byLabel('Plan body'), findsOne);
      await tester.tap(find.text('Plan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.semantics.byLabel('Plan body'), findsNothing);
      handle.dispose();
    });
  });

  group('motion', () {
    double height(WidgetTester tester) =>
        tester.getSize(find.byType(CarbonAccordionItem)).height;

    testWidgets('opening animates by default', (tester) async {
      await pumpCarbon(tester, _accordion([_plain('Plan')]));
      final closed = height(tester);
      await tester.tap(find.text('Plan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = height(tester);
      await tester.pumpAndSettle();
      final full = height(tester);
      expect(mid, greaterThan(closed));
      expect(mid, lessThan(full));
    });

    testWidgets('reduced motion jumps straight to the end state', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _accordion([_plain('Plan')]),
        reduceMotion: true,
      );
      final closed = height(tester);
      await tester.tap(find.text('Plan'));
      await tester.pump();
      final full = height(tester);
      expect(full, greaterThan(closed));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  testWidgets('content keeps a quarter of the width free on the end', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _accordion([_plain('Plan', initiallyOpen: true)]),
    );
    final body = tester.getRect(find.text('Plan body'));
    final item = tester.getRect(find.byType(CarbonAccordionItem));
    expect(item.right - 100, greaterThanOrEqualTo(body.right));
  });

  testWidgets('flush hover fill extends 16px past the heading', (tester) async {
    await pumpCarbon(
      tester,
      _accordion([_plain('Plan')], flush: true),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Plan')));
    await tester.pump();
    final fills = tester
        .widgetList<ColoredBox>(find.descendant(
          of: find.byType(CarbonAccordionItem),
          matching: find.byType(ColoredBox),
        ))
        .toList();
    expect(fills, isNotEmpty);
    final rect = tester.getRect(find.descendant(
      of: find.byType(CarbonAccordionItem),
      matching: find.byType(ColoredBox),
    ).first);
    expect(rect.left, -16);
  });
}
