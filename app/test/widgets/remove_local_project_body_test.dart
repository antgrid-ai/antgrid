// The consequence copy for removing a local project.
//
// Removing a project makes the bridge forget it, and forgetting force-removes
// every managed checkout the project owns — so this copy is the ONLY place a
// user is told that isolated work is about to be destroyed. It shipped for a
// while promising the opposite ("the folder is not deleted"), which is what
// these tests exist to stop coming back.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

SessionEntry _session({required String checkoutKind}) => SessionEntry(
  id: 's-$checkoutKind',
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  checkoutId: checkoutKind == 'main' ? 'main' : 'abc123',
  checkoutKind: checkoutKind,
);

void main() {
  late TestStoreOverrides stores;
  late ProviderContainer container;

  Future<void> seed(List<SessionEntry> sessions) async {
    await stores.cachedSessionsStore.put('proj-1', sessions);
  }

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
    container = ProviderContainer(overrides: stores.overrides);
  });

  tearDown(() async {
    container.dispose();
    await stores.close();
  });

  test(
    'a project with no isolated sessions promises only what it keeps',
    () async {
      await seed([_session(checkoutKind: 'main')]);
      final body = removeLocalProjectBody(container, 'proj-1');
      expect(body, contains('The project folder is not deleted.'));
      expect(body, isNot(contains('uncommitted')));
    },
  );

  test('an isolated session makes the destruction explicit', () async {
    await seed([
      _session(checkoutKind: 'main'),
      _session(checkoutKind: 'managed-worktree'),
    ]);
    final body = removeLocalProjectBody(container, 'proj-1');
    expect(body, contains('uncommitted changes'));
    expect(body, contains('branches'));
    // The reassurance that is still true has to survive alongside the warning:
    // the user's repository really is untouched, and dropping that sentence
    // would make an ordinary remove read as though it deletes their code.
    expect(body, contains('The project folder is not deleted.'));
  });

  // The forward pin. Isolation is derived by exclusion from `main`, so a kind
  // this build has never heard of still costs the user a working directory —
  // and the bridge owns that vocabulary.
  test('an unknown checkout kind still earns the warning', () async {
    await seed([_session(checkoutKind: 'dev-container')]);
    expect(
      removeLocalProjectBody(container, 'proj-1'),
      contains('uncommitted changes'),
    );
  });

  // A project the app has never opened caches nothing, so the warning cannot be
  // reached — which is exactly why the unconditional half may not claim that
  // nothing on disk is removed.
  test('a cold project falls back to a body that is still true', () async {
    final body = removeLocalProjectBody(container, 'never-opened');
    expect(body, contains('The project folder is not deleted.'));
    expect(body, isNot(contains('Files on disk are not affected')));
  });
}
