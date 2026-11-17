import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/demo_mode.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/project_composer.dart';
import '../../providers/project_index.dart';
import '../../utils/platform_utils.dart';
import 'context_picker.dart';
import 'project_first_menus.dart';

/// Project picker for the New Session composer.
///
/// The menu ([projectFirstEntries]) lists every project in the machine scope,
/// merged across machines; the machine chip then picks among its holders.
///
/// The project index is watched only while the menu is open: the composer is
/// on screen all the time, and nothing on the trigger depends on it.
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
    return ContextPicker(
      icon: CarbonIcons.folder,
      label: valid ? target!.name : 'Select project…',
      field: 'Project',
      attention: !valid,
      enabled: widget.enabled,
      onOpenChanged: _setOpen,
      entries: _open
          ? projectFirstEntries(
              views: ref.watch(inScopeProjectViewsProvider),
              currentKey: ref.watch(composerProjectViewProvider)?.group.key,
              // Desktop only, and never in the demo: this runs the OS folder
              // picker and registers a REAL project — minting a host device
              // uuid to hold it — from inside a sample project that promises
              // nothing is connected.
              onOpenFolder: !isMobilePlatform && !ref.watch(demoModeProvider)
                  ? widget.onOpenFolder
                  : null,
              onPick: (v) => pointComposerAtProject(ref.container, v),
            )
          : const [],
    );
  }
}
