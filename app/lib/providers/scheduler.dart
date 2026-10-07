import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../launcher/host_controller.dart' show HostPhase;
import '../connection/supervisor_state.dart' show Connected;
import '../models/scheduler.dart';
import '../util/device_id.dart';
import '../utils/platform_utils.dart';
import 'account_agents.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'recent_agents.dart';
import 'value_controller.dart';
import 'host_status.dart';
import 'supervisor_status.dart';

/// Null means the target desktop's loopback host.
final schedulerMachineProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController(null),
    );

final schedulerMachinesProvider = Provider<Map<String, String>>((ref) {
  if (ref.watch(demoModeProvider)) return const {};
  final machines = <String, String>{
    if (!isMobilePlatform) 'local': 'Local machine',
  };
  for (final recent in ref.watch(recentAgentsProvider)) {
    machines[baseDeviceUuid(recent.agentDeviceId)] =
        recent.hostMachineName ?? recent.agentLabel;
  }
  for (final machine in ref.watch(accountAgentsProvider).value ?? const []) {
    machines[machine.deviceUuid] = machine.machineName ?? machine.displayName;
  }
  return machines;
});

final schedulerTargetProvider = Provider<String?>((ref) {
  if (ref.watch(demoModeProvider)) return null;
  final selected = ref.watch(schedulerMachineProvider);
  if (selected != null) return selected == 'local' ? null : selected;
  if (!isMobilePlatform) return null;
  final recents = [...ref.watch(recentAgentsProvider)]
    ..sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
  if (recents.isNotEmpty) return baseDeviceUuid(recents.first.agentDeviceId);
  final machines = ref.watch(schedulerMachinesProvider);
  return machines.keys.firstOrNull;
});

final schedulerConnectedProvider = Provider<bool>((ref) {
  if (ref.watch(demoModeProvider)) return false;
  final target = ref.watch(schedulerTargetProvider);
  if (target != null) {
    return ref.watch(supervisorStatusProvider(target)).value is Connected;
  }
  if (isMobilePlatform) return false;
  return ref.watch(hostStatusProvider).value?.phase == HostPhase.up;
});

typedef SchedulerRequest =
    Future<Map<String, dynamic>> Function(
      String method, [
      Map<String, dynamic> params,
    ]);

/// Captures the target before an action starts, so changing the selector cannot
/// send the remainder of an editor operation to a different host.
final schedulerRequestProvider = Provider<SchedulerRequest>((ref) {
  final target = ref.watch(schedulerTargetProvider);
  final demo = ref.watch(demoModeProvider);
  final container = ref.container;
  return (method, [params = const {}]) async {
    if (demo || container.read(demoModeProvider)) {
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
    final client = await container.read(
      controlPlaneClientForProvider(target).future,
    );
    if (client == null || !client.transport.isEstablished) {
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
      schedules: schedulerMaps(
        listed['schedules'],
      ).map(AgentSchedule.fromJson).toList(),
      runs: schedulerMaps(history['runs']).map(ScheduleRun.fromJson).toList(),
    );
  }
}
