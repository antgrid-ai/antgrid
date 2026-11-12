import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _anchor = Key('anchor');
const String _tip = 'Saves every open file';

Widget _tooltip({
  FocusNode? focusNode,
  VoidCallback? onPressed,
  String message = _tip,
  CarbonTooltipAlignment alignment = CarbonTooltipAlignment.start,
  bool caret = true,
  bool enabled = true,
  bool preferAbove = true,
  Duration showDelay = const Duration(milliseconds: 200),
}) => CarbonTooltip(
  message: message,
  alignment: alignment,
  caret: caret,
  enabled: enabled,
  preferAbove: preferAbove,
  showDelay: showDelay,
  child: CarbonButton(
    key: _anchor,
    label: 'Save',
    focusNode: focusNode,
    onPressed: onPressed ?? () {},
  ),
);

TestGesture? _mouse;

/// Moves the shared mouse onto [target], leaving and re-entering so a tree
/// that was just rebuilt sees a fresh enter.
Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  var gesture = _mouse;
  if (gesture == null) {
    gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(1, 1));
    addTearDown(() async {
      await gesture!.removePointer();
      _mouse = null;
    });
    _mouse = gesture;
  }
  await gesture.moveTo(const Offset(1, 1));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
  return gesture;
}

const Duration _ms100 = Duration(milliseconds: 100);

void main() {
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('hover', () {
    testWidgets('shows after the delay and hides after the grace', (
      tester,
    ) async {
      await pumpCarbon(tester, Center(child: _tooltip()));
      final gesture = await _hover(tester, find.byKey(_anchor));
      await tester.pump(_ms100);
      expect(find.text(_tip), findsNothing);
      await tester.pump(_ms100 + const Duration(milliseconds: 10));
      expect(find.text(_tip), findsOneWidget);

      await gesture.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(find.text(_tip), findsOneWidget, reason: 'grace period');
      await tester.pump(_ms100 + const Duration(milliseconds: 10));
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('leaving before the delay never shows it', (tester) async {
      await pumpCarbon(tester, Center(child: _tooltip()));
      final gesture = await _hover(tester, find.byKey(_anchor));
      await tester.pump(_ms100);
      await gesture.moveTo(const Offset(5, 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('moving onto the tooltip keeps it open', (tester) async {
      await pumpCarbon(tester, Center(child: _tooltip()));
      final gesture = await _hover(tester, find.byKey(_anchor));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(_tip), findsOneWidget);
      await gesture.moveTo(tester.getCenter(find.text(_tip)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(_tip), findsOneWidget);
      await gesture.moveTo(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('a press on the trigger hides it and the tap still lands', (
      tester,
    ) async {
      var taps = 0;
      await pumpCarbon(
        tester,
        Center(child: _tooltip(onPressed: () => taps++)),
      );
      final gesture = await _hover(tester, find.byKey(_anchor));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(_tip), findsOneWidget);
      await gesture.down(tester.getCenter(find.byKey(_anchor)));
      await gesture.up();
      await tester.pump();
      expect(taps, 1);
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('zero delay shows immediately', (tester) async {
      await pumpCarbon(
        tester,
        Center(child: _tooltip(showDelay: Duration.zero)),
      );
      await _hover(tester, find.byKey(_anchor));
      expect(find.text(_tip), findsOneWidget);
    });
  });

  group('keyboard focus', () {
    testWidgets('shows on keyboard focus and hides on blur', (tester) async {
      final node = FocusNode();
      final other = FocusNode();
      addTearDown(node.dispose);
      addTearDown(other.dispose);
      await pumpCarbon(
        tester,
        Column(
          children: [
            _tooltip(focusNode: node),
            Focus(focusNode: other, child: const SizedBox(width: 10, height: 10)),
          ],
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.text(_tip), findsOneWidget);
      expect(node.hasPrimaryFocus, isTrue, reason: 'focus is not stolen');
      other.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('focus from a pointer interaction does not show it', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(tester, Center(child: _tooltip(focusNode: node)));
      node.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('Escape dismisses without moving focus', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpCarbon(tester, Center(child: _tooltip(focusNode: node)));
      node.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.text(_tip), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.text(_tip), findsNothing);
      expect(node.hasPrimaryFocus, isTrue);
    });

    testWidgets('Escape closes the tooltip before an enclosing dialog', (
      tester,
    ) async {
      final node = FocusNode();
      final harness = await pumpCarbon(tester, const SizedBox.shrink());
      addTearDown(node.dispose);
      late BuildContext host;
      await pumpCarbon(
        tester,
        Builder(
          builder: (context) {
            host = context;
            return const SizedBox.shrink();
          },
        ),
      );
      unawaited(
        showCarbonModal<void>(
          host,
          presentation: const CarbonModalPresentation.centered(),
          builder: (context) => CarbonModal.informational(
            title: 'Help',
            body: _tooltip(focusNode: node),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      node.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.text(_tip), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_tip), findsNothing);
      expect(find.text('Help'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Help'), findsNothing);
      expect(harness, isNotNull);
    });
  });

  group('touch', () {
    testWidgets('long press shows it until a tap elsewhere', (tester) async {
      await pumpCarbon(tester, Center(child: _tooltip()));
      await tester.longPress(find.byKey(_anchor));
      await tester.pump();
      expect(find.text(_tip), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(_tip), findsOneWidget, reason: 'stays until tap-away');
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('a plain tap does not show it and activates the child', (
      tester,
    ) async {
      var taps = 0;
      await pumpCarbon(
        tester,
        Center(child: _tooltip(onPressed: () => taps++)),
      );
      await tester.tap(find.byKey(_anchor));
      await tester.pump(const Duration(seconds: 1));
      expect(taps, 1);
      expect(find.text(_tip), findsNothing);
    });
  });

  group('placement', () {
    testWidgets('prefers above and flips below at the top edge', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        Align(alignment: Alignment.center, child: _tooltip(showDelay: Duration.zero)),
        size: const Size(600, 600),
      );
      await _hover(tester, find.byKey(_anchor));
      expect(
        tester.getRect(find.text(_tip)).bottom,
        lessThanOrEqualTo(tester.getRect(find.byKey(_anchor)).top),
      );

      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: _tooltip(showDelay: Duration.zero),
        ),
        size: const Size(600, 600),
      );
      await _hover(tester, find.byKey(_anchor));
      expect(
        tester.getRect(find.text(_tip)).top,
        greaterThanOrEqualTo(tester.getRect(find.byKey(_anchor)).bottom),
      );
    });

    testWidgets('start and end alignment follow text direction', (
      tester,
    ) async {
      for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
        for (final alignment in CarbonTooltipAlignment.values) {
          await pumpCarbon(
            tester,
            Center(
              child: _tooltip(alignment: alignment, showDelay: Duration.zero),
            ),
            size: const Size(600, 600),
            dir: dir,
          );
          await _hover(tester, find.byKey(_anchor));
          final anchor = tester.getRect(find.byKey(_anchor));
          // The tooltip surface is the DecoratedBox ancestor of the text.
          final surface = tester.getRect(
            find
                .ancestor(
                  of: find.text(_tip),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          final startsAtLeft =
              (dir == TextDirection.ltr) ==
              (alignment == CarbonTooltipAlignment.start);
          if (startsAtLeft) {
            expect(surface.left, closeTo(anchor.left, 0.5), reason: '$dir $alignment');
          } else {
            expect(surface.right, closeTo(anchor.right, 0.5), reason: '$dir $alignment');
          }
          await tester.pump(const Duration(milliseconds: 300));
        }
      }
    });

    testWidgets('is clamped inside the viewport and wraps long text', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        Align(
          alignment: Alignment.centerRight,
          child: _tooltip(
            message: 'A very long description ' * 12,
            showDelay: Duration.zero,
          ),
        ),
        size: const Size(320, 400),
      );
      await _hover(tester, find.byKey(_anchor));
      final rect = tester.getRect(
        find
            .ancestor(
              of: find.textContaining('A very long'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.width, lessThanOrEqualTo(288));
      expect(tester.takeException(), isNull);
    });

    testWidgets('inverse styling from the theme, with and without caret', (
      tester,
    ) async {
      for (final caret in [true, false]) {
        await pumpCarbon(
          tester,
          Center(child: _tooltip(caret: caret, showDelay: Duration.zero)),
        );
        await _hover(tester, find.byKey(_anchor));
        final theme = CarbonThemeData();
        final box = tester.widget<DecoratedBox>(
          find
              .ancestor(of: find.text(_tip), matching: find.byType(DecoratedBox))
              .first,
        );
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.color, theme.colors.backgroundInverse);
        expect(decoration.borderRadius, const BorderRadius.all(CarbonShape.tooltip));
        expect(tester.widget<Text>(find.text(_tip)).style!.color, theme.colors.textInverse);
        await tester.pump(const Duration(milliseconds: 300));
      }
    });

    testWidgets('theme and message updates reach the open tooltip', (
      tester,
    ) async {
      final harness = await pumpCarbon(
        tester,
        Center(child: _tooltip(showDelay: Duration.zero)),
      );
      await _hover(tester, find.byKey(_anchor));
      final dark = CarbonThemeData(scheme: CarbonThemeScheme.gray100);
      await harness.setTheme(tester, dark);
      expect(tester.widget<Text>(find.text(_tip)).style!.color, dark.colors.textInverse);
      await pumpCarbon(
        tester,
        Center(child: _tooltip(message: 'Different', showDelay: Duration.zero)),
        theme: dark,
      );
      await tester.pump();
      expect(find.text('Different'), findsOneWidget);
    });
  });

  group('semantics', () {
    testWidgets('exposes the message as tooltip without replacing the label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, Center(child: _tooltip()));
      final data = tester.getSemantics(find.byKey(_anchor)).getSemanticsData();
      expect(data.label, 'Save');
      expect(data.tooltip, _tip);
      handle.dispose();
    });

    testWidgets('disabled tooltip adds nothing', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(tester, Center(child: _tooltip(enabled: false)));
      expect(find.byType(CarbonTooltip), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(_anchor)).getSemanticsData().tooltip,
        isEmpty,
      );
      final gesture = await _hover(tester, find.byKey(_anchor));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(_tip), findsNothing);
      await gesture.moveTo(const Offset(5, 5));
      handle.dispose();
    });

    testWidgets('the popup text is not announced twice', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        Center(child: _tooltip(showDelay: Duration.zero)),
      );
      await _hover(tester, find.byKey(_anchor));
      expect(find.text(_tip), findsOneWidget);
      expect(find.bySemanticsLabel(_tip), findsNothing);
      handle.dispose();
    });
  });

  group('lifecycle', () {
    testWidgets('unmounting while visible leaves no overlay', (tester) async {
      await pumpCarbon(tester, Center(child: _tooltip()));
      await _hover(tester, find.byKey(_anchor));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(_tip), findsOneWidget);
      await pumpCarbon(tester, const SizedBox.shrink());
      await tester.pump();
      expect(find.text(_tip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pending show and hide timers are cancelled on dispose', (
      tester,
    ) async {
      await pumpCarbon(tester, Center(child: _tooltip()));
      final gesture = await _hover(tester, find.byKey(_anchor));
      // Show timer pending.
      await pumpCarbon(tester, const SizedBox.shrink());
      await tester.pump();

      await pumpCarbon(tester, Center(child: _tooltip()));
      await gesture.moveTo(const Offset(1, 1));
      await gesture.moveTo(tester.getCenter(find.byKey(_anchor)));
      await tester.pump(const Duration(milliseconds: 250));
      await gesture.moveTo(const Offset(1, 1));
      await tester.pump();
      // Hide-grace timer pending; the framework fails the test if any timer
      // outlives it.
      await pumpCarbon(tester, const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('scrolling the trigger out of view dismisses it', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpCarbon(
        tester,
        SizedBox(
          height: 300,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(
              children: [
                SizedBox(
                  height: 100,
                  child: Align(alignment: Alignment.bottomLeft, child: _tooltip(showDelay: Duration.zero)),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
        size: const Size(600, 600),
      );
      await _hover(tester, find.byKey(_anchor));
      expect(find.text(_tip), findsOneWidget);
      controller.jumpTo(600);
      await tester.pump();
      await tester.pump();
      expect(find.text(_tip), findsNothing);
    });

    testWidgets('repeated hover cycles do not accumulate overlays', (
      tester,
    ) async {
      await pumpCarbon(tester, Center(child: _tooltip(showDelay: Duration.zero)));
      final gesture = await _hover(tester, find.byKey(_anchor));
      for (var i = 0; i < 3; i++) {
        await gesture.moveTo(const Offset(5, 5));
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text(_tip), findsNothing);
        await gesture.moveTo(tester.getCenter(find.byKey(_anchor)));
        await tester.pump();
        expect(find.text(_tip), findsOneWidget);
      }
    });
  });
}
