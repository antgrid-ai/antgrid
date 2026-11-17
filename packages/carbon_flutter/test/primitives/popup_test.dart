import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const Key _anchor = Key('anchor');
const Key _popup = Key('popup');
const Size _view = Size(800, 600);

/// A trigger (focusable, toggles the controller) anchored at [offset].
class _Subject extends StatelessWidget {
  const _Subject({
    required this.controller,
    this.offset = const Offset(100, 100),
    this.anchorSize = const Size(200, 40),
    this.popupHeight = 120,
    this.popupWidth,
    this.matchAnchorWidth = true,
    this.alignment = CarbonPopupAlignment.start,
    this.onDismissed,
    this.triggerFocus,
    this.popupFocus,
    this.popupKey,
    this.requestFocusOnTap = false,
    this.popupContent,
  });

  final CarbonPopupController controller;
  final Offset offset;
  final Size anchorSize;
  final double popupHeight;
  final double? popupWidth;
  final bool matchAnchorWidth;
  final CarbonPopupAlignment alignment;
  final ValueChanged<CarbonPopupDismissReason>? onDismissed;
  final FocusNode? triggerFocus;
  final FocusNode? popupFocus;
  final Key? popupKey;
  final bool requestFocusOnTap;

  /// Replaces the default popup body, e.g. with a nested popup.
  final Widget? popupContent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.directional(
          textDirection: Directionality.of(context),
          start: offset.dx,
          top: offset.dy,
          child: CarbonAnchoredPopup(
            key: popupKey,
            controller: controller,
            matchAnchorWidth: matchAnchorWidth,
            alignment: alignment,
            onDismissed: onDismissed,
            popupBuilder: (context, available) =>
                popupContent ??
                _PopupBody(
                  height: popupHeight,
                  width: popupWidth,
                  focusNode: popupFocus,
                ),
            child: CarbonInteraction(
              key: _anchor,
              focusNode: triggerFocus,
              requestFocusOnTap: requestFocusOnTap,
              onPressed: controller.toggle,
              builder: (_, _, _) => SizedBox.fromSize(size: anchorSize),
            ),
          ),
        ),
      ],
    );
  }
}

class _PopupBody extends StatelessWidget {
  const _PopupBody({required this.height, this.width, this.focusNode});

  final double height;
  final double? width;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Focus(
      focusNode: focusNode,
      child: Container(
        key: _popup,
        width: width,
        height: height,
        color: theme.layer(CarbonLayer.of(context)),
        child: Text('Layer ${CarbonLayer.of(context)} ${theme.density.name}'),
      ),
    );
  }
}

void main() {
  late CarbonPopupController controller;

  setUp(() => controller = CarbonPopupController());
  tearDown(() => controller.dispose());

  Future<CarbonHarness> pump(
    WidgetTester tester,
    Widget child, {
    TextDirection dir = TextDirection.ltr,
  }) => pumpCarbon(tester, child, size: _view, dir: dir);

  testWidgets('opens below the anchor matching its width', (tester) async {
    await pump(tester, _Subject(controller: controller));
    expect(find.byKey(_popup), findsNothing);
    await tester.tap(find.byKey(_anchor));
    await tester.pump();
    expect(controller.isOpen, isTrue);
    final anchor = tester.getRect(find.byKey(_anchor));
    final popup = tester.getRect(find.byKey(_popup));
    expect(popup.top, anchor.bottom);
    expect(popup.left, anchor.left);
    expect(popup.width, anchor.width);
  });

  testWidgets('tapping the anchor again closes without reporting', (
    tester,
  ) async {
    final reasons = <CarbonPopupDismissReason>[];
    await pump(
      tester,
      _Subject(controller: controller, onDismissed: reasons.add),
    );
    await tester.tap(find.byKey(_anchor));
    await tester.pump();
    await tester.tap(find.byKey(_anchor));
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(find.byKey(_popup), findsNothing);
    expect(reasons, isEmpty);
  });

  testWidgets('outside tap dismisses; taps inside do not', (tester) async {
    final reasons = <CarbonPopupDismissReason>[];
    await pump(
      tester,
      _Subject(controller: controller, onDismissed: reasons.add),
    );
    controller.open();
    await tester.pump();
    await tester.tap(find.byKey(_popup));
    await tester.pump();
    expect(controller.isOpen, isTrue);

    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(find.byKey(_popup), findsNothing);
    expect(reasons, <CarbonPopupDismissReason>[
      CarbonPopupDismissReason.outsideTap,
    ]);
  });

  testWidgets('names the press that dismissed it from outside', (
    tester,
  ) async {
    await pump(tester, _Subject(controller: controller));
    controller.open();
    await tester.pump();

    final dismissing = await tester.startGesture(
      const Offset(700, 500),
      pointer: 901,
    );
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(CarbonAnchoredPopup.dismissedByPointer(901), isTrue);
    await dismissing.up();

    // A later press with the popup already closed dismissed nothing.
    final later = await tester.startGesture(
      const Offset(700, 500),
      pointer: 902,
    );
    expect(CarbonAnchoredPopup.dismissedByPointer(902), isFalse);
    await later.up();
  });

  testWidgets('Escape dismisses and restores focus to the trigger', (
    tester,
  ) async {
    final trigger = FocusNode();
    final inside = FocusNode();
    addTearDown(trigger.dispose);
    addTearDown(inside.dispose);
    final reasons = <CarbonPopupDismissReason>[];
    await pump(
      tester,
      _Subject(
        controller: controller,
        triggerFocus: trigger,
        popupFocus: inside,
        onDismissed: reasons.add,
      ),
    );
    trigger.requestFocus();
    await tester.pump();
    controller.open();
    await tester.pump();
    inside.requestFocus();
    await tester.pump();
    expect(inside.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(reasons, <CarbonPopupDismissReason>[CarbonPopupDismissReason.escape]);
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('Escape with focus on the trigger closes the popup', (
    tester,
  ) async {
    final trigger = FocusNode();
    addTearDown(trigger.dispose);
    await pump(
      tester,
      _Subject(controller: controller, triggerFocus: trigger),
    );
    trigger.requestFocus();
    controller.open();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('a trigger focused by the opening tap gets focus back', (
    tester,
  ) async {
    final other = FocusNode();
    final trigger = FocusNode();
    final inside = FocusNode();
    addTearDown(other.dispose);
    addTearDown(trigger.dispose);
    addTearDown(inside.dispose);
    await pump(
      tester,
      Column(
        children: <Widget>[
          Focus(focusNode: other, child: const SizedBox(height: 10)),
          Expanded(
            child: _Subject(
              controller: controller,
              triggerFocus: trigger,
              popupFocus: inside,
              requestFocusOnTap: true,
            ),
          ),
        ],
      ),
    );
    other.requestFocus();
    await tester.pump();
    await tester.tap(find.byKey(_anchor));
    await tester.pump();
    expect(controller.isOpen, isTrue);
    expect(trigger.hasFocus, isTrue);
    inside.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('a screen-reader open returns focus to the trigger', (
    tester,
  ) async {
    final trigger = FocusNode();
    final inside = FocusNode();
    addTearDown(trigger.dispose);
    addTearDown(inside.dispose);
    await pump(
      tester,
      _Subject(
        controller: controller,
        triggerFocus: trigger,
        popupFocus: inside,
        requestFocusOnTap: true,
      ),
    );
    final semantics = tester.getSemantics(find.byKey(_anchor));
    semantics.owner!.performAction(semantics.id, SemanticsAction.tap);
    await tester.pump();
    expect(controller.isOpen, isTrue);
    inside.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('Escape on a closed trigger reaches the enclosing dialog', (
    tester,
  ) async {
    final trigger = FocusNode();
    addTearDown(trigger.dispose);
    final harness = await pump(tester, const SizedBox());
    final navigator = harness.navigatorKey.currentState!;
    unawaited(
      navigator.push(
        RawDialogRoute<void>(
          barrierDismissible: true,
          barrierLabel: 'Dismiss',
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) =>
              _Subject(controller: controller, triggerFocus: trigger),
        ),
      ),
    );
    await tester.pump();
    trigger.requestFocus();
    await tester.pump();
    expect(trigger.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('Escape on a closed nested trigger closes the outer popup', (
    tester,
  ) async {
    final inner = CarbonPopupController();
    addTearDown(inner.dispose);
    final innerTrigger = FocusNode();
    addTearDown(innerTrigger.dispose);
    final reasons = <CarbonPopupDismissReason>[];
    await pump(
      tester,
      _Subject(
        controller: controller,
        onDismissed: reasons.add,
        popupContent: CarbonAnchoredPopup(
          controller: inner,
          popupBuilder: (_, _) => const _PopupBody(height: 40, width: 80),
          child: CarbonInteraction(
            focusNode: innerTrigger,
            onPressed: inner.toggle,
            builder: (_, _, _) => const SizedBox(width: 200, height: 40),
          ),
        ),
      ),
    );
    controller.open();
    await tester.pump();
    innerTrigger.requestFocus();
    await tester.pump();
    expect(innerTrigger.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(reasons, <CarbonPopupDismissReason>[CarbonPopupDismissReason.escape]);
  });

  testWidgets('programmatic close restores focus from inside the popup', (
    tester,
  ) async {
    final trigger = FocusNode();
    final inside = FocusNode();
    addTearDown(trigger.dispose);
    addTearDown(inside.dispose);
    await pump(
      tester,
      _Subject(controller: controller, triggerFocus: trigger, popupFocus: inside),
    );
    trigger.requestFocus();
    await tester.pump();
    controller.open();
    await tester.pump();
    inside.requestFocus();
    await tester.pump();
    controller.close();
    controller.close();
    await tester.pump();
    expect(trigger.hasFocus, isTrue);
  });

  testWidgets('system back closes the popup, not the route', (tester) async {
    final reasons = <CarbonPopupDismissReason>[];
    final harness = await pump(tester, const SizedBox());
    // The popup lives on a second route so a pop would be observable.
    harness.navigatorKey.currentState!.push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            _Subject(controller: controller, onDismissed: reasons.add),
      ),
    );
    await tester.pump();
    controller.open();
    await tester.pump();
    expect(find.byKey(_popup), findsOneWidget);

    await harness.back(tester);
    expect(controller.isOpen, isFalse);
    expect(reasons, <CarbonPopupDismissReason>[CarbonPopupDismissReason.back]);
    expect(harness.navigatorKey.currentState!.canPop(), isTrue);

    // Closed: back now pops the route as usual.
    await tester.pump();
    await harness.back(tester);
    await tester.pump();
    expect(harness.navigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('flips above when there is no room below', (tester) async {
    await pump(
      tester,
      _Subject(
        controller: controller,
        offset: const Offset(100, 500),
        popupHeight: 200,
      ),
    );
    controller.open();
    await tester.pump();
    final anchor = tester.getRect(find.byKey(_anchor));
    final popup = tester.getRect(find.byKey(_popup));
    expect(popup.bottom, anchor.top);
  });

  testWidgets('height is capped by the larger side when neither fits', (
    tester,
  ) async {
    await pump(
      tester,
      _Subject(
        controller: controller,
        offset: const Offset(100, 200),
        popupHeight: 1000,
      ),
    );
    controller.open();
    await tester.pump();
    final popup = tester.getRect(find.byKey(_popup));
    // 360px below (600 - 240) beats 200px above.
    expect(popup.top, 240);
    expect(popup.height, 360);
  });

  testWidgets('keyboard inset shrinks the space below', (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await pump(
      tester,
      _Subject(controller: controller, popupHeight: 400),
    );
    controller.open();
    await tester.pump();
    final popup = tester.getRect(find.byKey(_popup));
    // Anchor spans 100..140; the keyboard leaves 160px below and 100px above.
    expect(popup.top, 140);
    expect(popup.bottom, 300);
  });

  testWidgets('safe-area padding keeps a flipped popup off the inset', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 50);
    addTearDown(tester.view.resetPadding);
    await pump(
      tester,
      _Subject(
        controller: controller,
        offset: const Offset(100, 480),
        popupHeight: 1000,
      ),
    );
    controller.open();
    await tester.pump();
    final popup = tester.getRect(find.byKey(_popup));
    expect(popup.top, 40);
    expect(popup.bottom, 480);
  });

  testWidgets('clamps horizontally inside the viewport', (tester) async {
    await pump(
      tester,
      _Subject(
        controller: controller,
        offset: const Offset(700, 100),
        anchorSize: const Size(80, 40),
        matchAnchorWidth: false,
        popupWidth: 300,
      ),
    );
    controller.open();
    await tester.pump();
    final popup = tester.getRect(find.byKey(_popup));
    expect(popup.right, _view.width);
    expect(popup.width, 300);
  });

  testWidgets('start alignment follows RTL; end alignment mirrors it', (
    tester,
  ) async {
    await pump(
      tester,
      _Subject(
        controller: controller,
        matchAnchorWidth: false,
        popupWidth: 300,
      ),
      dir: TextDirection.rtl,
    );
    controller.open();
    await tester.pump();
    var anchor = tester.getRect(find.byKey(_anchor));
    var popup = tester.getRect(find.byKey(_popup));
    expect(popup.right, anchor.right);

    await pump(
      tester,
      _Subject(
        controller: controller,
        matchAnchorWidth: false,
        popupWidth: 300,
        offset: const Offset(400, 100),
        alignment: CarbonPopupAlignment.end,
      ),
      dir: TextDirection.rtl,
    );
    controller.open();
    await tester.pump();
    anchor = tester.getRect(find.byKey(_anchor));
    popup = tester.getRect(find.byKey(_popup));
    expect(popup.left, anchor.left);
  });

  testWidgets('removing the anchor while open closes without throwing', (
    tester,
  ) async {
    final reasons = <CarbonPopupDismissReason>[];
    await pump(
      tester,
      _Subject(controller: controller, onDismissed: reasons.add),
    );
    controller.open();
    await tester.pump();
    expect(find.byKey(_popup), findsOneWidget);

    await pump(tester, const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_popup), findsNothing);
    expect(controller.isOpen, isFalse);
    expect(reasons, <CarbonPopupDismissReason>[
      CarbonPopupDismissReason.anchorLost,
    ]);
    // Closing again is a no-op.
    controller.close();
    await tester.pump();
  });

  testWidgets('scrolling the anchor out of view closes it', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final reasons = <CarbonPopupDismissReason>[];
    await pump(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: 300,
          child: ListView(
            controller: scroll,
            children: <Widget>[
              const SizedBox(height: 50),
              Center(
                child: CarbonAnchoredPopup(
                  controller: controller,
                  onDismissed: reasons.add,
                  popupBuilder: (_, _) =>
                      const _PopupBody(height: 80, width: 100),
                  child: const SizedBox(key: _anchor, width: 100, height: 40),
                ),
              ),
              const SizedBox(height: 1000),
            ],
          ),
        ),
      ),
    );
    controller.open();
    await tester.pump();
    // Partially scrolled: still visible, follows the anchor.
    scroll.jumpTo(30);
    await tester.pump();
    await tester.pump();
    expect(controller.isOpen, isTrue);
    expect(
      tester.getRect(find.byKey(_popup)).top,
      tester.getRect(find.byKey(_anchor)).bottom,
    );

    scroll.jumpTo(200);
    await tester.pump();
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(find.byKey(_popup), findsNothing);
    expect(reasons, <CarbonPopupDismissReason>[
      CarbonPopupDismissReason.anchorLost,
    ]);
  });

  testWidgets('live theme change reaches open popup content', (tester) async {
    final harness = await pump(tester, _Subject(controller: controller));
    controller.open();
    await tester.pump();
    expect(find.text('Layer 2 compact'), findsOneWidget);
    final before = tester.element(find.byType(_PopupBody));

    await harness.setTheme(
      tester,
      CarbonThemeData(
        scheme: CarbonThemeScheme.gray100,
        density: CarbonDensity.touch,
      ),
    );
    expect(controller.isOpen, isTrue);
    expect(find.text('Layer 2 touch'), findsOneWidget);
    final container = tester.widget<Container>(find.byKey(_popup));
    expect(container.color, CarbonColors.gray100.layer02);
    // Same element: the popup was updated, not remounted.
    expect(tester.element(find.byType(_PopupBody)), same(before));
  });

  testWidgets('controller notifies on self-dismissal', (tester) async {
    var notifications = 0;
    controller.addListener(() => notifications++);
    await pump(tester, _Subject(controller: controller));
    controller.open();
    await tester.pump();
    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    expect(notifications, 2);
  });

  testWidgets('open before mount is applied on mount', (tester) async {
    controller.open();
    await pump(tester, _Subject(controller: controller));
    await tester.pump();
    expect(find.byKey(_popup), findsOneWidget);
  });

  testWidgets('swapping and disposing controllers while open is safe', (
    tester,
  ) async {
    final other = CarbonPopupController();
    await pump(tester, _Subject(controller: controller));
    controller.open();
    await tester.pump();

    await pump(tester, _Subject(controller: other));
    await tester.pump();
    expect(other.isOpen, isTrue);
    expect(controller.isOpen, isFalse);
    expect(find.byKey(_popup), findsOneWidget);

    other.dispose();
    await tester.pump();
    expect(find.byKey(_popup), findsNothing);
    expect(tester.takeException(), isNull);

    await pump(tester, const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the popup on an open controller is not a dismissal', (
    tester,
  ) async {
    final trigger = FocusNode();
    final inside = FocusNode();
    addTearDown(trigger.dispose);
    addTearDown(inside.dispose);
    final reasons = <CarbonPopupDismissReason>[];
    Widget build(int key) => _Subject(
      controller: controller,
      popupKey: ValueKey<int>(key),
      triggerFocus: trigger,
      popupFocus: inside,
      onDismissed: reasons.add,
    );
    await pump(tester, build(1));
    trigger.requestFocus();
    await tester.pump();
    controller.open();
    await tester.pump();

    await pump(tester, build(2));
    inside.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(controller.isOpen, isTrue);
    expect(find.byKey(_popup), findsOneWidget);
    expect(reasons, isEmpty);
    expect(inside.hasFocus, isTrue);
  });

  testWidgets('repeated mount and unmount while open', (tester) async {
    for (var i = 0; i < 3; i++) {
      await pump(tester, _Subject(controller: controller));
      controller.open();
      await tester.pump();
      await pump(tester, const SizedBox());
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });
}
