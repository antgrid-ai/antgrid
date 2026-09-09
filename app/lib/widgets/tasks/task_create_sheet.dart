import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_multiline_field.dart';
import '../../design/widgets/ab_select_sheet.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_switch.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../../util/detached.dart';
import 'task_publish_sheet.dart';

/// The create form. Returns the new task's number, or null if nothing was
/// created.
Future<int?> showTaskCreateSheet(BuildContext context) {
  return showAbAdaptiveSheet<int>(context, child: const _TaskCreateSheet());
}

class _TaskCreateSheet extends ConsumerStatefulWidget {
  const _TaskCreateSheet();

  @override
  ConsumerState<_TaskCreateSheet> createState() => _TaskCreateSheetState();
}

class _TaskCreateSheetState extends ConsumerState<_TaskCreateSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();
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

  @override
  void initState() {
    super.initState();
    _projectId = ref.read(taskFilterProvider).projectId;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickLabels() async {
    final all = ref.read(taskLabelsProvider).value ?? const <TaskLabel>[];
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
          ),
      ],
      selected: _labels.map((l) => l.id).toSet(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _labels = all.where((l) => picked.contains(l.id)).toList(growable: false);
    });
  }

  Future<void> _pickProject(Map<String, String> names) async {
    final picked = await showAbSelect<String>(
      context,
      title: 'Project',
      single: true,
      options: [
        const AbSelectOption(value: '', label: 'No project'),
        for (final entry in names.entries)
          AbSelectOption(value: entry.key, label: entry.value),
      ],
      selected: {_projectId ?? ''},
    );
    final choice = picked?.firstOrNull;
    if (choice == null || !mounted) return;
    setState(() {
      _projectId = choice.isEmpty ? null : choice;
      // Both derived state, and both must fall back to nothing chosen: a repo
      // belongs to the project it came from, and the switch's position was an
      // answer about a different destination.
      _repoId = null;
      _publishChoice = null;
      _projectChosenWithEmptyBody = _body.text.trim().isEmpty;
    });
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
    if (title.isEmpty || _submitting) return;
    setState(() => _submitting = true);
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
      // The refusal is already on `taskMutationErrorProvider`, which the list
      // banner renders. Keep the form open with the text still in it.
      setState(() => _submitting = false);
      return;
    }
    Navigator.of(context).pop(task.number);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = ref.watch(taskAssigneeCandidatesProvider);
    final projectNames = ref.watch(taskProjectNamesProvider);
    final projectId = _projectId;
    final targets = projectId == null
        ? const <TaskPublishTarget>[]
        : ref.watch(taskPublishTargetsProvider(projectId)).value ??
              const <TaskPublishTarget>[];
    final publish = _publishOn(targets);
    final palette = context.antgrid;
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
        Padding(
          padding: const EdgeInsets.all(AbTokens.space12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AbTextField(
                controller: _title,
                hintText: 'Title',
                autofocus: true,
                onSubmitted: (_) =>
                    detached('tasks', 'create task', () => _submit(targets)),
              ),
              const SizedBox(height: AbTokens.space8),
              AbMultilineField(
                controller: _body,
                hintText: 'Describe the work. This becomes the agent’s brief.',
                minLines: 3,
                maxLines: 8,
              ),
              const SizedBox(height: AbTokens.space8),
              Row(
                children: [
                  AbButton(
                    label: _labels.isEmpty
                        ? 'Labels'
                        : '${_labels.length} labels',
                    compact: true,
                    onTap: () => detached('tasks', 'pick labels', _pickLabels),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  if (candidates.isNotEmpty)
                    AbButton(
                      label: _assignee == null ? 'Unassigned' : 'Assigned to me',
                      compact: true,
                      onTap: () => setState(
                        () => _assignee = _assignee == null
                            ? TaskMemberAssignee(candidates.first.userId)
                            : null,
                      ),
                    ),
                  // Absent where the app cannot name a single project: an
                  // empty picker is a dead end, and a task with no project is
                  // the state this form has always produced.
                  if (projectNames.isNotEmpty) ...[
                    const SizedBox(width: AbTokens.space8),
                    AbButton(
                      label: projectId == null
                          ? 'No project'
                          : projectNames[projectId] ?? 'Project',
                      compact: true,
                      onTap: () => detached(
                        'tasks',
                        'pick project',
                        () => _pickProject(projectNames),
                      ),
                    ),
                  ],
                ],
              ),
              if (_labels.isNotEmpty) ...[
                const SizedBox(height: AbTokens.space8),
                Wrap(
                  spacing: AbTokens.space4,
                  runSpacing: AbTokens.space4,
                  children: [
                    for (final label in _labels)
                      AbLabelChip(label: label.name, colorHex: label.color),
                  ],
                ),
              ],
              // The form IS the confirm step: the title and body are on screen
              // being typed, next to the repo they would land in. A second
              // sheet on submit would be a confirmation of a confirmation, and
              // those get clicked through.
              if (targets.isNotEmpty) ...[
                const SizedBox(height: AbTokens.space12),
                _publishBlock(context, targets, publish),
              ],
              const SizedBox(height: AbTokens.space12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
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
                  AbButton(
                    label: 'Cancel',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: _submitting
                        ? 'Creating…'
                        : publish
                        ? 'Create task and issue'
                        : 'Create task',
                    variant: AbButtonVariant.primary,
                    onTap: _submitting
                        ? null
                        : () => detached(
                            'tasks',
                            'create task',
                            () => _submit(targets),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
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
