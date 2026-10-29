import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../models/memory.dart';
import '../services/memory_service.dart';
import '../utils/platform_utils.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'providers.dart' show warmServiceFor;

typedef MemoryRequest =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

/// Resolves the transport at call time and watches nothing: a dependency
/// rebuild here would dispose every consumer's state (an open correction
/// editor, a second `get`), and reading it must not build the project session.
final memoryRequestProvider = Provider.autoDispose
    .family<MemoryRequest, MemoryTarget>((ref, target) {
  final container = ref.container;
  return (request) async {
    if (container.read(demoModeProvider)) {
      throw const MemoryException(
        'UNAVAILABLE',
        'Memory is unavailable in the sample project.',
      );
    }
    if (target.projectEntryId case final entryId?) {
      final session = await warmServiceFor(
        container,
        entryId,
        (session) => session,
      );
      if (session == null) {
        throw const MemoryException(
          'UNAVAILABLE',
          'Reconnect this project to inspect its memories.',
        );
      }
      return requestProjectMemory(session, request);
    }
    if (target.machineId case final machineId?) {
      final client = await container.read(
        controlPlaneClientForProvider(machineId).future,
      );
      if (client == null || !client.transport.isEstablished) {
        throw const MemoryException(
          'UNAVAILABLE',
          'Connect this machine to inspect its memories.',
        );
      }
      return client.transport.request('memory.request', params: request);
    }
    if (isMobilePlatform) {
      throw const MemoryException(
        'UNAVAILABLE',
        'Open Memory from a connected machine.',
      );
    }
    final host = await container.read(hostControllerProvider).ensureHost();
    final client = HostControlClient(port: host.controlPort, token: host.token);
    try {
      return await client.memoryRequest(request);
    } finally {
      client.close();
    }
  };
    });

typedef MemoryQuery = ({
  MemoryTarget target,
  String query,
  bool history,
  int offset,
});

class MemorySnapshot {
  const MemorySnapshot({
    required this.status,
    this.records = const [],
    this.hasMore = false,
    this.resultError,
  });
  final MemoryStatus status;
  final List<MemoryRecord> records;
  final bool hasMore;
  final Object? resultError;
}

final memorySnapshotProvider = FutureProvider.autoDispose
    .family<MemorySnapshot, MemoryQuery>((ref, query) async {
      final request = ref.watch(memoryRequestProvider(query.target));
      final status = MemoryStatus.fromJson(await request({'op': 'status'}));
      if (!status.available) return MemorySnapshot(status: status);
      if (query.query.isNotEmpty && status.searchStatus != 'ready') {
        return MemorySnapshot(
          status: status,
          resultError: const MemoryException(
            'SEARCH_UNAVAILABLE',
            'Search is unavailable. Clear the search to browse saved records.',
          ),
        );
      }
      try {
        final result = await request(
          query.query.isEmpty
              ? {'op': 'list', 'history': query.history, 'offset': query.offset}
              : {'op': 'search', 'query': query.query, 'limit': 10},
        );
        return MemorySnapshot(
          status: status,
          records: (result['results'] as List? ?? const [])
              .map(
                (record) => MemoryRecord.fromJson(
                  (record as Map).cast<String, dynamic>(),
                ),
              )
              .toList(growable: false),
          hasMore: result['has_more'] == true,
        );
      } catch (error) {
        return MemorySnapshot(status: status, resultError: error);
      }
    });

typedef MemoryDetailQuery = ({MemoryTarget target, String id});
final memoryDetailProvider = FutureProvider.autoDispose
    .family<MemoryRecord, MemoryDetailQuery>((ref, query) async {
      final request = ref.watch(memoryRequestProvider(query.target));
      final result = await request({
        'op': 'get',
        'id': query.id,
        'history': true,
      });
      return MemoryRecord.fromJson(
        (result['record'] as Map).cast<String, dynamic>(),
      );
    });
