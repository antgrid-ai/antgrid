import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo/demo_scheduler.dart';
import '../demo/demo_identity.dart' show kDemoMachineName;
import '../launcher/host_control_client.dart';
import '../models/scheduler.dart';
import '../utils/platform_utils.dart';
import 'account_machines.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'scheduler_timezone.dart';

/// Rebuilt whenever the flag flips, so every entry into the sample starts from
/// the seed and nothing made inside it survives leaving.
final demoSchedulerBackendProvider = Provider<DemoSchedulerBackend>((ref) {
  ref.watch(demoModeProvider);
  final container = ref.container;
  return DemoSchedulerBackend(
    localTimezone: () => container.read(schedulerLocalTimezoneProvider.future),
  );
});

final schedulerMachinesProvider = Provider<Map<String, String>>((ref) {
  if (ref.watch(demoModeProvider)) {
    return const {kLocalMachineKey: kDemoMachineName};
  }
  return ref.watch(accountMachinesProvider);
});

final schedulerTargetProvider = Provider<String?>(
  (ref) => ref.watch(machineTargetProvider),
);

final schedulerConnectedProvider = Provider<bool>((ref) {
  // The sample has no connection to wait for, and every action is gated on this.
  if (ref.watch(demoModeProvider)) return true;
  return ref.watch(machineConnectedProvider(ref.watch(schedulerTargetProvider)));
});

typedef SchedulerRequest =
    Future<Map<String, dynamic>> Function(
      String method, [
      Map<String, dynamic> params,
    ]);

/// Captures the target before an action starts, so changing the selector cannot
/// send the remainder of an editor operation to a different host.
final schedulerRequestProvider = Provider<SchedulerRequest>((ref) {
  if (ref.watch(demoModeProvider)) {
    return ref.watch(demoSchedulerBackendProvider).request;
  }
  final target = ref.watch(schedulerTargetProvider);
  final container = ref.container;
  return (method, [params = const {}]) async {
    // A closure captured before the sample opened must not send a real host
    // the sample's edits.
    if (container.read(demoModeProvider)) {
      throw StateError('Scheduler is unavailable in the demo');
    }
    if (target == null) {
      if (isMobilePlatform) {
        throw StateError('Connect a machine to use Scheduler');
      }
      final host = await container.read(hostControllerProvider).ensureHost();
      final client = HostControlClient(
        port: host.controlPort,
        token: host.token,
      );
      try {
        return await client.schedulerRequest(method, params);
      } finally {
        client.close();
      }
    }
    final client = await connectedControlPlaneClient(container, target);
    if (client == null) {
      throw StateError('Machine unavailable. Connect it to manage schedules.');
    }
    return client.schedulerRequest(method, params);
  };
});

class SchedulerSnapshot {
  final SchedulerCapabilities capabilities;
  final List<SchedulerProject> projects;
  final List<AgentSchedule> schedules;
  final List<ScheduleRun> runs;
  const SchedulerSnapshot({
    required this.capabilities,
    required this.projects,
    required this.schedules,
    required this.runs,
  });
  static Future<SchedulerSnapshot> load(SchedulerRequest request) async {
    final capabilities = SchedulerCapabilities.fromJson(
      await request('scheduler.capabilities'),
    );
    if (!capabilities.supported) {
      return SchedulerSnapshot(
        capabilities: capabilities,
        projects: const [],
        schedules: const [],
        runs: const [],
      );
    }
    final listed = await request('scheduler.list');
    final history = await request('scheduler.runs');
    return SchedulerSnapshot(
      capabilities: capabilities,
      projects: schedulerMaps(
        listed['projects'],
      ).map(SchedulerProject.fromJson).toList(),
      // One-offs travel in their own key so a bridge-side one-off never reaches
      // an older app's cron-required parser through 'schedules'.
      schedules: [
        ...schedulerMaps(listed['schedules']),
        ...schedulerMaps(listed['oneOffSchedules']),
      ].map(AgentSchedule.fromJson).toList(),
      runs: schedulerMaps(history['runs']).map(ScheduleRun.fromJson).toList(),
    );
  }
}
