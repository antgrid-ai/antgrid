import 'package:flutter/material.dart' show MaterialPageRoute, Navigator;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_avatar.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_select_sheet.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../design/widgets/ab_multiline_field.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../../services/tasks_api.dart';
import '../../util/detached.dart';
import '../../util/external_url.dart';
import '../transcript/markdown_body.dart';
import 'task_launch_sheet.dart';
import 'task_provenance_view.dart';
import 'task_publish_sheet.dart';
import 'task_row_actions.dart';
import 'task_status_view.dart';

/// One task, in full.
///
/// The order is the UX doc's, not GitHub's: what an agent is doing right now
/// sits above the prose, because the run is the only thing here another tracker
/// could not show.
class TaskDetailView extends ConsumerStatefulWidget {
  const TaskDetailView({super.key, required this.number, this.onClose});

  final int number;

  /// Present on the phone's pushed route and the desktop split's close button;
  /// absent where the detail is the whole surface.
  final VoidCallback? onClose;

  @override
  ConsumerState<TaskDetailView> createState() => _TaskDetailViewState();
}

class _TaskDetailViewState extends ConsumerState<TaskDetailView> {
  @override
  void initState() {
    super.initState();
    // A deep link or a stale selection can name a task the list never fetched —
    // the list is filtered and paged, so "in the account" and "in the list" are
    // different questions.
    detached(
      'tasks',
      'load task',
      () => ref.read(taskListProvider.notifier).ensureLoaded(widget.number),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(taskListProvider);
    final task = tasks.value?.firstWhereOrNullByNumber(widget.number);

    if (task == null) {
      return switch (tasks) {
        AsyncError(:final error) => _DetailError(error: error),
        AsyncLoading() => const AbLoading(message: 'Loading task…'),
        _ => const AbEmptyState(
          icon: AbIcons.tasks,
          title: 'This task no longer exists',
        ),
      };
    }
    return _Loaded(task: task, onClose: widget.onClose);
  }
}

class _DetailError extends ConsumerWidget {
  const _DetailError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = error is TaskApiException ? error as TaskApiException : null;
    return AbEmptyState.error(
      title: api?.message ?? 'This task could not be loaded.',
      action: AbButton(
        label: 'Retry',
        onTap: () => detached(
          'tasks',
          'retry task load',
          () => ref.read(taskListProvider.notifier).refresh(),
        ),
      ),
    );
  }
}

class _Loaded extends ConsumerStatefulWidget {
  const _Loaded({required this.task, this.onClose});

  final Task task;
  final VoidCallback? onClose;

  @override
  ConsumerState<_Loaded> createState() => _LoadedState();
}

class _LoadedState extends ConsumerState<_Loaded> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  var _editingTitle = false;
  var _editingBody = false;

  /// Conflict fields with a resolve in flight, keyed by wire name. Per field,
  /// not one flag: settling the title must not disable the description's pair,
  /// and taking a side is not idempotent — the second call answers
  /// `NOT_CONFLICTED` and would overwrite the reply with a refusal banner.
  final _resolving = <String>{};

  /// Push blocks with a clear in flight, keyed by wire name. Per field and for
  /// the same reasons as [_resolving]: restarting the title must not disable the
  /// description's button, and a second call about the same field answers
  /// `NOT_BLOCKED` and would replace the reply with a refusal banner.
  final _clearingBlock = <String>{};

  /// Set for the WHOLE publish flow, confirmation included: two taps can open
  /// two confirm sheets, and confirming both would create two issues.
  var _publishing = false;

  /// Same shape as [_publishing]. A second unlink answers `NOT_LINKED` and
  /// would replace the reply with a refusal banner.
  var _unlinking = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Task get _task => widget.task;

  void _beginTitle() {
    _title.text = _task.title;
    setState(() => _editingTitle = true);
  }

  Future<void> _commitTitle() async {
    final next = _title.text.trim();
    setState(() => _editingTitle = false);
    if (next.isEmpty || next == _task.title) return;
    await ref.read(taskListProvider.notifier).setTitle(_task.number, next);
  }

  void _beginBody() {
    _body.text = _task.body;
    setState(() => _editingBody = true);
  }

  Future<void> _commitBody() async {
    final next = _body.text;
    setState(() => _editingBody = false);
    if (next == _task.body) return;
    await ref.read(taskListProvider.notifier).setBody(_task.number, next);
  }

  Future<void> _pickStatus() async {
    final picked = await showAbSelect<TaskStatus>(
      context,
      title: 'Status',
      single: true,
      options: [
        for (final status in TaskStatus.values)
          AbSelectOption(
            value: status,
            label: status.label,
            leading: TaskStatusDot(status: status),
          ),
      ],
      selected: {_task.status},
    );
    final next = picked?.firstOrNull;
    if (next != null && next != _task.status) {
      await ref.read(taskListProvider.notifier).setStatus(_task.number, next);
    }
  }

  Future<void> _pickAssignee() async {
    final candidates = ref.read(taskAssigneeCandidatesProvider);
    final current = _task.assignee;
    // An imported identity has no Antgrid account to replace it with anything
    // but a member, and clearing it would drop a fact the provider owns.
    if (current is TaskExternalAssignee) return;
    final picked = await showAbSelect<String>(
      context,
      title: 'Assignee',
      single: true,
      emptyMessage: 'Nobody else in this account can be assigned yet',
      options: [
        const AbSelectOption(value: '', label: 'Unassigned'),
        for (final c in candidates)
          AbSelectOption(
            value: c.userId,
            label: c.displayName,
            leading: AbAvatar(name: c.displayName, size: _avatarSize),
          ),
      ],
      selected: {if (current is TaskMemberAssignee) current.userId else ''},
    );
    final choice = picked?.firstOrNull;
    if (choice == null) return;
    await ref
        .read(taskListProvider.notifier)
        .setAssignee(
          _task.number,
          choice.isEmpty ? null : TaskMemberAssignee(choice),
        );
  }

  Future<void> _pickPriority() async {
    final picked = await showAbSelect<int>(
      context,
      title: 'Priority',
      single: true,
      options: const [
        AbSelectOption(value: -1, label: 'None'),
        AbSelectOption(value: 0, label: 'P0 — drop everything'),
        AbSelectOption(value: 1, label: 'P1 — next'),
        AbSelectOption(value: 2, label: 'P2 — soon'),
        AbSelectOption(value: 3, label: 'P3 — someday'),
      ],
      selected: {_task.priority ?? -1},
    );
    final choice = picked?.firstOrNull;
    if (choice == null) return;
    await ref
        .read(taskListProvider.notifier)
        .setPriority(_task.number, choice < 0 ? null : choice);
  }

  /// The disabled button is the affordance; this guard is what makes it safe.
  /// A second tap can be delivered in the same frame as the first, before the
  /// rebuild that greys the button out.
  Future<void> _resolve(String field, String take) async {
    if (_resolving.contains(field)) return;
    setState(() => _resolving.add(field));
    try {
      await ref
          .read(taskListProvider.notifier)
          .resolveConflict(_task.number, field: field, take: take);
    } finally {
      if (mounted) setState(() => _resolving.remove(field));
    }
  }

  /// Same shape as [_resolve], and needed for the same reason: the disabled
  /// button is the affordance, and a second tap can be delivered in the frame
  /// before the rebuild that greys it out.
  Future<void> _clearBlock(String field) async {
    if (_clearingBlock.contains(field)) return;
    setState(() => _clearingBlock.add(field));
    try {
      await ref
          .read(taskListProvider.notifier)
          .clearPushBlock(_task.number, field: field);
    } finally {
      if (mounted) setState(() => _clearingBlock.remove(field));
    }
  }

  /// The after-the-fact publish. The sheet is the consent moment, so the flow
  /// is one action from the guard's point of view: the button is dead from the
  /// first tap until the write settles.
  Future<void> _publish(List<TaskPublishTarget> targets) async {
    if (_publishing || targets.isEmpty) return;
    setState(() => _publishing = true);
    // Captured before the sheet: a list refresh under it can retire this
    // widget, and reading `ref` on a dead element throws.
    final container = ref.container;
    final number = _task.number;
    try {
      final repoId = await showTaskPublishConfirm(
        context,
        task: _task,
        targets: targets,
      );
      if (repoId == null) return;
      await container.read(taskListProvider.notifier).publish(
        number,
        repoId: repoId,
      );
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _unlink() async {
    if (_unlinking) return;
    setState(() => _unlinking = true);
    final container = ref.container;
    final number = _task.number;
    try {
      final confirmed = await showTaskUnlinkConfirm(context, _task);
      if (!confirmed) return;
      await container.read(taskListProvider.notifier).unlink(number);
    } finally {
      if (mounted) setState(() => _unlinking = false);
    }
  }

  Future<void> _delete() async {
    final container = ref.container;
    final confirmed = await showTaskDeleteConfirm(context, _task);
    if (!confirmed) return;
    if (container.read(selectedTaskNumberProvider) == _task.number) {
      container.read(selectedTaskNumberProvider.notifier).select(null);
    }
    await container.read(taskListProvider.notifier).delete(_task.number);
    if (mounted) widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final run = ref.watch(taskRunPresenceProvider)[_task.number];
    final failure = ref.watch(taskMutationErrorProvider);
    final conflict = _task.conflict;
    final pushBlock = _task.pushBlocked;
    final projectId = _task.projectId;
    // A refused or still-loading lookup answers the empty list, which is the
    // same thing to this view as "nowhere to publish": the action is absent,
    // never dead.
    final targets = projectId == null
        ? const <TaskPublishTarget>[]
        : ref.watch(taskPublishTargetsProvider(projectId)).value ??
              const <TaskPublishTarget>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context),
        const AbSeparator.horizontal(),
        if (failure != null)
          AbInlineBanner(
            text: failure.error.message,
            color: palette.warning,
            trailing: failure.retry == null
                ? null
                : AbButton(
                    label: 'Retry',
                    compact: true,
                    onTap: () =>
                        detached('tasks', 'retry mutation', failure.retry!),
                  ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: AbTokens.space24),
            children: [
              _attributes(context),
              if (run != null) ...[
                const AbSectionHeader(label: 'Run'),
                _runBlock(context, run),
              ],
              // Above the description, never below it: it says whose words
              // the next block is.
              if (!_task.isLocal) ...[
                const AbSectionHeader(label: 'Source'),
                TaskProvenanceBlock(task: _task),
              ],
              // A task published FROM here keeps `source: local` — the column
              // records where it was born, not where it now lives — so the
              // Source block above stays absent and this is the only place its
              // issue is ever named.
              if (_task.isLocal && _task.syncState != null) ...[
                const AbSectionHeader(label: 'GitHub'),
                _publishedBlock(context),
              ],
              // Under Source, above the description: the description is one of
              // the things that may have been overwritten, and the block above
              // is what says whose words replaced whose.
              if (conflict != null) ...[
                const AbSectionHeader(label: 'Unsettled changes'),
                _conflictBlock(context, conflict),
              ],
              // Beside the conflict block, because the two are halves of the
              // same question: that one is what came in and overwrote a value,
              // this one is what never went out. Both sit above the description
              // for the same reason — it is one of the values in question.
              if (pushBlock != null) ...[
                const AbSectionHeader(label: 'Stopped syncing'),
                _pushBlockBlock(context, pushBlock),
              ],
              AbSectionHeader(
                label: 'Description',
                trailing: _editingBody
                    ? null
                    : AbIconButton(
                        icon: AbIcons.edit,
                        tooltip: 'Edit description',
                        onTap: _beginBody,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AbTokens.space12,
                  AbTokens.space4,
                  AbTokens.space12,
                  AbTokens.space12,
                ),
                child: _bodyBlock(context),
              ),
              const AbSectionHeader(label: 'Details'),
              _metadata(context),
              Padding(
                padding: const EdgeInsets.all(AbTokens.space12),
                child: Wrap(
                  spacing: AbTokens.space8,
                  runSpacing: AbTokens.space8,
                  children: [
                    // Never the primary action: the primary action on a task
                    // is Start session, and publishing is not what this
                    // product is for.
                    if (_task.isPublishable && targets.isNotEmpty)
                      AbButton(
                        label: _publishing
                            ? 'Publishing…'
                            : _task.hasUnlinkedIdentity
                            // Says what it does rather than reading like a way
                            // to restore the link that was dropped.
                            ? 'Publish to GitHub (new issue)'
                            : 'Publish to GitHub',
                        onTap: _publishing
                            ? null
                            : () => detached(
                                'tasks',
                                'publish task',
                                () => _publish(targets),
                              ),
                      ),
                    if (_task.isLinked)
                      AbButton(
                        label: _unlinking ? 'Unlinking…' : 'Unlink from GitHub',
                        onTap: _unlinking
                            ? null
                            : () =>
                                  detached('tasks', 'unlink task', _unlink),
                      ),
                    AbButton(
                      label: 'Delete task',
                      color: palette.error,
                      onTap: () => detached('tasks', 'delete task', _delete),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final palette = context.antgrid;
    final launcher = ref.watch(taskLauncherProvider);
    final blockedReason =
        launcher?.unavailableReason(_task) ??
        // No launcher at all is a build-time state, not a user error: say what
        // is missing rather than leaving a dead button with no explanation.
        (launcher == null ? 'Starting a session from a task is not wired up yet.'
            : null);

    return Padding(
      padding: const EdgeInsets.all(AbTokens.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                _task.ref,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: palette.textMuted,
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              TaskStatusPill(status: _task.status),
              const Spacer(),
              AbIconButton(
                icon: AbIcons.edit,
                tooltip: 'Change status',
                onTap: () => detached('tasks', 'change status', _pickStatus),
              ),
              if (widget.onClose != null)
                AbIconButton(
                  icon: AbIcons.close,
                  tooltip: 'Close task',
                  onTap: widget.onClose!,
                ),
            ],
          ),
          const SizedBox(height: AbTokens.space8),
          if (_editingTitle)
            AbTextField(
              controller: _title,
              autofocus: true,
              hintText: 'Title',
              onSubmitted: (_) => detached('tasks', 'save title', _commitTitle),
            )
          else
            GestureDetector(
              onTap: _beginTitle,
              child: Text(
                _task.title,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontLg,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
            ),
          const SizedBox(height: AbTokens.space12),
          Row(
            children: [
              AbButton(
                label: 'Start session',
                variant: AbButtonVariant.primary,
                // The sheet, never the launch directly: [TaskLauncher.start]
                // takes no context, and a start has two things it must show
                // before and after — which project the session lands in, and
                // the bridge's reason when it refuses.
                onTap: blockedReason != null || launcher == null
                    ? null
                    : () => detached(
                        'tasks',
                        'start session',
                        () => showTaskLaunchSheet(context, _task),
                      ),
              ),
              if (blockedReason != null) ...[
                const SizedBox(width: AbTokens.space8),
                Expanded(
                  child: Text(
                    blockedReason,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: palette.textMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _attributes(BuildContext context) {
    final palette = context.antgrid;
    final assignee = _task.assignee;
    final projectName = _task.projectId == null
        ? null
        : ref.watch(taskProjectNamesProvider)[_task.projectId];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space8,
        AbTokens.space12,
        AbTokens.space8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _attribute(
            context,
            'Assignee',
            onTap: assignee is TaskExternalAssignee
                ? null
                : () => detached('tasks', 'pick assignee', _pickAssignee),
            child: _assigneeValue(context, assignee),
          ),
          // Outside the attribute row on purpose: the row is the reassign tap
          // target, and these identities are not editable from here — the
          // assignee never pushes, so this list only reports what the provider
          // holds.
          if (_task.otherAssignees.isNotEmpty) _coAssignees(context),
          _attribute(
            context,
            'Labels',
            onTap: () => detached(
              'tasks',
              'edit labels',
              () => editTaskLabels(context, ref, _task),
            ),
            child: _task.labels.isEmpty
                ? Text(
                    'None',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: palette.textMuted,
                    ),
                  )
                : Wrap(
                    spacing: AbTokens.space4,
                    runSpacing: AbTokens.space4,
                    children: [
                      for (final label in _task.labels)
                        AbLabelChip(label: label.name, colorHex: label.color),
                    ],
                  ),
          ),
          _attribute(
            context,
            'Priority',
            onTap: () => detached('tasks', 'pick priority', _pickPriority),
            child: Text(
              _task.priority == null ? 'None' : 'P${_task.priority}',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: _task.priority == null
                    ? palette.textMuted
                    : palette.textSecondary,
              ),
            ),
          ),
          if (_task.projectId != null)
            _attribute(
              context,
              'Project',
              child: Text(
                projectName ?? _task.projectId!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: projectName == null
                    ? AbTokens.monoStyle(
                        fontSize: AbTokens.fontXxs,
                        color: palette.textMuted,
                      )
                    : AbTokens.sansStyle(fontSize: AbTokens.fontXs),
              ),
            ),
        ],
      ),
    );
  }

  /// The sheet's one spelling of an assignee — the attribute row and the
  /// conflict block both read it, so the value under "Yours" is rendered the
  /// same way as the value it would be restored to.
  Widget _assigneeValue(BuildContext context, TaskAssignee? assignee) {
    final palette = context.antgrid;
    return switch (assignee) {
      null => Text(
        'Unassigned',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: palette.textMuted,
        ),
      ),
      TaskMemberAssignee() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbAvatar(name: assignee.userId, size: _avatarSize),
          const SizedBox(width: AbTokens.space6),
          Text(
            _displayNameFor(assignee.userId),
            style: AbTokens.sansStyle(fontSize: AbTokens.fontXs),
          ),
        ],
      ),
      // Read-only by design: this identity came from the provider and has no
      // Antgrid account to edit.
      TaskExternalAssignee() => Text(
        '@${assignee.login}',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          color: palette.textSecondary,
        ),
      ),
    };
  }

  /// Everyone else the provider has on this issue, named rather than counted —
  /// the sheet has the width the row does not.
  Widget _coAssignees(BuildContext context) {
    final palette = context.antgrid;
    return Padding(
      padding: const EdgeInsets.only(
        left: _attributeLabelWidth,
        bottom: AbTokens.space6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Also on ${taskProviderLabel(_task)}',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space4),
          Wrap(
            spacing: AbTokens.space12,
            runSpacing: AbTokens.space4,
            children: [
              for (final other in _task.otherAssignees)
                switch (other) {
                  TaskMemberAssignee() => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AbAvatar(name: other.userId, size: _avatarSize),
                      const SizedBox(width: AbTokens.space6),
                      Text(
                        _displayNameFor(other.userId),
                        style: AbTokens.sansStyle(fontSize: AbTokens.fontXs),
                      ),
                    ],
                  ),
                  TaskExternalAssignee() => Text(
                    '@${other.login}',
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      color: palette.textSecondary,
                    ),
                  ),
                },
            ],
          ),
        ],
      ),
    );
  }

  Widget _attribute(
    BuildContext context,
    String label, {
    required Widget child,
    VoidCallback? onTap,
  }) {
    final palette = context.antgrid;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _attributeLabelWidth,
            child: Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ),
          Expanded(child: child),
          if (onTap != null)
            AbIcon(
              AbIcons.chevronRight,
              size: AbTokens.iconButtonGlyph,
              color: palette.iconMuted,
            ),
        ],
      ),
    );
    if (onTap == null) return row;
    return GestureDetector(onTap: onTap, child: row);
  }

  /// What the last sync could not reconcile, and the two ways out of each one.
  ///
  /// Stacked rather than side by side: a description is the field most likely
  /// to collide and the one least readable in half a phone's width.
  Widget _conflictBlock(BuildContext context, TaskConflict conflict) {
    final palette = context.antgrid;
    final provider = taskProviderLabel(_task);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space6,
        AbTokens.space12,
        AbTokens.space6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (conflict.fields.isNotEmpty)
            Text(
              '$provider’s version is in place. Yours is held here until you '
              'pick one.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          for (final field in conflict.fields)
            _conflictFieldBlock(context, field),
          if (conflict.labelRemoveWins.isNotEmpty)
            _labelDropBlock(context, conflict.labelRemoveWins),
        ],
      ),
    );
  }

  Widget _conflictFieldBlock(BuildContext context, TaskConflictField field) {
    final palette = context.antgrid;
    final provider = taskProviderLabel(_task);
    final busy = _resolving.contains(field.field);
    return Container(
      margin: const EdgeInsets.only(top: AbTokens.space8),
      padding: const EdgeInsets.all(AbTokens.space8),
      decoration: BoxDecoration(
        border: Border.all(color: palette.borderDefault),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _taskFieldLabel(field.field),
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: AbTokens.space6),
          _conflictSide(
            context,
            'On $provider · in place now',
            field.field,
            field.remoteValue,
          ),
          const SizedBox(height: AbTokens.space6),
          _conflictSide(context, 'Yours · set aside', field.field, field.localValue),
          const SizedBox(height: AbTokens.space8),
          Row(
            children: [
              AbButton(
                label: 'Keep mine',
                onTap: busy
                    ? null
                    : () => detached(
                        'tasks',
                        'resolve conflict',
                        () => _resolve(field.field, 'local'),
                      ),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: 'Keep $provider’s',
                onTap: busy
                    ? null
                    : () => detached(
                        'tasks',
                        'resolve conflict',
                        () => _resolve(field.field, 'remote'),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _conflictSide(
    BuildContext context,
    String caption,
    String field,
    Object? value,
  ) {
    final palette = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          caption,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXxs,
            color: palette.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space2),
        // An issue body has no length this sheet can assume, and the sheet has
        // a delete button under it that must stay reachable.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _conflictValueMaxHeight),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: _conflictValue(context, field, value),
          ),
        ),
      ],
    );
  }

  /// Values are data, so mono — except the two the sheet already has a human
  /// spelling for, which render as that spelling rather than as wire JSON.
  Widget _conflictValue(BuildContext context, String field, Object? value) {
    final palette = context.antgrid;
    if (field == 'status') {
      // Antgrid vocabulary first, for a server that ever stores it that way.
      final status = TaskStatus.fromWire(value);
      if (status != null) {
        return Align(
          alignment: Alignment.centerLeft,
          child: TaskStatusPill(status: status),
        );
      }
      final provider = _providerStateLabel(value);
      if (provider != null) {
        return Text(
          provider,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXxs,
            color: palette.textSecondary,
          ),
        );
      }
    }
    // Null is a value here, not an absence: it says that side unassigned the
    // task, which is exactly what the other side overwrote.
    if (field == 'assignee' && (value == null || value is Map)) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _assigneeValue(context, TaskAssignee.fromJson(value)),
      );
    }
    final text = value is String ? value : (value == null ? '' : '$value');
    return Text(
      text.trim().isEmpty ? 'Empty' : text,
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontXxs,
        color: text.trim().isEmpty ? palette.textMuted : palette.textSecondary,
      ),
    );
  }

  /// Never a conflict, always a loss: one side removed these while the other
  /// still had them, and removal is the only outcome a sync can honour. So one
  /// acknowledgement, not a pair of choices.
  Widget _labelDropBlock(BuildContext context, List<String> names) {
    final palette = context.antgrid;
    final busy = _resolving.contains(_labelsConflictField);
    return Container(
      margin: const EdgeInsets.only(top: AbTokens.space8),
      padding: const EdgeInsets.all(AbTokens.space8),
      decoration: BoxDecoration(
        border: Border.all(color: palette.borderDefault),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Labels removed',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: AbTokens.space6),
          Wrap(
            spacing: AbTokens.space4,
            runSpacing: AbTokens.space4,
            children: [for (final name in names) AbLabelChip(label: name)],
          ),
          const SizedBox(height: AbTokens.space6),
          Text(
            'These were removed on one side while the other still had them, so '
            'they are off this task now. Add them back by hand if you still '
            'want them.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space8),
          Align(
            alignment: Alignment.centerLeft,
            child: AbButton(
              label: 'Got it',
              onTap: busy
                  ? null
                  : () => detached(
                      'tasks',
                      'acknowledge dropped labels',
                      // Only `remote` is accepted: restoring a label here would
                      // leave it absent on the provider with nothing to push it
                      // back.
                      () => _resolve(_labelsConflictField, 'remote'),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// The values this task holds that the provider never took, and the only way
  /// to send one again.
  ///
  /// Read the order off the payload rather than sorting here: the server walks
  /// its own field vocabulary to build it, which is the only stable order there
  /// is — the column is jsonb and cannot supply one.
  Widget _pushBlockBlock(BuildContext context, TaskPushBlock block) {
    final palette = context.antgrid;
    final provider = taskProviderLabel(_task);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space6,
        AbTokens.space12,
        AbTokens.space6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'These are saved on this task but stopped reaching $provider. '
            'Try again sends one of them once more.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
          for (final field in block.fields)
            _pushBlockFieldBlock(context, field),
        ],
      ),
    );
  }

  Widget _pushBlockFieldBlock(
    BuildContext context,
    TaskPushBlockedField field,
  ) {
    final palette = context.antgrid;
    final provider = taskProviderLabel(_task);
    final busy = _clearingBlock.contains(field.field);
    final attempts = switch (field.count) {
      <= 0 => 'Repeated attempts',
      1 => 'The last attempt',
      final count => 'The last $count attempts',
    };
    final lastAt = field.lastAt;
    return Container(
      margin: const EdgeInsets.only(top: AbTokens.space8),
      padding: const EdgeInsets.all(AbTokens.space8),
      decoration: BoxDecoration(
        border: Border.all(color: palette.borderDefault),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _taskFieldLabel(field.field),
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: AbTokens.space6),
          Text(
            'Saved here, not on $provider. $attempts changed nothing there, so '
            'Antgrid stopped sending it.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textSecondary,
            ),
          ),
          if (field.reason.isNotEmpty) ...[
            const SizedBox(height: AbTokens.space4),
            Text(
              field.reason,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ],
          if (lastAt != null) ...[
            const SizedBox(height: AbTokens.space4),
            Text(
              'Last tried ${_stamp(lastAt)}',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ],
          const SizedBox(height: AbTokens.space8),
          Align(
            alignment: Alignment.centerLeft,
            child: AbButton(
              label: 'Try again',
              onTap: busy
                  ? null
                  : () => detached(
                      'tasks',
                      'clear push block',
                      () => _clearBlock(field.field),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// The issue a task written here was published to.
  ///
  /// The pending arm is the one the mental model needs: between the button and
  /// the drain posting it, the task exists and the issue does not — without
  /// saying so, "it's public now" is what the user walks away believing.
  Widget _publishedBlock(BuildContext context) {
    final palette = context.antgrid;
    final url = _task.externalUrl;
    final key = _task.externalKey;
    final pending =
        _task.syncState == TaskSyncState.pending && _task.externalId == null;
    final unlinked = _task.syncState == TaskSyncState.unlinked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space6,
        AbTokens.space12,
        AbTokens.space6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AbIcon(
                unlinked ? AbIcons.syncOff : AbIcons.openExternal,
                size: AbTokens.iconButtonGlyph,
                color: palette.iconMuted,
              ),
              const SizedBox(width: AbTokens.space6),
              Text(
                pending
                    ? 'Creating the issue…'
                    : unlinked
                    ? 'No longer syncing'
                    : 'Published to GitHub',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: palette.textSecondary,
                ),
              ),
              if (key != null) ...[
                const SizedBox(width: AbTokens.space8),
                Flexible(
                  child: Text(
                    key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXxs,
                      color: palette.textMuted,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (url != null)
                AbButton(
                  label: 'Open issue',
                  compact: true,
                  leading: AbIcon(
                    AbIcons.openExternal,
                    size: AbTokens.iconButtonGlyph,
                    color: palette.textSecondary,
                  ),
                  onTap: () => detached(
                    'tasks',
                    'open issue',
                    () => openExternalUrl(context, url),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AbTokens.space6),
          Text(
            pending
                ? 'The task is saved here; the issue does not exist yet.'
                : unlinked
                ? 'Edits here no longer reach the issue, and it is untouched '
                      'where it is. Publishing again creates a second one.'
                : 'Edits to the title, description, status and labels are sent '
                      'to this issue.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _runBlock(BuildContext context, TaskRunPresence run) {
    final palette = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space6,
        AbTokens.space12,
        AbTokens.space6,
      ),
      child: Row(
        children: [
          TaskRunMark(run: run, showLabel: true),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              [
                if (run.sessionName != null) run.sessionName!,
                if (run.machineName != null) run.machineName!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bodyBlock(BuildContext context) {
    final palette = context.antgrid;
    if (_editingBody) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AbMultilineField(
            controller: _body,
            autofocus: true,
            minLines: 6,
            maxLines: 20,
            hintText: 'Describe the work. This becomes the agent’s brief.',
          ),
          const SizedBox(height: AbTokens.space8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AbButton(
                label: 'Cancel',
                onTap: () => setState(() => _editingBody = false),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: 'Save',
                variant: AbButtonVariant.primary,
                onTap: () => detached('tasks', 'save body', _commitBody),
              ),
            ],
          ),
        ],
      );
    }
    if (_task.body.trim().isEmpty) {
      return GestureDetector(
        onTap: _beginBody,
        child: Text(
          'No description. The agent gets the title alone.',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: palette.textMuted,
          ),
        ),
      );
    }
    return TranscriptMarkdown(data: _task.body);
  }

  Widget _metadata(BuildContext context) {
    final palette = context.antgrid;
    // An imported task's origin, issue key and sync state are the Source
    // block's, spelled out — repeating them here as raw wire values would be a
    // second, worse answer to the same question.
    final entries = <(String, String)>[
      if (_task.isLocal) ('Source', 'Antgrid'),
      ('Created', _stamp(_task.createdAt)),
      ('Updated', _stamp(_task.updatedAt)),
      if (_task.closedAt != null) ('Closed', _stamp(_task.closedAt!)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space6,
        AbTokens.space12,
        AbTokens.space6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (label, value) in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AbTokens.space4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _attributeLabelWidth,
                    child: Text(
                      label,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: palette.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontXxs,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _displayNameFor(String userId) {
    for (final c in ref.read(taskAssigneeCandidatesProvider)) {
      if (c.userId == userId) return c.displayName;
    }
    return userId;
  }
}

/// A route-pushed detail, for the phone. Desktop puts the same widget in the
/// split instead.
Future<void> showTaskDetail(BuildContext context, int number) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => ColoredBox(
        color: context.antgrid.bgDeepest,
        child: SafeArea(
          child: TaskDetailView(
            number: number,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    ),
  );
}

String _stamp(DateTime at) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// How the sheet names a field the server named — a conflict side or a push
/// that stopped. A field this app has no name for is printed by its wire
/// spelling rather than hidden: both blocks stay actionable on a vocabulary
/// this build predates, and hiding one turns it into a dead end.
///
/// The union of both vocabularies, deliberately: `assignee` conflicts but is
/// never pushed, `labels` is pushed but drops rather than conflicts, and a
/// second mapping per block is two places for the same name to go stale.
String _taskFieldLabel(String field) => switch (field) {
  'title' => 'Title',
  'body' => 'Description',
  'status' => 'Status',
  'assignee' => 'Assignee',
  'labels' => 'Labels',
  _ => field,
};

/// A conflicted `status` in the provider's own words, or null for a shape this
/// is not.
///
/// The stored value is PROVIDER space (`{state, stateReason}`), not Antgrid's —
/// that is where the merge compares status, to keep the many-to-one mapping
/// from manufacturing a push loop. So it is rendered in provider words rather
/// than as a [TaskStatusPill]: `open` covers `open`, `in_progress` and
/// `blocked`, and naming one of them here would be a guess presented as the
/// value the user is choosing between. The server resolves that ambiguity
/// against the live row when a side is taken; nothing about it is mirrored
/// here.
String? _providerStateLabel(Object? value) {
  if (value is! Map) return null;
  final reason = value['stateReason'];
  return switch (value['state']) {
    'open' => reason == 'reopened' ? 'Reopened' : 'Open',
    'closed' => switch (reason) {
      'not_planned' => 'Closed as not planned',
      'completed' => 'Closed as completed',
      _ => 'Closed',
    },
    _ => null,
  };
}

/// The resolve route's spelling for the dropped-label marker. Not a conflict
/// field — it has no `localValue`, and only `remote` is accepted.
const _labelsConflictField = 'labels';

const _attributeLabelWidth = 72.0;
const _avatarSize = 18.0;

/// Tall enough for a few lines of a description, short enough that two of them
/// plus the actions still fit a phone. Longer values scroll in place.
const _conflictValueMaxHeight = 96.0;

extension _TaskLookup on List<Task> {
  Task? firstWhereOrNullByNumber(int number) {
    for (final task in this) {
      if (task.number == number) return task;
    }
    return null;
  }
}
