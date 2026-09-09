import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/task.dart';
import '../../util/detached.dart';
import '../../util/external_url.dart';

/// Where a task came from, on every surface a task appears on.
///
/// This is the visible half of the untrusted-body mitigation
/// (`docs/tasks-and-integrations-plan.md`, "A task body is untrusted input to
/// an agent"): an imported task's body was written by whoever opened the issue
/// — on a public repo, a stranger — and one Start turns that text into the
/// opening instruction to an agent holding shell access on a real checkout.
/// Delimiting the span inside the prompt is not enough on its own, because a
/// user triaging a list has to be able to tell whose words these are without
/// opening anything. These marks are the mitigation, not decoration.

/// What to call the provider in a sentence. The wire value is a registry key
/// (`github`), never something to put in front of a user unchanged.
String taskProviderLabel(Task task) {
  final key = task.externalProvider ?? task.source;
  return switch (key) {
    'github' => 'GitHub',
    'local' => 'Antgrid',
    '' => 'another tracker',
    _ => '${key[0].toUpperCase()}${key.substring(1)}',
  };
}

/// The sync state as a sentence, or null where there is nothing to say.
///
/// `synced` earns no sentence: the provenance mark already says the task is
/// linked, and a permanent "In sync" would be the one line on this block that
/// never changes.
String? taskSyncSentence(Task task) {
  final provider = taskProviderLabel(task);
  return switch (task.syncState) {
    // Says only what happened. Which side won, and the way out, belong to the
    // conflict block directly under this one — saying it twice in two
    // paragraphs reads as two different facts.
    TaskSyncState.conflict =>
      'Edited here and on $provider at the same time.',
    TaskSyncState.unlinked => 'No longer linked to $provider.',
    TaskSyncState.pending => 'Waiting to sync with $provider.',
    TaskSyncState.synced || null => null,
  };
}

/// The row marker: one glyph, no label, no second line.
///
/// A list is scanned, not read, so the state is carried by the glyph's
/// identity and spelled out in the tooltip. Only [TaskSyncState.conflict] is
/// toned — it is the one state the user has something to do about.
class TaskProvenanceMark extends StatelessWidget {
  const TaskProvenanceMark({super.key, required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    if (task.isLocal) return const SizedBox.shrink();
    final palette = context.antgrid;
    final provider = taskProviderLabel(task);
    final (icon, color, message) = switch (task.syncState) {
      // The row has no room for a control, and the mark is not one — the row
      // itself opens the task, and the sheet is where the two versions and
      // the way out of them live. So the tooltip names the destination rather
      // than leaving the state as the last word.
      TaskSyncState.conflict => (
        AbIcons.syncConflict,
        palette.warning,
        'Imported from $provider · edited in both places — open the task to '
            'settle it',
      ),
      TaskSyncState.unlinked => (
        AbIcons.syncOff,
        palette.textMuted,
        'Imported from $provider · no longer linked',
      ),
      _ => (AbIcons.openExternal, palette.textMuted, 'Imported from $provider'),
    };
    return AbTooltip(
      message: message,
      child: AbIcon(icon, size: AbTokens.iconButtonGlyph, color: color),
    );
  }
}

/// The detail view's block: who wrote this, which issue it is, and the way out
/// to it.
class TaskProvenanceBlock extends StatelessWidget {
  const TaskProvenanceBlock({super.key, required this.task, this.onOpenUrl});

  final Task task;

  /// Seam for tests; production opens the system browser.
  final Future<void> Function(BuildContext context, String url)? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    if (task.isLocal) return const SizedBox.shrink();
    final palette = context.antgrid;
    final url = task.externalUrl;
    final sync = taskSyncSentence(task);
    final open = onOpenUrl ?? openExternalUrl;

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
                AbIcons.openExternal,
                size: AbTokens.iconButtonGlyph,
                color: palette.iconMuted,
              ),
              const SizedBox(width: AbTokens.space6),
              Text(
                'Imported from ${taskProviderLabel(task)}',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: palette.textSecondary,
                ),
              ),
              // `externalKey`, never `externalId`: the id is the provider's
              // opaque handle and reads as line noise. An account service
              // older than that field sends neither, and no key is better
              // than the wrong one.
              if (task.externalKey != null) ...[
                const SizedBox(width: AbTokens.space8),
                Flexible(
                  child: Text(
                    task.externalKey!,
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
              // Absent, never disabled: a task can be linked to a provider
              // whose issue URL the import never carried, and a dead button
              // reads as a broken one.
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
                    () => open(context, url),
                  ),
                ),
            ],
          ),
          if (sync != null) ...[
            const SizedBox(height: AbTokens.space6),
            Text(
              sync,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: task.syncState == TaskSyncState.conflict
                    ? palette.warning
                    : palette.textMuted,
              ),
            ),
          ],
          const SizedBox(height: AbTokens.space6),
          Text(
            'The description below was written outside your account.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// The launch sheet's line.
///
/// The prompt text already delimits and labels the untrusted span; this says
/// the same thing in the sheet's own chrome, where a user deciding whether to
/// press Start is looking.
class TaskProvenanceNotice extends StatelessWidget {
  const TaskProvenanceNotice({super.key, required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    if (task.isLocal) return const SizedBox.shrink();
    final palette = context.antgrid;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AbIcon(
          AbIcons.openExternal,
          size: AbTokens.iconButtonGlyph,
          color: palette.warning,
        ),
        const SizedBox(width: AbTokens.space6),
        Expanded(
          child: Text(
            'The brief below quotes an issue body imported from '
            '${taskProviderLabel(task)}. It was written outside your account '
            '— read it before you start.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.warning,
            ),
          ),
        ),
      ],
    );
  }
}
