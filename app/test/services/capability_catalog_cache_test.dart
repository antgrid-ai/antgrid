// app/test/services/capability_catalog_cache_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/models/capability_catalog.dart';
import 'package:antgrid/services/capability_catalog_cache.dart';

void main() {
  group('CapabilityCatalogCache', () {
    late Directory tmp;
    late CapabilityCatalogCache cache;

    const catalog = CapabilityCatalog(
      models: [
        AgentCapabilityModel(id: 'opus', name: 'Opus', efforts: ['high']),
      ],
    );

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('antgrid-caps-cache-test-');
      cache = CapabilityCatalogCache.testInstance(root: tmp.path);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('write + read round-trip', () async {
      await cache.write('local__claude-code', catalog);
      final read = await cache.read('local__claude-code');
      expect(read, isNotNull);
      expect(read!.models.single.id, 'opus');
    });

    test('machine key with ":" sanitizes to one file and round-trips', () async {
      const key = 'machine:abc-123__codex';
      await cache.write(key, catalog);
      expect(await cache.read(key), isNotNull);
      // Persisted under a filesystem-safe name (no raw ':').
      final files = Directory(
        p.join(tmp.path, 'cache', 'capability-catalog'),
      ).listSync().map((e) => p.basename(e.path)).toList();
      expect(files.single.contains(':'), isFalse);
    });

    test('read returns null for unknown key', () async {
      expect(await cache.read('local__missing'), isNull);
    });

    test('read returns null for corrupt file (does not throw)', () async {
      final f = File(
        p.join(tmp.path, 'cache', 'capability-catalog', 'local__x.json'),
      );
      await f.create(recursive: true);
      await f.writeAsString('{not json');
      expect(await cache.read('local__x'), isNull);
    });

    test('clear removes the key file', () async {
      await cache.write('local__x', catalog);
      await cache.clear('local__x');
      expect(await cache.read('local__x'), isNull);
    });
  });
}
