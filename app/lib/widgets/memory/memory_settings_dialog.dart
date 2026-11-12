import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/memory.dart';
import '../../providers/memory.dart';
import '../../util/detached.dart';
import 'memory_mutation.dart';

/// [context] must sit under an `AbCarbonScope`: the modal route takes its theme
/// and density from the presenting context.
Future<void> showMemorySettings(
  BuildContext context, {
  required MemoryTarget target,
  required Future<void> Function() onExportAll,
  String? machineName,
}) => showCarbonModal<void>(
  context,
  builder: (_) => MemorySettingsDialog(
    target: target,
    onExportAll: onExportAll,
    machineName: machineName,
  ),
);

class MemorySettingsDialog extends ConsumerStatefulWidget {
  const MemorySettingsDialog({
    super.key,
    required this.target,
    required this.onExportAll,
    this.machineName,
  });

  final MemoryTarget target;
  final Future<void> Function() onExportAll;

  /// Null for the local machine.
  final String? machineName;

  @override
  ConsumerState<MemorySettingsDialog> createState() =>
      _MemorySettingsDialogState();
}

class _MemorySettingsDialogState extends ConsumerState<MemorySettingsDialog>
    with MemoryMutation<MemorySettingsDialog> {
  @override
  MemoryTarget get mutationTarget => widget.target;

  @override
  String? get mutationMachineName => widget.machineName;

  String get _machine => widget.machineName ?? 'this machine';

  Future<void> _turnOff() async {
    final confirmed =
        await showCarbonModal<bool>(
          context,
          builder: (dialog) {
            final t = CarbonTheme.of(dialog);
            return CarbonModal.confirmation(
              title: 'Turn off Memory?',
              body: Text(
                'Agents stop saving and recalling memories. Everything saved stays on $_machine, and you can turn Memory back on here.',
                style: t.typography.body.copyWith(color: t.colors.textPrimary),
              ),
              danger: true,
              secondary: CarbonModalAction(
                label: 'Cancel',
                onPressed: () => Navigator.of(dialog).pop(false),
              ),
              primary: CarbonModalAction(
                label: 'Turn off',
                onPressed: () => Navigator.of(dialog).pop(true),
              ),
            );
          },
        ) ??
        false;
    if (!confirmed || !mounted) return;
    if (await sendMutation({'op': 'settings', 'enabled': false}) && mounted) {
      Navigator.of(context).pop();
    }
  }

  Widget _body(MemoryStatus? status, MemoryProjects? projects) {
    final t = CarbonTheme.of(context);
    final machinePaused = status?.paused ?? false;
    final live = [
      for (final p in projects?.projects ?? const <MemoryProjectSummary>[])
        if (!p.removed) p,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mutationError case final error?) ...[
          CarbonNotification(
            key: ValueKey(error),
            kind: CarbonNotificationKind.error,
            subtitle: error,
          ),
          const SizedBox(height: CarbonSpacing.spacing05),
        ],
        if (status == null)
          const Center(child: CarbonLoading(size: CarbonLoadingSize.small))
        else ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: CarbonToggle(
              labelText: 'Let agents save memories',
              value: !status.paused,
              onChanged: busy
                  ? null
                  : (v) => detached(
                      'Memory',
                      'pause toggle failed',
                      () => sendMutation({'op': 'settings', 'paused': !v}),
                    ),
            ),
          ),
          const SizedBox(height: CarbonSpacing.spacing02),
          Text(
            "When this is off, agents can still recall what's saved, and you can still edit and forget memories.",
            style: t.typography.helper.copyWith(color: t.colors.textSecondary),
          ),
        ],
        const SizedBox(height: CarbonSpacing.spacing05),
        if (machinePaused) ...[
          Text(
            'Saving is paused for every project.',
            style: t.typography.helper.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: CarbonSpacing.spacing03),
        ],
        CarbonContainedList(
          label: 'Saving by project',
          variant: CarbonContainedListVariant.disclosed,
          status: projects == null
              ? CarbonContainedListStatus.loading
              : CarbonContainedListStatus.content,
          emptyContent: Text(
            'No projects yet.',
            style: t.typography.body.copyWith(color: t.colors.textSecondary),
          ),
          children: [
            for (final p in live)
              CarbonContainedListRow(
                key: ValueKey(p.projectId),
                title: p.displayName,
                actions: [
                  CarbonToggle(
                    small: true,
                    value: !machinePaused && !p.paused,
                    semanticLabel: 'Saving for ${p.displayName}',
                    onText: 'Saving',
                    offText: 'Paused',
                    onChanged: busy || machinePaused
                        ? null
                        : (v) => detached(
                            'Memory',
                            'project pause toggle failed',
                            () => sendMutation({
                              'op': 'settings',
                              'project_id': p.projectId,
                              'project_paused': !v,
                            }),
                          ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: CarbonSpacing.spacing05),
        Text(
          "Memories stay on $_machine. Agents treat them as notes, not instructions: your repository's own docs always win.",
          style: t.typography.body.copyWith(color: t.colors.textSecondary),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(memoryStatusProvider(widget.target)).value;
    final projects = ref.watch(memoryProjectsProvider(widget.target)).value;
    return CarbonModal(
      title: 'Memory settings',
      body: _body(status, projects),
      actions: [
        CarbonModalAction(
          label: 'Export all memories',
          kind: CarbonButtonKind.secondary,
          onPressed: () {
            final export = widget.onExportAll;
            Navigator.of(context).pop();
            detached('Memory', 'export failed', export);
          },
        ),
        CarbonModalAction(
          label: 'Turn off Memory',
          kind: CarbonButtonKind.danger,
          onPressed: busy
              ? null
              : () => detached('Memory', 'turn off failed', _turnOff),
        ),
      ],
    );
  }
}
