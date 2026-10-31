Map<String, dynamic> memoryExportRecord(
  String id, {
  String owner = 'owner',
  String lifecycle = 'active',
  String? supersedes,
}) => {
  'id': id,
  'owner_id': owner,
  'content': 'Verified finding $id: café / 路径 "quoted"\nnext line',
  'memory_type': 'observation',
  'scope': 'project',
  'project_id': 'project',
  'applicability': 'Windows only',
  'evidence': ['source.dart:1'],
  'source': {'actor': 'agent', 'agent_id': 'codex', 'session_id': 'session'},
  'created_at': 1,
  'updated_at': 2,
  'lifecycle': lifecycle,
  'supersedes': ?supersedes,
};

Map<String, dynamic> memoryExportPage({
  List<Map<String, dynamic>> records = const [],
  Object? cursor,
  String owner = 'owner',
  int timestamp = 1000,
}) => {
  'version': 1,
  'owner_id': owner,
  'exported_at': timestamp,
  'records': records,
  'next_cursor': cursor,
};
