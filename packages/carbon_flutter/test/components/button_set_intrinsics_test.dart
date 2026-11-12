import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void _noop() {}

void main() {
  testWidgets('stacked set reports the stacked height to intrinsic parents', (
    tester,
  ) async {
    for (final alignment in CarbonButtonSetAlignment.values) {
      await pumpCarbon(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(
            width: 160,
            child: IntrinsicHeight(
              child: CarbonButtonSet(
                alignment: alignment,
                children: const [
                  CarbonButton(
                    key: Key('cancel'),
                    label: 'Cancel this whole operation',
                    onPressed: _noop,
                  ),
                  CarbonButton(
                    key: Key('ok'),
                    label: 'Confirm this whole operation',
                    onPressed: _noop,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final set = tester.getRect(find.byType(CarbonButtonSet));
      final a = tester.getRect(find.byKey(const Key('cancel')));
      final b = tester.getRect(find.byKey(const Key('ok')));
      expect(a.top, greaterThan(b.top), reason: '$alignment stacks');
      expect(set.height, greaterThanOrEqualTo(a.height + b.height));
    }
  });

  testWidgets('icon-only hover shows the semantic label as visible text', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      Align(
        alignment: AlignmentDirectional.topStart,
        child: CarbonButton.iconOnly(
          key: const Key('btn'),
          icon: const SizedBox.square(dimension: 16),
          semanticLabel: 'Delete',
          onPressed: () {},
        ),
      ),
    );
    expect(find.text('Delete'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('btn'))));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Delete'), findsOneWidget);
  });
}
