import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/control_plane.dart';
import '../../providers/demo_mode.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/now_ticker.dart';
import '../../util/relative_time.dart';
import '../ab_status_helpers.dart' show emptyAdvertHint;
import 'context_picker.dart';
import 'picker_sources.dart';

/// Project picker for the New Session composer.
///
/// The menu lists the VISIBLE source's projects:
///   - Local source: an "Open folder…" lead row (delegates to [onOpenFolder],
///     which runs the OS picker + upsert + select — logic stays in
///     NewSessionContent), then local folders.
///   - Remote source: rows from the machine's live control-plane advert
///     (buildRemoteProjectRows over controlPlaneStateProvider(uuid)), with a
///     "Connecting…" row while the advert is loading.
///
/// The advert and the clock are watched only while the menu is open: the
/// composer is on screen all the time, and watching the advert there would
/// dial a machine the user has not asked about.
class ProjectChip extends ConsumerStatefulWidget {
  const ProjectChip({
    super.key,
    required this.onOpenFolder,
    this.enabled = true,
  });

  final VoidCallback onOpenFolder;

  /// See [EnvironmentChip.enabled] — the composer owns the frozen state.
  final bool enabled;

  @override
  ConsumerState<ProjectChip> createState() => _ProjectChipState();
}

class _ProjectChipState extends ConsumerState<ProjectChip> {
  bool _open = false;

  void _setOpen(bool open) {
    if (!mounted || open == _open) return;
    setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(selectedTargetProjectProvider);
    final valid = ref.watch(newSessionHasValidTargetProvider);
    final selectedId = target?.id;
    return ContextPicker(
      icon: CarbonIcons.folder,
      label: valid ? target!.name : 'Select project…',
      field: 'Project',
      attention: !valid,
      enabled: widget.enabled,
      onOpenChanged: _setOpen,
      entries: _open ? _entries(selectedId) : const [],
    );
  }

  List<CarbonMenuEntry> _entries(String? selectedId) {
    final source = ref.watch(visiblePickerSourceProvider);
    final now = ref.watch(nowMinuteProvider).value ?? DateTime.now();

    void select(PickerProject p) =>
        ref.read(selectedTargetProjectProvider.notifier).set(p);

    List<CarbonMenuEntry> projectRows(
      List<PickerProject> rows,
      String? Function(PickerProject) describe,
    ) {
      final byId = {for (final p in rows) p.id: p};
      return [
        CarbonMenuRadioGroup<String>(
          value: selectedId,
          options: [
            for (final p in rows)
              CarbonOption(
                value: p.id,
                label: p.name,
                description: describe(p),
              ),
          ],
          onChanged: (id) {
            final p = byId[id];
            if (p != null) select(p);
          },
        ),
      ];
    }

    if (source == null) {
      return const [CarbonMenuItem(label: 'No sources available')];
    }

    if (source.isLocal) {
      return [
        CarbonMenuGroup(
          label: source.label,
          children: [
            // Hidden in the demo: this runs the OS folder picker and upserts
            // what it finds into ProjectStore, which registers a REAL project —
            // and mints a host device uuid to hold it — from inside a sample
            // project that promises nothing is connected.
            if (!ref.watch(demoModeProvider))
              CarbonMenuItem(
                label: 'Open folder…',
                icon: const CarbonIcon(CarbonIcons.folderAdd),
                onPressed: widget.onOpenFolder,
              ),
            if (source.projects.isEmpty)
              const CarbonMenuItem(label: 'No local projects yet')
            else
              ...projectRows(source.projects, (p) => _lastActive(p, now)),
          ],
        ),
      ];
    }

    // The mobile "no machines yet" fallback source ('machine:none') carries a
    // null uuid; surface a hint rather than force-unwrap it.
    final uuid = source.machineUuid;
    if (uuid == null) {
      return const [CarbonMenuItem(label: 'No machines on this account')];
    }

    final cp = ref.watch(controlPlaneStateProvider(uuid));
    final rows = cp.value == null
        ? const <PickerProject>[]
        : buildRemoteProjectRows(uuid, cp.value!.projects);
    return [
      CarbonMenuGroup(
        label: source.label,
        children: [
          if (cp.isLoading && rows.isEmpty)
            const CarbonMenuItem(label: 'Connecting…')
          // Error BEFORE the advert's tri-state: Riverpod retains the previous
          // value alongside an error, and a stale advert must not claim the
          // switch is off (or the catalog empty) for a machine that is
          // actually unreachable — same ordering as the drawer's error arm.
          else if (cp.hasError)
            const CarbonMenuItem(label: 'Machine offline')
          // The advert said WHY it is empty (switch off / genuinely no
          // projects / flag-less older bridge reads as offline) — shared copy
          // with the projects drawer.
          else if (rows.isEmpty)
            CarbonMenuItem(label: emptyAdvertHint(cp.value?.remoteAccessEnabled))
          else
            ...projectRows(rows, (p) => _remoteStatus(p, now)),
        ],
      ),
    ];
  }
}

/// Local rows carry no running/stopped state (always openable), so recency is
/// their only secondary text.
String? _lastActive(PickerProject p, DateTime now) {
  final last = p.lastActiveAt;
  return last == null ? null : 'Last active ${relativeTime(last, now: now)}';
}

/// A stopped project still carries its own `lastActiveAt` from the advert, so
/// users can tell which stopped project to reopen.
String _remoteStatus(PickerProject p, DateTime now) {
  if (p.running) return 'Running';
  final last = p.lastActiveAt;
  return last == null
      ? 'Stopped'
      : 'Stopped · last active ${relativeTime(last, now: now)}';
}
