import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/storage/drawer_collapsed_store.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => useInMemoryPrefs());

  test('fresh store reads an empty set', () async {
    final store = await DrawerCollapsedStore.open();
    expect(store.read(), isEmpty);
  });

  test('write then re-open round-trips the collapsed ids', () async {
    final store = await DrawerCollapsedStore.open();
    await store.write({'proj-a', 'agent-b'});

    final reopened = await DrawerCollapsedStore.open();
    expect(reopened.read(), {'proj-a', 'agent-b'});
  });

  test('write replaces the previous set (not a merge)', () async {
    final store = await DrawerCollapsedStore.open();
    await store.write({'proj-a'});
    await store.write({'proj-b'});
    expect(store.read(), {'proj-b'});
  });
}
