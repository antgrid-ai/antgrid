import 'package:flutter/foundation.dart';

@immutable
class MemoryTarget {
  const MemoryTarget.machine({this.machineId, this.label = 'This machine'})
    : projectEntryId = null;
  const MemoryTarget.project(String entryId, {this.label = 'This project'})
    : projectEntryId = entryId,
      machineId = null;

  final String? machineId;
  final String? projectEntryId;
  final String label;
  bool get isProject => projectEntryId != null;

  @override
  bool operator ==(Object other) =>
      other is MemoryTarget &&
      other.machineId == machineId &&
      other.projectEntryId == projectEntryId &&
      other.label == label;
  @override
  int get hashCode => Object.hash(machineId, projectEntryId, label);
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
      error = json['error'] is Map
          ? (json['error'] as Map)['message'] as String?
          : json['error'] as String?;
  final bool available;
  final bool enabled;
  final bool paused;
  final bool projectPaused;
  final String searchStatus;
  final String recoveryStatus;
  final int pendingOperations;
  final int failedOperations;
  final String? error;
}

class MemoryRecord {
  MemoryRecord.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      content = json['content'] as String,
      memoryType = json['memory_type'] as String,
      scope = json['scope'] as String,
      applicability = json['applicability'] as String? ?? '',
      projectId = json['project_id'] as String?,
      taskId = json['task_id'] as String?,
      checkoutId = json['checkout_id'] as String?,
      supersedes = json['supersedes'] as String?,
      supersededBy = json['superseded_by'] as String?,
      lifecycle = json['lifecycle'] as String? ?? 'active',
      source = (json['source'] as Map? ?? const {}).cast<String, dynamic>(),
      evidence = (json['evidence'] as List? ?? const []).cast<String>(),
      createdAt = _date(json['created_at']),
      updatedAt = _date(json['updated_at']),
      excerpted =
          json['excerpted'] == true || json['content_complete'] == false;

  final String id;
  final String content;
  final String memoryType;
  final String scope;
  final String applicability;
  final String? projectId;
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
