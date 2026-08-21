import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/models/session_entry.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  setUp(() {
    useInMemoryPrefs();
  });

  test('entries() returns a snapshot of all cached entry ids', () async {
    final store = await CachedSessionsStore.open();
    await store.put('projA', const [
      SessionEntry(
        id: 'a',
        name: 'A',
        createdAt: 1,
        lastUsedAt: 10,
        archived: false,
        running: false,
      ),
    ]);
    await store.put('uuid.projB', const [
      SessionEntry(
        id: 'b',
        name: 'B',
        createdAt: 2,
        lastUsedAt: 20,
        archived: false,
        running: false,
      ),
    ]);
    final all = store.entries();
    expect(all.keys.toSet(), {'projA', 'uuid.projB'});
    expect(all['projA']!.single.id, 'a');
    expect(
      () => all['projA']!.add(all['projA']!.first),
      throwsUnsupportedError,
    );
  });
}
