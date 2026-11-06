import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../launcher/host_controller.dart' show HostPhase;
import '../models/memory.dart';
import '../utils/platform_utils.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'host_status.dart' show hostStatusProvider;

typedef MemoryRequest =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

/// Resolves the transport at call time and watches nothing: a dependency
/// rebuild here would dispose every consumer's state (an open edit form, a
/// second `get`), and reading it must not spawn anything.
final memoryRequestProvider = Provider.autoDispose
    .family<MemoryRequest, MemoryTarget>((ref, target) {
      final container = ref.container;
      return (request) async {
        if (container.read(demoModeProvider)) {
          throw const MemoryException(
            'DEMO',
            'Memory is unavailable in the sample project.',
          );
        }
        if (target.machineId case final machineId?) {
          final client = await container.read(
            controlPlaneClientForProvider(machineId).future,
          );
          if (client == null || !client.transport.isEstablished) {
            throw const MemoryException(
              'NOT_CONNECTED',
              'Connect this machine to inspect its memories.',
            );
          }
          return client.transport.request('memory.request', params: request);
        }
        if (isMobilePlatform) {
          throw const MemoryException(
            'NO_MACHINE',
            'Open Memory from a connected machine.',
          );
        }
        final host = await container.read(hostControllerProvider).ensureHost();
        final client = HostControlClient(
          port: host.controlPort,
          token: host.token,
        );
        try {
          return await client.memoryRequest(request);
        } finally {
          client.close();
        }
      };
    });

final memoryStatusProvider = FutureProvider.autoDispose
    .family<MemoryStatus, MemoryTarget>((ref, target) async {
      final request = ref.watch(memoryRequestProvider(target));
      return MemoryStatus.fromJson(await request({'op': 'status'}));
    });

final memoryProjectsProvider = FutureProvider.autoDispose
    .family<MemoryProjects, MemoryTarget>((ref, target) async {
      final request = ref.watch(memoryRequestProvider(target));
      return MemoryProjects.fromJson(await request({'op': 'projects'}));
    });

typedef MemoryPageQuery = ({
  MemoryTarget target,
  MemoryFilter filter,
  int offset,
});

class MemoryPage {
  const MemoryPage({
    required this.records,
    required this.hasMore,
    required this.total,
  });
  final List<MemoryRecord> records;
  final bool hasMore;
  final int total;
}

final memoryPageProvider = FutureProvider.autoDispose
    .family<MemoryPage, MemoryPageQuery>((ref, query) async {
      final request = ref.watch(memoryRequestProvider(query.target));
      final result = await request(query.filter.request(query.offset));
      final records = [
        for (final record in result['results'] as List? ?? const [])
          MemoryRecord.fromJson((record as Map).cast<String, dynamic>()),
      ];
      return MemoryPage(
        records: records,
        hasMore: result['has_more'] == true,
        total: result['total'] as int? ?? records.length,
      );
    });

/// Pages are separate offset queries over a live newest-first table, so an
/// agent save between two fetches shifts rows down and repeats one across the
/// page boundary. Ids key the rows, the selection and arrow-key navigation, so
/// a repeat must never reach them.
List<MemoryRecord> concatMemoryPages(Iterable<MemoryPage> pages) {
  final seen = <String>{};
  return [
    for (final page in pages)
      for (final record in page.records)
        if (seen.add(record.id)) record,
  ];
}

typedef MemoryDetailQuery = ({MemoryTarget target, String id});

final memoryDetailProvider = FutureProvider.autoDispose
    .family<MemoryDetail, MemoryDetailQuery>((ref, query) async {
      final request = ref.watch(memoryRequestProvider(query.target));
      return MemoryDetail.fromJson(
        await request({
          'op': 'get',
          'id': query.id,
          'history': true,
          'earlier': true,
        }),
      );
    });

/// Asks the local desktop host, for the drawer. Null on mobile, in demo, unless
/// the host is up right now, or on any error: the drawer must never spawn a
/// host or dial a remote. Gated on the live phase because "was ever up" would
/// let a rebuild during `failed` or `restarting` respawn the host through
/// `ensureHost`.
Future<T?> _peekLocalMemory<T>(
  Ref ref,
  Map<String, dynamic> request,
  T Function(Map<String, dynamic> answer) parse,
) async {
  if (ref.watch(demoModeProvider) || isMobilePlatform) return null;
  if (ref.watch(hostStatusProvider).value?.phase != HostPhase.up) return null;
  try {
    final host = await ref.read(hostControllerProvider).peekHost();
    if (host == null) return null;
    final client = HostControlClient(port: host.controlPort, token: host.token);
    try {
      return parse(await client.memoryRequest(request));
    } finally {
      client.close();
    }
  } catch (_) {
    return null;
  }
}

final memoryDrawerSummaryProvider = FutureProvider.autoDispose<MemoryProjects?>(
  (ref) async {
    return _peekLocalMemory(ref, {'op': 'projects'}, MemoryProjects.fromJson);
  },
);

/// Whether this desktop's Memory is on right now, for the drawer's restart
/// badge. Anything short of a live host's answer is false.
final memoryDrawerEnabledProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  final enabled = await _peekLocalMemory(
    ref,
    {'op': 'status'},
    (answer) => MemoryStatus.fromJson(answer).enabled,
  );
  return enabled ?? false;
});

void invalidateMemoryViews(WidgetRef ref, MemoryTarget target) {
  ref.invalidate(memoryStatusProvider(target));
  ref.invalidate(memoryProjectsProvider(target));
  ref.invalidate(memoryPageProvider);
  ref.invalidate(memoryDetailProvider);
  ref.invalidate(memoryDrawerSummaryProvider);
  ref.invalidate(memoryDrawerEnabledProvider);
}
