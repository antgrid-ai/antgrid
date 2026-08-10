import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_menu.dart';
import '../../providers/control_plane.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/now_ticker.dart';
import '../../util/relative_time.dart';
import '../ab_status_helpers.dart' show friendlyErrorCopy;
import 'environment_menu.dart';
import 'picker_sources.dart';

/// Project chip + panel for the New Session composer.
///
/// The panel lists the VISIBLE source's projects:
///   - Local source: an "Open folder…" lead row (delegates to [onOpenFolder],
///     which runs the OS picker + upsert + select — logic stays in
///     NewSessionContent, unchanged from the old rail), then local folders.
///   - Remote source: rows from the machine's live control-plane advert
///     (buildRemoteProjectRows over controlPlaneStateProvider(uuid)); shows a
///     "Connecting…" hint while the advert is loading — live via ConsumerWidget,
///     so rows appear the moment the advert lands (the reason showAbPanel
///     exists rather than showAbMenu's static entries).
class ProjectChip extends ConsumerWidget {
  const ProjectChip({super.key, required this.onOpenFolder});

  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(selectedTargetProjectProvider);
    final valid = ref.watch(newSessionHasValidTargetProvider);
    return ComposerChip(
      icon: AbIcons.folder,
      label: valid ? target!.name : 'Select project…',
      attention: !valid,
      onTap: (ctx) async {
        final anchor = abMenuAnchorRect(ctx);
        if (anchor == null) return;
        await showAbPanel<void>(
          context: ctx,
          anchorRect: anchor,
          // The composer sits at the bottom of the screen, so the panel
          // should open upward toward the visible content.
          preferred: AbMenuPlacement.above,
          builder: (_) => ProjectPanel(onOpenFolder: onOpenFolder),
        );
      },
    );
  }
}

/// Panel content for [ProjectChip]: the visible source's "Open folder…" +
/// local projects, or a remote machine's live advertised projects.
class ProjectPanel extends ConsumerWidget {
  const ProjectPanel({super.key, required this.onOpenFolder});

  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(visiblePickerSourceProvider);
    final selectedId = ref.watch(selectedTargetProjectProvider)?.id;
    final now = ref.watch(nowMinuteProvider).value ?? DateTime.now();

    void select(PickerProject p) {
      ref.read(selectedTargetProjectProvider.notifier).set(p);
      Navigator.of(context).pop();
    }

    if (source == null) return const PanelHint('No sources available');

    if (source.isLocal) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelSectionHeader(source.label),
          PanelRow(
            icon: AbIcons.newFolder,
            label: 'Open folder…',
            selected: false,
            onTap: () {
              Navigator.of(context).pop();
              onOpenFolder();
            },
          ),
          if (source.projects.isEmpty)
            const PanelHint('No local projects yet')
          else
            for (final p in source.projects)
              PanelRow(
                icon: AbIcons.folder,
                label: p.name,
                selected: p.id == selectedId,
                trailing: _lastActiveTrailing(p, now),
                onTap: () => select(p),
              ),
        ],
      );
    }

    // Remote machine: expand its live advert. The mobile "no machines yet"
    // fallback source ('machine:none') carries a null uuid — surface a graceful
    // hint rather than force-unwrapping it (which crashed the tappable chip).
    // Copy matches EnvironmentPanel's machines hint; the full connect steps
    // live in the canvas behind this panel (_ConnectMachineGuide).
    final uuid = source.machineUuid;
    if (uuid == null) return const PanelHint('No machines on this account');

    final cp = ref.watch(controlPlaneStateProvider(uuid));
    final rows = cp.value == null
        ? const <PickerProject>[]
        : buildRemoteProjectRows(uuid, cp.value!.projects);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelSectionHeader(source.label),
        if (cp.isLoading && rows.isEmpty)
          const PanelHint('Connecting…')
        // The advert arrived and said the machine's remote-access switch is
        // off — neither offline nor "no projects". Same copy as the
        // NOT_ALLOWED verb refusal: one switch, one wording (the arm is a
        // literal in ab_status_helpers.dart, so the `!` cannot fire).
        else if (cp.value?.remoteAccessEnabled == false)
          PanelHint(friendlyErrorCopy('NOT_ALLOWED')!)
        else if (cp.value?.remoteAccessEnabled == true && rows.isEmpty)
          const PanelHint('No projects on this machine yet')
        // An empty FLAG-LESS advert is the common OFFLINE case: a null/absent
        // control-plane client yields an empty ControlPlaneState (not an
        // error), so an error and an empty advert with no remoteAccessEnabled
        // (older bridge) both read as "offline", not "no projects" — ported
        // from the old rail's _OfflineMachineRow.
        else if (cp.hasError || rows.isEmpty)
          const PanelHint('Machine offline')
        else
          for (final p in rows)
            PanelRow(
              icon: AbIcons.folder,
              label: p.name,
              selected: p.id == selectedId,
              trailing: _RemoteStatusTrailing(project: p, now: now),
              onTap: () => select(p),
            ),
      ],
    );
  }
}

/// Local rows carry no running/stopped state (always openable), so their only
/// trailing affordance is recency — ported from the old rail's `_ProjectRow`.
Widget? _lastActiveTrailing(PickerProject p, DateTime now) {
  final last = p.lastActiveAt;
  return last == null ? null : _LastActiveLabel(last: last, now: now);
}

/// Right-aligned "last active …" recency text, capped so it can't dominate a
/// narrow row and over-squeeze the project name. Ported from the old rail's
/// `_LastActiveLabel` (`project_rail_picker.dart`).
class _LastActiveLabel extends StatelessWidget {
  const _LastActiveLabel({required this.last, required this.now});

  final DateTime last;
  final DateTime now;

  static const double _maxWidth = 140;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: Text(
        'last active ${relativeTime(last, now: now)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXxs,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}

/// Running/stopped status badge for a remote project row, with the recency
/// label underneath when stopped (a stopped project still carries its own
/// `lastActiveAt` from the control-plane advert, so users can tell which
/// stopped project to reopen). Ported from the old rail's `_ProjectRow`
/// trailing (`project_rail_picker.dart`) so the panel doesn't silently drop
/// this status affordance.
class _RemoteStatusTrailing extends StatelessWidget {
  const _RemoteStatusTrailing({required this.project, required this.now});

  final PickerProject project;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    final last = project.lastActiveAt;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        AbChip.system(
          label: project.running ? 'RUNNING' : 'STOPPED',
          color: project.running ? t.statusRunning : t.textMuted,
        ),
        if (!project.running && last != null) ...[
          const SizedBox(height: AbTokens.space2),
          _LastActiveLabel(last: last, now: now),
        ],
      ],
    );
  }
}
