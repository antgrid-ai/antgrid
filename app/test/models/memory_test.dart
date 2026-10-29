import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> rec(String id, {Map<String, dynamic>? extra}) => {
  'id': id,
  'content': 'c $id',
  'memory_type': 'note',
  'scope': 'project',
  'project_id': 'p',
  'source': {'actor': 'agent', 'agent_id': 'codex'},
  'created_at': 1000,
  'updated_at': 1000,
  'lifecycle': 'active',
  ...?extra,
};

void main() {
  group('MemoryStatus', () {
    test('parses failures', () {
      final s = MemoryStatus.fromJson({
        'available': true,
        'enabled': true,
        'search_status': 'ready',
        'failed_operations': 1,
        'failures': [
          {
            'code': 'CONFLICT',
            'target_id': 'a',
            'latest_id': 'b',
            'project_id': 'p',
          },
        ],
      });
      expect(s.failures, hasLength(1));
      expect(s.failures.single.code, 'CONFLICT');
      expect(s.failures.single.showId, 'b');
      expect(s.searchReady, isTrue);
      expect(s.needsAttention, isTrue);
    });

    test('lenient defaults', () {
      final s = MemoryStatus.fromJson({});
      expect(s.available, isFalse);
      expect(s.failures, isEmpty);
      expect(s.searchStatus, 'unavailable');
      expect(s.recoveryStatus, 'ready');
      expect(s.cleanupFailed, isFalse);
      expect(s.needsAttention, isTrue);
    });

    test('healthy status needs no attention; cleanup failure does', () {
      final ok = {
        'available': true,
        'search_status': 'ready',
        'recovery_status': 'ready',
      };
      expect(MemoryStatus.fromJson(ok).needsAttention, isFalse);
      expect(
        MemoryStatus.fromJson({
          ...ok,
          'recovery_status': 'cleanup_failed',
        }).needsAttention,
        isTrue,
      );
    });

    test('failure without latest id shows the target', () {
      expect(
        MemoryFailure.fromJson({
          'code': 'CONFLICT',
          'target_id': 'a',
          'project_id': null,
        }).showId,
        'a',
      );
    });
  });

  group('MemoryProjects', () {
    final projects = MemoryProjects.fromJson({
      'memories': 5,
      'earlier_versions': 2,
      'projects': [
        {'project_id': 'gone', 'memories': 1, 'earlier_versions': 0, 'paused': false, 'cataloged': false},
        {'project_id': 'z', 'memories': 2, 'earlier_versions': 1, 'paused': true, 'label': 'Zeta'},
        {'project_id': 'a', 'memories': 2, 'earlier_versions': 1, 'paused': false, 'label': 'alpha'},
      ],
    });

    test('orders cataloged by lowercased name, removed last', () {
      expect(projects.projects.map((p) => p.projectId), ['a', 'z', 'gone']);
      expect(projects.memories, 5);
    });

    test('labels, removed and operator []', () {
      expect(projects['z']!.paused, isTrue);
      expect(projects['nope'], isNull);
      expect(projects.labelFor('a'), 'alpha');
      expect(projects.labelFor('gone'), 'gone');
      expect(projects.labelFor('nope'), 'nope');
      expect(projects.isRemoved('gone'), isTrue);
      expect(projects.isRemoved('a'), isFalse);
      expect(projects.isRemoved('nope'), isFalse);
      expect(projects['a']!.cataloged, isTrue);
    });

    test('empty', () {
      expect(MemoryProjects.empty.projects, isEmpty);
    });
  });

  test('MemoryDetail parsing', () {
    final d = MemoryDetail.fromJson({
      'record': rec('b'),
      'earlier': [rec('a')],
      'earlier_has_more': true,
    });
    expect(d.record.id, 'b');
    expect(d.earlier.single.id, 'a');
    expect(d.earlierHasMore, isTrue);
    final bare = MemoryDetail.fromJson({'record': rec('b')});
    expect(bare.earlier, isEmpty);
    expect(bare.earlierHasMore, isFalse);
  });

  group('MemoryFilter', () {
    test('list request omits null keys', () {
      expect(const MemoryFilter().request(0), {
        'op': 'list',
        'versions': 'current',
        'offset': 0,
      });
      expect(
        const MemoryFilter(
          versions: MemoryVersions.earlier,
          projectId: 'p',
          memoryType: 'note',
        ).request(50),
        {
          'op': 'list',
          'versions': 'earlier',
          'offset': 50,
          'project_id': 'p',
          'memory_type': 'note',
        },
      );
    });

    test('search request trims the query', () {
      expect(const MemoryFilter(query: '  hello ').request(50), {
        'op': 'search',
        'query': 'hello',
        'limit': 50,
        'offset': 50,
        'versions': 'current',
      });
      expect(
        const MemoryFilter(query: 'x', projectId: 'p', memoryType: 'note').request(0),
        {
          'op': 'search',
          'query': 'x',
          'limit': 50,
          'offset': 0,
          'versions': 'current',
          'project_id': 'p',
          'memory_type': 'note',
        },
      );
    });

    test('blank query is a browse', () {
      expect(const MemoryFilter(query: '   ').isSearch, isFalse);
      expect(const MemoryFilter(query: '   ').request(0)['op'], 'list');
    });

    test('browse drops only the query', () {
      const f = MemoryFilter(
        query: 'q',
        versions: MemoryVersions.earlier,
        projectId: 'p',
        memoryType: 'note',
      );
      expect(
        f.browse(),
        const MemoryFilter(
          versions: MemoryVersions.earlier,
          projectId: 'p',
          memoryType: 'note',
        ),
      );
      expect(f.browse().hashCode, f.browse().hashCode);
    });
  });

  group('MemoryRecord getters', () {
    test('defaults', () {
      final r = MemoryRecord.fromJson(rec('a'));
      expect(r.isCurrent, isTrue);
      expect(r.isTaskScope, isFalse);
      expect(r.byApp, isFalse);
      expect(r.agentId, 'codex');
      expect(r.kindLabel, 'Note');
      expect(r.shortSessionId, isNull);
    });

    test('task scope, app source, superseded', () {
      final r = MemoryRecord.fromJson(
        rec(
          'a',
          extra: {
            'scope': 'task',
            'task_id': '0123456789abcdef',
            'source': {'actor': 'app'},
            'lifecycle': 'superseded',
            'memory_type': 'task_state',
          },
        ),
      );
      expect(r.isCurrent, isFalse);
      expect(r.isTaskScope, isTrue);
      expect(r.byApp, isTrue);
      expect(r.agentId, isNull);
      expect(r.shortSessionId, '01234567');
      expect(r.kindLabel, 'Session progress');
    });

    test('kind labels', () {
      expect(memoryKindLabel('preference'), 'Preference');
      expect(memoryKindLabel('observation'), 'Observation');
      expect(memoryKindLabel('other'), 'other');
      expect(kMemoryKindOrder, ['preference', 'note', 'observation', 'task_state']);
    });
  });

  test('concatMemoryPages drops a repeated boundary id, first wins', () {
    MemoryRecord r(String id) => MemoryRecord.fromJson(rec(id));
    final out = concatMemoryPages([
      MemoryPage(records: [r('a'), r('b')], hasMore: true, total: 4),
      MemoryPage(records: [r('b'), r('c')], hasMore: false, total: 4),
    ]);
    expect(out.map((e) => e.id), ['a', 'b', 'c']);
  });
}
