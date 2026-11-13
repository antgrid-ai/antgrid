import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/widgets/auth_status_pill.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../design/test_harness.dart';

CurrentUser _user({String? tier, bool promotional = false}) => CurrentUser(
  userId: 'u1',
  email: 'dev@example.com',
  tier: tier,
  promotional: promotional,
);

Future<void> _pump(WidgetTester tester, AuthStatusPill pill) =>
    pumpAntgrid(tester, AbCarbonScope(child: pill));

void main() {
  testWidgets('a promotional grant renders no tag at all', (tester) async {
    // TEMP-PROMO: this whole branch retires with the grant.
    await _pump(tester, AuthStatusPill(_user(tier: 'pro', promotional: true)));
    expect(find.byType(CarbonTag), findsNothing);
    // Any tier word here, in any widget, is what App Store review rejected.
    expect(find.text('Beta'), findsNothing);
    expect(find.text('Pro'), findsNothing);
  });

  testWidgets('a real pro subscription reads Pro on a blue tag', (
    tester,
  ) async {
    await _pump(tester, AuthStatusPill(_user(tier: 'pro')));
    expect(find.text('Pro'), findsOneWidget);
    expect(tester.widget<CarbonTag>(find.byType(CarbonTag)).color,
        CarbonTagColor.blue);
  });

  testWidgets('an unknown tier falls back to an outlined Trial', (
    tester,
  ) async {
    await _pump(tester, AuthStatusPill(_user()));
    expect(find.text('Trial'), findsOneWidget);
    expect(tester.widget<CarbonTag>(find.byType(CarbonTag)).color,
        CarbonTagColor.outline);
  });

  testWidgets('a named tier is shown in sentence case', (tester) async {
    await _pump(tester, AuthStatusPill(_user(tier: 'team')));
    expect(find.text('Team'), findsOneWidget);
  });

  testWidgets('no signed-in user renders nothing', (tester) async {
    await _pump(tester, const AuthStatusPill(null));
    expect(find.byType(AuthStatusPill), findsOneWidget);
    expect(find.byType(CarbonTag), findsNothing);
  });
}
