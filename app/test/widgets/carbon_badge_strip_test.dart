import 'package:antgrid/widgets/carbon_badge_strip.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('badgeStripCap', () {
    test('is unbounded when the badges fit', () {
      expect(badgeStripCap([20, 0, 40], 100), double.infinity);
    });

    test('takes from the widest first and leaves the narrow ones whole', () {
      expect(badgeStripCap([20, 0, 200], 100), 80);
      expect(badgeStripCap([30, 90, 90], 120), 45);
    });
  });

  Future<List<Rect>> pumpStrip(
    WidgetTester tester,
    List<double> widths, {
    TextDirection direction = TextDirection.ltr,
  }) async {
    final keys = [for (var i = 0; i < widths.length; i++) GlobalKey()];
    await tester.pumpWidget(
      Directionality(
        textDirection: direction,
        child: Center(
          child: CarbonBadgeStrip(
            maxWidth: 100,
            children: [
              for (var i = 0; i < widths.length; i++)
                SizedBox(key: keys[i], width: widths[i], height: 10),
            ],
          ),
        ),
      ),
    );
    return [for (final k in keys) tester.getRect(find.byKey(k))];
  }

  testWidgets('an empty badge takes no share of the width', (tester) async {
    final rects = await pumpStrip(tester, [0, 0, 90, 0]);
    expect(rects[2].width, 90);
    expect(tester.getSize(find.byType(CarbonBadgeStrip)).width, 90);
  });

  testWidgets('overflowing badges shrink the widest to fit', (tester) async {
    final rects = await pumpStrip(tester, [20, 200]);
    expect(rects.map((r) => r.width), [20, 80]);
    expect(rects[1].left, rects[0].right);
  });

  testWidgets('right to left lays the first badge at the end', (tester) async {
    final rects = await pumpStrip(
      tester,
      [20, 30],
      direction: TextDirection.rtl,
    );
    expect(rects[0].right, rects[1].left + 50);
    expect(rects[1].right, rects[0].left);
  });
}
