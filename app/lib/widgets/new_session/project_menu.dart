import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_icons.dart';
import '../../design/widgets/ab_menu.dart';
import '../../providers/new_session_picker.dart';
import 'environment_menu.dart';
import 'project_first_menus.dart';

/// Project chip + panel for the New Session composer.
///
/// The panel ([ProjectFirstPanel]) lists every project in the machine scope,
/// merged across machines.
class ProjectChip extends ConsumerWidget {
  const ProjectChip({
    super.key,
    required this.onOpenFolder,
    this.enabled = true,
  });

  final VoidCallback onOpenFolder;

  /// See [EnvironmentChip.enabled] — the composer owns the frozen state.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(selectedTargetProjectProvider);
    final valid = ref.watch(newSessionHasValidTargetProvider);
    return ComposerChip(
      icon: AbIcons.folder,
      label: valid ? target!.name : 'Select project…',
      attention: !valid,
      enabled: enabled,
      onTap: (ctx) async {
        final anchor = abMenuAnchorRect(ctx);
        if (anchor == null) return;
        await showAbPanel<void>(
          context: ctx,
          anchorRect: anchor,
          // The composer sits at the bottom of the screen, so the panel
          // should open upward toward the visible content.
          preferred: AbMenuPlacement.above,
          // Every project in scope, merged across machines — the project is
          // chosen first and the machine chip then picks among its holders.
          builder: (_) => ProjectFirstPanel(onOpenFolder: onOpenFolder),
        );
      },
    );
  }
}

