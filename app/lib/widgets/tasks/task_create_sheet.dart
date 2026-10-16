import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_select_sheet.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_switch.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../../services/tasks_api.dart' show TaskApiException;
import '../../util/detached.dart';
import 'create_label_dialog.dart';
import 'task_body_editor.dart';
import 'task_publish_sheet.dart';

/// The create form. Returns the new task's number, or null if nothing was
/// created.
Future<int?> showTaskCreateSheet(BuildContext context) {
  // Sized for writing a brief, not a one-liner: a body editor and a metadata
  // sidebar side by side, the shape of GitHub's new-issue page.
  return showAbAdaptiveSheet<int>(
    context,
    maxWidth: 960,
    // A half-written brief is too costly to lose to a stray click beside the
    // dialog; Cancel and the close button are the ways out.
    dismissible: false,
    child: const _TaskCreateSheet(),
  );
}

/// Below this the metadata sidebar folds under the editor.
const _sidebarBreakpoint = 680.0;
const _sidebarWidth = 220.0;

class _TaskCreateSheet extends ConsumerStatefulWidget {
  const _TaskCreateSheet();

  @override
  ConsumerState<_TaskCreateSheet> createState() => _TaskCreateSheetState();
}

class _TaskCreateSheetState extends ConsumerState<_TaskCreateSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _bodyFocus = FocusNode();

  /// The refusal from the last create. It renders here because the list
  /// banner that normally carries it sits behind this sheet, unseen.
  String? _submitError;
  var _labels = <TaskLabel>[];
  TaskAssignee? _assignee;
  var _submitting = false;

  /// Seeded from the list's own project scope: a task written while looking at
  /// one project's tasks belongs to that project.
  String? _projectId;

  /// Null until the user touches the switch, which is what lets the repo's
  /// per-project default position it — and only position it.
  bool? _publishChoice;

  /// The repo chosen when several qualify. A single target needs none: it is
  /// the only place the issue could go.
  String? _repoId;

  /// Whether the body was still empty when this project was chosen.
  ///
  /// The default may position a control the user is about to look at; it may
  /// never arm one over text already typed. Filing a half-written note against
  /// a project must not flip a switch nobody touched, so the default only
  /// applies to a project chosen before there was anything to publish.
  var _projectChosenWithEmptyBody = true;

  /// Whether the title is blank, which is what the Create button answers to:
  /// a task with no title is refused by the server, so the button says so up
  /// front instead of accepting the tap and doing nothing.
  var _titleBlank = true;

  @override
  void initState() {
    super.initState();
    _projectId = ref.read(taskFilterProvider).projectId;
    _title.addListener(_onTitleChanged);
  }

  void _onTitleChanged() {
    final blank = _title.text.trim().isEmpty;
    // Only when the answer flips: every keystroke would otherwise rebuild the
    // whole form for a value that has not changed.
    if (blank != _titleBlank) setState(() => _titleBlank = blank);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _pickLabels() async {
    final all = ref.read(taskLabelsProvider).value ?? const <TaskLabel>[];
    // Filled by onCreateNew below — see the matching comment in
    // task_row_actions.dart's editTaskLabels, which has the same gap.
    final justCreated = <TaskLabel>[];
    final picked = await showAbSelect<String>(
      context,
      title: 'Labels',
      emptyMessage: 'This account has no labels yet',
      options: [
        for (final label in all)
          AbSelectOption(
            value: label.id,
            label: label.name,
            leading: AbLabelChip(label: label.name, colorHex: label.color),
            onDelete: (ctx) => confirmDeleteLabel(ctx, ref, label),
          ),
      ],
      selected: _labels.map((l) => l.id).toSet(),
      createTooltip: 'New label',
      onCreateNew: (ctx) async {
        final created = await showCreateLabelDialog(ctx);
        if (created != null) justCreated.add(created);
        return created?.id;
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _labels = [
        ...all,
        ...justCreated,
      ].where((l) => picked.contains(l.id)).toList(growable: false);
    });
  }

  /// Prefix marking a picker value as a repo with no project yet rather than a
  /// project id — the two share one list and must never be mistaken for each
  /// other.
  static const _repoPrefix = 'repo:';

  /// True while a repo with no project yet is being turned into one.
  var _creatingProject = false;
  String? _projectError;

  Future<void> _pickProject(
    Map<String, String> names,
    List<UnlinkedRepo> unlinked,
  ) async {
    final picked = await showAbSelect<String>(
      context,
      title: 'Project',
      single: true,
      options: [
        const AbSelectOption(value: '', label: 'No project'),
        for (final entry in names.entries)
          AbSelectOption(value: entry.key, label: entry.value),
        // Repos the GitHub App can see that no machine has opened. Choosing one
        // creates its project, so a task can be filed against it before anyone
        // has a checkout.
        for (final repo in unlinked)
          AbSelectOption(
            value: '$_repoPrefix${repo.id}',
            label: repo.name,
            detail: 'GitHub repo, not opened on a machine yet',
          ),
      ],
      selected: {_projectId ?? ''},
    );
    final choice = picked?.firstOrNull;
    if (choice == null || !mounted) return;

    var chosen = choice.isEmpty ? null : choice;
    if (chosen != null && chosen.startsWith(_repoPrefix)) {
      chosen = await _materialize(chosen.substring(_repoPrefix.length));
      // A failure keeps the previous choice and says why; nothing to apply.
      if (chosen == null || !mounted) return;
    }
    setState(() {
      _projectError = null;
      _projectId = chosen;
      // Both derived state, and both must fall back to nothing chosen: a repo
      // belongs to the project it came from, and the switch's position was an
      // answer about a different destination.
      _repoId = null;
      _publishChoice = null;
      _projectChosenWithEmptyBody = _body.text.trim().isEmpty;
    });
  }

  /// Turns a repo the account can see into a project, and refreshes the lists
  /// that feed the picker so it is offered as a project from now on.
  ///
  /// Returns the project id, or null after recording why it could not.
  Future<String?> _materialize(String repoId) async {
    setState(() {
      _creatingProject = true;
      _projectError = null;
    });
    try {
      final project = await ref
          .read(tasksApiProvider)
          .createProjectFromRepo(repoId);
      // Refreshed and awaited, so the button can name the project the moment it
      // is chosen instead of flashing a placeholder while the list reloads.
      ref.invalidate(taskUnlinkedReposProvider);
      ref.invalidate(taskProjectsProvider);
      await ref.read(taskProjectsProvider.future);
      return project.id;
    } on TaskApiException catch (e) {
      if (mounted) setState(() => _projectError = e.message);
      return null;
    } catch (_) {
      if (mounted) {
        setState(() => _projectError = 'Couldn’t set up that repo. Try again.');
      }
      return null;
    } finally {
      if (mounted) setState(() => _creatingProject = false);
    }
  }

  Future<void> _pickRepo(List<TaskPublishTarget> targets) async {
    final picked = await pickTaskPublishTarget(
      context,
      targets,
      selected: _target(targets),
    );
    if (picked == null || !mounted) return;
    setState(() => _repoId = picked.id);
  }

  /// The destination as it stands: the only target, the one explicitly chosen,
  /// or nothing.
  TaskPublishTarget? _target(List<TaskPublishTarget> targets) {
    if (targets.length == 1) return targets.single;
    for (final target in targets) {
      if (target.id == _repoId) return target;
    }
    return null;
  }

  /// Whether this task will be created on GitHub, derived rather than stored so
  /// the switch on screen and the field on the wire can never disagree.
  bool _publishOn(List<TaskPublishTarget> targets) {
    final target = _target(targets);
    if (target == null) return false;
    // Several repos means an explicit choice with no default at all — the
    // per-project default only speaks where there is one possible destination.
    final defaultOn =
        targets.length == 1 &&
        target.publishNewByDefault &&
        _projectChosenWithEmptyBody;
    return _publishChoice ?? defaultOn;
  }

  Future<void> _submit(List<TaskPublishTarget> targets) async {
    final title = _title.text.trim();
    if (title.isEmpty || _submitting || _creatingProject) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final publish = _publishOn(targets);
    final task = await ref
        .read(taskListProvider.notifier)
        .create(
          title: title,
          publish: publish,
          publishRepoId: publish ? _target(targets)?.id : null,
          body: _body.text.isEmpty ? null : _body.text,
          projectId: _projectId,
          assignee: _assignee,
          labelIds: _labels.isEmpty
              ? null
              : _labels.map((l) => l.id).toList(growable: false),
        );
    if (!mounted) return;
    if (task == null) {
      // Keep the form open with the text still in it. The refusal moves from
      // the list banner to the sheet so it is shown once, where it can be seen.
      final failure = ref.read(taskMutationErrorProvider);
      ref.read(taskMutationErrorProvider.notifier).set(null);
      setState(() {
        _submitting = false;
        _submitError = failure?.error.message ?? 'Could not create the task.';
      });
      return;
    }
    Navigator.of(context).pop(task.number);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = ref.watch(taskAssigneeCandidatesProvider);
    final projectNames = ref.watch(taskProjectNamesProvider);
    final unlinkedRepos =
        ref.watch(taskUnlinkedReposProvider).value ?? const <UnlinkedRepo>[];
    final projectId = _projectId;
    final targets = projectId == null
        ? const <TaskPublishTarget>[]
        : ref.watch(taskPublishTargetsProvider(projectId)).value ??
              const <TaskPublishTarget>[];
    final publish = _publishOn(targets);
    final palette = context.antgrid;

    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AbTextField(
          controller: _title,
          hintText: 'Title',
          autofocus: true,
          // Enter moves on to the description: creating here would file a
          // public issue from a half-written task when publish is on by
          // default.
          onSubmitted: (_) => _bodyFocus.requestFocus(),
        ),
        const SizedBox(height: AbTokens.space12),
        TaskBodyEditor(controller: _body, focusNode: _bodyFocus),
        for (final error in [_submitError, _projectError])
          if (error != null) ...[
            const SizedBox(height: AbTokens.space8),
            Text(
              error,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.error,
              ),
            ),
          ],
        // The form IS the confirm step: the title and body are on screen
        // being typed, next to the repo they would land in. A second sheet on
        // submit would be a confirmation of a confirmation, and those get
        // clicked through.
        if (targets.isNotEmpty) ...[
          const SizedBox(height: AbTokens.space12),
          _publishBlock(context, targets, publish),
        ],
      ],
    );

    final sidebar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (candidates.isNotEmpty)
          _SidebarField(
            label: 'Assignee',
            onTap: () => setState(
              () => _assignee = _assignee == null
                  ? TaskMemberAssignee(candidates.first.userId)
                  : null,
            ),
            tooltip: _assignee == null ? 'Assign yourself' : 'Unassign',
            child: _sidebarValue(
              context,
              _assignee == null
                  ? 'No one — assign yourself'
                  : candidates.first.displayName,
              muted: _assignee == null,
            ),
          ),
        _SidebarField(
          label: 'Labels',
          tooltip: 'Edit labels',
          onTap: () => detached('tasks', 'pick labels', _pickLabels),
          child: _labels.isEmpty
              ? _sidebarValue(context, 'None yet', muted: true)
              : Wrap(
                  spacing: AbTokens.space4,
                  runSpacing: AbTokens.space4,
                  children: [
                    for (final label in _labels)
                      AbLabelChip(label: label.name, colorHex: label.color),
                  ],
                ),
        ),
        // Absent where the app cannot name a single project: an empty picker
        // is a dead end, and a task with no project is the state this form
        // has always produced.
        if (projectNames.isNotEmpty || unlinkedRepos.isNotEmpty)
          _SidebarField(
            label: 'Project',
            tooltip: 'Choose project',
            onTap: _creatingProject
                ? null
                : () => detached(
                    'tasks',
                    'pick project',
                    () => _pickProject(projectNames, unlinkedRepos),
                  ),
            child: _sidebarValue(
              context,
              _creatingProject
                  ? 'Setting up…'
                  : projectId == null
                  ? 'No project'
                  : projectNames[projectId] ?? 'Project',
              muted: projectId == null && !_creatingProject,
            ),
          ),
      ],
    );

    final footer = Padding(
      padding: const EdgeInsets.all(AbTokens.space12),
      child: Row(
        children: [
          Expanded(
            child: publish
                ? const SizedBox.shrink()
                : Text(
                    'Stays in this Antgrid account.',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: palette.textMuted,
                    ),
                  ),
          ),
          AbButton(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
          const SizedBox(width: AbTokens.space8),
          AbButton(
            label: _submitting
                ? 'Creating…'
                : publish
                ? 'Create task and issue'
                : 'Create task',
            variant: AbButtonVariant.primary,
            onTap: _submitting || _creatingProject || _titleBlank
                ? null
                : () =>
                      detached('tasks', 'create task', () => _submit(targets)),
          ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space12,
            AbTokens.space8,
            AbTokens.space8,
            AbTokens.space8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'New task',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const AbSeparator.horizontal(),
        // Flexible + scroll: the editor is tall, and a short window or a phone
        // with the keyboard up must scroll the form rather than overflow it.
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AbTokens.space12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < _sidebarBreakpoint) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      main,
                      const SizedBox(height: AbTokens.space12),
                      sidebar,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: main),
                    const SizedBox(width: AbTokens.space16),
                    SizedBox(width: _sidebarWidth, child: sidebar),
                  ],
                );
              },
            ),
          ),
        ),
        const AbSeparator.horizontal(),
        footer,
      ],
    );
  }

  Widget _sidebarValue(
    BuildContext context,
    String text, {
    bool muted = false,
  }) {
    final palette = context.antgrid;
    return Text(
      text,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontXs,
        color: muted ? palette.textMuted : palette.textSecondary,
      ),
    );
  }

  /// The one control on this form with a blast radius outside the account.
  ///
  /// Its two states are deliberately asymmetric: ON reads as a live warning
  /// with the repo named in it, OFF is as quiet as any other field. A
  /// pre-checked switch under one line of grey text is the weakest possible
  /// signal on the highest-consequence control, and there is no second sheet
  /// behind it.
  Widget _publishBlock(
    BuildContext context,
    List<TaskPublishTarget> targets,
    bool publish,
  ) {
    final palette = context.antgrid;
    final target = _target(targets);
    final tone = publish ? palette.warning : null;
    return Container(
      padding: const EdgeInsets.all(AbTokens.space8),
      decoration: BoxDecoration(
        border: Border.all(
          color: publish ? palette.warning : palette.borderDefault,
        ),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AbSwitch(
                value: publish,
                tone: palette.warning,
                semanticLabel: 'Create on GitHub too',
                // Several repos and none chosen: there is nowhere for the
                // switch to point yet, so it cannot be turned on.
                onChanged: target == null
                    ? null
                    : (v) => setState(() => _publishChoice = v),
              ),
              const SizedBox(width: AbTokens.space8),
              Expanded(
                child: Text(
                  'Create on GitHub too',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    fontWeight: publish ? FontWeight.w600 : FontWeight.normal,
                    color: tone ?? palette.textSecondary,
                  ),
                ),
              ),
              if (targets.length > 1)
                AbButton(
                  label: target == null ? 'Choose a repo' : 'Change repo',
                  compact: true,
                  onTap: () => detached(
                    'tasks',
                    'pick publish repo',
                    () => _pickRepo(targets),
                  ),
                ),
            ],
          ),
          if (target == null)
            Padding(
              padding: const EdgeInsets.only(top: AbTokens.space6),
              child: Text(
                'This project is connected to several repos. Pick one before '
                'turning this on.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: palette.textMuted,
                ),
              ),
            )
          else ...[
            const SizedBox(height: AbTokens.space6),
            if (publish)
              Text(
                'Will be created in',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: palette.warning,
                ),
              ),
            TaskPublishDestination(target: target, tone: tone),
            // Says the pre-checked position is a project setting rather than
            // something this form decided on its own.
            if (targets.length == 1 && target.publishNewByDefault) ...[
              const SizedBox(height: AbTokens.space4),
              Text(
                'On by default for ${target.slug}. Turning it off here changes '
                'only this task.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: palette.textMuted,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// One metadata block in the create form's sidebar: a label with an edit
/// affordance over its current value, the way GitHub's issue sidebar lists
/// assignees, labels and project. The whole block is the tap target.
class _SidebarField extends StatelessWidget {
  const _SidebarField({
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(bottom: AbTokens.space12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        fontWeight: FontWeight.w600,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                  AbIconButton(
                    icon: AbIcons.edit,
                    tooltip: tooltip,
                    onTap: onTap,
                  ),
                ],
              ),
              const SizedBox(height: AbTokens.space4),
              child,
              const SizedBox(height: AbTokens.space12),
              const AbSeparator.horizontal(),
            ],
          ),
        ),
      ),
    );
  }
}
