import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_list_row.dart';
import '../providers/auth.dart';
import '../providers/tasks.dart';
import 'tasks/tasks_surface.dart';

/// The sidebar's permanent entry into the account-wide task list, rendered
/// once directly under the "This machine" band (`LocalMachineBand` in
/// `drawer_entry_row.dart`) — a peer of the local projects listed below it,
/// not nested under any one of them and not a menu item (there used to be a
/// "Tasks…" entry in `AccountFooter`'s overflow menu; this row replaced it).
///
/// Renders nothing signed out: tasks are account data, gated on the same
/// `currentUserProvider` check the rest of the account surface uses.
class TasksNavRow extends ConsumerWidget {
  const TasksNavRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(currentUserProvider).value != null;
    if (!signedIn) return const SizedBox.shrink();

    final count = ref.watch(openTaskCountProvider);
    final t = context.antgrid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.drawerGutter),
      child: AbListRow(
        horizontalPadding: 0,
        density: AbRowDensity.sm,
        hoverable: true,
        leading: AbIcon(
          AbIcons.tasks,
          size: AbTokens.iconButtonGlyph,
          color: t.textSecondary,
        ),
        title: Text(
          'Tasks',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: t.textSecondary,
          ),
        ),
        // Open tasks across the whole account, not just this project — the
        // same scope the row's own tap opens onto.
        trailing: (count ?? 0) > 0
            ? Text(
                '$count',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: t.textMuted,
                ),
              )
            : null,
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
        onTap: () => openTasks(context, ref),
      ),
    );
  }
}
