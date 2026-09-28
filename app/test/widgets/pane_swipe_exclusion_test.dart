import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/widgets/pane_swipe_exclusion.dart';

void main() {
  // The shell's fling dispatchers are raw ANCESTOR listeners that ask
  // `claims` on pointer-down; this pins the ordering that makes the answer
  // true — the zone, being deeper, sees the same down first.
  testWidgets('an ancestor listener sees a pointer that went down in the '
      'zone as claimed, and one outside it as not', (tester) async {
    final seen = <bool>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Listener(
          onPointerDown: (e) => seen.add(PaneSwipeExclusion.claims(e.pointer)),
          child: Column(
            children: [
              Container(
                key: const Key('outside'),
                height: 100,
                width: 100,
                color: const Color(0xFF000000),
              ),
              PaneSwipeExclusion(
                child: Container(
                  key: const Key('inside'),
                  height: 100,
                  width: 100,
                  color: const Color(0xFF000000),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.dragFrom(
      tester.getCenter(find.byKey(const Key('inside'))),
      const Offset(80, 0),
    );
    await tester.dragFrom(
      tester.getCenter(find.byKey(const Key('outside'))),
      const Offset(80, 0),
    );
    expect(seen, [true, false]);
  });
}
