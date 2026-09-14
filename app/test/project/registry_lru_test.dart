import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session_registry.dart';

void main() {
  group('ProjectSessionRegistry LRU', () {
    test('touch beyond cap evicts oldest and fires callback', () async {
      final evicted = <String>[];
      final registry = ProjectSessionRegistry(
        localCap: 2,
        relayCap: 2,
        onEvict: (id) async {
          evicted.add(id);
        },
      );
      registry.touch('a', isLocal: true);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      registry.touch('b', isLocal: true);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      registry.touch('c', isLocal: true);
      await Future<void>.delayed(Duration.zero);
      expect(evicted, ['a']);
      expect(registry.openProjects, ['b', 'c']);
    });

    test('a pinned project is never the victim, even as the oldest', () async {
      final evicted = <String>[];
      final registry = ProjectSessionRegistry(
        localCap: 2,
        relayCap: 2,
        onEvict: (id) async {
          evicted.add(id);
        },
      );
      registry.touch('a', isLocal: true);
      registry.setPinned({'a'});
      await Future<void>.delayed(const Duration(milliseconds: 1));
      registry.touch('b', isLocal: true);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      registry.touch('c', isLocal: true);
      await Future<void>.delayed(Duration.zero);
      expect(evicted, ['b']);
      expect(registry.openProjects, ['a', 'c']);
    });

    test('an all-pinned bucket stays over cap rather than looping', () async {
      final evicted = <String>[];
      final registry = ProjectSessionRegistry(
        localCap: 1,
        relayCap: 1,
        onEvict: (id) async {
          evicted.add(id);
        },
      );
      registry.touch('a', isLocal: true);
      registry.setPinned({'a'});
      registry.touch('b', isLocal: true);
      registry.setPinned({'a', 'b'});
      await Future<void>.delayed(Duration.zero);
      expect(evicted, isEmpty);
      expect(registry.openProjects, ['a', 'b']);
    });

    test('lifting the last pin brings the bucket back down', () async {
      final evicted = <String>[];
      final registry = ProjectSessionRegistry(
        localCap: 1,
        relayCap: 1,
        onEvict: (id) async {
          evicted.add(id);
        },
      );
      registry.touch('a', isLocal: true);
      registry.setPinned({'a'});
      await Future<void>.delayed(const Duration(milliseconds: 1));
      registry.touch('b', isLocal: true);
      await Future<void>.delayed(Duration.zero);
      expect(evicted, isEmpty, reason: 'b is the just-touched protected id');

      // Nothing else would wake eviction: no project is opened or focused when
      // the last member is released, so setPinned itself has to re-run it.
      registry.setPinned(const {});
      await Future<void>.delayed(Duration.zero);
      expect(evicted, ['a']);
      expect(registry.openProjects, ['b']);
    });

    test(
      'setPinned notifies only when the open set actually changed',
      () async {
        var notifications = 0;
        final registry = ProjectSessionRegistry(
          localCap: 2,
          relayCap: 2,
          onEvict: (_) async {},
        );
        registry.touch('a', isLocal: true);
        registry.addListener(() => notifications++);
        registry.setPinned({'a'});
        expect(notifications, 0);
        expect(registry.pinnedProjects, {'a'});
        registry.setPinned({'a'});
        expect(notifications, 0);
      },
    );
  });
}
