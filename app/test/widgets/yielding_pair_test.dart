import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/widgets/yielding_pair.dart';

Widget _pair() => YieldingPair(
  leading: const SizedBox(width: 100, height: 10),
  trailing: const SizedBox(width: 50, height: 20),
  yielding: YieldingSide.leading,
  keep: 30,
  keepFraction: 0.5,
);

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(alignment: Alignment.topLeft, child: child),
);

void main() {
  testWidgets('dry layout agrees with real layout when the pair yields', (
    tester,
  ) async {
    await tester.pumpWidget(_host(SizedBox(width: 120, child: _pair())));
    final box = tester.renderObject<RenderBox>(find.byType(YieldingPair));

    expect(box.size, const Size(120, 20));
    expect(
      box.getDryLayout(const BoxConstraints(maxWidth: 120)),
      box.size,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reports intrinsics as one line of both children', (
    tester,
  ) async {
    await tester.pumpWidget(_host(IntrinsicWidth(child: _pair())));
    final box = tester.renderObject<RenderBox>(find.byType(YieldingPair));

    expect(tester.takeException(), isNull);
    expect(box.getMaxIntrinsicWidth(double.infinity), 150);
    expect(box.getMinIntrinsicHeight(double.infinity), 20);
    expect(box.size, const Size(150, 20));
  });
}
