// Pins "Modified" as a yellow letter on every Carbon theme: supportWarning is
// a fill colour and washes out as text on a light layer, so the light themes
// take a darker yellow that still clears text contrast.
import 'package:antgrid/widgets/git_status_color.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('Modified is yellow-hued and legible on the light theme', () {
    const colors = CarbonColors.white;
    final c = gitStatusColor(colors, 'M');
    final hue = HSLColor.fromColor(c).hue;
    expect(hue, inInclusiveRange(35, 60));
    expect(_contrast(c, colors.background), greaterThanOrEqualTo(4.5));
    expect(_contrast(c, colors.layer01), greaterThanOrEqualTo(4.5));
  });
}
