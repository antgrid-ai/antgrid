import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_select_sheet.dart';
import '../../design/widgets/ab_separator.dart';
import '../../models/task.dart';
import '../../util/detached.dart';

/// The three facts a person must see before a private note becomes a public
/// issue, and the two confirmations that show them.
///
/// Publishing is the one irreversible verb on a task — deleting a GitHub issue
/// is admin-only and the content is already in every watcher's inbox — so the
/// repo Antgrid will actually address, the exact text going out, and who will
/// be able to read it are stated at both entry points. The create form states
/// them itself (it IS the confirm step, per the plan); this file is the
/// after-the-fact path plus the pieces the form shares with it, so the two
/// cannot drift into saying different things.

/// The destination, named the way the API will address it.
///
/// `owner/name` comes from the integration's own granted-repo list, never from
/// the project's client-asserted remote — so this is what the user is
/// approving, not a label that merely resembles it.
class TaskPublishDestination extends StatelessWidget {
  const TaskPublishDestination({
    super.key,
    required this.target,
    this.tone,
  });

  final TaskPublishTarget target;

  /// Colours the repo line where the surface is already reading as armed.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AbIcon(
              AbIcons.openExternal,
              size: AbTokens.iconButtonGlyph,
              color: tone ?? palette.iconMuted,
            ),
            const SizedBox(width: AbTokens.space6),
            Flexible(
              child: Text(
                target.slug,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: tone ?? palette.textSecondary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AbTokens.space4),
        Text(
          target.visibilitySentence,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXxs,
            color: tone ?? palette.textMuted,
          ),
        ),
      ],
    );
  }
}

/// The repo picker. No preselection when several qualify — the plan's rule,
/// and the reason the confirm button stays dead until one is named.
Future<TaskPublishTarget?> pickTaskPublishTarget(
  BuildContext context,
  List<TaskPublishTarget> targets, {
  TaskPublishTarget? selected,
}) async {
  final picked = await showAbSelect<String>(
    context,
    title: 'Create the issue in',
    single: true,
    options: [
      for (final target in targets)
        AbSelectOption(
          value: target.id,
          label: target.slug,
          detail: target.visibility.isEmpty ? null : target.visibility,
        ),
    ],
    selected: {if (selected != null) selected.id},
  );
  final id = picked?.firstOrNull;
  if (id == null) return null;
  for (final target in targets) {
    if (target.id == id) return target;
  }
  return null;
}

/// The after-the-fact confirmation. Returns the repo id to publish into, or
/// null when the user backed out.
///
/// [targets] must be non-empty: the action is absent, never dead, when there
/// is nowhere to publish to.
Future<String?> showTaskPublishConfirm(
  BuildContext context, {
  required Task task,
  required List<TaskPublishTarget> targets,
}) {
  return showAbAdaptiveSheet<String>(
    context,
    child: _TaskPublishConfirmSheet(task: task, targets: targets),
  );
}

/// Unlink's confirmation.
///
/// The copy's whole job is to separate this from a delete: nothing happens to
/// the issue, and publishing again later makes a second one.
Future<bool> showTaskUnlinkConfirm(BuildContext context, Task task) {
  final issue = task.externalKey ?? 'the issue';
  return AbConfirmDialog.show(
    context: context,
    title: 'Stop syncing ${task.ref} with GitHub?',
    body:
        'Edits here stop reaching $issue, and edits there stop reaching this '
        'task. Nothing happens to the issue itself — it is not closed, '
        'deleted or changed. Publishing this task again later creates a '
        'second issue rather than restoring this link.',
    confirmLabel: 'Unlink',
  );
}

class _TaskPublishConfirmSheet extends StatefulWidget {
  const _TaskPublishConfirmSheet({required this.task, required this.targets});

  final Task task;
  final List<TaskPublishTarget> targets;

  @override
  State<_TaskPublishConfirmSheet> createState() =>
      _TaskPublishConfirmSheetState();
}

class _TaskPublishConfirmSheetState extends State<_TaskPublishConfirmSheet> {
  /// Preselected only when there is exactly one place it could go. Several
  /// means an explicit choice, so the sheet opens with nothing chosen.
  late TaskPublishTarget? _target = widget.targets.length == 1
      ? widget.targets.single
      : null;

  Future<void> _pick() async {
    final picked = await pickTaskPublishTarget(
      context,
      widget.targets,
      selected: _target,
    );
    if (picked == null || !mounted) return;
    setState(() => _target = picked);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final task = widget.task;
    final target = _target;
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
                  'Publish ${task.ref} to GitHub',
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
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AbTokens.space12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.targets.length > 1) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AbButton(
                      label: target == null
                          ? 'Choose a repo'
                          : 'Change repo',
                      compact: true,
                      onTap: () =>
                          detached('tasks', 'pick publish repo', _pick),
                    ),
                  ),
                  const SizedBox(height: AbTokens.space8),
                ],
                if (target == null)
                  Text(
                    'This project is connected to several repos. Pick the one '
                    'the issue should be created in.',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: palette.textMuted,
                    ),
                  )
                else
                  TaskPublishDestination(target: target),
                if (task.hasUnlinkedIdentity) ...[
                  const SizedBox(height: AbTokens.space8),
                  _RepublishNotice(task: task),
                ],
                const SizedBox(height: AbTokens.space12),
                Text(
                  'This is what goes out',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXxs,
                    color: palette.textMuted,
                  ),
                ),
                const SizedBox(height: AbTokens.space4),
                Container(
                  padding: const EdgeInsets.all(AbTokens.space8),
                  decoration: BoxDecoration(
                    border: Border.all(color: palette.borderDefault),
                    borderRadius: AbTokens.borderRadius5,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Mono for both, like the conflict block's values: these
                      // are the exact strings the API will send, not chrome.
                      Text(
                        task.title,
                        style: AbTokens.monoStyle(
                          fontSize: AbTokens.fontXs,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AbTokens.space6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: _bodyPreviewMaxHeight,
                        ),
                        child: SingleChildScrollView(
                          physics: const ClampingScrollPhysics(),
                          child: Text(
                            task.body.trim().isEmpty
                                ? 'No description — the issue is opened with '
                                      'the title alone.'
                                : task.body,
                            style: AbTokens.monoStyle(
                              fontSize: AbTokens.fontXxs,
                              color: task.body.trim().isEmpty
                                  ? palette.textMuted
                                  : palette.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AbTokens.space8),
                // The standing write channel, said out loud once. Publish and
                // import are the only two moments with a prompt; after this
                // every title, description and label edit reaches GitHub with
                // no further asking.
                Text(
                  'From then on, edits to the title, description, status and '
                  'labels are sent to the issue without asking again.',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXxs,
                    color: palette.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        const AbSeparator.horizontal(),
        Padding(
          padding: const EdgeInsets.all(AbTokens.space12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AbButton(
                label: 'Cancel',
                onTap: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: 'Create the issue',
                color: palette.accent,
                onTap: target == null
                    ? null
                    : () => Navigator.of(context).pop(target.id),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What a task carries after it was unlinked: an issue that still exists, is
/// still where it was, and is not the one about to be created.
class _RepublishNotice extends StatelessWidget {
  const _RepublishNotice({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final url = task.externalUrl;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AbIcon(
          AbIcons.warning,
          size: AbTokens.iconButtonGlyph,
          color: palette.warning,
        ),
        const SizedBox(width: AbTokens.space6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This creates a NEW issue. '
                '${task.externalKey ?? 'The issue this task was published to'} '
                'still exists and stays where it is.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: palette.warning,
                ),
              ),
              if (url != null) ...[
                const SizedBox(height: AbTokens.space2),
                Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXxs,
                    color: palette.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Enough for a few lines of a description with the actions still on screen on
/// a phone. Longer bodies scroll in place.
const _bodyPreviewMaxHeight = 120.0;
