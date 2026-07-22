import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

LocalProjectEntry _entry(String id) => LocalProjectEntry(
  AbProject(
    projectId: id,
    folder: '/tmp/$id',
    displayName: id,
    hostDeviceUuid: id,
    hostMachineName: '',
    lastOpenedAt: DateTime.now(),
  ),
);

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    // Hover prefetch is desktop-only (DrawerEntryRow short-circuits its
    // pointer handlers when isMobilePlatform is true). flutter_test defaults
    // defaultTargetPlatform to android, which would disable the behavior under
    // test — force a desktop platform so the hover timer actually arms.
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  testWidgets(
    'hover >=300ms triggers session factory; <300ms does not',
    timeout: const Timeout(Duration(seconds: 30)),
    (tester) async {
      // Hover prefetch is desktop-only (DrawerEntryRow short-circuits its
      // pointer handlers when isMobilePlatform is true). flutter_test defaults
      // defaultTargetPlatform to android, which would disable the behavior
      // under test — force a desktop platform so the hover timer actually
      // arms. Reset inside the body (in finally): flutter_test's foundation-var
      // invariant check runs at the end of the test body, before any tearDown.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        var factoryCalls = 0;
        Future<ProjectSession> factory(Ref ref, String id) async {
          factoryCalls++;
          // Throw so the future resolves without needing a real ProjectSession;
          // we only care about counting invocations here.
          throw StateError('factory-stub');
        }

        Future<void> mount() async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                ...stores.overrides,
                projectSessionFactoryProvider.overrideWithValue(factory),
              ],
              child: MaterialApp(
                home: Scaffold(body: DrawerEntryRow(_entry('hover-p'))),
              ),
            ),
          );
          await tester.pump();
        }

        await mount();

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(gesture.removePointer);
        await gesture.addPointer();

        // Hover for 200ms then leave (move pointer far away, off the row).
        // Should NOT trigger.
        final center = tester.getCenter(find.byType(DrawerEntryRow));
        await gesture.moveTo(center);
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.moveTo(const Offset(-100, -100));
        await tester.pump(const Duration(milliseconds: 200));
        expect(factoryCalls, 0);

        // Hover for 350ms — should trigger once.
        await gesture.moveTo(center);
        await tester.pump(const Duration(milliseconds: 350));
        expect(factoryCalls, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
