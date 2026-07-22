import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/storage/recent_ports_store.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  setUp(() {
    useInMemoryPrefs();
  });

  test(
    'removeProject drops all ports for the project, leaves others',
    () async {
      final store = await RecentPortsStore.open();
      addTearDown(store.close);
      await store.add('p1', 3000, 'http');
      await store.add('p1', 5173, 'http');
      await store.add('p2', 8080, 'https');

      await store.removeProject('p1');

      expect(store.list('p1'), isEmpty);
      expect(store.list('p2').map((e) => e.port), [8080]);
    },
  );

  test('removeProject persists the removal across reopen', () async {
    final store = await RecentPortsStore.open();
    await store.add('p1', 3000, 'http');
    await store.add('p2', 8080, 'http');

    await store.removeProject('p1');

    final reopened = await RecentPortsStore.open();
    expect(reopened.list('p1'), isEmpty);
    expect(reopened.list('p2').map((e) => e.port), [8080]);
  });

  test('removeProject is a no-op for an unknown project', () async {
    final store = await RecentPortsStore.open();
    addTearDown(store.close);
    await store.add('p1', 3000, 'http');

    await store.removeProject('does-not-exist');

    expect(store.list('p1').map((e) => e.port), [3000]);
  });
}
