import 'package:flutter/material.dart'
    show MaterialPageRoute, Navigator, Scaffold;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_avatar.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_diff_stat.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_menu.dart' show abMenuAnchorRect;
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_select_sheet.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/task.dart';
import '../../navigation/nav_controller.dart' show recordProjectFocus;
import '../../providers/agent_transport.dart'
    show selectProject, selectedRegistrationIdProvider;
import '../../providers/new_session_action.dart'
    show openRemoteProjectForActivation;
import '../../util/device_id.dart' show baseDeviceUuid, baseProjectId;
import '../../providers/task_launcher.dart' show pendingTaskLaunchProvider;
import '../../providers/providers.dart'
    show taskCheckoutFileTreeStateProvider, checkoutServiceOrNull;
import '../../providers/task_project_source.dart';
import '../../providers/tasks.dart';
import '../../services/tasks_api.dart';
import '../../util/detached.dart';
import '../../util/external_url.dart';
import '../diff_viewer.dart';
import '../file_tree_view.dart';
import '../file_viewer_router.dart';
import '../send_capture_to_agent.dart';
import '../transcript/markdown_body.dart';
import 'markdown_format.dart';
import 'task_body_editor.dart';
import 'task_launch_sheet.dart';
import 'task_project_missing.dart';
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
    final failure = ref.watch(taskMutationErrorProvider);

    if (task == null) {
      // `ensureLoaded`'s own failure is the authoritative reason this task
      // isn't in the list — checked before falling back to `tasks`' state, or
      // a network blip fetching just THIS task reads as it having been
      // deleted, and the list's own banner (which suppresses whenever it
      // thinks this pane already shows the error) shows nothing either.
      if (failure != null && failure.taskNumber == widget.number) {
        return _DetailError(error: failure.error, onRetry: failure.retry);
      }
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
  const _DetailError({required this.error, this.onRetry});

  final Object error;

  /// Retries the specific failed call. Falls back to refreshing the whole
  /// list, the only recovery available for a failure that named no retry.
  final Future<void> Function()? onRetry;

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
          onRetry ?? () => ref.read(taskListProvider.notifier).refresh(),
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

  /// Issue-template guidance in the description, hidden the way the
  /// provider hides it until asked for.
  var _showComments = false;

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

  final _paneFocus = FocusNode(debugLabel: 'task detail');

  // Focused by hand when editing starts: `autofocus` only takes when nothing
  // in the scope has focus, and the pane always does.
  final _titleFocus = FocusNode(debugLabel: 'task title');
  final _bodyFocus = FocusNode(debugLabel: 'task body');

  /// The fields a keyboard shortcut opens; the key finds where to anchor it.
  final _statusField = GlobalKey();
  final _assigneeField = GlobalKey();
  final _labelsField = GlobalKey();
  final _priorityField = GlobalKey();

  /// Which field's picker is up — its chevron stays shown until it closes.
  String? _openFieldId;

  @override
  void initState() {
    super.initState();
    // Focusing a project can swap the route under this view, so the launch it
    // queued may be picked up by the NEW instance rather than the one that
    // queued it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refetchProjectsIfUnresolved();
      _launchIfQueued();
    });
  }

  /// The account's project list is fetched once at sign-in and a failed fetch
  /// stays failed, so a task opened after that would otherwise sit on
  /// "couldn't load" until the user finds the refresh button.
  void _refetchProjectsIfUnresolved() {
    if (!mounted) return;
    final phase = ref
        .read(taskProjectResolutionProvider(_task.projectId))
        .phase;
    if (phase == TaskProjectPhase.unresolved) {
      ref.invalidate(taskProjectsProvider);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _paneFocus.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Task get _task => widget.task;

  /// True while a remote machine is being woken for this task's Start.
  var _focusing = false;
  String? _focusError;

  /// Focus the task's own project — a local folder or a project on another
  /// machine — then open the launch sheet once that focus has landed; see
  /// [_launchIfQueued].
  ///
  /// [registrationId] is a bare project id for a local folder, or the compound
  /// `<machineUuid>.<projectId>` for a remote one, which has to be woken and
  /// dialled first and so can take a while and can fail.
  Future<void> _focusThenLaunch(String registrationId) async {
    final container = ref.container;
    // Queued BEFORE the focus moves: focusing a project can replace the screen
    // this view lives on, and the instance that mounts next is the one that
    // opens the sheet.
    container.read(pendingTaskLaunchProvider.notifier).set(_task.number);

    if (!registrationId.contains('.')) {
      selectProject(container, registrationId);
      _launchIfQueued();
      return;
    }

    setState(() {
      _focusing = true;
      _focusError = null;
    });
    try {
      await openRemoteProjectForActivation(
        container,
        machineUuid: baseDeviceUuid(registrationId),
        projectId: baseProjectId(registrationId),
      );
      recordProjectFocus(container);
    } catch (e) {
      if (container.read(pendingTaskLaunchProvider) == _task.number) {
        container.read(pendingTaskLaunchProvider.notifier).set(null);
      }
      if (mounted) {
        setState(() {
          _focusing = false;
          _focusError = 'Couldn’t reach that machine — is it online?';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _focusing = false);
    _launchIfQueued();
  }

  void _launchIfQueued() {
    if (!mounted) return;
    if (ref.read(pendingTaskLaunchProvider) != _task.number) return;
    final wanted =
        ref.read(taskProjectSourceProvider(_task.projectId))?.targetIds ??
        const <String>[];
    if (!wanted.contains(ref.read(selectedRegistrationIdProvider))) return;
    ref.read(pendingTaskLaunchProvider.notifier).set(null);
    detached(
      'tasks',
      'start session',
      () => showTaskLaunchSheet(context, _task),
    );
  }

  void _beginTitle() {
    _title.text = _task.title;
    setState(() => _editingTitle = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _titleFocus.requestFocus();
    });
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bodyFocus.requestFocus();
    });
  }

  Future<void> _commitBody() async {
    final next = _body.text;
    setState(() => _editingBody = false);
    if (next == _task.body) return;
    await ref.read(taskListProvider.notifier).setBody(_task.number, next);
  }

  void _toggleTask(int index) {
    final next = MarkdownFormat.toggleTask(_task.body, index);
    if (next == null) return;
    final tasks = ref.read(taskListProvider.notifier);
    final number = _task.number;
    detached('tasks', 'toggle task item', () => tasks.setBody(number, next));
  }

  Future<void> _pickStatus([Rect? anchor]) async {
    // Captured before the sheet: a list refresh under it can retire this
    // widget, and reading `ref` on a dead element throws.
    final container = ref.container;
    final picked = await showAbSelect<TaskStatus>(
      context,
      title: 'Status',
      single: true,
      anchor: anchor,
      shortcut: _statusKey,
      options: [
        for (final status in TaskStatus.selectable)
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
      await container
          .read(taskListProvider.notifier)
          .setStatus(_task.number, next);
    }
  }

  Future<void> _pickAssignee([Rect? anchor]) async {
    final container = ref.container;
    final candidates = container.read(taskAssigneeCandidatesProvider);
    final current = _task.assignee;
    // An imported identity has no Antgrid account to replace it with anything
    // but a member, and clearing it would drop a fact the provider owns.
    if (current is TaskExternalAssignee) return;
    final picked = await showAbSelect<String>(
      context,
      title: 'Assignee',
      single: true,
      anchor: anchor,
      shortcut: _assigneeKey,
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
    await container
        .read(taskListProvider.notifier)
        .setAssignee(
          _task.number,
          choice.isEmpty ? null : TaskMemberAssignee(choice),
        );
  }

  Future<void> _pickPriority([Rect? anchor]) async {
    final container = ref.container;
    final picked = await showAbSelect<int>(
      context,
      title: 'Priority',
      single: true,
      anchor: anchor,
      shortcut: _priorityKey,
      options: [
        AbSelectOption(
          value: -1,
          label: _priorityLabel(null),
          leading: const _PriorityDot(priority: null),
        ),
        for (var p = 0; p < _priorityNames.length; p++)
          AbSelectOption(
            value: p,
            label: _priorityLabel(p),
            leading: _PriorityDot(priority: p),
            keywords: ['P$p'],
          ),
      ],
      selected: {_task.priority ?? -1},
    );
    final choice = picked?.firstOrNull;
    if (choice == null) return;
    await container
        .read(taskListProvider.notifier)
        .setPriority(_task.number, choice < 0 ? null : choice);
  }

  Future<void> _pickProject([Rect? anchor]) async {
    final container = ref.container;
    final names = container.read(taskProjectNamesProvider);
    final picked = await showAbSelect<String>(
      context,
      title: 'Project',
      single: true,
      anchor: anchor,
      options: [
        const AbSelectOption(value: '', label: 'No project'),
        for (final entry in names.entries)
          AbSelectOption(value: entry.key, label: entry.value),
      ],
      selected: {_task.projectId ?? ''},
    );
    final choice = picked?.firstOrNull;
    if (choice == null) return;
    final next = choice.isEmpty ? null : choice;
    if (next == _task.projectId) return;
    await container
        .read(taskListProvider.notifier)
        .setProject(_task.number, next);
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
      await container
          .read(taskListProvider.notifier)
          .publish(number, repoId: repoId);
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
    final session = ref.watch(taskSessionProvider(_task.number));
    // Captured in the SAME tick as `session`: `taskSessionProvider` only ever
    // resolves against the currently focused project's own sessions (see its
    // own doc), so this is the project `session.checkoutId` actually lives
    // in — never re-read live from inside `_TaskChangesSection`, or a focus
    // change between this section mounting and unmounting misroutes its
    // activate/deactivate at whichever project is focused BY THEN.
    final registrationId = ref.watch(selectedRegistrationIdProvider);
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

    final segments = MarkdownFormat.splitComments(_task.body);
    final commentCount = segments.where((s) => s.isComment).length;

    final main = <Widget>[
      _lead(context),
      if (run != null) ...[_sectionHeader('Run'), _runBlock(context, run)],
      // Right after the run: a checkout is only resolvable while a
      // session is actually attached to this task, so the two either
      // show together or not at all.
      if (run != null && session != null && registrationId != null) ...[
        _sectionHeader('Changes'),
        _TaskChangesSection(
          registrationId: registrationId,
          checkoutId: session.checkoutId,
        ),
      ],
      if (_task.push != null) _pushStatusBlock(context),
      // Above the description: the description is one of the things that
      // may have been overwritten.
      if (conflict != null) ...[
        _sectionHeader('Unsettled changes'),
        _conflictBlock(context, conflict),
      ],
      // Beside the conflict block, because the two are halves of the same
      // question: that one is what came in and overwrote a value, this one
      // is what never went out.
      if (pushBlock != null) ...[
        _sectionHeader('Stopped syncing'),
        _pushBlockBlock(context, pushBlock),
      ],
      _sectionHeader(
        'Description',
        trailing: Expanded(
          child: Row(
            children: [
              // The Source block sits in the side column, so the header
              // itself says whose words follow.
              if (!_task.isLocal)
                Flexible(
                  child: Text(
                    'written on ${taskProviderLabel(_task)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: palette.textMuted,
                    ),
                  ),
                ),
              const Spacer(),
              if (commentCount > 0 && !_editingBody)
                Flexible(
                  flex: _toggleFlex,
                  child: AbButton(
                    label: _showComments
                        ? 'Hide template comments'
                        : commentCount == 1
                        ? 'Show 1 template comment'
                        : 'Show $commentCount template comments',
                    compact: true,
                    wrapLabel: true,
                    onTap: () => setState(() => _showComments = !_showComments),
                  ),
                ),
              if (!_editingBody) ...[
                const SizedBox(width: AbTokens.space4),
                AbIconButton(
                  icon: AbIcons.edit,
                  tooltip: 'Edit description',
                  onTap: _beginBody,
                ),
              ],
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AbTokens.space12,
          AbTokens.space4,
          AbTokens.space12,
          AbTokens.space12,
        ),
        child: _bodyBlock(context, segments),
      ),
    ];

    final side = <Widget>[
      _sectionHeader('Properties'),
      _attributes(context),
      if (!_task.isLocal) ...[
        _sideRule(),
        _sectionHeader('Source'),
        TaskProvenanceBlock(task: _task),
      ]
      // A task published FROM here keeps `source: local` — the column
      // records where it was born, not where it now lives — so the Source
      // block above stays absent and this is the only place its issue is
      // ever named.
      else if (_task.syncState != null) ...[
        _sideRule(),
        _sectionHeader('GitHub'),
        _publishedBlock(context),
      ],
      _sideRule(),
      _sectionHeader('Activity'),
      _metadata(context),
    ];
    final actions = _actions(context, targets);

    final body = LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _twoColumnMinWidth) {
          return ListView(
            padding: const EdgeInsets.only(bottom: AbTokens.space24),
            children: [
              ...main,
              const AbSeparator.horizontal(),
              const SizedBox(height: AbTokens.space8),
              ...side,
              actions,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AbTokens.space12,
                  AbTokens.space8,
                  AbTokens.space12,
                  AbTokens.space24,
                ),
                children: [
                  // Prose past this measure stops being readable; the rest of
                  // a wide pane stays empty rather than stretching it.
                  Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _mainMaxWidth,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: main,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const AbSeparator.vertical(),
            SizedBox(
              width: _sideWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AbTokens.space4,
                        vertical: AbTokens.space8,
                      ),
                      children: side,
                    ),
                  ),
                  // Pinned under the column, not scrolled with it: the
                  // destructive pair is always where the eye last left it.
                  const AbSeparator.horizontal(),
                  actions,
                ],
              ),
            ),
          ],
        );
      },
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _topBar(context),
        const AbSeparator.horizontal(),
        // Scoped to THIS task's number: `task_list_view.dart`'s own banner
        // hides itself whenever the failing task is the one open here, on the
        // assumption this pane already shows it — true only if this check is
        // here, or a failure on a task the list is showing (deleted from a
        // row-actions sheet, say) would surface on whichever unrelated task
        // happens to be open in the split, instead of on the list itself.
        if (failure != null && failure.taskNumber == _task.number)
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
        Expanded(child: body),
      ],
    );

    // A click anywhere in the pane hands it focus, so the field shortcuts work
    // without a tab stop — unless something inside (a title being edited)
    // already has it, which a pointer-down must not steal mid-selection.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_paneFocus.hasFocus) _paneFocus.requestFocus();
      },
      child: Focus(
        focusNode: _paneFocus,
        autofocus: true,
        onKeyEvent: _onPaneKey,
        child: content,
      ),
    );
  }

  /// The task's id and state, and the ways out of it. Status is set from its
  /// field in Properties; the pill here only reports it.
  Widget _topBar(BuildContext context) {
    final palette = context.antgrid;
    final url = _task.externalUrl;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space6,
      ),
      child: Row(
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
          if (url != null)
            AbButton(
              label: 'View on ${taskProviderLabel(_task)}',
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
          if (widget.onClose != null) ...[
            const SizedBox(width: AbTokens.space4),
            AbIconButton(
              icon: AbIcons.close,
              tooltip: 'Close task',
              onTap: widget.onClose!,
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String label, {Widget? trailing}) =>
      AbSectionHeader(label: label, mono: true, trailing: trailing);

  Widget _sideRule() => const Padding(
    padding: EdgeInsets.symmetric(
      horizontal: AbTokens.space12,
      vertical: AbTokens.space10,
    ),
    child: AbSeparator.horizontal(),
  );

  /// Stacked full-width: the side column is too narrow to fit two of these
  /// side by side without wrapping their labels mid-word.
  Widget _actions(BuildContext context, List<TaskPublishTarget> targets) {
    final palette = context.antgrid;
    final buttons = <Widget>[
      // Never the primary action: the primary action on a task is Start
      // session, and publishing is not what this product is for.
      if (_task.isPublishable && targets.isNotEmpty)
        AbButton(
          label: _publishing
              ? 'Publishing…'
              : _task.hasUnlinkedIdentity
              // Says what it does rather than reading like a way to restore
              // the link that was dropped.
              ? 'Publish to GitHub (new issue)'
              : 'Publish to GitHub',
          expand: true,
          wrapLabel: true,
          onTap: _publishing
              ? null
              : () =>
                    detached('tasks', 'publish task', () => _publish(targets)),
        ),
      if (_task.isLinked)
        AbButton(
          label: _unlinking ? 'Unlinking…' : 'Unlink from GitHub',
          expand: true,
          wrapLabel: true,
          onTap: _unlinking
              ? null
              : () => detached('tasks', 'unlink task', _unlink),
        ),
      AbButton(
        label: 'Delete task',
        color: palette.error,
        expand: true,
        wrapLabel: true,
        onTap: () => detached('tasks', 'delete task', _delete),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.all(AbTokens.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AbTokens.space8,
        children: buttons,
      ),
    );
  }

  /// The title, and what it takes to start work on it.
  Widget _lead(BuildContext context) {
    final palette = context.antgrid;
    final launcher = ref.watch(taskLauncherProvider);
    // The task's repository is known but no opened folder is it: the fix is
    // to open or clone it, which replaces the generic "no project" sentence.
    final resolution = ref.watch(
      taskProjectResolutionProvider(_task.projectId),
    );
    final source = resolution.source;
    // A task filed against a project must never fall back to "whichever project
    // is focused" just because the account's project list has not arrived: the
    // session would start in the wrong repository, silently.
    final projectUnknown = resolution.blocksLaunch && _task.status.isOpen;
    // Neither a local folder nor a project on an open machine is this repo.
    final projectMissing =
        source != null && !source.reachable && _task.status.isOpen;
    // The task's own repo is reachable — here or on another machine — but is
    // not the focused project: Start focuses it first rather than refusing, or
    // worse, launching into whichever unrelated project happens to be focused.
    final targets = source?.targetIds ?? const <String>[];
    final needsFocus =
        targets.isNotEmpty &&
        !targets.contains(ref.watch(selectedRegistrationIdProvider)) &&
        _task.status.isOpen;
    final blockedReason = projectUnknown
        ? (resolution.phase == TaskProjectPhase.loading
              ? 'Loading this task’s project…'
              : 'Couldn’t load this task’s project, so Antgrid can’t tell '
                    'which repository to start in.')
        : projectMissing || needsFocus
        ? null
        : launcher?.unavailableReason(_task) ??
              // No launcher at all is a build-time state, not a user error: say
              // what is missing rather than leaving a dead button with no
              // explanation.
              (launcher == null
                  ? 'Starting a session from a task is not wired up yet.'
                  : null);

    return Padding(
      padding: const EdgeInsets.all(AbTokens.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_editingTitle)
            AbTextField(
              controller: _title,
              focusNode: _titleFocus,
              hintText: 'Title',
              onSubmitted: (_) => detached('tasks', 'save title', _commitTitle),
            )
          else
            GestureDetector(
              onTap: _beginTitle,
              child: Text(
                _task.title,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontDisplaySm,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                  height: _titleLineHeight,
                ),
              ),
            ),
          const SizedBox(height: AbTokens.space16),
          if (projectMissing)
            TaskProjectMissing(source: source)
          else
            Row(
              children: [
                AbButton(
                  label: _focusing ? 'Opening machine…' : 'Start session',
                  variant: AbButtonVariant.primary,
                  // The sheet, never the launch directly: [TaskLauncher.start]
                  // takes no context, and a start has two things it must show
                  // before and after — which project the session lands in, and
                  // the bridge's reason when it refuses.
                  onTap:
                      _focusing ||
                          projectUnknown ||
                          blockedReason != null ||
                          launcher == null
                      ? null
                      : needsFocus
                      ? () => detached(
                          'tasks',
                          'focus project for task',
                          () => _focusThenLaunch(targets.first),
                        )
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
                  if (resolution.phase == TaskProjectPhase.unresolved &&
                      projectUnknown) ...[
                    const SizedBox(width: AbTokens.space8),
                    AbButton(
                      label: 'Retry',
                      compact: true,
                      onTap: () => ref.invalidate(taskProjectsProvider),
                    ),
                  ],
                ],
              ],
            ),
          if (_focusError != null) ...[
            const SizedBox(height: AbTokens.space6),
            Text(
              _focusError!,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.error,
              ),
            ),
          ] else if (needsFocus && targets.first.contains('.')) ...[
            // The session will run on another machine; say so before the tap,
            // since the sheet only names the project.
            const SizedBox(height: AbTokens.space6),
            Text(
              'Starts on another of your machines: '
              '${source!.remote.firstWhere((r) => r.registrationId == targets.first).label}.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ],
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

    final priority = _task.priority;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space10,
        AbTokens.space12,
        AbTokens.space14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _attribute(
            context,
            'Status',
            fieldKey: _statusField,
            tooltip: 'Change status',
            shortcut: _statusKey,
            open: _openFieldId == 'status',
            onTap: _openStatus,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TaskStatusDot(status: _task.status),
                const SizedBox(width: AbTokens.space6),
                Flexible(
                  child: Text(
                    _task.status.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(fontSize: AbTokens.fontXs),
                  ),
                ),
              ],
            ),
          ),
          _attribute(
            context,
            'Priority',
            fieldKey: _priorityField,
            tooltip: 'Set priority',
            shortcut: _priorityKey,
            open: _openFieldId == 'priority',
            onTap: _openPriority,
            child: priority == null
                ? _placeholder(context, 'Set priority')
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PriorityDot(priority: priority),
                      const SizedBox(width: AbTokens.space6),
                      Flexible(
                        child: Text(
                          _priorityLabel(priority),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AbTokens.sansStyle(fontSize: AbTokens.fontXs),
                        ),
                      ),
                    ],
                  ),
          ),
          _attribute(
            context,
            'Assignee',
            fieldKey: _assigneeField,
            tooltip: 'Change assignee',
            shortcut: _assigneeKey,
            open: _openFieldId == 'assignee',
            onTap: assignee is TaskExternalAssignee ? null : _openAssignee,
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
            fieldKey: _labelsField,
            tooltip: 'Edit labels',
            shortcut: _labelsKey,
            open: _openFieldId == 'labels',
            onTap: _openLabels,
            child: _task.labels.isEmpty
                ? _placeholder(context, 'Add label')
                : Wrap(
                    spacing: AbTokens.space6,
                    runSpacing: AbTokens.space4,
                    children: [
                      for (final label in _task.labels)
                        AbLabelChip(label: label.name, colorHex: label.color),
                    ],
                  ),
          ),
          _attribute(
            context,
            'Project',
            // Once a task is filed against a project, that project is where
            // its checkout, sessions and provenance all live — reassigning it
            // here would orphan those without moving them, so the field is
            // set-once: editable only while still unset.
            open: _openFieldId == 'project',
            onTap: _task.projectId == null ? _openProject : null,
            child: _task.projectId == null
                ? _placeholder(context, 'Set project')
                : Text(
                    projectName ?? _task.projectId!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: projectName == null
                        ? AbTokens.monoStyle(
                            fontSize: AbTokens.fontXxs,
                            color: palette.textMuted,
                          )
                        : AbTokens.monoStyle(fontSize: AbTokens.fontXs),
                  ),
          ),
        ],
      ),
    );
  }

  /// An empty field's own call to action, rather than "None": the row is the
  /// control, so its empty state says what tapping it does.
  Widget _placeholder(BuildContext context, String text) {
    final palette = context.antgrid;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbIcon(AbIcons.add, size: AbTokens.fontSm, color: palette.textMuted),
        const SizedBox(width: AbTokens.space6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: palette.textMuted,
            ),
          ),
        ),
      ],
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
          Flexible(
            child: Text(
              _displayNameFor(assignee.userId),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(fontSize: AbTokens.fontXs),
            ),
          ),
        ],
      ),
      // Read-only by design: this identity came from the provider and has no
      // Antgrid account to edit.
      TaskExternalAssignee() => Text(
        '@${assignee.login}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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
        left: _fieldLabelWidth,
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

  /// One labelled field. The value is the control: tapping it opens its
  /// picker anchored beneath it, so the popover reads as dropping out of the
  /// field it edits.
  Widget _attribute(
    BuildContext context,
    String label, {
    required Widget child,
    void Function(Rect? anchor)? onTap,
    GlobalKey? fieldKey,
    String? tooltip,
    String? shortcut,
    bool open = false,
  }) {
    final palette = context.antgrid;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space2),
      child: Row(
        children: [
          SizedBox(
            width: _fieldLabelWidth - _fieldInset,
            child: Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: palette.textMuted,
              ),
            ),
          ),
          Flexible(
            child: _AttributeField(
              key: fieldKey,
              tooltip: tooltip == null
                  ? null
                  : shortcut == null
                  ? tooltip
                  : '$tooltip  ($shortcut)',
              onTap: onTap,
              open: open,
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  /// Opens the field's picker from the keyboard, anchored where a click on
  /// the field would have anchored it.
  void _openFromKey(GlobalKey field, void Function(Rect? anchor) open) {
    final fieldContext = field.currentContext;
    open(fieldContext == null ? null : abMenuAnchorRect(fieldContext));
  }

  /// Holds [field]'s chevron up for as long as its picker is open, so the
  /// popover stays visibly tied to the field it dropped from.
  void _openField(String field, String what, Future<void> Function() open) {
    detached('tasks', what, () async {
      setState(() => _openFieldId = field);
      try {
        await open();
      } finally {
        if (mounted && _openFieldId == field) {
          setState(() => _openFieldId = null);
        }
      }
    });
  }

  void _openStatus(Rect? anchor) =>
      _openField('status', 'change status', () => _pickStatus(anchor));

  void _openAssignee(Rect? anchor) =>
      _openField('assignee', 'pick assignee', () => _pickAssignee(anchor));

  void _openLabels(Rect? anchor) => _openField(
    'labels',
    'edit labels',
    () => editTaskLabels(
      context,
      ref,
      _task,
      anchor: anchor,
      shortcut: _labelsKey,
    ),
  );

  void _openPriority(Rect? anchor) =>
      _openField('priority', 'pick priority', () => _pickPriority(anchor));

  void _openProject(Rect? anchor) =>
      _openField('project', 'pick project', () => _pickProject(anchor));

  /// Plain-letter shortcuts, honoured only while the pane ITSELF holds focus.
  /// Not a `CallbackShortcuts`: that marks the key handled even when its
  /// callback bails, and a handled key never reaches text input — the title
  /// and description editors would lose every s, a, l and p typed into them.
  KeyEventResult _onPaneKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || FocusManager.instance.primaryFocus != node) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyS) {
      _openFromKey(_statusField, _openStatus);
    } else if (key == LogicalKeyboardKey.keyA) {
      if (_task.assignee is TaskExternalAssignee) return KeyEventResult.ignored;
      _openFromKey(_assigneeField, _openAssignee);
    } else if (key == LogicalKeyboardKey.keyL) {
      _openFromKey(_labelsField, _openLabels);
    } else if (key == LogicalKeyboardKey.keyP) {
      _openFromKey(_priorityField, _openPriority);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
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
          _conflictSide(
            context,
            'Yours · set aside',
            field.field,
            field.localValue,
          ),
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
    // See [Task.isPushDisconnected]: distinct from [unlinked] (this task
    // choosing to stop) — this is the channel itself being down.
    final disconnected = _task.isPushDisconnected;
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
                disconnected
                    ? AbIcons.warning
                    : unlinked
                    ? AbIcons.syncOff
                    : AbIcons.openExternal,
                size: AbTokens.iconButtonGlyph,
                color: disconnected ? palette.warning : palette.iconMuted,
              ),
              const SizedBox(width: AbTokens.space6),
              Flexible(
                child: Text(
                  pending
                      ? 'Creating the issue…'
                      : unlinked
                      ? 'No longer syncing'
                      : disconnected
                      ? (_task.pushReason == TaskPushReason.pushOff
                            ? 'Not pushing to GitHub'
                            : _task.pushReason == TaskPushReason.repoRemoved
                            ? 'Repository removed'
                            : 'GitHub disconnected')
                      : 'Published to GitHub',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: disconnected
                        ? palette.warning
                        : palette.textSecondary,
                  ),
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
            ],
          ),
          const SizedBox(height: AbTokens.space6),
          Text(
            pending
                ? 'The task is saved here; the issue does not exist yet.'
                : unlinked
                ? 'Edits here no longer reach the issue, and it is untouched '
                      'where it is. Publishing again creates a second one.'
                : disconnected
                ? taskPushReasonDetail(_task)
                : 'Edits to the title, description, status and labels are sent '
                      'to this issue.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: disconnected ? palette.warning : palette.textMuted,
            ),
          ),
          if (url != null) ...[
            const SizedBox(height: AbTokens.space8),
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
        ],
      ),
    );
  }

  /// Edits queued for the provider, retrying, or abandoned — the state a
  /// "synced" task otherwise hides. A failed publish lands here with its error,
  /// beside the Publish button that comes back for it.
  Widget _pushStatusBlock(BuildContext context) {
    final palette = context.antgrid;
    final push = _task.push!;
    final failed = push.state == TaskPushState.failed;
    final provider = taskProviderLabel(_task);
    final headline = switch (push.state) {
      TaskPushState.queued =>
        push.pending == 1
            ? '1 edit waiting to reach $provider'
            : '${push.pending} edits waiting to reach $provider',
      TaskPushState.retrying => 'Retrying — $provider did not accept an edit',
      TaskPushState.failed =>
        _task.externalId == null
            ? 'Publishing to $provider failed'
            : 'An edit could not be sent to $provider',
    };
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
          Text(
            headline,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: failed ? palette.error : palette.warning,
            ),
          ),
          if (push.lastError != null) ...[
            const SizedBox(height: AbTokens.space4),
            Text(
              push.lastError!,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ],
          if (push.nextAttemptAt != null &&
              push.state == TaskPushState.retrying) ...[
            const SizedBox(height: AbTokens.space4),
            Text(
              'Next attempt ${_stamp(push.nextAttemptAt!)}',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ],
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

  Widget _bodyBlock(BuildContext context, List<MarkdownSegment> segments) {
    final palette = context.antgrid;
    if (_editingBody) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TaskBodyEditor(controller: _body, focusNode: _bodyFocus, minLines: 8),
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
    return _description(context, segments);
  }

  /// The body as markdown, with its template comments hidden or set apart.
  ///
  /// Box indices stay document-wide across the pieces: [MarkdownFormat]
  /// counts boxes outside comments only, which is exactly what is rendered.
  Widget _description(BuildContext context, List<MarkdownSegment> segments) {
    final palette = context.antgrid;
    final prose = segments.where((s) => !s.isComment).map((s) => s.text);
    final hasComments = prose.length != segments.length;
    if (!hasComments) {
      return TranscriptMarkdown(data: _task.body, onToggleTask: _toggleTask);
    }
    if (!_showComments) {
      final text = prose.join();
      // Headings with nothing under them are the template's own skeleton.
      final filledIn = text
          .split('\n')
          .any((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (text.trim().isNotEmpty)
            TranscriptMarkdown(data: text, onToggleTask: _toggleTask),
          if (!filledIn) ...[
            if (text.trim().isNotEmpty) const SizedBox(height: AbTokens.space8),
            Text(
              'Template has no content filled in yet.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: palette.textMuted,
              ),
            ),
          ],
        ],
      );
    }
    final children = <Widget>[];
    var boxes = 0;
    for (final segment in segments) {
      if (segment.isComment) {
        if (segment.text.isEmpty) continue;
        children.add(_TemplateComment(text: segment.text));
        continue;
      }
      if (segment.text.trim().isEmpty) continue;
      final first = boxes;
      children.add(
        TranscriptMarkdown(
          data: segment.text,
          onToggleTask: (i) => _toggleTask(first + i),
        ),
      );
      boxes += MarkdownFormat.taskCount(segment.text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AbTokens.space10,
      children: children,
    );
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

/// The task's own changed-files list, scoped to a specific session checkout
/// rather than whatever checkout the Git tab happens to have open.
///
/// Owns that checkout's activation for as long as it is mounted: a checkout's
/// services bundle only pulls a live tree once `activate()` has been called
/// on it — normally reserved for whichever checkout is on screen (see
/// `FileService.activate`'s own doc) — so this section puts its own checkout
/// on screen for its lifetime and hands it back on dispose, the same
/// contract the workspace shell holds for the focused one.
class _TaskChangesSection extends ConsumerStatefulWidget {
  const _TaskChangesSection({
    required this.registrationId,
    required this.checkoutId,
  });

  /// The project this checkout actually lives in — captured by the caller
  /// from the SAME read that resolved [checkoutId], never re-read live here.
  /// See [checkoutServiceOrNull]'s own doc for why: this section can outlive
  /// a focus change, and re-reading focus at dispose time would activate one
  /// project's checkout and deactivate a different one's.
  final String registrationId;

  final String checkoutId;

  @override
  ConsumerState<_TaskChangesSection> createState() =>
      _TaskChangesSectionState();
}

class _TaskChangesSectionState extends ConsumerState<_TaskChangesSection> {
  @override
  void initState() {
    super.initState();
    _activate(widget.registrationId, widget.checkoutId);
  }

  @override
  void didUpdateWidget(covariant _TaskChangesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registrationId != widget.registrationId ||
        oldWidget.checkoutId != widget.checkoutId) {
      _deactivate(oldWidget.registrationId, oldWidget.checkoutId);
      _activate(widget.registrationId, widget.checkoutId);
    }
  }

  @override
  void dispose() {
    _deactivate(widget.registrationId, widget.checkoutId);
    super.dispose();
  }

  void _activate(String registrationId, String checkoutId) =>
      checkoutServiceOrNull(
        ref.container,
        registrationId,
        checkoutId,
        (s) => s,
      )?.activate();

  void _deactivate(String registrationId, String checkoutId) =>
      checkoutServiceOrNull(
        ref.container,
        registrationId,
        checkoutId,
        (s) => s,
      )?.deactivate();

  /// Bounded height, not `shrinkWrap`: this list sits inside the detail
  /// view's own outer `ListView`, and an unbounded list of a long-running
  /// task's changes would grow to fill the whole scroll region, pushing
  /// every other section (Description included) off screen.
  static const double _kListHeight = 220;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final registrationId = widget.registrationId;
    final checkoutId = widget.checkoutId;
    final state = ref
        .watch(
          taskCheckoutFileTreeStateProvider((
            registrationId: registrationId,
            checkoutId: checkoutId,
          )),
        )
        .value;
    if (state == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AbTokens.space12,
          vertical: AbTokens.space8,
        ),
        child: AbLoading(message: 'loading changes...'),
      );
    }
    final gitStatus = state.gitStatus;
    if (gitStatus.entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space12,
          vertical: AbTokens.space6,
        ),
        child: Text(
          'Nothing changed yet.',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: palette.textMuted,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space12,
            vertical: AbTokens.space4,
          ),
          child: AbDiffStat(
            additions: gitStatus.additions,
            deletions: gitStatus.deletions,
            fontSize: AbTokens.fontXs,
          ),
        ),
        SizedBox(
          height: _kListHeight,
          child: FileTreeView(
            root: state.root,
            expandedPaths: state.expandedPaths,
            selectedFilePath: state.git.diffPath,
            gitStatus: gitStatus,
            changesOnly: true,
            collapsedPaths: state.git.collapsedPaths,
            onToggleExpanded: (path) => checkoutServiceOrNull(
              ref.container,
              registrationId,
              checkoutId,
              (s) => s.fileService,
            )?.toggleGitFolder(path),
            onFileSelected: (path) => _openTaskFileDiff(
              context,
              ref,
              registrationId,
              checkoutId,
              path,
            ),
          ),
        ),
      ],
    );
  }
}

/// Pushes the same diff (and, from there, the same file viewer) the Git tab
/// itself uses — see `GitPanel`'s own content area — scoped to [checkoutId]
/// rather than whichever checkout is currently focused.
Future<void> _openTaskFileDiff(
  BuildContext context,
  WidgetRef ref,
  String registrationId,
  String checkoutId,
  String path,
) {
  final fileService = checkoutServiceOrNull(
    ref.container,
    registrationId,
    checkoutId,
    (s) => s.fileService,
  );
  if (fileService == null) return Future.value();
  fileService.requestDiff(path);
  // "View file" swaps this route from the diff to the file. The Git pane no
  // longer has a file mode of its own, so the file loads through the
  // checkout's Files pane — the workspace tab it would otherwise reveal is not
  // on screen behind a pushed route.
  var showingFile = false;
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => Scaffold(
        backgroundColor: routeContext.antgrid.bgDeepest,
        body: SafeArea(
          child: StatefulBuilder(
            builder: (_, setRouteState) => Consumer(
              builder: (consumerContext, consumerRef, _) {
                final state = consumerRef
                    .watch(
                      taskCheckoutFileTreeStateProvider((
                        registrationId: registrationId,
                        checkoutId: checkoutId,
                      )),
                    )
                    .value;
                final git = state?.git;
                final files = state?.files;
                if (showingFile && files?.selectedFilePath == path) {
                  return FileViewerRouter(
                    fileContent: files!.viewingFile,
                    isLoading: files.isLoading,
                    selectedFilePath: path,
                    fileWasModified: files.fileModifiedExternally,
                    onRefreshContent: () =>
                        fileService.requestFileContent(path),
                    onClose: () {
                      fileService.clearDiff();
                      Navigator.of(consumerContext).pop();
                    },
                  );
                }
                if (git == null ||
                    git.diffPath != path ||
                    git.diffContent == null) {
                  return const AbLoading();
                }
                return DiffViewer(
                  path: path,
                  gitStatus: state!.gitFileStatuses[path],
                  diff: git.diffContent!,
                  additions: git.diffAdditions ?? 0,
                  deletions: git.diffDeletions ?? 0,
                  onViewFile: () {
                    fileService.selectFile(path);
                    setRouteState(() => showingFile = true);
                  },
                  onClose: () {
                    fileService.clearDiff();
                    Navigator.of(consumerContext).pop();
                  },
                  onSendToAgent: (sendContext, message) => sendCaptureToAgent(
                    context: sendContext,
                    container: consumerRef.container,
                    text: message,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

/// A route-pushed detail, for the phone. Desktop puts the same widget in the
/// split instead.
Future<void> showTaskDetail(BuildContext context, int number) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      // A Scaffold, not a ColoredBox: a pushed route has no Material above it,
      // so bare Text falls back to the debug yellow-underline style.
      builder: (context) => Scaffold(
        backgroundColor: context.antgrid.bgDeepest,
        body: SafeArea(
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

/// Below this the side column drops under the description instead of
/// squeezing it: the description is the part that needs the width.
const _twoColumnMinWidth = 700.0;

/// Against the header's spacer: the toggle takes what it needs first and
/// wraps only when the header truly cannot fit it.
const _toggleFlex = 8;
const _sideWidth = 320.0;
const _mainMaxWidth = 760.0;
const _titleLineHeight = 1.3;

const _attributeLabelWidth = 72.0;
const _avatarSize = 18.0;

/// Wider than [_attributeLabelWidth]: the editable fields carry a hover box
/// whose padding would otherwise crowd the label.
const _fieldLabelWidth = 88.0;

/// How far a field box reaches left of its value: the label column gives
/// this back, so values line up with [_fieldLabelWidth] whatever their box.
const _fieldInset = AbTokens.space8 + 1;

/// [AbTokens.rowHeightXs] less the field box's 1px border and vertical padding.
const _fieldInnerMinHeight = AbTokens.rowHeightXs - 2 * AbTokens.space2 - 2;

const _statusKey = 'S';
const _assigneeKey = 'A';
const _labelsKey = 'L';
const _priorityKey = 'P';

/// Indexed by the stored priority: 0 is the most urgent.
const _priorityNames = ['Urgent', 'High', 'Medium', 'Low'];

String _priorityLabel(int? priority) =>
    priority == null || priority < 0 || priority >= _priorityNames.length
    ? (priority == null ? 'No priority' : 'P$priority')
    : _priorityNames[priority];

/// Filled for a set priority, hollow for none — the same mark in the field
/// and in its picker.
class _PriorityDot extends StatelessWidget {
  const _PriorityDot({required this.priority});

  final int? priority;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final color = switch (priority) {
      0 => palette.error,
      1 => palette.warning,
      2 => palette.statusThinking,
      3 => palette.accent,
      _ => palette.iconMuted,
    };
    final filled = priority != null;
    return Container(
      width: AbTokens.dotSizeSm,
      height: AbTokens.dotSizeSm,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? color : null,
        border: filled ? null : Border.all(color: color, width: 1.5),
      ),
    );
  }
}

/// A field value that is its own control: flat at rest, boxed on hover. The
/// chevron saying it opens a list shows only on hover or while its picker is
/// up, so a column of fields reads as values rather than a stack of
/// dropdowns. Read-only values ([onTap] null) render bare, so an uneditable
/// field never looks like a dead button.
class _AttributeField extends StatefulWidget {
  const _AttributeField({
    super.key,
    required this.child,
    this.onTap,
    this.tooltip,
    this.open = false,
  });

  final Widget child;

  /// Receives this field's rect in overlay coordinates, for anchoring.
  final void Function(Rect? anchor)? onTap;
  final String? tooltip;

  /// This field's picker is showing.
  final bool open;

  @override
  State<_AttributeField> createState() => _AttributeFieldState();
}

class _AttributeFieldState extends State<_AttributeField> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final onTap = widget.onTap;
    final boxed = onTap != null && _hovered;
    final showChevron = boxed || widget.open;
    // Hugs its value: the box and the chevron grow with what the field holds.
    final content = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space2,
      ),
      decoration: BoxDecoration(
        color: boxed ? palette.bgHover : null,
        borderRadius: AbTokens.borderRadius5,
        border: Border.all(
          color: boxed ? palette.borderDefault : const Color(0x00000000),
        ),
      ),
      child: ConstrainedBox(
        // The row, not the box, carries the height floor: a Row stretched to
        // a minimum centres its children, a Container would top-align them.
        constraints: const BoxConstraints(minHeight: _fieldInnerMinHeight),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: widget.child),
            if (onTap != null) ...[
              const SizedBox(width: AbTokens.space8),
              AnimatedOpacity(
                opacity: showChevron ? 1 : 0,
                duration: AbTokens.motionSnap,
                child: AbIcon(
                  AbIcons.chevronDown,
                  size: AbTokens.fontSm,
                  color: palette.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    final tooltip = widget.tooltip;
    final control = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(abMenuAnchorRect(context)),
        child: content,
      ),
    );
    return tooltip == null
        ? control
        : AbTooltip(message: tooltip, child: control);
  }
}

/// A template's guidance comment, set apart from what the author wrote:
/// dashed and muted, because it is the form's text rather than the issue's.
class _TemplateComment extends StatelessWidget {
  const _TemplateComment({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    return CustomPaint(
      painter: _DashedBorder(color: palette.borderDefault),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space12,
          vertical: AbTokens.space8,
        ),
        child: Text(
          text,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXs,
            color: palette.textMuted,
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color});

  final Color color;

  static const _dash = 4.0;
  static const _gap = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(AbTokens.radius5),
        ).deflate(0.5),
      );
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        canvas.drawPath(metric.extractPath(d, d + _dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

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
