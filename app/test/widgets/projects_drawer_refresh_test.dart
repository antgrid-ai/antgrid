// Verifies the machine-list refresh affordance in ProjectsDrawer:
//   tapping the refresh button in the PROJECTS group label re-fetches the
//   account inventory (accountAgentsProvider) so a newly-added remote machine
//   appears without an app restart.
//
// Local projects and QR-paired recent agents are already store-reactive; only
// the inventory FutureProvider loads once per session, so it's the one source
// the button needs to invalidate.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/widgets/projects_drawer.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  testWidgets('tapping the PROJECTS refresh button re-fetches the inventory', (
    tester,
  ) async {
    var fetches = 0;
    Widget buildDrawer() => ProviderScope(
      overrides: [
        ...stores.overrides,
        accountAgentsProvider.overrideWith((ref) async {
          fetches++;
          return <InventoryAgent>[];
        }),
        currentUserProvider.overrideWith((_) async => null),
      ],
      child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
    );

    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();
    expect(fetches, 1);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(fetches, 2);
  });
}
