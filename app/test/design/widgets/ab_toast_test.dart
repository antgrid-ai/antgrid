import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_toast.dart';

import '../test_harness.dart';

void main() {
  testWidgets('renders title and desc', (tester) async {
    await pumpAntgrid(
      tester,
      const AbToast(
        icon: AbIcons.check,
        title: 'Session committed',
        description: '14 files · feat/auth-flow',
      ),
    );
    expect(find.text('Session committed'), findsOneWidget);
    expect(find.text('14 files · feat/auth-flow'), findsOneWidget);
  });

  testWidgets('action button fires onAction', (tester) async {
    var clicked = false;
    await pumpAntgrid(
      tester,
      AbToast(
        icon: AbIcons.check,
        title: 'x',
        description: 'y',
        actionLabel: 'Open PR',
        onAction: () => clicked = true,
      ),
    );
    await tester.tap(find.text('Open PR'));
    expect(clicked, isTrue);
  });
}
