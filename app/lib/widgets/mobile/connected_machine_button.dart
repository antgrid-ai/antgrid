import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../providers/machine_directory.dart';
import '../../providers/mobile_connection.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../carbon_status_dot.dart';
import '../machine_scope_menu.dart' show machineActivityLine;
import '../machine_summary_tile.dart';
import 'mobile_connect.dart' show SwitchMachineSheet, mobileMachineName;

/// The machine the phone is connected to, heading the drawer and the New
/// Session canvas. Opens [SwitchMachineSheet].
class ConnectedMachineButton extends ConsumerWidget {
  const ConnectedMachineButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(mobileConnectionProvider.select((c) => c.machineId));
    if (id == null) return const SizedBox.shrink();
    final machine = ref
        .watch(machineDirectoryProvider)
        .firstWhereOrNull((m) => m.id == id);
    final name = mobileMachineName(ref, id);
    final activity = machine == null
        ? null
        : machineActivityLine(
            machine,
            ref.watch(recentSessionsProvider),
            ref.watch(recentSessionStatusesProvider),
          );
    return MachineSummaryTile(
      leading: CarbonStatusDot(
        color: CarbonTheme.of(context).colors.supportSuccess,
      ),
      title: name,
      titleIsName: true,
      summary: 'Connected · ${activity ?? 'idle'}',
      semanticLabel:
          'Connected to $name, ${activity ?? 'idle'}. Switch machine',
      onPressed: () =>
          showAbAdaptiveSheet<void>(context, child: const SwitchMachineSheet()),
    );
  }
}
