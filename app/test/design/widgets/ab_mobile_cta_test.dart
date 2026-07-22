import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_mobile_cta.dart';

import '../test_harness.dart';

void main() {
  testWidgets('default state shows enable label', (tester) async {
    await pumpAntgrid(tester, AbMobileCta(active: false, onTap: () {}));
    expect(find.text('Enable mobile access'), findsOneWidget);
  });

  testWidgets('active state shows connected label', (tester) async {
    await pumpAntgrid(tester, AbMobileCta(active: true, onTap: () {}));
    expect(find.text('Mobile · connected'), findsOneWidget);
  });

  testWidgets('tap fires callback', (tester) async {
    var calls = 0;
    await pumpAntgrid(
      tester,
      AbMobileCta(active: false, onTap: () => calls++),
    );
    await tester.tap(find.byType(AbMobileCta));
    expect(calls, 1);
  });
}
