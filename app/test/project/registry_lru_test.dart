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
  });
}
