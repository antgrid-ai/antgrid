import 'dart:convert';

import 'package:flutter/foundation.dart';

@immutable
class MemoryTarget {
  const MemoryTarget.machine({this.machineId, this.label = 'This machine'});

  /// Null is this desktop's local host.
  final String? machineId;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is MemoryTarget &&
      other.machineId == machineId &&
      other.label == label;
  @override
  int get hashCode => Object.hash(machineId, label);
}

enum MemoryVersions { current, earlier }

const kMemoryPageSize = 50;
const kMemoryKindOrder = ['preference', 'note', 'observation', 'task_state'];

String memoryKindLabel(String memoryType) => switch (memoryType) {
  'preference' => 'Preference',
  'note' => 'Note',
  'observation' => 'Observation',
  'task_state' => 'Session progress',
  _ => memoryType,
};

@immutable
class MemoryFilter {
  const MemoryFilter({
    this.query = '',
    this.versions = MemoryVersions.current,
    this.projectId,
    this.memoryType,
  });

  final String query;
  final MemoryVersions versions;
  final String? projectId;
  final String? memoryType;

  bool get isSearch => query.trim().isNotEmpty;

  MemoryFilter copyWith({
    String? query,
    MemoryVersions? versions,
    String? projectId,
    bool clearProjectId = false,
    String? memoryType,
    bool clearMemoryType = false,
  }) => MemoryFilter(
    query: query ?? this.query,
    versions: versions ?? this.versions,
    projectId: clearProjectId ? null : projectId ?? this.projectId,
    memoryType: clearMemoryType ? null : memoryType ?? this.memoryType,
  );

  MemoryFilter browse() => copyWith(query: '');

  Map<String, dynamic> request(int offset) => isSearch
      ? {
          'op': 'search',
          'query': query.trim(),
          'limit': kMemoryPageSize,
          'offset': offset,
          'versions': versions.name,
          'project_id': ?projectId,
          'memory_type': ?memoryType,
        }
      : {
          'op': 'list',
          'versions': versions.name,
          'offset': offset,
          'project_id': ?projectId,
          'memory_type': ?memoryType,
        };

  @override
  bool operator ==(Object other) =>
      other is MemoryFilter &&
      other.query == query &&
      other.versions == versions &&
      other.projectId == projectId &&
      other.memoryType == memoryType;
  @override
  int get hashCode => Object.hash(query, versions, projectId, memoryType);
}

class MemoryException implements Exception {
  const MemoryException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

class MemoryResponse {
  const MemoryResponse({
    required this.requestId,
    required this.ok,
    this.result,
    this.error,
  });
  final String requestId;
  final bool ok;
  final Map<String, dynamic>? result;
  final MemoryException? error;

  static MemoryResponse? fromJson(Map<String, dynamic> json) {
    final requestId = json['requestId'];
    final ok = json['ok'];
    if (requestId is! String || ok is! bool) return null;
    if (ok) {
      final result = json['result'];
      if (result is! Map<String, dynamic>) return null;
      return MemoryResponse(requestId: requestId, ok: true, result: result);
    }
    final error = json['error'];
    if (error is! Map ||
        error['code'] is! String ||
        error['message'] is! String) {
      return null;
    }
    return MemoryResponse(
      requestId: requestId,
      ok: false,
      error: MemoryException(
        error['code'] as String,
        error['message'] as String,
      ),
    );
  }
}

class MemoryExportPage {
  const MemoryExportPage._({
    required this.ownerId,
    required this.exportedAt,
    required this.records,
    required this.nextCursor,
  });

  final String ownerId;
  final int exportedAt;
  final List<Map<String, dynamic>> records;
  final String? nextCursor;

  factory MemoryExportPage.fromJson(Map<String, dynamic> json) {
    const fields = {
      'version',
      'owner_id',
      'exported_at',
      'records',
      'next_cursor',
    };
    final owner = json['owner_id'];
    final timestamp = json['exported_at'];
    final records = json['records'];
    final cursor = json['next_cursor'];
    if (json.length != fields.length ||
        !json.keys.every(fields.contains) ||
        json['version'] is! int ||
        json['version'] != 1 ||
        !_exportId(owner) ||
        timestamp is! int ||
        timestamp < 0 ||
        records is! List ||
        records.length > 64 ||
        (cursor != null &&
            (cursor is! String ||
                cursor.trim().isEmpty ||
                utf8.encode(cursor).length > 2048))) {
      throw _invalidExportPage;
    }
    final parsed = <Map<String, dynamic>>[];
    for (final record in records) {
      if (record is! Map<String, dynamic> || !_exportRecord(record, owner)) {
        throw _invalidExportPage;
      }
      parsed.add(
        Map<String, dynamic>.unmodifiable({
          ...record,
          'evidence': List<String>.unmodifiable(record['evidence'] as List),
          'source': Map<String, dynamic>.unmodifiable(record['source'] as Map),
        }),
      );
    }
    if ((parsed.isEmpty && cursor != null) ||
        utf8.encode(jsonEncode(json)).length > 256 * 1024) {
      throw _invalidExportPage;
    }
    return MemoryExportPage._(
      ownerId: owner as String,
      exportedAt: timestamp,
      records: List.unmodifiable(parsed),
      nextCursor: cursor as String?,
    );
  }
}

const _invalidExportPage = MemoryException(
  'BAD_RESPONSE',
  'Malformed memory export page. Start the export again.',
);

bool _exportId(Object? value) =>
    value is String && value.isNotEmpty && value.length <= 256;

bool _exportRecord(Map<String, dynamic> record, Object? owner) {
  const optionalIds = {
    'task_id',
    'checkout_id',
    'supersedes',
    'superseded_by',
  };
  const fields = {
    'id',
    'owner_id',
    'content',
    'memory_type',
    'scope',
    'applicability',
    'evidence',
    'source',
    'created_at',
    'updated_at',
    'lifecycle',
    'project_id',
    ...optionalIds,
  };
  final source = record['source'];
  final evidence = record['evidence'];
  if (!record.keys.every(fields.contains) ||
      !_exportId(record['id']) ||
      record['owner_id'] != owner ||
      record['content'] is! String ||
      !const {
        'preference',
        'task_state',
        'observation',
        'note',
      }.contains(record['memory_type']) ||
      !const {'project', 'task'}.contains(record['scope']) ||
      !_exportId(record['project_id']) ||
      !const {
        'active',
        'expired',
        'superseded',
      }.contains(record['lifecycle']) ||
      (record.containsKey('applicability') &&
          record['applicability'] is! String) ||
      optionalIds.any(
        (key) => record.containsKey(key) && !_exportId(record[key]),
      ) ||
      record['created_at'] is! int ||
      (record['created_at'] as int) < 0 ||
      record['updated_at'] is! int ||
      (record['updated_at'] as int) < 0 ||
      evidence is! List ||
      !evidence.every((value) => value is String) ||
      source is! Map<String, dynamic> ||
      !const {'agent', 'app'}.contains(source['actor'])) {
    return false;
  }
  const sourceIds = {'project_id', 'session_id', 'checkout_id', 'agent_id'};
  return source.keys.every(
        (key) => key == 'actor' || sourceIds.contains(key),
      ) &&
      sourceIds.every(
        (key) => !source.containsKey(key) || _exportId(source[key]),
      );
}

class MemoryFailure {
  MemoryFailure.fromJson(Map<String, dynamic> json)
    : code = json['code'] as String? ?? '',
      targetId = json['target_id'] as String? ?? '',
      latestId = json['latest_id'] as String?,
      projectId = json['project_id'] as String?;

  final String code;
  final String targetId;
  final String? latestId;
  final String? projectId;

  /// The latest version is what the user can act on; the target is only the
  /// stale one the failed save named.
  String get showId => latestId ?? targetId;
}

class MemoryStatus {
  MemoryStatus.fromJson(Map<String, dynamic> json)
    : available = json['available'] == true,
      enabled = json['enabled'] == true,
      paused = json['paused'] == true,
      projectPaused = json['project_paused'] == true,
      searchStatus = json['search_status'] as String? ?? 'unavailable',
      recoveryStatus = json['recovery_status'] as String? ?? 'ready',
      pendingOperations = json['pending_operations'] as int? ?? 0,
      failedOperations = json['failed_operations'] as int? ?? 0,
      failures = [
        for (final failure in json['failures'] as List? ?? const [])
          if (failure is Map)
            MemoryFailure.fromJson(failure.cast<String, dynamic>()),
      ],
      error = (json['error'] as Map?)?['message'] as String?;
  final bool available;
  final bool enabled;
  final bool paused;
  final bool projectPaused;
  final String searchStatus;
  final String recoveryStatus;
  final int pendingOperations;
  final int failedOperations;
  final List<MemoryFailure> failures;
  final String? error;

  bool get searchReady => searchStatus == 'ready';
  bool get cleanupFailed => recoveryStatus == 'cleanup_failed';
  bool get needsAttention =>
      !available || !searchReady || failedOperations > 0 || cleanupFailed;
}

class MemoryRecord {
  MemoryRecord.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      content = json['content'] as String,
      memoryType = json['memory_type'] as String,
      scope = json['scope'] as String,
      applicability = json['applicability'] as String? ?? '',
      projectId = json['project_id'] as String,
      taskId = json['task_id'] as String?,
      checkoutId = json['checkout_id'] as String?,
      supersedes = json['supersedes'] as String?,
      supersededBy = json['superseded_by'] as String?,
      lifecycle = json['lifecycle'] as String? ?? 'active',
      source = (json['source'] as Map? ?? const {}).cast<String, dynamic>(),
      evidence = (json['evidence'] as List? ?? const []).cast<String>(),
      createdAt = _date(json['created_at']),
      updatedAt = _date(json['updated_at']),
      excerpted = json['excerpted'] == true;

  final String id;
  final String content;
  final String memoryType;
  final String scope;
  final String applicability;
  final String projectId;
  final String? taskId;
  final String? checkoutId;
  final String? supersedes;
  final String? supersededBy;
  final String lifecycle;
  final Map<String, dynamic> source;
  final List<String> evidence;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool excerpted;

  bool get isCurrent => lifecycle == 'active';
  bool get isTaskScope => scope == 'task';
  bool get byApp => source['actor'] == 'app';
  String? get agentId => source['agent_id'] as String?;
  String get kindLabel => memoryKindLabel(memoryType);
  String? get shortSessionId {
    final id = taskId;
    if (id == null) return null;
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  static DateTime? _date(Object? value) => switch (value) {
    int value => DateTime.fromMillisecondsSinceEpoch(value),
    String value => DateTime.tryParse(value),
    _ => null,
  };

  Map<String, dynamic> correction({
    required String content,
    required String applicability,
    required List<String> evidence,
  }) => {
    'content': content,
    'memory_type': memoryType,
    'scope': scope,
    'applicability': applicability,
    'evidence': evidence,
    'restrict_to_checkout': checkoutId != null,
    'supersedes': id,
  };
}

class MemoryDetail {
  MemoryDetail.fromJson(Map<String, dynamic> json)
    : record = MemoryRecord.fromJson(
        (json['record'] as Map).cast<String, dynamic>(),
      ),
      earlier = [
        for (final record in json['earlier'] as List? ?? const [])
          MemoryRecord.fromJson((record as Map).cast<String, dynamic>()),
      ],
      earlierHasMore = json['earlier_has_more'] == true;

  final MemoryRecord record;
  final List<MemoryRecord> earlier;
  final bool earlierHasMore;
}

class MemoryProjectSummary {
  MemoryProjectSummary.fromJson(Map<String, dynamic> json)
    : projectId = json['project_id'] as String,
      memories = json['memories'] as int? ?? 0,
      paused = json['paused'] == true,
      label = json['label'] as String?,
      cataloged = json['cataloged'] != false;

  final String projectId;
  final int memories;
  final bool paused;
  final String? label;
  final bool cataloged;

  String get displayName => (label?.isNotEmpty ?? false) ? label! : projectId;
  bool get removed => !cataloged;

  /// A removed project's name is unknowable, so the suffix is the only hint
  /// that its rows are orphaned.
  String get stateLabel => removed ? '$displayName (removed)' : displayName;
}

class MemoryProjects {
  const MemoryProjects._(this.projects, this.memories);

  factory MemoryProjects.fromJson(Map<String, dynamic> json) {
    final rows = [
      for (final row in json['projects'] as List? ?? const [])
        if (row is Map)
          MemoryProjectSummary.fromJson(row.cast<String, dynamic>()),
    ];
    // Removed projects sink: their name is unknowable, so they read as ids.
    rows.sort((a, b) {
      final byRemoved = (a.removed ? 1 : 0).compareTo(b.removed ? 1 : 0);
      return byRemoved != 0
          ? byRemoved
          : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return MemoryProjects._(
      List.unmodifiable(rows),
      json['memories'] as int? ?? 0,
    );
  }

  static const empty = MemoryProjects._([], 0);

  final List<MemoryProjectSummary> projects;
  final int memories;

  MemoryProjectSummary? operator [](String projectId) {
    for (final project in projects) {
      if (project.projectId == projectId) return project;
    }
    return null;
  }

  String labelFor(String projectId) =>
      this[projectId]?.displayName ?? projectId;
  bool isRemoved(String projectId) => this[projectId]?.removed ?? false;
  String stateLabelFor(String projectId) =>
      this[projectId]?.stateLabel ?? projectId;
}
