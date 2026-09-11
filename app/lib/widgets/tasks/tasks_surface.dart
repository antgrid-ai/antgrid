import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_toolbar.dart';
import '../../navigation/nav_controller.dart';
import '../../navigation/nav_location.dart';
import '../../providers/agent_transport.dart' show selectedTargetProvider;
import '../../providers/sessions.dart' show activeSessionIdProvider;
import '../../providers/tasks.dart';
import '../../providers/ui_attention_providers.dart';
import '../../util/detached.dart';
import '../drawer_dismiss.dart';
import 'task_detail_view.dart';
import 'task_list_view.dart';

/// The tasks surface: one list widget, laid out for the pointer or the thumb.
///
/// Desktop is a master–detail split so `j`/`k` triage never costs a navigation
/// round trip; a phone shows the list and pushes the detail, which is what makes
/// system back mean "back to the list".
class TasksSurface extends ConsumerWidget {
  const TasksSurface({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth >= kMediumBreakpoint;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AbToolbar.panel(
              title: 'Tasks',
              actions: [
                if (onClose != null)
                  AbIconButton(
                    icon: AbIcons.close,
                    tooltip: 'Close tasks',
                    onTap: onClose!,
                  ),
              ],
            ),
            Expanded(child: split ? const _Split() : const _Stacked()),
          ],
        );
      },
    );
  }
}

class _Split extends ConsumerWidget {
  const _Split();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedTaskNumberProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _listPaneWidth,
          child: TaskListView(
            onOpen: (number) =>
                ref.read(selectedTaskNumberProvider.notifier).select(number),
          ),
        ),
        const AbSeparator.vertical(),
        Expanded(
          child: selected == null
              ? const AbEmptyState(
                  icon: AbIcons.tasks,
                  title: 'Pick a task',
                  subtitle: 'Its runs, brief and history open here.',
                )
              : TaskDetailView(
                  // Rebuilds the detail's state when the selection moves, so a
                  // half-typed title never follows the user to another task.
                  key: ValueKey(selected),
                  number: selected,
                  onClose: () => ref
                      .read(selectedTaskNumberProvider.notifier)
                      .select(null),
                ),
        ),
      ],
    );
  }
}

class _Stacked extends ConsumerStatefulWidget {
  const _Stacked();

  @override
  ConsumerState<_Stacked> createState() => _StackedState();
}

class _StackedState extends ConsumerState<_Stacked> {
  @override
  void initState() {
    super.initState();
    // A task pre-selected before this list existed (`openTasks`'s `select`,
    // from the drawer, the Git panel's task strip, or the Tasks nav row)
    // needs pushing explicitly here — unlike `_Split`, which just reads the
    // selection straight into its own right pane, a phone has no pane to read
    // it into, so nothing pushes the detail route unless this does.
    final preselected = ref.read(selectedTaskNumberProvider);
    if (preselected != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        detached(
          'tasks',
          'open pre-selected task',
          () => showTaskDetail(context, preselected),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Covers a LATER external selection made while this list stays mounted
    // (e.g. the Git panel's task strip, tapped again without leaving Tasks) —
    // [initState] only catches the selection that existed at first mount.
    ref.listen<int?>(selectedTaskNumberProvider, (prev, next) {
      if (next == null || next == prev) return;
      detached('tasks', 'open task', () => showTaskDetail(context, next));
    });
    return TaskListView(
      compact: true,
      onOpen: (number) =>
          ref.read(selectedTaskNumberProvider.notifier).select(number),
    );
  }
}

/// Switches the workbench to the tasks surface — the same mechanism
/// [WorkbenchSurface.appSettings] uses (see `workspace_shell.dart`'s and
/// `new_session_screen.dart`'s `_workbenchSurfaceChild`/`_surfaceChild`): it
/// replaces the agent + context panel while the project drawer stays put,
/// rather than a dialog route that would cover it too. [select], when given,
/// is opened in the detail pane (or pushed on a phone) as soon as the surface
/// is up.
void openTasks(BuildContext context, WidgetRef ref, {int? select}) {
  if (select != null) {
    ref.read(selectedTaskNumberProvider.notifier).select(select);
  }
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.tasks);
  ref
      .read(navControllerProvider.notifier)
      .commit(
        NavLocation(
          target: ref.read(selectedTargetProvider),
          surface: WorkbenchSurface.tasks,
          sessionId: ref.read(activeSessionIdProvider),
        ),
      );
  // Mobile: the drawer this row lives in is a slide-in overlay over the
  // surface switch above, so it must be dismissed for the switch to be seen.
  closeDrawerIfOverlay(context);
}

const _listPaneWidth = 380.0;
