import 'package:antgrid/widgets/terminal_scroll_physics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ScrollMetrics at(double pixels) => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 1000,
    pixels: pixels,
    viewportDimension: 400,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 1,
  );

  test('a release mid-list does not glide', () {
    const physics = FingerTrackingScrollPhysics();
    expect(physics.createBallisticSimulation(at(500), 3000), isNull);
  });

  test('a position past an end still settles back', () {
    const physics = FingerTrackingScrollPhysics();
    expect(physics.createBallisticSimulation(at(-20), 0), isNotNull);
  });

  test('only phones drop the glide', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(terminalScrollPhysics, isA<FingerTrackingScrollPhysics>());
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(terminalScrollPhysics, isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
