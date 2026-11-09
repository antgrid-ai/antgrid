import 'package:clock/clock.dart';

import '../models/memory.dart';
import 'demo_identity.dart';
import 'fixtures/demo_memory_fixtures.dart';

/// In-memory stand-in for a machine's Memory store, answering the app's
/// `memory.request` ops in the shapes packages/antgrid-memory returns, so the
/// real Memory screen renders the sample. Edits, forgets and settings change
/// this copy only; nothing reaches a disk or a machine.
class DemoMemoryBackend {
  DemoMemoryBackend({DateTime Function()? now}) : _now = now ?? clock.now {
    final opened = _now();
    for (final seed in kDemoMemorySeeds) {
      final at = opened.subtract(seed.age).millisecondsSinceEpoch;
      _records[seed.id] = {
        'id': seed.id,
        'owner_id': kDemoMemoryOwnerId,
        'content': seed.content,
        'memory_type': seed.memoryType,
        'scope': seed.scope,
        'project_id': kDemoProjectId,
        'task_id': ?seed.taskId,
        if (seed.applicability.isNotEmpty) 'applicability': seed.applicability,
        'evidence': seed.evidence,
        'source': <String, dynamic>{
          'actor': seed.agentId == null ? 'app' : 'agent',
          'agent_id': ?seed.agentId,
        },
        'supersedes': ?seed.supersedes,
        'created_at': at,
        'updated_at': at,
      };
    }
    for (final record in [..._records.values]) {
      if (record['supersedes'] case final String old) {
        _records[old]?['superseded_by'] = record['id'];
      }
    }
  }

  final DateTime Function() _now;
  final Map<String, Map<String, dynamic>> _records = {};
  final Map<String, String> _savedByOperation = {};
  bool _enabled = true;
  bool _paused = false;
  bool _projectPaused = false;
  int _nextId = 1;

  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async =>
      switch (request['op']) {
        'status' || 'repair' || 'dismiss' => _status(),
        'settings' => _settings(request),
        'projects' => _projects(),
        'list' => _page(request, matches: (_) => true),
        'search' => _search(request),
        'get' => _get(request),
        'save' => _save(request),
        'forget' => _forget(request['id'] as String),
        'export' => _export(request['project_id'] as String?),
        _ => throw const MemoryException(kDemoRefusalCode, kDemoRefusalText),
      };

  Map<String, dynamic> _status() => {
    'available': true,
    'enabled': _enabled,
    'paused': _paused,
    'project_paused': false,
    'search_status': 'ready',
    'recovery_status': 'ready',
    'pending_operations': 0,
    'failed_operations': 0,
    'failures': const <Object>[],
    if (_enabled) 'sessions_without_memory': const <Object>[],
  };

  Map<String, dynamic> _settings(Map<String, dynamic> request) {
    if (request['enabled'] case final bool enabled) _enabled = enabled;
    if (request['paused'] case final bool paused) _paused = paused;
    if (request['project_paused'] case final bool paused) {
      _projectPaused = paused;
    }
    return _status();
  }

  bool _current(Map<String, dynamic> record) =>
      record['superseded_by'] == null;

  Map<String, dynamic> _projects() {
    final current = _records.values.where(_current).length;
    final earlier = _records.length - current;
    return {
      'projects': [
        {
          'project_id': kDemoProjectId,
          'label': kDemoDisplayName,
          'memories': current,
          'earlier_versions': earlier,
          'paused': _projectPaused,
          'cataloged': true,
        },
      ],
      'memories': current,
      'earlier_versions': earlier,
    };
  }

  Map<String, dynamic> _page(
    Map<String, dynamic> request, {
    required bool Function(Map<String, dynamic> record) matches,
    int limit = kMemoryPageSize,
  }) {
    final earlier = request['versions'] == MemoryVersions.earlier.name;
    final projectId = request['project_id'] as String?;
    final memoryType = request['memory_type'] as String?;
    final rows =
        _records.values
            .where(
              (r) =>
                  _current(r) != earlier &&
                  (projectId == null || r['project_id'] == projectId) &&
                  (memoryType == null || r['memory_type'] == memoryType) &&
                  matches(r),
            )
            .toList()
          ..sort(
            (a, b) => (b['created_at'] as int).compareTo(a['created_at'] as int),
          );
    final offset = request['offset'] as int? ?? 0;
    final page = rows.skip(offset).take(limit);
    return {
      'results': [for (final r in page) _wire(r)],
      'has_more': rows.length > offset + limit,
      'total': rows.length,
    };
  }

  /// Every term must appear; a quoted phrase is one term.
  Map<String, dynamic> _search(Map<String, dynamic> request) {
    final terms = [
      for (final m in RegExp(r'"([^"]+)"|(\S+)').allMatches(
        request['query'] as String,
      ))
        (m.group(1) ?? m.group(2)!).toLowerCase(),
    ];
    return _page(
      request,
      limit: request['limit'] as int? ?? kMemoryPageSize,
      matches: (r) {
        final text = '${r['content']} ${r['applicability'] ?? ''}'
            .toLowerCase();
        return terms.every(text.contains);
      },
    );
  }

  Map<String, dynamic> _require(String id) =>
      _records[id] ??
      (throw const MemoryException('NOT_FOUND', 'Memory not found'));

  Map<String, dynamic> _get(Map<String, dynamic> request) {
    final record = _require(request['id'] as String);
    final earlier = <Map<String, dynamic>>[];
    var previous = _records[record['supersedes']];
    while (previous != null) {
      earlier.add(_wire(previous));
      previous = _records[previous['supersedes']];
    }
    return {
      'record': _wire(record),
      if (request['earlier'] == true) ...{
        'earlier': earlier,
        'earlier_has_more': false,
      },
    };
  }

  Map<String, dynamic> _save(Map<String, dynamic> request) {
    final key = request['operation_key'] as String;
    if (_savedByOperation[key] case final id?) {
      return {
        'operation_key': key,
        'id': id,
        'outcome': 'already_present',
        'lifecycle': 'active',
      };
    }
    final save = (request['save'] as Map).cast<String, dynamic>();
    final replaced = switch (save['supersedes']) {
      final String id => _require(id),
      _ => null,
    };
    if (replaced != null && !_current(replaced)) {
      throw const MemoryException(
        'CONFLICT',
        'A newer version of this memory exists',
      );
    }
    final id = 'mem_demo_edit_${_nextId++}';
    final at = _now().millisecondsSinceEpoch;
    final applicability = save['applicability'] as String? ?? '';
    _records[id] = {
      'id': id,
      'owner_id': kDemoMemoryOwnerId,
      'content': save['content'],
      'memory_type': save['memory_type'],
      'scope': save['scope'],
      'project_id': replaced?['project_id'] ?? kDemoProjectId,
      'task_id': ?replaced?['task_id'],
      if (applicability.isNotEmpty) 'applicability': applicability,
      'evidence': <String>[...?(save['evidence'] as List?)?.cast<String>()],
      'source': <String, dynamic>{'actor': 'app'},
      'supersedes': ?replaced?['id'],
      'created_at': at,
      'updated_at': at,
    };
    replaced?['superseded_by'] = id;
    _savedByOperation[key] = id;
    return {
      'operation_key': key,
      'id': id,
      'outcome': 'saved',
      'lifecycle': 'active',
    };
  }

  /// Takes the whole correction chain with it, as the real store does.
  Map<String, dynamic> _forget(String id) {
    final chain = {id};
    final pending = [_require(id)];
    while (pending.isNotEmpty) {
      final row = pending.removeLast();
      for (final related in [
        _records[row['supersedes']],
        _records[row['superseded_by']],
      ]) {
        if (related != null && chain.add(related['id'] as String)) {
          pending.add(related);
        }
      }
    }
    chain.forEach(_records.remove);
    return {'forgotten': true, 'cleanup': 'complete'};
  }

  Map<String, dynamic> _export(String? projectId) => {
    'version': 1,
    'owner_id': kDemoMemoryOwnerId,
    'exported_at': _now().millisecondsSinceEpoch,
    'records': [
      for (final r in _records.values)
        if (projectId == null || r['project_id'] == projectId) _wire(r),
    ],
    'next_cursor': null,
  };

  /// A copy, so nothing the screen holds can change the store under it. Typed
  /// as decoded JSON is, which the export check requires.
  Map<String, dynamic> _wire(Map<String, dynamic> record) => {
    ...record,
    'evidence': <String>[...record['evidence'] as List<String>],
    'source': <String, dynamic>{...record['source'] as Map<String, dynamic>},
    'lifecycle': _current(record) ? 'active' : 'superseded',
  };
}
