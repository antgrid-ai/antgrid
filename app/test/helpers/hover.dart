import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';

/// Puts a mouse pointer on [target]'s centre and leaves it there.
///
/// Rows that reveal their actions on hover drop those widgets entirely at rest,
/// so a test asserting on one has to bring the pointer over first — nothing is
/// findable without this. The pointer is removed on teardown because the
/// framework asserts on a live one when the test ends.
Future<void> hoverRow(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
}
