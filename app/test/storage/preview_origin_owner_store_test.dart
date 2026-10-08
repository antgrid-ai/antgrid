import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/storage/preview_origin_owner_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  setUp(useInMemoryPrefs);

  test('a fresh store reads null', () async {
    expect(await PreviewOriginOwnerStore().read(), isNull);
  });

  test('corrupt JSON, a non-int key, an out-of-range port or a non-String '
      'value each read null', () async {
    for (final raw in [
      '{not json',
      '[1,2]',
      '{"abc":"a"}',
      '{"0":"a"}',
      '{"65536":"a"}',
      '{"3000":5}',
    ]) {
      useInMemoryPrefs({PreviewOriginOwnerStore.key: raw});
      expect(await PreviewOriginOwnerStore().read(), isNull, reason: raw);
    }
  });

  test('replace then merge survives a new instance', () async {
    await PreviewOriginOwnerStore().replace({3000: 'a'});
    await PreviewOriginOwnerStore().merge({3000: 'a'}, {4000: 'b'});
    expect(await PreviewOriginOwnerStore().read(), {3000: 'a', 4000: 'b'});
  });

  test('the unsettled owner round-trips', () async {
    final store = PreviewOriginOwnerStore();
    await store.replace({3000: PreviewOriginOwnerStore.unsettled});
    expect(await store.read(), {3000: ''});
  });

  test('exceeding maxEntries forgets the map', () async {
    final store = PreviewOriginOwnerStore();
    await store.replace({});
    await store.merge({}, {
      for (var p = 1; p <= PreviewOriginOwnerStore.maxEntries + 1; p++) p: 'a',
    });
    expect(await store.read(), isNull);
  });

  test('forget reads null', () async {
    final store = PreviewOriginOwnerStore();
    await store.replace({3000: 'a'});
    expect(await store.forget(), isTrue);
    expect(await store.read(), isNull);
  });

  test('demo owners are dropped by merge and replace', () async {
    final store = PreviewOriginOwnerStore();
    await store.replace({3000: 'a', 3001: kDemoProjectId});
    expect(await store.read(), {3000: 'a'});
    await store.merge(
      (await store.read())!,
      {4000: 'dev-1.$kDemoProjectId', 5000: 'b'},
    );
    expect(await store.read(), {3000: 'a', 5000: 'b'});
  });
}
