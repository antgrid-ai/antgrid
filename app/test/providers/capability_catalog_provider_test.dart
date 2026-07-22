import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/models/capability_catalog.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/capability_catalog.dart';
import 'package:antgrid/services/capability_catalog_cache.dart';

const _catalog = CapabilityCatalog(
  models: [AgentCapabilityModel(id: 'opus', name: 'Opus')],
);

ProviderContainer _container(String root) => ProviderContainer(
      overrides: [
        capabilityCatalogCacheProvider.overrideWithValue(
          CapabilityCatalogCache.testInstance(root: root),
        ),
      ],
    );

// `remember` writes to disk fire-and-forget (unawaited), so the file lands
// asynchronously. Poll rather than sleep a fixed interval — returns as soon as
// the write completes and only fails after a generous timeout, avoiding both
// CI flakiness (slow/loaded runners, AV-scanned temp dirs) and wasted wall-clock.
Future<CapabilityCatalog?> _readWithRetry(
  CapabilityCatalogCache cache,
  String key, {
  Duration timeout = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final c = await cache.read(key);
    if (c != null) return c;
    await Future.delayed(step);
  }
  return null;
}

void main() {
  group('key helpers', () {
    test('local target → local source key', () {
      expect(capabilitySourceKey(null), 'local');
      expect(capabilitySourceKey(const LocalProject('p1')), 'local');
    });

    test('remote target → machine:<deviceUuid> source key', () {
      expect(
        capabilitySourceKey(
          const RemoteProject(machineUuid: 'dev-1', projectId: 'p1'),
        ),
        'machine:dev-1',
      );
    });

    test('composite key joins with __', () {
      expect(capabilityCacheKey('local', 'claude-code'), 'local__claude-code');
    });
  });

  group('capabilityCatalogProvider', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('antgrid-caps-prov-test-');
    });
    tearDown(() async => tmp.delete(recursive: true));

    test('remember stores in memory and persists to disk', () async {
      final c = _container(tmp.path);
      addTearDown(c.dispose);
      c.read(capabilityCatalogProvider.notifier).remember('local__x', _catalog);
      // In-memory update is synchronous — assert it immediately.
      expect(c.read(capabilityCatalogProvider)['local__x']!.models.single.id,
          'opus');
      // A fresh cache instance reads it back off disk (poll for the async write).
      final onDisk = await _readWithRetry(
          CapabilityCatalogCache.testInstance(root: tmp.path), 'local__x');
      expect(onDisk!.models.single.id, 'opus');
    });

    test('remember ignores empty catalog', () async {
      final c = _container(tmp.path);
      addTearDown(c.dispose);
      c.read(capabilityCatalogProvider.notifier)
          .remember('local__x', const CapabilityCatalog());
      expect(c.read(capabilityCatalogProvider).containsKey('local__x'), isFalse);
    });

    test('ensureHydrated loads a disk catalog into state', () async {
      await CapabilityCatalogCache.testInstance(root: tmp.path)
          .write('local__y', _catalog);
      final c = _container(tmp.path);
      addTearDown(c.dispose);
      await c.read(capabilityCatalogProvider.notifier).ensureHydrated('local__y');
      expect(c.read(capabilityCatalogProvider)['local__y']!.models.single.id,
          'opus');
    });

    test('ensureHydrated latches after a confirmed-absent read', () async {
      final c = _container(tmp.path);
      addTearDown(c.dispose);
      final notifier = c.read(capabilityCatalogProvider.notifier);
      // No file on disk → confirmed absent, key stays out of state.
      await notifier.ensureHydrated('local__z');
      expect(c.read(capabilityCatalogProvider).containsKey('local__z'), isFalse);
      // A file appears out-of-band (NOT via remember, which sets state directly).
      await CapabilityCatalogCache.testInstance(root: tmp.path)
          .write('local__z', _catalog);
      // The completed read is latched, so ensureHydrated no longer touches disk;
      // the out-of-band file is deliberately not picked up. This is what stops
      // the per-rebuild disk re-read for a key that has never been cached.
      await notifier.ensureHydrated('local__z');
      expect(c.read(capabilityCatalogProvider).containsKey('local__z'), isFalse);
    });
  });
}
