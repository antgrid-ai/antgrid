import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_toolbar.dart';
import '../../providers/tasks.dart';
import '../../util/detached.dart';
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

class _Stacked extends ConsumerWidget {
  const _Stacked();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TaskListView(
      compact: true,
      onOpen: (number) {
        ref.read(selectedTaskNumberProvider.notifier).select(number);
        detached('tasks', 'open task', () => showTaskDetail(context, number));
      },
    );
  }
}

/// Opens the tasks surface full-screen.
///
/// A dialog route, following the mobile session search: the Android back button
/// and the system back gesture close it for free, which an overlay would
/// swallow neither of.
Future<void> showTasks(BuildContext context) {
  return showDialog<void>(
    context: context,
    // The surface draws its own safe area — the list must run to the bottom
    // edge under the gesture bar rather than stopping short of it.
    useSafeArea: false,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: context.antgrid.bgDeepest,
      child: SafeArea(
        child: TasksSurface(onClose: () => Navigator.of(context).pop()),
      ),
    ),
  );
}

const _listPaneWidth = 380.0;
