import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_panel_header.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/session_target.dart';
import '../providers/agent_transport.dart';
import '../services/control_plane_client.dart';

/// Post-pair project picker. Lists the projects the agent advertises to this
/// phone over the control plane (its allowlist ∩ the host catalog) and lets the
/// user open a running one or remotely start a stopped one.
///
/// The [ControlPlaneClient] is injected (not read from a provider) so this
/// screen is drivable in a widget test with a [FakeAgentTransport]-backed
/// client — mirroring the per-project services' injected-transport pattern.
class ProjectPickerScreen extends ConsumerWidget {
  const ProjectPickerScreen({super.key, required this.client});

  final ControlPlaneClient client;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: Column(
        children: [
          const AbPanelHeader(title: 'PROJECTS'),
          Expanded(
            child: StreamBuilder<ControlPlaneState>(
              stream: client.stateStream,
              initialData: client.currentState,
              builder: (context, snapshot) {
                final state = snapshot.data ?? const ControlPlaneState();
                final projects = state.projects;
                final body = projects.isEmpty
                    ? const AbEmptyState(
                        title: 'No projects available',
                        subtitle:
                            'Allow a project from the desktop app to '
                            'see it here.',
                        showBrand: true,
                      )
                    : ListView.separated(
                        itemCount: projects.length,
                        separatorBuilder: (_, _) =>
                            const AbSeparator.horizontal(),
                        itemBuilder: (_, i) {
                          final p = projects[i];
                          return _ProjectRow(
                            project: p,
                            onOpen: () =>
                                ref
                                    .read(selectedTargetProvider.notifier)
                                    .set(RemoteTarget.legacy(
                                  p.projectId,
                                )),
                            onStart: () => client.startProject(p.projectId),
                          );
                        },
                      );
                return Column(
                  children: [
                    if (state.lastError != null)
                      _ErrorBanner(error: state.lastError!),
                    Expanded(child: body),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline failure notice for a rejected control-plane verb (the agent's
/// `control:result` with `ok:false`, e.g. NOT_ALLOWED when a phone taps Start
/// for a project that was de-allowlisted). A notice is chrome → sans.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});

  final ControlPlaneError error;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      decoration: BoxDecoration(
        color: antgrid.bgRaised,
        border: Border(bottom: BorderSide(color: antgrid.borderSubtle)),
      ),
      child: Text(
        error.message.isEmpty ? error.code : error.message,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: antgrid.error,
        ),
      ),
    );
  }
}

/// A single advertised project. Label is chrome (sans, the row default);
/// the path/id is code/data (mono). A running project offers Open (select the
/// data plane); a stopped one offers Start (remote `project:start`).
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.onOpen,
    required this.onStart,
  });

  final AdvertisedProject project;
  final VoidCallback onOpen;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final running = project.running;
    return AbListRow(
      leading: AbStatusDot(
        tone: running ? AbStatusTone.success : AbStatusTone.disabled,
        pulse: running,
      ),
      title: Text(project.label ?? project.projectId),
      subtitle: Text(
        project.path ?? project.projectId,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXxs,
          color: context.antgrid.textMuted,
        ),
      ),
      trailing: running
          ? AbButton(
              label: 'Open',
              variant: AbButtonVariant.primary,
              compact: true,
              onTap: onOpen,
            )
          : AbButton(label: 'Start', compact: true, onTap: onStart),
    );
  }
}
