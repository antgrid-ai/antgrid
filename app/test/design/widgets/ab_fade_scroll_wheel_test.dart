import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_fade_scroll.dart';

void main() {
  testWidgets('a plain mouse wheel scrolls an overflowing AbFadeScroll', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 200,
            height: 40,
            child: AbFadeScroll(
              children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(width: 60, height: 40, child: Text('chip $i')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final controllerState = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    expect(controllerState.position.pixels, 0);
    expect(controllerState.position.maxScrollExtent, greaterThan(0));

    // A plain vertical wheel notch — dx: 0 — is what a mouse (not a
    // trackpad) actually sends; this row has no vertical scrollable
    // ancestor to steal it, so it must land as horizontal movement.
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(AbFadeScroll)),
        scrollDelta: const Offset(0, 100),
      ),
    );
    await tester.pumpAndSettle();

    expect(controllerState.position.pixels, 100);
  });

  testWidgets(
    'a trackpad two-finger scroll also scrolls an overflowing AbFadeScroll',
    (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              height: 40,
              child: AbFadeScroll(
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(width: 60, height: 40, child: Text('chip $i')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controllerState = tester.state<ScrollableState>(
        find.byType(Scrollable),
      );
      expect(controllerState.position.pixels, 0);

      // Windows/macOS precision-touchpad two-finger scroll arrives as a
      // pan/zoom stream, never as a PointerScrollEvent — a separate code
      // path from the wheel test above, and the one a laptop trackpad
      // actually exercises.
      final center = tester.getCenter(find.byType(AbFadeScroll));
      final pointer = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pointer.panZoomStart(center));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(center, pan: const Offset(0, -100)),
      );
      await tester.pumpAndSettle();

      expect(controllerState.position.pixels, isNot(0));
    },
  );

  testWidgets(
    'a mouse click-and-drag also scrolls an overflowing AbFadeScroll',
    (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              height: 40,
              child: AbFadeScroll(
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(width: 60, height: 40, child: Text('chip $i')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controllerState = tester.state<ScrollableState>(
        find.byType(Scrollable),
      );
      expect(controllerState.position.pixels, 0);

      // The default ScrollBehavior omits the mouse from `dragDevices`
      // (reserved for text selection) — without AbFadeScroll's local
      // override this drag is a no-op.
      await tester.drag(
        find.byType(AbFadeScroll),
        const Offset(-100, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(controllerState.position.pixels, greaterThan(0));
    },
  );
}
