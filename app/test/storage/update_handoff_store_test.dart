import 'package:antgrid/storage/update_handoff_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

// Raw key: under `flutter test` the storage scope prefix is empty
// (see storage_scope.dart), so fixtures may seed the bare literal.
const _key = 'antgrid.update_handoff_version.v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an ordinary launch has nothing to announce', () async {
    useInMemoryPrefs();
    final store = await UpdateHandoffStore.open();
    expect(await store.consume('1.20677.101'), isNull);
  });

  test(
    'a mark older than the running build is the update that landed',
    () async {
      useInMemoryPrefs({_key: '1.20677.100'});
      final store = await UpdateHandoffStore.open();
      expect(await store.consume('1.20677.101'), '1.20677.100');
    },
  );

  test(
    'the mark is consumed, so the announcement fires at most once',
    () async {
      useInMemoryPrefs({_key: '1.20677.100'});
      final store = await UpdateHandoffStore.open();
      await store.consume('1.20677.101');
      expect(await store.consume('1.20677.101'), isNull);
    },
  );

  test('a hand-off that replaced nothing announces nothing', () async {
    // Windows relaunches with the same argument after a crash; an unchanged
    // version is exactly how that case is told apart from a real update.
    useInMemoryPrefs({_key: '1.20677.101'});
    final store = await UpdateHandoffStore.open();
    expect(await store.consume('1.20677.101'), isNull);
  });

  test(
    'a mark newer than the running build is a rollback, not an update',
    () async {
      // Trivial to reach on Linux, where installing an older AppImage is a file
      // copy — announcing "updated to" the older build would be plainly wrong.
      useInMemoryPrefs({_key: '1.20678.1'});
      final store = await UpdateHandoffStore.open();
      expect(await store.consume('1.20677.101'), isNull);
    },
  );

  test('an unparseable version still announces', () async {
    // A local build reports `dev`. Erring towards the announcement is the
    // cheaper mistake: swallowing a real update's is the expensive one.
    useInMemoryPrefs({_key: 'dev'});
    final store = await UpdateHandoffStore.open();
    expect(await store.consume('1.20677.101'), 'dev');
  });

  test('clear drops a mark for an install that never happened', () async {
    useInMemoryPrefs();
    final store = await UpdateHandoffStore.open();
    await store.markHandoff('1.20677.100');
    await store.clear();
    expect(await store.consume('1.20677.101'), isNull);
  });
}
