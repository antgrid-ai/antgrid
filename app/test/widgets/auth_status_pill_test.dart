import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/widgets/auth_status_pill.dart';
import 'package:flutter_test/flutter_test.dart';

import '../design/test_harness.dart';

CurrentUser _user({String? tier, bool promotional = false}) => CurrentUser(
  userId: 'u1',
  email: 'dev@example.com',
  tier: tier,
  promotional: promotional,
);

void main() {
  testWidgets('a promotional grant renders no chip at all', (tester) async {
    // TEMP-PROMO: this whole branch retires with the grant.
    await pumpAntgrid(
      tester,
      AuthStatusPill(_user(tier: 'pro', promotional: true)),
    );
    expect(find.byType(AbChip), findsNothing);
  });

  testWidgets('a real pro subscription reads PRO', (tester) async {
    await pumpAntgrid(tester, AuthStatusPill(_user(tier: 'pro')));
    expect(find.text('PRO'), findsOneWidget);
  });

  testWidgets('an unknown tier falls back to TRIAL', (tester) async {
    await pumpAntgrid(tester, AuthStatusPill(_user()));
    expect(find.text('TRIAL'), findsOneWidget);
  });

  testWidgets('no signed-in user renders nothing', (tester) async {
    await pumpAntgrid(tester, const AuthStatusPill(null));
    expect(find.byType(AuthStatusPill), findsOneWidget);
    expect(find.byType(AbChip), findsNothing);
  });
}
