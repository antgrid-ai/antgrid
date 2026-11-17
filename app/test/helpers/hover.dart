import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';

final _mice = Expando<TestGesture>('hoverRow mouse');

/// Puts a mouse pointer on [target]'s centre and leaves it there.
///
/// Rows that reveal their actions on hover drop those widgets entirely at rest,
/// so a test asserting on one has to bring the pointer over first — nothing is
/// findable without this. The pointer is removed on teardown because the
/// framework asserts on a live one when the test ends.
Future<void> hoverRow(WidgetTester tester, Finder target) async {
  // One mouse per tester: the framework asserts when a second pointer is added
  // for a device that is already present, as a test hovering two rows would.
  var gesture = _mice[tester];
  if (gesture == null) {
    gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    _mice[tester] = gesture;
  }
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
}
